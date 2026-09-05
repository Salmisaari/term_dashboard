"""macOS terminal adapter. Every control operation addresses an exact session."""
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


class BridgeError(RuntimeError):
    pass


def run(argv, timeout=12):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise BridgeError(f"{Path(argv[0]).name} timed out after {timeout}s. Check the terminal app and macOS Automation permission for TD.") from exc
    except OSError as exc:
        raise BridgeError(f"{Path(argv[0]).name}: {exc}") from exc
    if result.returncode:
        raise BridgeError(result.stderr.strip()[:500] or f"{argv[0]} failed")
    return result.stdout


ITERM_DISCOVERY = '''
use framework "Foundation"
use scripting additions
if application "iTerm2" is not running then return "[]"
set sessionResults to current application's NSMutableArray's array()
tell application "iTerm2"
 repeat with w in every window
  repeat with t in every tab of w
   repeat with s in every session of t
    set entry to current application's NSMutableDictionary's dictionary()
    entry's setObject:(unique ID of s) forKey:"native_id"
    entry's setObject:(tty of s) forKey:"tty"
    entry's setObject:(name of s) forKey:"name"
    entry's setObject:(id of w as text) forKey:"window"
    set sessionPath to ""
    try
     tell s to set sessionPath to variable named "path"
    end try
    if sessionPath is missing value then set sessionPath to ""
    entry's setObject:sessionPath forKey:"cwd"
    sessionResults's addObject:entry
   end repeat
  end repeat
 end repeat
end tell
set payload to current application's NSJSONSerialization's dataWithJSONObject:sessionResults options:0 |error|:(missing value)
return (current application's NSString's alloc()'s initWithData:payload encoding:4) as text
'''
TERMINAL_DISCOVERY = '''
use framework "Foundation"
use scripting additions
if application "Terminal" is not running then return "[]"
set sessionResults to current application's NSMutableArray's array()
tell application "Terminal"
 repeat with w in every window
  repeat with t in every tab of w
   set entry to current application's NSMutableDictionary's dictionary()
   entry's setObject:(tty of t) forKey:"native_id"
   entry's setObject:(tty of t) forKey:"tty"
   entry's setObject:(custom title of t) forKey:"name"
   entry's setObject:(id of w as text) forKey:"window"
   sessionResults's addObject:entry
  end repeat
 end repeat
end tell
set payload to current application's NSJSONSerialization's dataWithJSONObject:sessionResults options:0 |error|:(missing value)
return (current application's NSString's alloc()'s initWithData:payload encoding:4) as text
'''
ITERM_ACTION = '''
on run argv
 set targetID to item 1 of argv
 set actionName to item 2 of argv
 tell application "iTerm2"
  repeat with w in every window
   repeat with t in every tab of w
    repeat with s in every session of t
     if unique ID of s is targetID then
      if actionName is "read" then return contents of s
      if actionName is "focus" then
       select t
       tell s to select
       set index of w to 1
       activate
       return "Focused"
      end if
      if actionName is "send" then
       tell s to write text (item 3 of argv)
       return "Delivered"
      end if
     end if
    end repeat
   end repeat
  end repeat
 end tell
 error "Session closed before the action; refresh the workspace."
end run
'''
TERMINAL_ACTION = '''
on run argv
 set targetTTY to item 1 of argv
 set actionName to item 2 of argv
 tell application "Terminal"
  repeat with w in every window
   repeat with t in every tab of w
    if tty of t is targetTTY then
     if actionName is "read" then return contents of t
     if actionName is "focus" then
      set selected tab of w to t
      set index of w to 1
      activate
      return "Focused"
     end if
    end if
   end repeat
  end repeat
 end tell
 error "Session closed before the action; refresh the workspace."
end run
'''


def provider_for(commands, title=""):
    for provider in ("claudex", "claude", "codex", "hermes"):
        # Titles alone are not proof that an agent process is still alive.
        for command in commands:
            if Path(command).name.lower().lstrip("-") in (provider, provider + ".exe"):
                return provider
    return "shell"


def project_for(cwd, registry):
    matches = [(name, str(Path(item["path"]).expanduser())) for name, item in registry.items()
               if isinstance(item, dict) and isinstance(item.get("path"), str)]
    for name, path in sorted(matches, key=lambda pair: len(pair[1]), reverse=True):
        if cwd == path or cwd.startswith(path.rstrip("/") + "/"):
            return name
    return Path(cwd).name if cwd else "Terminal"


def redact(text):
    """Best-effort masking of common credentials; output remains local and sensitive."""
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    text = re.sub(r"(?i)((?:api[_-]?key|access[_-]?token|secret|password|authorization)\s*[:=]\s*)\S+", r"\1[redacted]", text)
    text = re.sub(r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+)\b", "[redacted]", text)
    return "\n".join(text.splitlines()[-100:])[-16000:]


