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

  osascript - "$tty" "$prompt" <<'APPLESCRIPT'
on run argv
    set targetTTY to item 1 of argv
    set promptText to item 2 of argv
    tell application "iTerm2"
        repeat with w in every window
            repeat with t in every tab of w
                repeat with s in every session of t
                    if tty of s is targetTTY then
                        tell s to write text promptText
                        return "Sent"
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return "Session not found"
end run
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

    # Get the TTY of the new session so we can send /effort max later
    local new_tty
    local title
    title="$(basename "$path")"

    new_tty="$(osascript <<APPLESCRIPT
tell application "iTerm2"
    set newWindow to (create window with default profile)
    tell current session of current tab of newWindow
        write text "cd ${path} && clear && claude --dangerously-skip-permissions"
        set name to "${title}"
        return tty
    end tell
end tell
APPLESCRIPT
    )"
    echo "Opened window for $project → $path (launching Claude Code)"

    # Background: wait for Claude to initialize, then send /effort max
    if [[ -n "$new_tty" ]]; then
      (
        sleep 6
        osascript <<APPLESCRIPT
tell application "iTerm2"
    repeat with w in every window
        repeat with t in every tab of w
            repeat with s in every session of t
                if tty of s is "${new_tty}" then
                    tell s to write text "/effort max"
                    return "Sent"
                end if
            end repeat
        end repeat
    end repeat
end tell
APPLESCRIPT
      ) &
    fi
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

  # First pass: match by registered project name
  while IFS=$'\t' read -r tty win tab sess_id sess_name cwd proj claude; do
    [[ "$proj" == "-" ]] && proj=""
    if [[ "$proj" == "$project" ]]; then
      echo "$tty"
      return
    fi
  done <<< "$all_sessions"

  # Second pass: match by folder path, prefer active Claude sessions
  local target_path
  target_path="$(cd "$HOME/Desktop/Code/$project" 2>/dev/null && pwd)" || return

  # Prefer TTY with Claude running
  while IFS=$'\t' read -r tty win tab sess_id sess_name cwd proj claude; do
    [[ "$cwd" == "-" ]] && cwd=""
    if [[ ("$cwd" == "$target_path" || "$cwd" == "$target_path/"*) && "$claude" == "active" ]]; then
      echo "$tty"
      return
    fi
  done <<< "$all_sessions"

  # Fall back to any session in that directory
  while IFS=$'\t' read -r tty win tab sess_id sess_name cwd proj claude; do
    [[ "$cwd" == "-" ]] && cwd=""
    if [[ "$cwd" == "$target_path" || "$cwd" == "$target_path/"* ]]; then
      echo "$tty"
      return
    fi
  done <<< "$all_sessions"
}
