#!/usr/bin/env bash
# Build before stopping the running panel; preserve the previous native executable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
action="${1:-start}"
case "$action" in
  stop)
    pkill -f 'TD.app/Contents/MacOS/TD' 2>/dev/null && echo 'TD stopped. Terminals keep running.' || echo 'TD is not running.'
    exit 0 ;;
  start|demo|build) ;;
  *) echo 'Usage: td menubar [start|stop|demo|build]' >&2; exit 1 ;;
esac
src="$ROOT/menubar/td-workspace.swift"
bin="$ROOT/menubar/td-menubar"
app="$ROOT/menubar/TD.app"
if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
  build_dir="$(mktemp -d /tmp/td-menubar-build.XXXXXX)"
  trap 'rm -rf "$build_dir"' EXIT
  echo 'Building native terminal workspace…'
  swiftc "$src" -o "$build_dir/TD" -framework Cocoa
  codesign --verify "$build_dir/TD"
  backup="${TD_CONFIG_DIR:-$HOME/.config/td}/menubar-before-workspace"
  if [[ ! -e "$backup/TD" && -f /Applications/TD.app/Contents/MacOS/TD ]]; then
    mkdir -p "$backup"
    cp /Applications/TD.app/Contents/MacOS/TD "$backup/TD"
    cp /Applications/TD.app/Contents/Info.plist "$backup/Info.plist"
  fi
  cp "$build_dir/TD" "$bin"
fi
if [[ "$action" == build ]]; then echo "Built: $bin"; exit 0; fi
# Only a successful build replaces the active application. Never delete the bundle.
if [[ "$action" == start ]]; then
  pkill -f 'TD.app/Contents/MacOS/TD' 2>/dev/null || true
fi
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/TD"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TD</string>
<key>CFBundleIdentifier</key><string>com.td.menubar</string>
<key>CFBundleName</key><string>TD</string>
<key>CFBundleVersion</key><string>2.0</string>
<key>LSUIElement</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>TD browses your project folders in Desktop/Code.</string>
<key>NSAppleEventsUsageDescription</key><string>TD lists your terminal sessions and opens the exact terminal you choose.</string>
</dict></plist>
PLIST
if [[ "$action" == demo ]]; then
  open -n "$app" --args --demo --show
  echo 'Edward demo opened in a separate TD menu item. Real terminals are untouched.'
  exit 0
fi
installed="$app"
if [[ -w /Applications ]]; then
  mkdir -p /Applications/TD.app/Contents/MacOS
  cp "$app/Contents/MacOS/TD" /Applications/TD.app/Contents/MacOS/TD
  cp "$app/Contents/Info.plist" /Applications/TD.app/Contents/Info.plist
  installed=/Applications/TD.app
fi
open "$installed" --args --show
echo 'TD is in your menu bar. Click the session count to expand; double-tap Caps Lock for Quick Add.'
