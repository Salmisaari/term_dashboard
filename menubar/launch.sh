#!/usr/bin/env bash
# Build before stopping the running panel; preserve the previous native executable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
action="${1:-start}"
case "$action" in
  --help|-h) echo 'Usage: td menubar [start|stop|demo|build]'; exit 0 ;;
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
# Assemble and sign before replacing the active application. Never delete the bundle.
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
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - --identifier com.td.menubar "$app"
codesign --verify --strict "$app"
if [[ "$action" == demo ]]; then
  open -n "$app" --args --demo --show
  echo 'Edward demo opened in a separate TD menu item. Real terminals are untouched.'
  exit 0
fi
pkill -f 'TD.app/Contents/MacOS/TD' 2>/dev/null || true
installed="$app"
if [[ -w /Applications ]]; then
  mkdir -p /Applications/TD.app/Contents/MacOS
  cp "$app/Contents/MacOS/TD" /Applications/TD.app/Contents/MacOS/TD
  cp "$app/Contents/Info.plist" /Applications/TD.app/Contents/Info.plist
  mkdir -p /Applications/TD.app/Contents/_CodeSignature
  cp "$app/Contents/_CodeSignature/CodeResources" /Applications/TD.app/Contents/_CodeSignature/CodeResources
  installed=/Applications/TD.app
fi
xattr -dr com.apple.FinderInfo "$installed" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$installed" 2>/dev/null || true
codesign --verify --strict "$installed"
open "$installed" --args --show
echo 'TD is in your menu bar. Click the session count to expand; double-tap Caps Lock for Quick Add.'
