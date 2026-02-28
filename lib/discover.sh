#!/usr/bin/env bash
# discover.sh — scan iTerm sessions, match to projects

# Get all iTerm sessions as JSON array: [{tty, name, window_id, tab_index, session_id}]
discover_sessions() {
  osascript <<'APPLESCRIPT'
    use scripting additions
    use framework "Foundation"

    tell application "iTerm2"
      set results to ""
      set winIdx to 0
      repeat with w in every window
        set winIdx to winIdx + 1
        set tabIdx to 0
        repeat with t in every tab of w
          set tabIdx to tabIdx + 1
          repeat with s in every session of t
            try
              set ttyPath to tty of s
              set sessName to name of s
              set sessId to unique ID of s
              if ttyPath is not missing value and ttyPath is not "" then
                set results to results & ttyPath & "	" & winIdx & "	" & tabIdx & "	" & sessId & "	" & sessName & linefeed
              end if
            end try
          end repeat
        end repeat
      end repeat
      return results
    end tell
APPLESCRIPT
}

# Get working directory for a TTY by finding the foreground process
get_cwd_for_tty() {
  local tty_name="$1"
  local short_tty="${tty_name#/dev/}"

  # Get the shell process on this TTY and find its cwd
  local pid
  pid="$(ps -t "$short_tty" -o pid=,comm= 2>/dev/null | awk '/zsh|bash/{print $1; exit}')"

  if [[ -z "$pid" ]]; then
    # Fallback: any process on this TTY
    pid="$(ps -t "$short_tty" -o pid= 2>/dev/null | awk 'NR==1{print $1}')"
  fi

  if [[ -n "$pid" ]]; then
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//'
  fi
}

# Check if claude is running on a TTY
is_claude_running() {
  local short_tty="${1#/dev/}"
  ps -t "$short_tty" -o comm= 2>/dev/null | grep -q claude
}

# Match a directory to a registered project name
match_project() {
  local dir="$1"
  [[ ! -f "$PROJECTS_FILE" ]] && return

  local entries name path resolved
  entries="$(jq -r 'to_entries[] | "\(.key)\t\(.value.path)"' "$PROJECTS_FILE" 2>/dev/null)"
  [[ -z "$entries" ]] && return

  while IFS=$'\t' read -r name path; do
    [[ -z "$name" ]] && continue
    resolved="$(cd "$path" 2>/dev/null && pwd)" || continue
    if [[ "$dir" == "$resolved" || "$dir" == "$resolved/"* ]]; then
      echo "$name"
      return
    fi
  done <<< "$entries"
}

# Full discovery: returns tab-separated lines
# tty | window | tab | session_id | name | cwd | project | claude_running
discover_all() {
  local raw
  raw="$(discover_sessions)"
  [[ -z "$raw" ]] && return

  while IFS=$'\t' read -r tty win tab sess_id sess_name; do
    [[ -z "$tty" ]] && continue
    local cwd project claude_status

    cwd="$(get_cwd_for_tty "$tty" 2>/dev/null)" || cwd=""
    project=""
    if [[ -n "$cwd" ]]; then
      project="$(match_project "$cwd")" || project=""
    fi

    if is_claude_running "$tty"; then
      claude_status="active"
    else
      claude_status="no"
    fi

    # Use "-" as placeholder for empty fields (bash read collapses consecutive delimiters)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$tty" "$win" "$tab" "$sess_id" "$sess_name" "${cwd:--}" "${project:--}" "$claude_status"
  done <<< "$raw"
}
