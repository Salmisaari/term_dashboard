#!/usr/bin/env bash
# send.sh — send text to iTerm sessions, focus windows

# Focus the iTerm window/tab running a project
td_go() {
  local project="${1:?Usage: td go <project>}"
  local tty
  tty="$(find_tty_for_project "$project")"

  if [[ -z "$tty" ]]; then
    echo "No active session found for project: $project"
    return 1
  fi

  osascript <<APPLESCRIPT
tell application "iTerm2"
    repeat with w in every window
        repeat with t in every tab of w
            repeat with s in every session of t
                if tty of s is "$tty" then
                    select t
                    set index of w to 1
                    activate
                    return "Focused"
                end if
            end repeat
        end repeat
    end repeat
end tell
return "Session not found"
APPLESCRIPT
}

# Send a prompt to a Claude session running a project
td_kick() {
  local project="${1:?Usage: td kick <project> \"<prompt>\"}"
  local prompt="${2:?Usage: td kick <project> \"<prompt>\"}"
  local tty
  tty="$(find_tty_for_project "$project")"

  if [[ -z "$tty" ]]; then
    echo "No active session found for project: $project"
    return 1
  fi

  # Check that Claude is running on this TTY
  if ! is_claude_running "$tty"; then
    echo "Claude is not running in the $project session ($tty)"
    return 1
  fi

  osascript <<APPLESCRIPT
tell application "iTerm2"
    repeat with w in every window
        repeat with t in every tab of w
            repeat with s in every session of t
                if tty of s is "$tty" then
                    tell s to write text "$prompt"
                    return "Sent"
                end if
            end repeat
        end repeat
    end repeat
end tell
return "Session not found"
APPLESCRIPT
  echo "Sent prompt to $project"
}

# Open new iTerm window(s) for project(s)
td_start() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: td start <project> [project...]"
    return 1
  fi

  for project in "$@"; do
    local path
    path="$(jq -r --arg p "$project" '.[$p].path // empty' "$PROJECTS_FILE")"

    if [[ -z "$path" ]]; then
      echo "Unknown project: $project (register with 'td projects add')"
      continue
    fi

    if [[ ! -d "$path" ]]; then
      echo "Project path not found: $path"
      continue
    fi

    osascript <<APPLESCRIPT
tell application "iTerm2"
    set newWindow to (create window with default profile)
    tell current session of current tab of newWindow
        write text "cd ${path} && clear"
    end tell
    activate
end tell
APPLESCRIPT
    echo "Opened window for $project → $path"
  done
}

# Find the TTY for a project (checks live sessions first, then discovery)
find_tty_for_project() {
  local project="$1"

  # First check hook-written session files (fast path)
  for f in "${SESSIONS_DIR}"/*.json; do
    [[ -f "$f" ]] || continue
    local p
    p="$(jq -r '.project // empty' "$f" 2>/dev/null)"
    if [[ "$p" == "$project" ]]; then
      local tty
      tty="$(jq -r '.tty // empty' "$f" 2>/dev/null)"
      if [[ -e "$tty" ]]; then
        echo "$tty"
        return
      fi
    fi
  done

  # Fallback: live discovery
  local all_sessions
  all_sessions="$(discover_all 2>/dev/null)" || true
  [[ -z "$all_sessions" ]] && return

  while IFS=$'\t' read -r tty win tab sess_id sess_name cwd proj claude; do
    [[ "$proj" == "-" ]] && proj=""
    if [[ "$proj" == "$project" ]]; then
      echo "$tty"
      return
    fi
  done <<< "$all_sessions"
}
