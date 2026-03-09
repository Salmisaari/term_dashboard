#!/usr/bin/env bash
# status.sh — display session states, label sessions, project overviews

# Show all iTerm sessions with project and Claude status
td_status() {
  echo "Scanning iTerm sessions..."
  echo ""

  local output
  output="$(discover_all 2>/dev/null)"

  if [[ -z "$output" ]]; then
    echo "  No iTerm sessions found."
    echo ""
    return
  fi

  while IFS=$'\t' read -r tty win tab sess_id sess_name cwd project claude; do
    [[ -z "$tty" ]] && continue
    # Restore empty fields from "-" placeholder
    [[ "$cwd" == "-" ]] && cwd=""
    [[ "$project" == "-" ]] && project=""
    local label

    if [[ -n "$project" ]]; then
      label="$project"
    elif [[ -n "$cwd" ]]; then
      label="${cwd/#$HOME/~}"
    else
      label="(unknown)"
    fi

    # Claude indicator
    local indicator
    if [[ "$claude" == "active" ]]; then
      indicator="● Claude"
    else
      indicator="○ shell"
    fi

    # Check for hook-written status
    local hook_status=""
    local tty_file="${SESSIONS_DIR}/$(basename "$tty").json"
    if [[ -f "$tty_file" ]]; then
      local task
      task="$(jq -r '.lastPrompt // empty' "$tty_file" 2>/dev/null)"
      if [[ -n "$task" ]]; then
        if [[ ${#task} -gt 50 ]]; then
          task="${task:0:47}..."
        fi
        hook_status=" → $task"
      fi
    fi

    printf "  %-14s  %-10s  %-30s%s\n" "$tty" "$indicator" "$label" "$hook_status"
  done <<< "$output"
  echo ""
}

# Morning standup overview across all projects
td_standup() {
  if [[ ! -f "$PROJECTS_FILE" ]] || [[ "$(jq 'length' "$PROJECTS_FILE")" == "0" ]]; then
    echo "No projects registered. Use 'td projects add <name> <path>' first."
    return 1
  fi

  local entries
  entries="$(jq -r 'to_entries[] | "\(.key)\t\(.value.path)\t\(.value.repo // "")"' "$PROJECTS_FILE")"

  while IFS=$'\t' read -r name path repo; do
    [[ -z "$name" ]] && continue

    if [[ ! -d "$path" ]]; then
      echo "── $name ── (path not found: $path)"
      echo ""
      continue
    fi

    local branch
    branch="$(git -C "$path" branch --show-current 2>/dev/null || echo "?")"
    echo "── $name ($branch) ──────────────────────────"

    # Working tree status
    local status_output
    status_output="$(git -C "$path" status --short 2>/dev/null)" || true
    if [[ -z "$status_output" ]]; then
      echo "  ✓ clean working tree"
    else
      local count
      count="$(echo "$status_output" | wc -l | tr -d ' ')"
      echo "  ⚠ $count file(s) modified"
    fi

    # Recent commits
    local log_output
    log_output="$(git -C "$path" log --oneline -3 2>/dev/null)" || true
    if [[ -n "$log_output" ]]; then
      echo "  Recent:"
      while read -r line; do
        echo "    $line"
      done <<< "$log_output"
    fi

    # Open PRs (if repo is set)
    if [[ -n "$repo" ]]; then
      local prs
      prs="$(gh pr list -R "$repo" --limit 5 --json number,title 2>/dev/null)" || true
      if [[ -n "$prs" && "$prs" != "[]" ]]; then
        echo "  PRs:"
        echo "$prs" | jq -r '.[] | "    #\(.number) \(.title)"' 2>/dev/null || true
      fi

      # CI status
      local runs
      runs="$(gh run list -R "$repo" --limit 3 --json status,conclusion,name,headBranch 2>/dev/null)" || true
      if [[ -n "$runs" && "$runs" != "[]" ]]; then
        echo "  CI:"
        echo "$runs" | jq -r '.[] |
          (if .conclusion == "success" then "✓"
           elif .conclusion == "failure" then "✗"
           elif .status == "in_progress" then "…"
           else "?" end) as $icon |
          "    \($icon) \(.name) (\(.headBranch))"' 2>/dev/null || true
      fi
    fi

    echo ""
  done <<< "$entries"
}

# Manage project registry
td_projects() {
  local subcmd="${1:-list}"
  shift 2>/dev/null || true

  case "$subcmd" in
    list)
      if [[ "$(jq 'length' "$PROJECTS_FILE" 2>/dev/null)" == "0" ]]; then
        echo "No projects registered. Use 'td projects add <name> <path>' to add one."
        return
      fi
      echo "Registered projects:"
      echo ""
      jq -r 'to_entries[] | "  \(.key)\t\(.value.path)\t\(.value.repo // "")"' "$PROJECTS_FILE" | \
        column -t -s $'\t'
      echo ""
      ;;
    add)
      local name="${1:?Usage: td projects add <name> <path> [repo]}"
      local path="${2:?Usage: td projects add <name> <path> [repo]}"
      local repo="${3:-}"

      # Resolve to absolute path
      path="$(cd "$path" 2>/dev/null && pwd)" || {
        echo "Path not found: $2"
        return 1
      }

      # Auto-detect repo from git remote if not provided
      if [[ -z "$repo" ]]; then
        repo="$(git -C "$path" remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\(.*\)\.git$/\1/' | sed 's/.*github\.com[:/]\(.*\)$/\1/')" || repo=""
      fi

      local tmp
      tmp="$(jq --arg n "$name" --arg p "$path" --arg r "$repo" \
        '.[$n] = {path: $p, repo: $r}' "$PROJECTS_FILE")"
      echo "$tmp" > "$PROJECTS_FILE"
      echo "Added project: $name → $path"
      [[ -n "$repo" ]] && echo "  repo: $repo"
      ;;
    remove|rm)
      local name="${1:?Usage: td projects remove <name>}"
      if jq -e --arg n "$name" '.[$n]' "$PROJECTS_FILE" >/dev/null 2>&1; then
        local tmp
        tmp="$(jq --arg n "$name" 'del(.[$n])' "$PROJECTS_FILE")"
        echo "$tmp" > "$PROJECTS_FILE"
        echo "Removed project: $name"
      else
        echo "Project not found: $name"
        return 1
      fi
      ;;
    *)
      echo "Unknown subcommand: $subcmd (try 'list', 'add', 'remove')"
      return 1
      ;;
  esac
}

