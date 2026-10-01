#!/bin/bash
# Compile unprivileged, then install only the binary and fixed launchd job.
set -euo pipefail
awake_root="$(cd "$(dirname "$0")/.." && pwd)"
awake_action="${1:-setup}"
case "$awake_action" in setup|uninstall) ;; *) exit 1 ;; esac
if [[ "$(id -u)" == 0 ]]; then
  echo 'Run td awake setup as your normal user; macOS will request authentication.' >&2; exit 1
fi
if [[ "${TD_CONFIG_DIR:-$HOME/.config/td}" != "$HOME/.config/td" ]]; then
  echo 'Run awake setup from your normal TD configuration.' >&2; exit 1
fi
awake_build="$(mktemp -d /tmp/td-awake-install.XXXXXX)"
trap 'rm -rf "$awake_build"' EXIT
if [[ "$awake_action" == setup ]]; then
  echo 'Building closed-lid awake helper…'
  swiftc "$awake_root/menubar/td-awake.swift" -o "$awake_build/td-awake" -framework IOKit
  codesign --verify "$awake_build/td-awake"
  [[ "$("$awake_build/td-awake" --version)" == 'TD awake helper 1.0' ]]
else
  python3 -B -I "$awake_root/dashboard/awake.py" off
fi
python3 -B -I - "$awake_build" "$awake_action" <<'PY'
import os, pathlib, plistlib, shlex, subprocess, sys
stage = pathlib.Path(sys.argv[1])
executable = '/Library/PrivilegedHelperTools/com.td.awake'
job = '/Library/LaunchDaemons/com.td.awake.plist'
label = 'system/com.td.awake'
if sys.argv[2] == 'setup':
    (stage/'com.td.awake.plist').write_bytes(plistlib.dumps({
        'Label': 'com.td.awake', 'ProgramArguments': [executable, '--daemon', str(os.getuid())],
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 2,
        'ProcessType': 'Background', 'UserName': 'root', 'Umask': 0o077,
    }))
    commands = [
        '/bin/launchctl bootout '+label+' 2>/dev/null || true',
        '/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools',
        '/usr/bin/install -o root -g wheel -m 755 '+shlex.quote(str(stage/'td-awake'))+' '+executable,
        '/usr/bin/install -o root -g wheel -m 644 '+shlex.quote(str(stage/'com.td.awake.plist'))+' '+job,
        '/bin/launchctl bootstrap system '+job,
    ]
else:
    commands = [
        '/bin/launchctl bootout '+label+' 2>/dev/null || true',
        'if [ -f /var/db/com.td.awake.json ]; then /bin/launchctl bootstrap system '+job+'; echo "Sleep recovery pending; helper retained." >&2; exit 1; fi',
        '/bin/rm -f '+executable+' '+job,
        '/bin/rm -f /var/run/com.td.awake/control.sock',
        '/bin/rmdir /var/run/com.td.awake 2>/dev/null || true',
    ]
command = 'set -eu\n'+'\n'.join(commands)
print('macOS will request administrator authentication for the TD awake helper.', flush=True)
result = subprocess.run(['/usr/bin/osascript', '-e', 'on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run', command], capture_output=True, text=True)
if result.returncode:
    if '(-128)' in result.stderr:
        message = 'Setup cancelled. The existing helper and awake session were left unchanged.' if sys.argv[2] == 'setup' else 'Removal cancelled. The helper remains installed; Awake is off.'
        raise SystemExit(message)
    raise SystemExit(result.stderr.strip() or 'Awake setup failed.')
PY
if [[ "$awake_action" == setup ]]; then
  for attempt in {1..20}; do
    [[ -S /var/run/com.td.awake/control.sock ]] && break
    sleep 0.25
  done
  python3 -B -I - "$awake_root" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from dashboard.awake import request
state = request('status')
if not state.get('helper_installed') or state.get('error'):
    raise SystemExit(state.get('error') or 'Awake helper did not start.')
print(state['message'])
PY
  echo 'Closed-lid helper installed. Start a timer from TD or run td awake 4h.'
else
  echo 'Closed-lid helper removed. Normal sleep is available.'
fi
