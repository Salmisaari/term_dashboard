#!/bin/bash
# Installed native companion. Its runtime lives inside TD.app, outside iCloud Desktop.
set -euo pipefail
TD_RUNTIME_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${TD_CONFIG_DIR:-${HOME}/.config/td}"
case "${1:-}" in
  workspace|sessions|session|agent)
    exec python3 -B -I "$TD_RUNTIME_DIR/dashboard/cli.py" "$@"
    ;;
  awake)
    mkdir -p "$CONFIG_DIR"
    source "$TD_RUNTIME_DIR/lib/awake.sh"
    shift
    td_awake "$@"
    ;;
  tile)
    source "$TD_RUNTIME_DIR/lib/tile.sh"
    shift
    td_tile "$@"
    ;;
  *)
    echo 'TD native companion: workspace | sessions | session | agent | awake | tile' >&2
    exit 1
    ;;
esac
