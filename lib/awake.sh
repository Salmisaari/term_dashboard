#!/usr/bin/env bash
# One client for the CLI, native panel and optional browser workspace.
td_awake() {
  local awake_root
  awake_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  case "${1:-}" in
    setup|uninstall) bash "$awake_root/menubar/awake-setup.sh" "$1" ;;
    *) python3 -B -I "$awake_root/dashboard/awake.py" "$@" ;;
  esac
}