class MacBridge:
    demo = False

    def __init__(self, config):
        self.config = Path(config)

    def discover(self):
        # lstart keeps a reused PID from inheriting a previous process's reports.
        process_text = run(["ps", "-axo", "pid=,ppid=,tty=,stat=,lstart=,comm="], timeout=8)
        by_tty = {}
        for line in process_text.splitlines():
            fields = line.split(None, 9)
            if len(fields) != 10 or fields[2] in ("??", "?"):
                continue
            tty = fields[2] if fields[2].startswith("tty") else "tty" + fields[2]
            by_tty.setdefault("/dev/" + tty, []).append({
                "pid": int(fields[0]), "ppid": int(fields[1]), "stat": fields[3],
                "started": " ".join(fields[4:9]), "command": fields[9]})
        sources, warnings = [], []
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [(app, pool.submit(run, ["osascript", "-e", script], 12))
                       for app, script in (("iTerm2", ITERM_DISCOVERY), ("Terminal", TERMINAL_DISCOVERY))]
            for app, future in futures:
                try:
                    rows = json.loads(future.result())
                    sources.extend(dict(row, app=app) for row in rows)
                except (BridgeError, ValueError) as exc:
                    warnings.append(f"{app} discovery unavailable: {str(exc)[:220]}")
        known_ttys = {row["tty"] for row in sources}
        for tty, processes in by_tty.items():
            if tty not in known_ttys:
                shell = next((p for p in processes if Path(p["command"]).name.lstrip("-") in ("zsh", "bash", "fish", "sh", "nu")), None)
                if shell:
                    sources.append({"native_id": tty, "tty": tty, "name": "", "window": "", "app": "Other terminal"})
        selected = {}
        for row in sources:
            processes = by_tty.get(row["tty"], [])
            agents = [p for p in processes if provider_for([p["command"]]) != "shell"]
            shells = [p for p in processes if Path(p["command"]).name.lstrip("-") in ("zsh", "bash", "fish", "sh", "nu")]
            # Prefer the deepest/newest agent over its launcher wrapper.
            selected[row["tty"]] = (max(agents, key=lambda p: p["pid"]) if agents else
                                     min(shells or processes, key=lambda p: p["pid"]) if processes else None)
        pids = {str(selected[row["tty"]]["pid"]) for row in sources if not row.get("cwd") and selected[row["tty"]]}
        cwds = {}
        if pids:
            try:
                output = run(["/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(sorted(pids)), "-d", "cwd", "-Fn"], timeout=8)
                pid = ""
                for line in output.splitlines():
                    if line.startswith("p"):
                        pid = line[1:]
                    elif line.startswith("n"):
                        cwds[pid] = line[1:]
            except BridgeError:
                warnings.append("Working directories unavailable; session IDs still identify terminals.")
        try:
            registry = json.loads((self.config / "projects.json").read_text())
            if not isinstance(registry, dict):
                registry = {}
        except (OSError, ValueError):
            registry = {}
        sessions = []
        for row in sources:
            process = selected[row["tty"]]
            cwd = row.get("cwd") or (cwds.get(str(process["pid"]), "") if process else "")
            provider = provider_for([process["command"]]) if process else "shell"
            instance = f'{process["pid"]}:{process["started"]}' if process else "unknown"
            app = row["app"]
            ident = f'{app}:{row["native_id"]}'
            if app != "iTerm2":
                ident += ":" + instance
            title_project = re.sub(r"\s+\((?:codex|claude|claudex|hermes)\)$", "", re.sub(r"^[^\w~/.]+", "", row["name"]))[:80]
            sessions.append(dict(row, id=ident, instance=instance, cwd=cwd,
                                 project=project_for(cwd, registry) if cwd else title_project or "Terminal", provider=provider,
                                 status="running" if provider != "shell" else "shell",
                                 summary="Agent process detected. Waiting for a status report." if provider != "shell" else "Shell is open.",
                                 can_focus=app != "Other terminal", can_read=app != "Other terminal",
                                 can_send=app == "iTerm2" and provider != "shell", observed_at=time.time()))
        return sessions, warnings

    def perform(self, session, action, text=""):
        if not session.get("can_" + action):
            raise BridgeError(f"{action.title()} is unavailable for this session.")
        script = ITERM_ACTION if session["app"] == "iTerm2" else TERMINAL_ACTION
        result = run(["osascript", "-e", script, session["native_id"], action, text], timeout=10)
        return redact(result) if action == "read" else result.strip()

    def awake(self, duration):
        return run([str(ROOT / "td"), "awake", duration], timeout=8).strip()


class DemoBridge:
    demo = True

    def __init__(self, config=None):
        self.calls = []
        self.sessions = []
        for i, (project, provider, status, summary) in enumerate([
            ("edward_agent", "hermes", "waiting", "Your terminal brief is ready. One decision needs you."),
            ("term_dashboard", "codex", "running", "Building the terminal workspace. Browser checks next."),
            ("penny_agent", "claude", "waiting", "Tests passed. Ready for the next task."),
            ("dev_agent", "codex", "blocked", "Needs a decision on the database migration."),
            ("finn_agent", "claude", "running", "Reviewing the API changes."),
            ("edward_agent", "codex", "shell", "A separate Edward development session.")]):
            self.sessions.append(dict(id=f"demo:{i+1}", native_id=str(i+1), instance=f"demo-process-{i+1}",
                tty=f"/dev/demo00{i}", name=project, window=str(i+1), app="Demo", cwd=f"~/Code/{project}",
                project=project, provider=provider if status != "shell" else "shell", status=status,
                summary=summary, can_focus=True, can_read=True, can_send=status != "shell", observed_at=time.time()))

    def discover(self):
        return [dict(s, observed_at=time.time()) for s in self.sessions], []

    def perform(self, session, action, text=""):
        self.calls.append((session["id"], action, text))
        if action == "read":
            return f'$ cd {session["cwd"]}\n\n{session["summary"]}\n\n[Edward demo · no live terminal output]\n'
        return "Demo focus recorded" if action == "focus" else "Demo prompt delivered"

    def awake(self, duration):
        return "Demo awake: " + duration
