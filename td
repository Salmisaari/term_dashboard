#!/usr/bin/env bash
# td — Term Dashboard: control plane for Claude Code sessions
set -euo pipefail

# Resolve symlinks to find the real script directory
_self="$0"
while [[ -L "$_self" ]]; do
  _dir="$(cd "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  [[ "$_self" != /* ]] && _self="$_dir/$_self"
done
TD_DIR="$(cd "$(dirname "$_self")" && pwd)"
CONFIG_DIR="${TD_CONFIG_DIR:-${HOME}/.config/td}"
# The workspace and agent interface share a structured local state store.
case "${1:-}" in
  dashboard|workspace|sessions|session|agent)
    exec python3 -B -I "${TD_DIR}/dashboard/cli.py" "$@"
    ;;
  menubar)
    shift
    exec bash "${TD_DIR}/menubar/launch.sh" "$@"
    ;;
  awake)
    # These native controls do not depend on discovery or tiling modules.
    mkdir -p "$CONFIG_DIR"
    source "${TD_DIR}/lib/awake.sh"
    shift
    td_awake "$@"
    exit
    ;;
esac
PROJECTS_FILE="${CONFIG_DIR}/projects.json"
SESSIONS_DIR="${CONFIG_DIR}/sessions"

# Ensure config exists
mkdir -p "$SESSIONS_DIR"
[[ -f "$PROJECTS_FILE" ]] || echo '{}' > "$PROJECTS_FILE"

# Source library files
source "${TD_DIR}/lib/discover.sh"
source "${TD_DIR}/lib/tile.sh"
source "${TD_DIR}/lib/send.sh"
source "${TD_DIR}/lib/status.sh"
source "${TD_DIR}/lib/awake.sh"

# ── Help texts ───────────────────────────────────────────────────────

show_help() {
  cat <<'EOF'
td — Term Dashboard

  Control plane for managing multiple iTerm2 + Claude Code sessions.
  Scan sessions, tile windows, send prompts, and get morning overviews.

Usage: td [command] [args]

Commands:
  dashboard    Optional browser workspace (the native home is td menubar)
  sessions     Structured live terminal inventory (JSON)
  session      Focus, read, pin, or acknowledge an exact terminal session
  agent        Portable navigator contract, reports, and proposed handoffs
  status       Show all iTerm sessions with Claude and project status
  tile         Tile iTerm windows per display (main app half, terminals fit in the rest)
  go           Focus the iTerm window running a specific project
  kick         Send a prompt to a running Claude Code session
  start        Open new iTerm window(s) for project(s)
  standup      Morning overview: git status, PRs, CI across all projects
  label        Set iTerm tab titles to project/directory names
  projects     Manage the project registry
  menubar      Launch the ⌘td menu bar app
  awake        Keep working with the lid closed (off → 1h → 4h → 24h)

Run 'td <command> --help' for details on a specific command.
EOF
}

show_help_status() {
  cat <<'EOF'
td status — Show all iTerm sessions

  Scans every iTerm session on the current machine, detects which ones
  are running Claude Code, and matches working directories to registered
  projects. If hooks are installed, also shows the last prompt sent.

Usage: td status

Example output:
  /dev/ttys004    ● Claude  pepe
  /dev/ttys003    ● Claude  ~/Desktop/Code/OKRs
  /dev/ttys002    ○ shell   ~
EOF
}

show_help_tile() {
  cat <<'EOF'
td tile — Tile iTerm windows on current Space

  Arranges iTerm windows in a grid. Only touches windows on the active
  macOS Space. Each connected display is packed on its own. If that
  display already has Chrome, Slack, or a similar main window, terminals
  fill the leftover half so they all fit.

Usage: td tile [options]

Options:
  --with <app>        Only treat this app as the main window (e.g. "Safari")
  --no-main           Full grid, ignore browsers and other main apps
  --main-size <pct>   Width used if a browser is snapped (default: 50)
  --gap <px>          Gap between windows in pixels (default: 4)

Examples:
  td tile                      Auto-detect main window, tile this Space
  td tile --no-main            Full-screen terminal grid
  td tile --main-size 60       Snap a covering browser to 60%
  td tile --with "Safari"      Only treat Safari as the main app
EOF
}

show_help_go() {
  cat <<'EOF'
td go — Focus a project's iTerm window

  Finds the iTerm session running a registered project and brings
  its window to the front.

Usage: td go <project>

Example:
  td go pepe
EOF
}

show_help_kick() {
  cat <<'EOF'
td kick — Send a prompt to a Claude Code session

  Types text into a running Claude Code session as if you typed it.
  The target session must have Claude actively running.

Usage: td kick <project> "<prompt>"

Examples:
  td kick pepe "check if CI is passing and fix any issues"
  td kick my-api "run the tests"
EOF
}

show_help_start() {
  cat <<'EOF'
td start — Open new iTerm windows for projects

  Creates a new iTerm window for each project, cd's to the project
  directory. Register projects first with 'td projects add'.

Usage: td start <project> [project ...]

Examples:
  td start pepe
  td start pepe my-api    Open two windows
EOF
}

show_help_standup() {
  cat <<'EOF'
td standup — Morning overview across all projects

  For each registered project, shows:
  - Git branch and working tree status
  - Last 3 commits
  - Open pull requests (if GitHub repo is configured)
  - CI status (if GitHub repo is configured)

Usage: td standup
EOF
}

show_help_label() {
  cat <<'EOF'
td label — Set iTerm tab titles

  Sets each iTerm session's tab title to its matched project name
  or directory basename. Sessions with Claude running get a ✳ prefix.
  Useful for quickly identifying sessions after tiling.

Usage: td label
EOF
}

show_help_projects() {
  cat <<'EOF'
td projects — Manage the project registry

  Projects map a short name to a directory path and optional GitHub
  repo. Used by status, go, kick, start, standup, and label.

Usage:
  td projects                          List all registered projects
  td projects add <name> <path> [repo] Register a project
  td projects remove <name>            Unregister a project

  The GitHub repo is auto-detected from the git remote if not provided.

Examples:
  td projects add pepe ~/Desktop/Code/Pepe_agent
  td projects add myapp ./myapp Salmisaari/myapp
  td projects remove myapp
EOF
}

show_help_awake() {
  cat <<'EOF'
td awake — Keep working with the lid closed

  Uses TD's native helper on power and battery. Stops at 10% battery.
  Timers continue after quitting TD; display sleep and locking remain available.
  One-time setup requires macOS administrator authentication.

Usage:
  td awake              Cycle: off → 1h → 4h → 24h → off
  td awake 1h           Stay awake for 1 hour
  td awake 4h           Stay awake for 4 hours
  td awake 24h          Stay awake for 24 hours
  td awake off          Disable immediately
  td awake status       Show current state + remaining time
  td awake setup        Install the native closed-lid helper
  td awake uninstall    Restore sleep and remove the helper

Examples:
  td awake              First run → 1h. Run again → 4h.
  td awake off          Cancel an active timer.
EOF
}

show_help_menubar() {
  cat <<'EOF'
td menubar — Menu bar app for quick access

  Opens the compact native terminal workspace in your top bar.
  Click the count for sessions, updates, and agent navigation.
  Double-tap Caps Lock for Quick Add; right-click for tiling.

Usage:
  td menubar           Build (if needed) and launch
  td menubar start     Same as above
  td menubar stop      Quit the menu bar app; terminals keep running
  td menubar demo      Separate, isolated Edward walkthrough
  td menubar build     Compile without replacing the running app
EOF
}

# ── Subcommand routing ──────────────────────────────────────────────

cmd="${1:-status}"
shift 2>/dev/null || true

# Check for --help on any subcommand
for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    case "$cmd" in
      status)   show_help_status ;;
      tile)     show_help_tile ;;
      go)       show_help_go ;;
      kick)     show_help_kick ;;
      start)    show_help_start ;;
      standup)  show_help_standup ;;
      label)    show_help_label ;;
      projects) show_help_projects ;;
      menubar)  show_help_menubar ;;
      awake)    show_help_awake ;;
      *)        show_help ;;
    esac
    exit 0
  fi
done

case "$cmd" in
  status)    td_status "$@" ;;
  tile)      td_tile "$@" ;;
  go)        td_go "$@" ;;
  kick)      td_kick "$@" ;;
  start)     td_start "$@" ;;
  standup)   td_standup "$@" ;;
  label)     td_label "$@" ;;
  menubar)   td_menubar "$@" ;;
  projects)  td_projects "$@" ;;
  awake)     td_awake "$@" ;;
  help|-h|--help) show_help ;;
  *)
    echo "Unknown command: $cmd (try 'td help')"
    exit 1
    ;;
esac
