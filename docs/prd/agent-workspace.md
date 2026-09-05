# Terminal workspace

## Goal
Give Johannes a calm, local home for open terminals: one next action, an accurate inventory, durable receipts, and a portable contract that lets a chosen agent navigate sessions. Edward is the proof case, including duplicate Edward terminals.

## Scope and chosen design
Add a Python-standard-library loopback service and dependency-free browser UI alongside the Bash CLI. Preserve existing commands and the native menu app. Native-only expansion and a TUI were considered; the local web surface gives humans and any CLI agent a shared state model with fewer dependencies. The user requested independent execution, so architectural choices are made here without a confirmation gate.

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
- [ ] Local state, live bridge, structured CLI and agent contract.
- [ ] Calm dashboard: focus, sessions, navigator, receipts, search, pause/revoke.
- [ ] Demo with isolated state and Edward walkthrough.
- [ ] CLI entry points, usage docs, and optional persistent local launch service.
- [ ] Regression tests for identity, expiry, revocation, races, delivery failure, HTTP isolation.
- [ ] Run documented existing checks where source is available; dogfood live discovery and browser actions.

## Done criteria
Live sessions render with exact IDs; duplicate Edward sessions remain distinct. Human can focus/read, pin/acknowledge, select/revoke navigator, copy guide, and review proposals. Agent CLI can read inventory, authenticate navigation, publish reports, propose actions; disabled/stale/wrong agents are rejected. No fabricated completion. UI works at desktop and narrow width with empty/error states. Automated checks and browser walkthrough pass; live integration gaps are documented honestly.
