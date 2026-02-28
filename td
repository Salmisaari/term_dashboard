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
CONFIG_DIR="${HOME}/.config/td"
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

# ── Subcommand routing ──────────────────────────────────────────────

cmd="${1:-status}"
shift 2>/dev/null || true

case "$cmd" in
  status)    td_status "$@" ;;
  tile)      td_tile "$@" ;;
  go)        td_go "$@" ;;
  kick)      td_kick "$@" ;;
  start)     td_start "$@" ;;
  standup)   td_standup "$@" ;;
  label)     td_label "$@" ;;
  projects)  td_projects "$@" ;;
  help|-h|--help)
    cat <<'EOF'
td — Term Dashboard

Usage: td <command> [args]

Commands:
  status                   Show all iTerm sessions and Claude status (default)
  tile [options]           Tile iTerm windows on current Space
    --with <app>           Set main app (default: auto-detect browser)
    --no-main              No main app, full grid
    --main-size <pct>      Main app width % (default: 55)
    --all                  Tile across all Spaces
  go <project>             Focus the iTerm window running a project
  kick <project> "<prompt>" Send a prompt to a Claude session
  start <project> [...]    Open new iTerm window(s) for project(s)
  standup                  Morning overview: git, PRs, CI across projects
  label                    Set iTerm tab titles to project names
  projects                 List registered projects
  projects add <name> <path> [repo]  Register a project
  projects remove <name>   Unregister a project
  help                     Show this help
EOF
    ;;
  *)
    echo "Unknown command: $cmd (try 'td help')"
    exit 1
    ;;
esac
