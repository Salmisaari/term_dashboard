#!/usr/bin/env bash
# td-hook.sh — Claude Code hook that writes session state
# Called by Claude Code hooks: SessionStart, Stop, UserPromptSubmit
#
# Environment variables from Claude Code hooks:
#   CLAUDE_SESSION_ID, CLAUDE_PROJECT_DIR, etc.
# Stdin: JSON with hook-specific data

set -euo pipefail

SESSIONS_DIR="${HOME}/.config/td/sessions"
PROJECTS_FILE="${HOME}/.config/td/projects.json"
mkdir -p "$SESSIONS_DIR"

event="${1:-unknown}"

# Determine TTY
tty_path="$(tty 2>/dev/null || echo "")"
if [[ -z "$tty_path" ]]; then
  # Try to get from parent process
  tty_path="$(ps -o tty= -p $PPID 2>/dev/null | sed 's/^/\/dev\//' || echo "")"
fi

if [[ -z "$tty_path" || "$tty_path" == "/dev/" ]]; then
  exit 0  # Can't determine TTY, skip silently
fi

tty_file="${SESSIONS_DIR}/$(basename "$tty_path").json"

# Get working directory
cwd="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Match to project
project=""
if [[ -f "$PROJECTS_FILE" ]]; then
  project=$(jq -r --arg d "$cwd" '
    to_entries[] |
    select(.value.path as $p | $d | startswith($p)) |
    .key
  ' "$PROJECTS_FILE" 2>/dev/null | sed -n '1p')
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$event" in
  start)
    jq -n \
      --arg tty "$tty_path" \
      --arg project "$project" \
      --arg cwd "$cwd" \
      --arg updated "$timestamp" \
      '{tty: $tty, project: $project, cwd: $cwd, status: "active", lastPrompt: "", updated: $updated}' \
      > "$tty_file"
    ;;

  stop)
    if [[ -f "$tty_file" ]]; then
      jq --arg updated "$timestamp" \
        '.status = "stopped" | .updated = $updated' \
        "$tty_file" > "${tty_file}.tmp" && mv "${tty_file}.tmp" "$tty_file"
    fi
    ;;

  prompt)
    # Read prompt from stdin (Claude Code passes hook data as JSON on stdin)
    prompt_text=""
    if read -r -t 1 input_json 2>/dev/null; then
      prompt_text="$(echo "$input_json" | jq -r '.prompt // .input // empty' 2>/dev/null || echo "")"
    fi

    if [[ -f "$tty_file" ]]; then
      jq --arg updated "$timestamp" --arg prompt "$prompt_text" \
        '.status = "active" | .lastPrompt = $prompt | .updated = $updated' \
        "$tty_file" > "${tty_file}.tmp" && mv "${tty_file}.tmp" "$tty_file"
    else
      jq -n \
        --arg tty "$tty_path" \
        --arg project "$project" \
        --arg cwd "$cwd" \
        --arg updated "$timestamp" \
        --arg prompt "$prompt_text" \
        '{tty: $tty, project: $project, cwd: $cwd, status: "active", lastPrompt: $prompt, updated: $updated}' \
        > "$tty_file"
    fi
    ;;
esac
