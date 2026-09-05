#!/usr/bin/env python3
"""CLI entry point, shared by humans and agents."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser

sys.path.append(str(Path(__file__).resolve().parent.parent))
from dashboard.bridge import MacBridge, DemoBridge, BridgeError, ROOT
from dashboard.core import Workspace, WorkspaceError
from dashboard.server import Server
from dashboard.native import dispatch


def parser():
    top = argparse.ArgumentParser(prog="td", description="A local home for your terminals and agents.")
    commands = top.add_subparsers(dest="command", required=True)
    native = commands.add_parser("workspace", help="Native menu panel transport (JSON on stdin)")
    native.add_argument("--demo", action="store_true")
    dashboard = commands.add_parser("dashboard", help="Open the terminal workspace")
    dashboard.add_argument("action", nargs="?", choices=["start", "serve", "status", "stop", "install", "uninstall"], default="start")
    dashboard.add_argument("--demo", action="store_true", help="Use the isolated Edward walkthrough")
    dashboard.add_argument("--port", type=int)
    dashboard.add_argument("--no-open", action="store_true")
    sessions = commands.add_parser("sessions", help="Live inventory as JSON")
    sessions.add_argument("--demo", action="store_true")
    session = commands.add_parser("session", help="Human terminal controls")
    session.add_argument("action", choices=["read", "focus", "pin", "acknowledge", "snooze"])
    session.add_argument("session")
    session.add_argument("--demo", action="store_true")
    agent = commands.add_parser("agent", help="Provider-neutral coordination contract")
    agent.add_argument("action", choices=["context", "guide", "check", "focus", "read", "report", "propose"])
    agent.add_argument("session", nargs="?")
    agent.add_argument("--status", choices=["running", "waiting", "blocked", "done"])
    agent.add_argument("--summary", default="")
    agent.add_argument("--evidence", default="")
    agent.add_argument("--prompt", default="")
    agent.add_argument("--reason", default="")
    agent.add_argument("--token", default=os.environ.get("TD_AGENT_TOKEN", ""), help="Prefer TD_AGENT_TOKEN to avoid storing the token in shell history")
    agent.add_argument("--demo", action="store_true")
    return top


def healthy(url, demo):
    try:
        with urllib.request.urlopen(url + "/health", timeout=1) as response:
            data = json.load(response)
        return data.get("app") == "term-dashboard" and data.get("demo") is demo
    except Exception:
        return False


def launch(args, config):
    port = args.port or (7374 if args.demo else 7373)
    if not 1024 <= port <= 65535:
        raise WorkspaceError("Choose a port between 1024 and 65535.")
    url = f"http://127.0.0.1:{port}"
    lockpath = config / ("dashboard-demo.lock" if args.demo else "dashboard.lock")
    if args.action == "status":
        print(json.dumps({"running": healthy(url, args.demo), "url": url, "demo": args.demo}))
        return
    if args.action == "stop":
        try:
            pid = int(lockpath.read_text().strip())
        except (OSError, ValueError) as exc:
            raise WorkspaceError("No service PID is recorded for this workspace.") from exc
        command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
        if str(Path(__file__).resolve()) not in command or " dashboard serve " not in command:
            raise WorkspaceError("The recorded service is no longer running.")
        os.kill(pid, signal.SIGTERM)
        print("Dashboard stopped. Your terminal sessions continue.")
        return
    serve_args = [sys.executable, "-B", "-I", str(Path(__file__).resolve()), "dashboard", "serve", "--port", str(port), "--no-open"]
    if args.demo:
        serve_args.append("--demo")
    if args.action in ("install", "uninstall"):
        if args.demo:
            raise WorkspaceError("The demo is not installed at login.")
        label = "local.term-dashboard.workspace"
        plist = Path.home() / "Library/LaunchAgents" / (label + ".plist")
        target = f"gui/{os.getuid()}"
        if args.action == "uninstall":
            subprocess.run(["launchctl", "bootout", target + "/" + label], capture_output=True)
            plist.unlink(missing_ok=True)
            print("Dashboard login service removed. Terminal sessions are unchanged.")
            return
        if healthy(url, args.demo):
            raise WorkspaceError("Stop the current dashboard with 'td dashboard stop', then run 'td dashboard install'.")
        plist.parent.mkdir(parents=True, exist_ok=True)
        with plist.open("wb") as file:
            plistlib.dump({"Label": label, "ProgramArguments": serve_args, "RunAtLoad": True,
                "KeepAlive": True, "ThrottleInterval": 10, "WorkingDirectory": str(ROOT),
                "EnvironmentVariables": {"TD_CONFIG_DIR": str(config), "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
                "StandardOutPath": str(config / "dashboard.log"), "StandardErrorPath": str(config / "dashboard.log")}, file)
        result = subprocess.run(["launchctl", "bootstrap", target, str(plist)], capture_output=True, text=True)
        if result.returncode:
            raise WorkspaceError("Login configuration written; launchctl could not load it: " + result.stderr.strip())
        print("Dashboard will open its local service at login: " + url)
        return
    if args.action == "start":
        if not healthy(url, args.demo):
            logfile = config / ("dashboard-demo.log" if args.demo else "dashboard.log")
            with logfile.open("ab") as log:
                process = subprocess.Popen(serve_args, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            for _ in range(60):
                if healthy(url, args.demo):
                    break
                if process.poll() is not None:
                    raise WorkspaceError(f"The dashboard could not start. Check {logfile}")
                time.sleep(0.25)
            else:
                raise WorkspaceError(f"Dashboard is still starting. Check {logfile}")
        if not args.no_open:
            webbrowser.open(url)
        print(url)
        return
    bridge = DemoBridge(config) if args.demo else MacBridge(config)
    work = Workspace(config, bridge)
    with lockpath.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise WorkspaceError("A dashboard service is already running for this workspace.") from exc
        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()))
        lock.flush()
        with Server(("127.0.0.1", port), work) as server:
            worker = threading.Thread(target=server.poll, daemon=True)
            worker.start()
            print(url, flush=True)
            if not args.no_open:
                webbrowser.open(url)
            def stop(signum, frame):
                server.stopping.set()
                threading.Thread(target=server.shutdown, daemon=True).start()
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            try:
                server.serve_forever()
            finally:
                server.stopping.set()


def main():
    os.umask(0o077)
    args = parser().parse_args()
    config = Path(os.environ.get("TD_CONFIG_DIR", str(Path.home() / ".config/td"))).expanduser().resolve()
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        if args.command == "dashboard":
            launch(args, config)
            return
        work = Workspace(config, DemoBridge(config) if args.demo else MacBridge(config))
        if args.command == "workspace":
            payload = sys.stdin.read(20001)
            if len(payload) > 20000:
                raise WorkspaceError("Native request is too large.")
            try:
                request = json.loads(payload or "{}")
            except ValueError as exc:
                raise WorkspaceError("Invalid native request JSON.") from exc
            result = dispatch(work, request)
        elif args.command == "sessions":
            result = work.view(refresh=True)
        elif args.command == "session":
            if args.action in ("focus", "read"):
                result = work.session_action(args.session, args.action)
            else:
                work.refresh()
                result = work.note(args.session, args.action)
        elif args.action == "context":
            result = work.view(refresh=True)
        elif args.action == "guide":
            result = work.guide()
        elif args.action == "check":
            result = work.check(args.token)
        else:
            if not args.session:
                raise WorkspaceError("Provide the exact session ID from td agent context.")
            if args.action in ("focus", "read"):
                result = work.session_action(args.session, args.action, token=args.token)
            elif args.action == "report":
                result = work.report(args.session, args.status, args.summary, args.evidence, args.token)
            else:
                result = work.propose(args.session, args.prompt, args.reason, args.token)
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except (WorkspaceError, BridgeError, OSError) as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
