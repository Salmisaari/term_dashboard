## [2026-09-16] fix | Swap keeps a preselected destination agent

Clicking `>` / ⇄ no longer advances Claude → Claudex → … . The provider already on the bar is the hop target. Choosing which terminal to leave also leaves that destination alone.

## [2026-09-16] fix | Tile packs each monitor around browser/Slack halves

`td tile` now treats Slack and other large apps as the main window, not only Chrome. Each display keeps its own windows; terminals fill the leftover half so they all fit. Tiny Chrome popups and fullscreen overlays are ignored.

## [2026-09-16] fix | Swap copies the Window Title field onto the new iTerm window

iTerm's window `name` is read-only, so swap only filled Session Name and the bar still showed the agent status line. Swap now writes Edit Session → Window Title (`titleOverrideFormat`) on the new window, using the old window's override or its short session name (d2c_invoicing, hiring).

## [2026-09-16] feature | Grok launch + click-to-cycle providers

Quick Add now launches Grok (`grok --always-approve`) alongside Claude/Claudex/Codex/Hermes. Clicking the provider name advances to the next agent; `>` still opens the picker.

## [2026-09-16] feature | One-click provider swap with continue prompt

`>` arms a swap (`⇄`). The second click opens the next provider in the same folder with a compact recap from the live terminal (and `NEXT_SESSION.md` when present). The previous window is left running.

## [2026-09-16] feature | Swap copies the source window title

A provider swap names the new iTerm window after the old one (e.g. `hiring`), so the title does not have to be set by hand.

## [2026-09-16] fix | Swap picker shows iTerm window titles

When several agents share a repo, session rows show the window title (hiring, receipts) instead of repeating the folder name.

## [2026-09-16] feature | Swap picker when a repo has several terminals

Arming swap on a folder with more than one live agent opens a short list. Click the terminal to leave, then `⇄`. A single match still hops from the compact bar.

## [2026-09-16] feature | Grok launches stay in compact mode

TD pins `[ui] compact_mode = true` before starting Grok. `/compact-mode` is a toggle and there is no CLI flag, so config is the always-on switch.
