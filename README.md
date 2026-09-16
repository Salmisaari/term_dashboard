# td — Term Dashboard

A control plane for managing multiple [iTerm2](https://iterm2.com) + [Claude Code](https://claude.ai/code) sessions on macOS.

Scan active sessions, tile windows, send prompts, and get morning overviews — all from one command or a menu bar click.

```
td status
/dev/ttys004    ● Claude  pepe
/dev/ttys003    ● Claude  droppe-returns
/dev/ttys002    ○ shell   ~
```

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| **macOS 11+** | Ventura/Sonoma/Sequoia recommended |
| **[iTerm2](https://iterm2.com)** | Must be installed and running |
| **Xcode Command Line Tools** | For Swift compiler (`xcode-select --install`) |
| **Bash 5+** | macOS ships with bash 3; install via `brew install bash` |
| **jq** | `brew install jq` |
| **[Homebrew](https://brew.sh)** | Recommended for installing deps |
| **Claude / Claudex / Codex / Hermes / Grok** | Optional — install the CLI you want Quick Add to launch |
| **GitHub CLI (`gh`)** | Optional — for `td standup` PR/CI status |

### Install dependencies

```bash
# Install Homebrew (if you don't have it)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required tools
brew install bash jq

# Optional: GitHub CLI for standup PR/CI integration
brew install gh && gh auth login
```

---

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/Salmisaari/term_dashboard.git
cd term_dashboard

# 2. Run the installer
./install.sh
```

The installer will:
- Create `~/bin/td` symlink pointing to the repo
- Set up the hook script at `~/.config/td/hooks/td-hook.sh`
- Optionally add Claude Code session-tracking hooks to `~/.claude/settings.json`
- Warn you if `~/bin` is not in your `PATH`

### Add `~/bin` to your PATH (if needed)

Add this to your `~/.zshrc` (or `~/.bash_profile`):

```bash
export PATH="$HOME/bin:$PATH"
```

Then reload: `source ~/.zshrc`

### Grant iTerm2 automation permission

`td` uses AppleScript to communicate with iTerm2. On first run, macOS will prompt you to allow this. If it doesn't appear automatically:

> **System Settings → Privacy & Security → Automation → Terminal (or your shell) → iTerm2** ✓

---

## Quick Start

```bash
# Register your projects (short name + path)
td projects add myapp ~/Desktop/Code/myapp
td projects add api   ~/Desktop/Code/my-api

# Check all active iTerm sessions
td status

# Tile windows on the current Space
td tile

# Send a prompt to a running Claude session
td kick myapp "run the tests and fix any failures"

# Morning overview (git + PRs + CI)
td standup
```

---

## Commands

### `td status`
Show all open iTerm sessions with Claude status and project name.

```
/dev/ttys004    ● Claude  myapp       last: "run the tests"
/dev/ttys003    ● Claude  api
/dev/ttys002    ○ shell   ~
```

---

### `td tile`
Tile all iTerm windows on the **current Space**. Each connected display is handled independently: windows stay on their current display. If that display already has a browser, Slack, or similar main window, terminals pack into the leftover half so everything fits.

```bash
td tile                        # Auto-detect main window, tile this Space
td tile --no-main              # Full-screen terminal grid
td tile --main-size 60         # If a browser is snapped, give it 60% of the display
td tile --with "Safari"        # Only treat Safari as the main app
td tile --gap 8                # 8px gaps between windows
```

Tiling layout:
- **Main window present**: terminals fill the leftover half (usually the right side)
- **No main window**: terminals use the whole display
- **Wide leftover**: terminals sit in a row; tall leftover: they stack
- **Multiple displays**: each monitor is packed on its own

---

### `td go <project>`
Focus the iTerm window running a specific project.

```bash
td go myapp
```

---

### `td kick <project> "<prompt>"`
Type a prompt into a running Claude Code session. Claude must be active in that session.

```bash
td kick myapp "check if CI is passing and fix any issues"
td kick api   "run the tests"
```

---

### `td start <project> [project ...]`
Open new iTerm window(s) for registered projects, `cd`'d into each project directory.

```bash
td start myapp
td start myapp api      # Opens two windows
```

---

### `td standup`
Morning overview for all registered projects:
- Current branch + working tree status
- Last 3 commits
- Open pull requests (requires `gh`)
- CI status (requires `gh`)

```bash
td standup
```

---

### `td label`
Set iTerm tab titles to project names. Sessions with Claude running get a `✳` prefix.

```bash
td label
```

---

### `td projects`
Manage the project registry stored at `~/.config/td/projects.json`.

```bash
td projects                              # List all
td projects add myapp ~/Desktop/Code/myapp
td projects add myapp ~/Desktop/Code/myapp owner/repo   # With GitHub repo
td projects remove myapp
```

The GitHub repo is auto-detected from the git remote if not specified.

---

### `td menubar`
Build (if needed) and launch the **⌘td** menu bar app.

```bash
td menubar          # Launch
td menubar stop     # Quit
```

**Menu bar features:**
- **Click** → Compact Quick Add bar; click its session count for the workspace
- **Right-click** → Quick Add, sessions, tiling, auto-tile, quit
- **Caps Lock double-tap** → Quick Add panel: browse `~/Desktop/Code/`, click the provider name to cycle Claude → Claudex → Codex → Hermes → Grok. Click `>` to turn it into a swap control, then click `⇄` to open the next provider in the same folder with a continue prompt from the live terminal. If that folder has several terminals, pick the one to leave from the list. The old window stays and keeps its title. Each new agent launches interactively in no-permission mode. Type multiline prompts that expand vertically
- Session rows show exact terminals and recent agent reports; a running process alone does not imply progress

The first launch compiles the Swift source — takes ~10 seconds. Subsequent launches are instant.

---

## Claude Code Integration (Hooks)

If you use Claude Code, `td` can track what each session is doing in real time. The installer offers to add hooks automatically. To add them manually:

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "~/.config/td/hooks/td-hook.sh start"}]}],
    "Stop":         [{"hooks": [{"type": "command", "command": "~/.config/td/hooks/td-hook.sh stop"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.config/td/hooks/td-hook.sh prompt"}]}]
  }
}
```

With hooks active, `td status` shows the last prompt each session received.

---

## Configuration

| Path | Purpose |
|------|---------|
| `~/.config/td/projects.json` | Project registry |
| `~/.config/td/sessions/` | Per-TTY session state (written by hooks) |
| `~/.claude/settings.json` | Claude Code hooks (optional) |

---

## Uninstall

```bash
rm ~/bin/td
rm -rf ~/.config/td
# Remove hooks from ~/.claude/settings.json if you added them
```

---

## Troubleshooting

**`td: command not found`**
Make sure `~/bin` is in your `PATH` (see installation step above) and restart your terminal.

**AppleScript permission denied**
Go to System Settings → Privacy & Security → Automation and allow your terminal app to control iTerm2.

**Menu bar app won't build**
Make sure Xcode Command Line Tools are installed: `xcode-select --install`

**`jq: command not found`**
Install with `brew install jq`.

**Sessions show wrong project**
Re-register the project with the correct path: `td projects add <name> <path>`

---

## Project Structure

```
term_dashboard/
├── td                   # Main CLI (bash)
├── install.sh           # Installer
├── lib/
│   ├── discover.sh      # iTerm session discovery
│   ├── tile.sh          # Window tiling engine
│   ├── send.sh          # Prompt sending / window focus
│   └── status.sh        # Status display, standup, project management
├── menubar/
│   ├── td-workspace.swift # Native compact workspace
│   └── launch.sh          # Build and launch the menu app
├── hooks/
│   └── td-hook.sh       # Claude Code hook script
└── tests/
    └── test-kick.sh     # Test suite
```

## Terminal workspace and agent navigation

```bash
td menubar               # Native workspace in your existing top bar
td menubar demo          # Isolated Edward walkthrough, also in the top bar
td sessions              # JSON inventory for any agent or script
```

The dark two-line bar stays compact. Click its count to see sessions and updates;
choose a terminal to inspect it, hold one focus, or enable an agent navigator.
Copy the handoff into that agent. Its reports and proposed prompts arrive in the
same panel. Pause revokes navigation; approved prompts get submission receipts.
Quick Add keeps the provider picker, multiline drafts, and awake timer.

The native app uses Python 3.9+ with no extra packages and needs no web server.
`td dashboard` remains an optional browser surface. See [the workspace guide](docs/agent-workspace.md)
for keyboard controls, the agent contract, terminal support, and verification.
