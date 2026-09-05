# Terminal workspace

Run `td dashboard` to open a local workspace at <http://127.0.0.1:7373>.
It runs in the background and needs Python 3.9+; there are no packages to install.
Run `td dashboard --demo` for the isolated Edward walkthrough at port 7374.

## The human loop

- **Overview:** one next action, your chosen focus, five nearby sessions, and a few recent receipts.
- **All terminals:** search by project, provider, path, title, or TTY. Each terminal has its own identity, including two terminals in the same Edward project.
- **Terminal details:** open its native window, inspect bounded visible output, pin it as your focus, or acknowledge its latest report. Parking for 30 minutes also releases a pin.
- **Navigator:** select an agent terminal and enable navigation. Copy the generated handoff into that exact agent. “Ready” means access is enabled; “Connected” means the agent checked in in the last 90 seconds. “Quiet” means its check-in is older. Enabling access does not start a model worker.
- **Activity:** review proposed prompts with their exact destination and text. Approve sends only to an agent with a fresh `waiting` report for the same process instance. A successful delivery is a submission receipt, not a claim that the task finished.

Navigation can always be paused, including during a discovery outage. Pausing or switching the navigator revokes the previous token and cancels its pending proposals. It cannot undo an already delivered prompt or interrupt work an agent already started.

Keyboard: `1` overview, `2` terminals, `3` activity, `/` search, `Esc` close a dialog. Shortcuts leave text entry alone. Reduced-motion preferences are respected.

## Give any agent the map

Copy the handoff from the dashboard. It includes the workspace location, a revocable token, the exact controller identity, and these provider-neutral commands:

```bash
td agent context                           # timestamped inventory, reports, proposals, receipts
td agent check                             # validate access and check in
td agent read '<exact session ID>'          # bounded terminal content, marked untrusted
td agent focus '<exact session ID>'         # focus that native session
td agent report '<ID>' --status running --summary 'Checking the result'
td agent report '<ID>' --status waiting --summary 'Input prompt is ready' --evidence 'Observed terminal prompt'
td agent report '<ID>' --status done --summary 'Tests pass' --evidence '24 passed; command and result'
td agent propose '<ID>' --prompt 'Proposed next task' --reason 'Why this helps'
```

Agent controls use `TD_AGENT_TOKEN` from the handoff. Prefer the environment variable to `--token`, which can appear in shell history. Reports expire after ten minutes and are invalidated when the target process restarts. A process being alive does not prove progress or readiness. `done` requires evidence, and the UI identifies whose report it is.

The handoff asks the navigator to inspect at most six sessions in its first pass, surface one next action, and stop when a decision is needed. Continued watching requires a user instruction and check-ins at least once a minute. There is no hidden recurring model call, provider API key, or automatic outbound messaging.

`td sessions` is the same structured inventory for scripts. Human CLI controls use `td session focus|read|pin|acknowledge|snooze '<ID>'`. Agent commands deliberately omit approval/delivery and navigator configuration. The browser owns those decisions. This is a managed application contract, not an OS sandbox: a process with general shell/filesystem access is still capable of bypassing the application.

## Terminal support and freshness

| Terminal | Discover | Focus | Inspect | Reviewed prompt |
| --- | --- | --- | --- | --- |
| iTerm2 | Yes | Yes | Yes | Detected agent + fresh waiting report |
| Terminal.app | Yes | Yes | Yes | No |
| Other local TTY shells | Process metadata | No | No | No |

Projects use iTerm's current directory when available, then process CWD, then a title label. Registered projects use the longest matching directory boundary. Agent detection uses executable identity rather than title text; Codex helper processes are excluded. A Python-hosted custom agent without a recognizable executable may appear as a shell until an adapter is added.

Discovery runs every five seconds. Partial adapter failures preserve that adapter's last-known sessions as stale; actions are disabled. Global failures retain the last overview. Closed sessions leave an activity receipt. Terminal content is fetched only on inspection; the last 100 lines / 16 KB are returned with common credential patterns masked. Masking is best effort, so treat terminal content as sensitive and untrusted.

## Lifetime and local data

```bash
td dashboard status           # service health and URL
td dashboard stop             # stop dashboard; terminal processes continue
td dashboard serve --no-open  # foreground, useful for debugging
td dashboard install          # optional launchd service, restart at login/crash
td dashboard uninstall        # remove launchd service
```

Stop a manually started dashboard before installing the login service. The login service's KeepAlive restarts it if stopped; use `uninstall` to disable that service. This supervises the dashboard only. Terminal apps own terminal processes. The Keep awake selector uses the existing `td awake` timer; neither it nor this dashboard restores terminals after logout/reboot.

Data stays in `~/.config/td/` (override with `TD_CONFIG_DIR`):

- `workspace.sqlite3`: reports, focus, acknowledgment/snooze, navigator grant, proposals, and up to 500 activity receipts.
- `workspace-demo.sqlite3`: independent Edward example state. Demo actions never call a native terminal or change Edward production data.
- `dashboard.log` / `dashboard-demo.log`: service startup output; no terminal transcripts or prompts are logged.
- `dashboard.lock` / `dashboard-demo.lock`: one service per workspace/mode, with its process ID.

The HTTP service binds to `127.0.0.1` only. Requests require the exact Host, same Origin if supplied, and a per-server browser token. No CORS access, remote listener, arbitrary shell execution endpoint, CDN, analytics, or cloud model service is used.

## Verification

```bash
python3 -B -I tests/test_workspace.py
bash tests/test-tile.sh
bash -n td
node --check dashboard/static/app.js
```

The behavior tests cover identity, restarts, revocation, freshness, evidence, persistent notes, explicit review, duplicate/concurrent delivery, uncertain outcomes, demo isolation, and HTTP boundaries. `tests/test-workspace-browser.py` is an optional browser walkthrough using Playwright and a separate Chrome instance; it requires `pip install playwright` and Chrome. It starts its own isolated demo service and never opens or controls live terminals.
