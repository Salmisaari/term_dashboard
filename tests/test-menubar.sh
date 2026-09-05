#!/usr/bin/env bash
# Exercise real AppKit controls + isolated shared backend; requires macOS GUI session.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TD_NATIVE_TEST_DIR="$(mktemp -d /tmp/td-native-checks.XXXXXX)"
trap 'rm -rf "$TD_NATIVE_TEST_DIR"' EXIT
python3 -B -I - "$ROOT" "$TD_NATIVE_TEST_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
source=(root/'menubar/td-workspace.swift').read_text().split('let application = NSApplication.shared')[0]
Path(sys.argv[2]).write_text(source+(root/'tests/native-workspace-checks.swift').read_text())
PY
swiftc "$TD_NATIVE_TEST_DIR/main.swift" -o "$TD_NATIVE_TEST_DIR/TD-checks" -framework Cocoa
TD_CONFIG_DIR="$TD_NATIVE_TEST_DIR/state" TD_EXECUTABLE="$ROOT/td" "$TD_NATIVE_TEST_DIR/TD-checks" --demo --headless
