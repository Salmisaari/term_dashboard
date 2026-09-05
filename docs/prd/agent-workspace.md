# Terminal workspace

## Goal
Give Johannes a calm, local home for open terminals: one next action, an accurate inventory, durable receipts, and a portable contract that lets a chosen agent navigate sessions. Edward is the proof case, including duplicate Edward terminals.

## Scope and chosen design
The native menu bar is the primary home, as clarified by the user's screenshot. Keep the existing dark two-line Quick Add panel and expand beneath it for sessions, updates, and navigator controls. A native AppKit panel talks directly to the shared Python state/bridge via structured local commands; it does not require a web server or browser. The earlier browser UI remains an optional secondary surface. The user requested independent execution, so architectural choices are made here without a confirmation gate.

Discover iTerm2 and Terminal.app plus observable TTY processes. Control supported terminal sessions by immutable instance identity, never project name. Other terminals are visible with explicit capability limits. Do not claim to supervise processes through logout/reboot; the existing timed awake control is exposed and terminal lifetimes remain with their terminal app.

## Workflow contract
Actors: human, selected navigator (any detected agent session), terminal processes, deterministic bridge, local state store.

1. Observe: bridge reads terminal metadata and process state; emits timestamped sessions with identity, provider, project, and capabilities. Poll in the background. Failure preserves the last snapshot with a stale banner and disables actions.
2. Prioritize: persisted pin, recent waiting/blocked reports, then connected sessions determine one next action. Full inventory stays available without interruptive notifications.
3. Grant: human selects an exact agent session and enables navigation. Persist a revocable token bound to that session/process instance; show awaiting check-in until an authenticated report arrives. Switching/off invalidates old tokens. Offline controllers cannot act.
4. Handoff: generate copyable provider-neutral instructions and CLI commands. Human explicitly sends the handoff only to a verified waiting agent; otherwise copy and paste in the intended agent. Never inject prompts into a busy or unverified terminal automatically.
5. Navigate: token allows bounded terminal read and focus. Terminal contents are untrusted data, never instructions. Navigator can report summaries, waiting states, evidence, and propose a prompt. It cannot approve or send its own proposals via the managed agent API.
6. Review: human sees the exact destination and prompt; delivery requires a fresh waiting report for that exact instance. Atomically claim a proposal before delivery. A timeout becomes uncertain, never auto-retried. Delivery receipt means typed into terminal, not completed work.
7. Close loop: agent publishes outcome and evidence; UI identifies agent reports as such. Human acknowledgment hides that specific update until a new report arrives. Recent history persists across restarts.

State: private SQLite database, atomic transitions, bounded event history. Live discovery recomputed; reports expire after 10 minutes and are bound to process incarnation. Snapshot actions fail closed after discovery failure. Local browser requests require an ephemeral token and exact same origin; no remote listener or shell execution endpoint. This is an application capability boundary, not an OS sandbox for agents with general filesystem/shell access.

Edward proof case: real Edward sessions auto-recognized by project folder; a clearly labeled isolated demo contains Edward coordinating development and review terminals. No Edward production stores, messages, or settings are changed.

Failure UX: retain drafts on error; immediate pending labels; retry discovery; no fabricated status; allow revocation even when discovery fails. Respect reduced motion, keyboard navigation, readable contrast, and narrow screens.

## Build list
- [x] Compact native Quick Add with inline sessions, updates, inspection, and revocable navigator.
- [x] Native structured transport; preserve provider picker, multiline drafts, awake, Caps Lock shortcut, and tiling.
- [x] Compile, exercise isolated Edward flow in AppKit, inspect rendered native panel, and install the verified app. macOS access renewal remains a human OS step.
- [x] Local state, live bridge, structured CLI and agent contract.
- [x] Calm dashboard: focus, sessions, navigator, receipts, search, pause/revoke.
- [x] Demo with isolated state and Edward walkthrough.
- [x] CLI entry points, usage docs, and optional persistent local launch service.
- [x] Regression tests for identity, expiry, revocation, races, delivery failure, HTTP isolation.
- [x] Run documented existing checks where source is available; dogfood live discovery and browser actions.

## Done criteria
Live sessions render with exact IDs; duplicate Edward sessions remain distinct. Human can focus/read, pin/acknowledge, select/revoke navigator, copy guide, and review proposals. Agent CLI can read inventory, authenticate navigation, publish reports, propose actions; disabled/stale/wrong agents are rejected. No fabricated completion. The primary UI is the 400 × 52 point native bar, expanding in place for search, session details, reports, and proposals. Native keyboard/draft/error flows and the isolated Edward AppKit walkthrough pass; live integration gaps are documented honestly.

## Verification record

