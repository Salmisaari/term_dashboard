#!/usr/bin/env bash
# awake — prevent display sleep via caffeinate, with a shared state file
# State: $CONFIG_DIR/awake.state — JSON {"state","end_ts","pid"}

AWAKE_STATE_FILE="${CONFIG_DIR}/awake.state"

_awake_read() {
  local key="$1"
  if [[ -f "$AWAKE_STATE_FILE" ]]; then
    jq -r ".${key} // empty" "$AWAKE_STATE_FILE" 2>/dev/null || true
  fi
  return 0
}

_awake_write() {
  local state="$1" end_ts="$2" pid="$3"
  printf '{"state":"%s","end_ts":%s,"pid":%s}\n' "$state" "${end_ts:-0}" "${pid:-0}" > "$AWAKE_STATE_FILE"
}

_awake_kill_existing() {
  local pid; pid="$(_awake_read pid)"
  _awake_is_live "$pid" && kill "$pid" 2>/dev/null || true
}

_awake_is_live() {
  local pid="$1" awake_command
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "1" ]] || return 1
  awake_command="$(/bin/ps -p "$pid" -o comm= 2>/dev/null)" || return 1
  [[ "${awake_command##*/}" == "caffeinate" ]] && kill -0 "$pid" 2>/dev/null
}

_awake_next() {
  case "$1" in
    off|"") echo "1h" ;;
    1h)     echo "4h" ;;
    4h)     echo "24h" ;;
    24h)    echo "off" ;;
    *)      echo "1h" ;;
  esac
}

_awake_secs() {
  case "$1" in
    1h)  echo 3600 ;;
    4h)  echo 14400 ;;
    24h) echo 86400 ;;
    *)   echo 0 ;;
  esac
}

td_awake() {
  local arg="${1:-}"
  local current; current="$(_awake_read state)"
  current="${current:-off}"

  # If state file says active but caffeinate is dead, treat as off
  local cur_pid; cur_pid="$(_awake_read pid)"
  if [[ "$current" != "off" ]]; then
    _awake_is_live "$cur_pid" || current="off"
  fi

  # No arg → cycle
  [[ -z "$arg" ]] && arg="$(_awake_next "$current")"

  case "$arg" in
    off|0)
      _awake_kill_existing
      _awake_write off 0 0
      echo "awake: off"
      ;;
    1h|4h|24h)
      _awake_kill_existing
      local secs; secs="$(_awake_secs "$arg")"
      caffeinate -d -t "$secs" >/dev/null 2>&1 &
      local new_pid=$!
      disown 2>/dev/null || true
      local end_ts=$(( $(date +%s) + secs ))
      _awake_write "$arg" "$end_ts" "$new_pid"
      echo "awake: $arg (until $(date -r "$end_ts" '+%H:%M'))"
      ;;
    status)
      if [[ "$current" == "off" ]]; then
        echo "awake: off"
      else
        local end_ts; end_ts="$(_awake_read end_ts)"
        local now; now="$(date +%s)"
        local remaining=$(( end_ts - now ))
        if (( remaining > 0 )); then
          if (( remaining >= 3600 )); then
            printf 'awake: %s (%d:%02d:%02d remaining)\n' "$current" $((remaining/3600)) $(((remaining%3600)/60)) $((remaining%60))
          else
            printf 'awake: %s (%02d:%02d remaining)\n' "$current" $((remaining/60)) $((remaining%60))
          fi
        else
          _awake_write off 0 0
          echo "awake: off"
        fi
      fi
      ;;
    *)
      echo "Usage: td awake [1h|4h|24h|off|status]"
      echo "  No arg cycles: off → 1h → 4h → 24h → off"
      return 1
      ;;
  esac
}