# Label all iTerm sessions with project name / directory
td_label() {
  echo "Labeling iTerm sessions..."

  local output
  output="$(discover_all 2>/dev/null)"
  [[ -z "$output" ]] && { echo "  No sessions found."; return; }

  local count=0
  while IFS=$'\t' read -r tty win tab sess_id sess_name cwd project claude; do
    [[ -z "$tty" ]] && continue
    [[ "$cwd" == "-" ]] && cwd=""
    [[ "$project" == "-" ]] && project=""

    # Build a label: project name, or short dirname, with Claude indicator
    local label
    if [[ -n "$project" ]]; then
      label="$project"
    elif [[ -n "$cwd" ]]; then
      label="$(basename "$cwd")"
    else
      continue
    fi

    if [[ "$claude" == "active" ]]; then
      label="✳ ${label}"
    fi

    # Set the iTerm session name via AppleScript
    osascript <<APPLESCRIPT 2>/dev/null
tell application "iTerm2"
    repeat with w in every window
        repeat with t in every tab of w
            repeat with s in every session of t
                if unique ID of s is "$sess_id" then
                    set name of s to "$label"
                    return
                end if
            end repeat
        end repeat
    end repeat
end tell
APPLESCRIPT
    count=$((count + 1))
    echo "  $tty → $label"
  done <<< "$output"
  echo "Labeled $count sessions."
}

# Build and launch the menu bar app
td_menubar() {
  local subcmd="${1:-start}"

  local src="${TD_DIR}/menubar/td-menubar.swift"
  local bin="${TD_DIR}/menubar/td-menubar"
  local app_dir="${TD_DIR}/menubar/TD.app"
  local app_bin="${app_dir}/Contents/MacOS/TD"

  case "$subcmd" in
    start)
      # Kill existing instance
      pkill -f "TD.app/Contents/MacOS/TD" 2>/dev/null || true

      # Build if binary is missing or source is newer
      if [[ ! -f "$app_bin" || "$src" -nt "$app_bin" ]]; then
        echo "Building menu bar app..."
        swiftc -o "$bin" "$src" -framework Cocoa 2>&1 || {
          echo "Build failed"; return 1
        }
        mkdir -p "${app_dir}/Contents/MacOS"
        cp "$bin" "$app_bin"
        echo "Built."
      fi

      # Sync to /Applications so it's launchable from Spotlight/Finder
      if [[ -d /Applications ]]; then
        cp -R "$app_dir" /Applications/TD.app 2>/dev/null || true
      fi

      open /Applications/TD.app 2>/dev/null || open "$app_dir"
      echo "Menu bar app launched (⌘td in top bar)"
      ;;
    stop)
      pkill -f "TD.app/Contents/MacOS/TD" 2>/dev/null && echo "Stopped." || echo "Not running."
      ;;
    *)
      echo "Usage: td menubar [start|stop]"
      ;;
  esac
}
