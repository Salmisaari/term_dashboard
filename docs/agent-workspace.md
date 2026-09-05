# Terminal workspace

Run `td menubar` to update and open TD in your existing menu bar. The native AppKit
panel starts at 400 × 52 points, matching the original Quick Add bar. It talks
directly to the Python workspace; no browser, web server, model API key, or package
installation is needed. Python 3.9+ and the existing Swift compiler are required.

## The human loop

- **Quick Add:** double-tap Caps Lock or click the TD grid icon. Choose a project under Desktop/Code, choose Claude/Claudex/Codex/Hermes, and enter a prompt. Return launches; Shift–Return adds a line. The existing harness launch flags are retained. Hermes starts interactively before receiving its initial prompt.
- **Sessions:** click the count chip to expand the same panel. The first number is the terminal count; the second is new updates. Search by project, provider, path, title, or TTY. Two Edward terminals remain separate rows.
- **Details:** choose a terminal, Open or Inspect it, Hold one focus, mark its update Seen, or park it for 30 minutes with Later. Existing-session drafts use **copy & open** so you can paste when the agent is ready. Drafts remain in memory when you close the panel or switch terminals; they are not persisted after quitting TD.
- **Navigation:** choose an agent terminal and turn on **Let this agent navigate**, then **Copy handoff** and paste it into that agent. Awaiting check-in means the grant is ready; Checked in means the agent used it within 90 seconds. Quiet and Disconnected are explicit. Turning on the grant does not start a hidden model worker.
- **Updates:** agent reports, recent receipts, and proposed prompts appear here. Review shows the exact destination and full prompt. Approve requires a fresh waiting report for that process instance. A receipt confirms submission; completion needs the agent's evidence.
- **Pause:** revoke the navigator from any expanded view, including during discovery or an outage. This cancels pending proposals and invalidates the old handoff; it cannot undo a prompt already delivered or interrupt work already started.
- **Awake:** the header timer holds display wakefulness for 1, 4, or 24 hours. Right-click the menu icon for tiling, optional auto-tile on Space changes, and Quit.

Keyboard: `⌘L` sessions/search, `⌘N` new terminal, `⌘R` refresh, arrows then Return
to select a search result, Shift–Return for a new prompt line, Escape to step back
or collapse. The panel restores drafts, avoids pop-up notifications and animations,
and shows failures inline. Quitting TD leaves your terminals running.

`td menubar demo` opens a separate native menu item with isolated Edward data.
The Updates tab includes **Try Edward's check-in** to exercise report → proposal →
review → receipt. Demo controls never touch your real terminals or awake timer.

## Give any agent the map

Copy the handoff from the selected terminal in the menu panel. It includes the workspace location, a revocable token, the exact controller identity, and these provider-neutral commands:

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

`td sessions` is the same structured inventory for scripts. Human CLI controls use `td session focus|read|pin|acknowledge|snooze '<ID>'`. Agent commands deliberately omit approval/delivery and navigator configuration. The native panel owns those decisions; the optional browser exposes the same controls. This is a managed application contract, not an OS sandbox: a process with general shell/filesystem access is still capable of bypassing the application.

## Terminal support and freshness

| Terminal | Discover | Focus | Inspect | Reviewed prompt |
| --- | --- | --- | --- | --- |
| iTerm2 | Yes | Yes | Yes | Detected agent + fresh waiting report |
| Terminal.app | Yes | Yes | Yes | No |
| Other local TTY shells | Process metadata | No | No | No |

Projects use iTerm's current directory when available, then process CWD, then a title label. Registered projects use the longest matching directory boundary. Agent detection uses executable identity rather than title text; Codex helper processes are excluded. A Python-hosted custom agent without a recognizable executable may appear as a shell until an adapter is added.

Native discovery runs every five seconds while the panel is open and every fifteen seconds while it is tucked away. Partial adapter failures preserve that adapter's last-known sessions as stale; actions are disabled. Global failures retain the last overview. Closed sessions leave an activity receipt. Terminal content is fetched only on inspection; the last 100 lines / 16 KB are returned with common credential patterns masked. Masking is best effort, so treat terminal content as sensitive and untrusted.

## Lifetime and local data

The native app requires no background HTTP service. Launch it normally through
`td menubar` or `/Applications/TD.app`; `td menubar stop` quits it. The build happens
before the old app is stopped. Its executable is backed up at
`~/.config/td/menubar-before-workspace/TD` on the first workspace update.

The earlier browser surface remains optional:


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
python3 -B -I tests/test_native.py
bash tests/test-menubar.sh
bash tests/test-tile.sh
bash -n td
node --check dashboard/static/app.js
```

The behavior tests cover identity, restarts, revocation, freshness, evidence, persistent notes, explicit review, duplicate/concurrent delivery, uncertain outcomes, demo isolation, and HTTP boundaries. `tests/test-workspace-browser.py` is an optional browser walkthrough using Playwright and a separate Chrome instance; it requires `pip install playwright` and Chrome. It starts its own isolated demo service and never opens or controls live terminals.

The AppKit check compiles the actual native view code, clicks its controls, and
exercises Edward's isolated workflow without a web server. It also checks duplicate
terminal search, arrow selection, multiline drafts, clipboard handoff, revocation,
and failure recovery. Native PNGs are written to `/tmp/td-native-*.png` (override
with `TD_NATIVE_ARTIFACTS`). Live prompt launch/delivery is tested with a mocked
bridge to avoid submitting unsolicited work to your agents.

The active native source is `menubar/td-workspace.swift`. The older local
`td-menubar.swift` was cloud-offloaded and could not be read; it is retained intact.
The new entry point preserves the documented Quick Add/provider/awake/tiling flow.

After a native rebuild, macOS can require renewed Desktop and Automation access.
Allow TD in the system dialog; the panel's **Allow terminal access…** button requests
access to the running terminal apps. If access was previously denied it opens
System Settings → Privacy & Security → Automation. Live controls remain paused
until that OS permission is granted. The Caps Lock global shortcut also depends
on the existing macOS input-monitoring permission for TD.
