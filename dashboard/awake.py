"""Local client for TD's privileged, fixed-command awake service."""
import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

SOCKET = "/var/run/com.td.awake/control.sock"
CONFIG = Path(os.environ.get("TD_CONFIG_DIR", Path.home() / ".config/td"))
DURATIONS = ("off", "1h", "4h", "24h")
SETUP_MESSAGE = "Closed-lid setup required. Run td awake setup (one macOS administrator authentication)."


def request(action, duration=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(8)
        client.connect(SOCKET)
        # Authenticate the server too: never trust a user-created lookalike socket.
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        if libc.getpeereid(client.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0 or uid.value != 0:
            raise RuntimeError("Awake service is not owned by root. Run td awake setup to repair it.")
        client.sendall((json.dumps({"action": action, "duration": duration}) + "\n").encode())
        data = b""
        while b"\n" not in data and len(data) < 8192:
            part = client.recv(8192 - len(data))
            if not part:
                break
            data += part
        result = json.loads(data)
        if not isinstance(result, dict) or "state" not in result:
            raise RuntimeError(result.get("error", "Invalid awake service response.") if isinstance(result, dict) else "Invalid awake service response.")
        # Off describes TD's ownership, not another app's global sleep setting.
        if result["state"] == "off" and result.get("message") == "Awake is off. Normal sleep restored.":
            result["message"] = "TD awake is off."
        return result


def legacy_status(config):
    """Recognize old caffeinate timers without claiming lid-close protection."""
    off = {"state": "off", "end_ts": 0, "closed_lid": False, "helper_installed": False,
           "backend": "none", "message": SETUP_MESSAGE}
    try:
        state = json.loads((Path(config) / "awake.state").read_text())
        if not isinstance(state, dict):
            return off
        pid = int(state.get("pid", 0))
        if state.get("state") not in DURATIONS[1:] or state.get("end_ts", 0) <= time.time() or pid <= 1:
            return off
        process = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True, timeout=2)
        if process.returncode or Path(process.stdout.strip()).name != "caffeinate":
            return off
        return dict(off, state=state["state"], end_ts=state["end_ts"], pid=pid,
                    backend="caffeinate", message="Legacy timer: lid must stay open. " + SETUP_MESSAGE)
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return off


def status(config=CONFIG):
    # Isolated/demo configurations must never control the machine-wide service.
    if Path(config).resolve() != (Path.home() / ".config/td").resolve():
        return legacy_status(config)
    try:
        return request("status")
    except (FileNotFoundError, ConnectionRefusedError):
        return legacy_status(config)
    except (OSError, ValueError, RuntimeError) as exc:
        return {"state": "off", "end_ts": 0, "closed_lid": False,
                "helper_installed": True, "backend": "native", "error": str(exc),
                "message": "Cannot verify closed-lid protection. Check td awake status."}


def stop_legacy(config):
    previous = legacy_status(config)
    if previous.get("pid"):
        try:
            os.kill(previous["pid"], 15)
        except ProcessLookupError:
            pass
    Path(config).mkdir(parents=True, exist_ok=True)
    (Path(config) / "awake.state").write_text('{"state":"off","end_ts":0,"pid":0}\n')


def change(duration, config=CONFIG):
    if duration not in DURATIONS:
        raise ValueError("Choose off, 1h, 4h, or 24h.")
    isolated = Path(config).resolve() != (Path.home() / ".config/td").resolve()
    if isolated:
        if duration == "off":
            stop_legacy(config)
            return status(config)
        raise RuntimeError("Closed-lid control is unavailable in an isolated TD_CONFIG_DIR.")
    try:
        result = request("off" if duration == "off" else "start", duration)
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        if duration == "off":
            stop_legacy(config)
            return status(config)
        raise RuntimeError(SETUP_MESSAGE) from exc
    if result.get("error"):
        raise RuntimeError(result["error"])
    # Only discard the legacy timer after the new backend has succeeded.
    stop_legacy(config)
    return result


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg in ("--help", "-h"):
        print("Usage: td awake [1h|4h|24h|off|status|setup|uninstall]\n"
              "No argument cycles off → 1h → 4h → 24h → off.\n"
              "Closed-lid work on AC and battery; stops at 10% battery.\n"
              "Timers continue after quitting TD. Display sleep and locking remain available.")
        return
    current = status()
    if not arg:
        arg = DURATIONS[(DURATIONS.index(current.get("state", "off")) + 1) % len(DURATIONS)]
    result = current if arg == "status" else change("off" if arg == "0" else arg)
    if result.get("error"):
        raise RuntimeError(result["error"])
    state = result.get("state", "off")
    remaining = max(0, int(result.get("end_ts", 0) - time.time()))
    suffix = f" ({remaining // 3600}:{remaining // 60 % 60:02}:{remaining % 60:02} remaining)" if state != "off" else ""
    print(f"awake: {state}{suffix}\n{result.get('message', '')}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
