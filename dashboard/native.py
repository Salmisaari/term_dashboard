"""Typed, local transport for the native menu panel. No HTTP service required."""
from pathlib import Path
import shlex

from .bridge import run
from .core import WorkspaceError, bounded


PROVIDERS = {
    "claude": ["claude", "--dangerously-skip-permissions"],
    "claudex": ["claudex", "--dangerously-skip-permissions"],
    "codex": ["codex", "--dangerously-bypass-approvals-and-sandbox"],
    "hermes": ["hermes", "--yolo", "--cli"],
}

LAUNCH = '''
on run argv
 tell application "iTerm2"
  set w to create window with default profile
  set s to current session of w
  tell s to write text (item 1 of argv)
  if (count of argv) > 1 then
   delay 3
   tell s to write text (item 2 of argv)
  end if
  activate
 end tell
 return "Terminal opened"
end run
'''


def launch_command(folder, provider, prompt, code_dir=None):
    root = (code_dir or Path.home() / "Desktop/Code").resolve()
    if provider not in PROVIDERS:
        raise WorkspaceError("Choose Claude, Claudex, Codex, or Hermes.")
    path = Path(bounded(folder, "Folder", 2000)).expanduser().resolve()
    if not path.is_dir() or root not in path.parents:
        raise WorkspaceError("Choose an existing project inside Desktop/Code.")
    if not isinstance(prompt, str) or len(prompt) > 8000:
        raise WorkspaceError("Keep the prompt under 8,000 characters.")
    if prompt:
        bounded(prompt, "Prompt", 8000)
    # Keep the user's existing Quick Add harness flags. All user text is shell-quoted.
    argv = PROVIDERS[provider] + ([prompt] if prompt and provider != "hermes" else [])
    return "ulimit -n 65536; cd " + shlex.quote(str(path)) + " && " + shlex.join(argv)


def dispatch(work, request):
    if not isinstance(request, dict):
        raise WorkspaceError("Expected a native request object.")
    action = request.get("action", "state")
    sid = request.get("session")
    if not isinstance(action, str):
        raise WorkspaceError("Native action must be text.")
    if action in ("read", "focus", "pin", "acknowledge", "snooze") or (action == "controller" and request.get("enabled")):
        sid = bounded(sid, "Session ID", 500)
    if action in ("approve", "dismiss"):
        bounded(request.get("proposal"), "Proposal ID", 100)
    result = {}
    if action == "cached":
        pass
    elif action == "state":
        work.refresh()
    elif action == "refresh":
        work.refresh(force=True)
    elif action == "controller":
        result = work.configure_controller(sid, request.get("enabled"))
    elif action == "guide":
        result = work.guide()
    elif action in ("read", "focus"):
        result = work.session_action(sid, action)
    elif action in ("pin", "acknowledge", "snooze"):
        work.refresh()
        result = work.note(sid, action)
    elif action in ("approve", "dismiss"):
        result = work.resolve_proposal(request.get("proposal"), action)
    elif action == "awake":
        result = work.awake(request.get("duration"))
    elif action == "demo":
        result = work.demo_loop()
    elif action == "launch":
        command = launch_command(request.get("folder"), request.get("provider"), request.get("prompt", ""))
        if work.bridge.demo:
            result = {"message": "Demo: a new terminal would open. Your real terminals are unchanged."}
        else:
            # Never retry: a transport timeout may occur after iTerm creates the window.
            try:
                args = ["/usr/bin/osascript", "-e", LAUNCH, command]
                if request.get("provider") == "hermes" and request.get("prompt"):
                    args.append(request["prompt"])
                run(args)
            except Exception as exc:
                raise WorkspaceError("Launch could not be confirmed. Check iTerm before trying again. " + str(exc)) from exc
            result = {"message": "Terminal opened. Waiting for the agent to start."}
            with work.db() as conn:
                work.event(conn, "launch", None, result["message"])
    else:
        raise WorkspaceError("Unsupported native action.")
    state = work.view()
    # Folder metadata only; no recursive scans, file contents, or terminal output in polling.
    root = Path.home() / "Desktop/Code"
    try:
        folders = [{"name": p.name, "path": str(p)} for p in root.iterdir()
                   if not p.name.startswith(".") and p.is_dir()]
    except OSError:
        folders = []
    state["folders"] = sorted(folders, key=lambda p: p["name"].lower())
    return {"result": result, "state": state}