- Automated workspace tests pass: identity, process incarnation, reports/expiry, navigator revocation, deterministic review, concurrency, uncertain delivery, persistence, HTTP isolation, and native macOS metadata parsing.
- Existing tiling regression: 6 assertions pass; Bash syntax and browser JavaScript syntax pass.
- Isolated Chrome walkthrough: Edward handoff/check-in, output inspection, proposal approval, delivery receipt, duplicate Edward search, pin, revoke, narrow layout, empty search, and connection interruption. No JavaScript errors; screenshots inspected at 1440 and 390 pixels.
- Live Mac: 13 terminals / 12 detected agent processes, two distinct Edward sessions, no discovery warnings, scan under two seconds. Native read and focus verified against the term_dashboard terminal without sending prompts to running agents.
- Both local services run: live 7373, isolated demo 7374. No production Edward stores or communications modified.
- Existing menu app and test-kick source are cloud-offloaded; their regressions could not be run. These files were left intact.
- The host hangs on rename operations. CLI startup disables Python bytecode writes. Git objects were recovered from the original matching remote commit and feature checkpoints recorded on codex/terminal-workspace; original offloaded index and ignore files are retained. A generated .git/index.workspace is available for index-only verification.

## Native correction and verification

- The screenshot clarified that the menu bar is the home. Added `menubar/td-workspace.swift` and a direct JSON transport; the panel requires no browser or web service.
- Preserved provider choice, multiline prompts, awake timer, Caps Lock entry, and tiling entry points. Existing-session drafts copy and open the exact terminal; agent proposals retain reviewed delivery.
- 36 Python contract checks pass. Native AppKit walkthrough passes with actual controls: duplicate Edward search, arrow/Return selection, multiline draft retention, toggle/clipboard handoff, check-in, reviewed delivery, inspection, pin, pause during a pending request, and disconnected-target recovery.
- Inspected compact, session, detail, and proposal renders. Native visual checks now render offscreen so they do not steal the user's typing focus.
- Live CLI/native adapter discovery verifies 13 agents, two distinct Edward IDs, and no warnings. The installed app's rebuilt identity needs macOS access renewed: Desktop access and Automation for iTerm2. Native preflight displays an Allow terminal access control instead of repeatedly issuing AppleEvents while consent is missing. OS consent cannot be granted by the agent.
- Both optional browser services are stopped. The native TD app is installed; its original executable was backed up at `~/.config/td/menubar-before-workspace/TD`.
- iCloud offloaded additional existing files during the work, including `lib/tile.sh` and its regression script. Earlier tiling run passed all six assertions; a fresh run cannot read those sources now. They remain intact. Menu startup and awake use independent early CLI routes.

- Final installed bundle passes `codesign --verify --strict`; the final live native render has 13 sessions, fresh state, and zero warnings. Browser services remain stopped.

- Single-click regression fixed: restore native window presentation in `show()`, and keep only snapshot rendering offscreen. The new actual status-button click check fails against the previous commit and passes after the fix; the opened panel accepts keyboard input and the Edward workflow remains green.

- Minimal main view is now an invariant: normal opening collapses prior views, background discovery/permission errors cannot expand it, and receipts use the existing session indicator. Explicit session/menu/search actions reveal the workspace. AppKit checks cover all of these transitions while retaining the selected terminal and draft.

- Independent completion audit: inventory/back navigation now retains the exact draft destination; wrapped prompts stay readable within a five-line limit; refresh preserves terminal text selection; unfinished folder searches cannot launch in the old project; late launch receipts cannot erase edited drafts. All are covered by the native interaction checks.
- Packaging the companion inside `TD.app` removes the native app's runtime dependency on the iCloud-backed checkout. Build validation exercises that standalone companion in an isolated Edward workspace before replacing the running app. Awake validation covers first use, malformed state, and stale PIDs so unrelated processes are never stopped.

- Completion checks: 40 Python tests pass, including the standalone bundled CLI, folder-access failures, and real macOS awake-process identity. The full AppKit Edward workflow passes with the compact/open/close and interruption cases. Current tiling source passes independent-display, no-main, and browser-filtering checks with window mutation mocked.

- Build staging also moved out of iCloud Desktop after Finder metadata was re-added during signing. The installer validates both the compiled entry point and the packaged runtime before stopping the existing app.

- Installed-bundle verification passed: signature, native version handshake, first-class bundled companion, Edward check-in → reviewed prompt → receipt → revoke, and handoff commands pointing inside `/Applications/TD.app`. Normal user opening remains compact. Any macOS Automation/Desktop consent remains a human OS step, reachable through the compact status indicator; it does not stop independent demo or runtime verification.

- Live load exposed an iTerm inventory regression: separate metadata AppleEvents exceeded the 12-second limit. Discovery now batches metadata, checks layout ordering, and uses one process-directory lookup. All 13 live terminals, including both Edwards, refreshed in 0.75 seconds without warnings. Exact-session actions also check TTY identity; a deliberately mismatched identity was refused, and a bounded read from the TD terminal succeeded without sending input.
- Final adapter verification covers split panes across multiple tabs/windows, duplicate names, quotes, Unicode, and process-directory association. All 41 Python tests and the full native AppKit workflow pass. Snapshot diagnostics now reject incomplete inventories as well as globally stale ones.
- Fixed an installation failure confirmed in the macOS kernel log: overwriting an executable in place left its old code signature cached. The installer now creates a fresh executable inode with `install -m 755` and validates `--version` in both staged and installed bundles. The installed app launches successfully after replacement.
