# Closed-lid awake

## Goal and chosen design

Keep applications running when this Mac's lid closes, including charger changes
and battery operation. The user chose native TD support over Amphetamine on
2026-09-20, with low-battery protection.

The existing `caffeinate -d` timer only prevents idle display sleep. macOS logs
confirm Clamshell Sleep. Amphetamine's Power Protect uses the system-wide
`pmset -a disablesleep` setting; TD will own that same setting through a small,
root-owned launchd helper, without an Amphetamine dependency or sudoers changes.

## Scope and contract

- Keep the existing Off / 1h / 4h / 24h controls; permit display sleep and locking.
- Authenticate local socket clients against the installing user's UID. The helper
  accepts only status, fixed timer durations, and stop. No arbitrary commands,
  executable paths, settings, or state-file locations arrive from clients.
- Record ownership before changing system sleep. Refuse to take ownership when
  sleep was already disabled externally. Only restore settings TD owns.
- Restore sleep on expiry, Off, helper restart/termination, battery <=10% while
  unplugged, or critical thermal state. A daemon crash is recovered by launchd;
  a root-owned journal allows recovery across reboot and partial failures.
- Timers survive quitting the TD panel. Stop explicitly using Off.
- Verify the effective system setting before showing closed-lid protection.
- One administrator authentication installs the reviewed executable and launchd
  configuration. Never execute a user-writable script as a persistent root service.
- Network outages, app crashes, logout, and reboot recovery of terminal sessions
  are outside scope. Closed-lid operation needs a ventilated surface.

## Build list

1. Implement and compile the native helper, timer policy, ownership and recovery.
2. Add a local client and setup/removal flow; migrate the old timer safely.
3. Connect CLI, bundled runtime, menu status and optional browser status.
4. Exercise policy and transport failures with isolated tests.
5. Run documented backend and AppKit regressions; build/install the TD bundle.
6. Authenticate helper installation; verify real on/off/system-setting transitions.
7. Activate a timed session and verify a closed-lid process/network heartbeat with
   charger disconnect/reconnect when the user can physically perform that test.

## Done criteria

All controls share the helper's live state; missing setup is explicit. No success
is reported for a failed sleep-setting change. Timeout, low battery, critical
thermal state, restart, malformed requests, unauthorized clients and external
setting ownership are covered. Packaging includes every runtime dependency.
Physical lid/power-transition verification is reported separately from automated
checks, especially on this Mac's macOS 27 beta.

## Verification

- Implemented and installed the root-owned helper and updated TD.app. A longer
  live test caught a timeout in `pmset -g`, which also enumerates unrelated app
  assertions. The helper correctly restored sleep, but ended the timer early.
  The corrected helper reads the kernel's `SleepDisabled` property through
  IOKit directly. It passes the policy tests and 1,000 native status/battery
  reads in each actual sleep-setting state, including the on → off transition.
  The updated TD bundle includes the corrected installer/source. Installing the
  corrected helper is awaiting macOS authentication; the timer is currently off.
- 35 helper checks, 8 Python client tests, 21 native backend tests, 32 workspace
  tests, and the AppKit workflow pass. AppKit includes live control rendering and
  failure-state checks. Shell syntax, JavaScript syntax, bundle verification and
  `git diff --check` pass.
- Real helper/CLI: start sets `SleepDisabled=1`, Off restores sleep, malformed and
  unsupported socket requests fail without replacing the active session. The
  journal and executable are root-owned; only the installing UID/root can control
  the service. The client rejects an actual socket hosted by a non-root process.
- Both the repo CLI and installed app companion share live state. The old
  caffeinate timer was retired after native protection succeeded. The four-hour
  timer was ended by the status-query timeout; it will be restored after the
  corrected helper is installed.
- Restart, battery cutoff, thermal emergency, failed writes and external setting
  changes were checked through the injected system adapter; a real daemon crash
  and an actual low-battery/thermal event were not induced on the user's Mac.
- Physical lid-close/charger-change verification is pending. The temporary
  monitor at `/tmp/td-closed-lid-check.jsonl` recorded 150 samples on battery,
  zero TCP connection failures, maximum heartbeat gap 2.14 seconds, and zero
  lid-closed samples. This checks lid-open continuity, not closed-lid operation.

Commands: `bash tests/test-awake-helper.sh`, `python3 -B -I tests/test_awake.py`,
`python3 -B -I tests/test_native.py`, `python3 -B -I tests/test_workspace.py`,
`bash tests/test-menubar.sh`, `./td menubar build`, `./td awake status`.

## Operation and recovery

Use TD's Awake menu or `td awake 1h`, `4h`, `24h`, `off`, and `status`.
`td awake setup` installs the helper with macOS administrator authentication;
`td awake uninstall` restores TD-owned sleep settings before removing it.
The system-wide setting is not an automatically released process assertion. The
root-owned journal plus launchd restart provide recovery; simultaneous use of
other applications that modify the same setting should be avoided. Do not disable
or delete the daemon while its timer is active. Manual emergency recovery is
`sudo pmset -a disablesleep 0`; the helper detects the change and ends its timer.

Installed locations: `/Library/PrivilegedHelperTools/com.td.awake`,
`/Library/LaunchDaemons/com.td.awake.plist`, `/var/db/com.td.awake.json` (only while
TD owns a session), and `/var/run/com.td.awake/control.sock`.

## Research

- [Apple idle-sleep assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep): lid closure can still cause sleep.
- [Amphetamine Power Protect](https://github.com/x74353/Amphetamine-Power-Protect): benchmark for Apple Silicon power-source transitions.
- [Apple pmset source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m): system sleep and display sleep are separate settings.
- [Apple thermal guidance](https://developer.apple.com/documentation/xcode/responding-to-power-notifications): stop at critical thermal state. The 10% battery cutoff is TD policy.
