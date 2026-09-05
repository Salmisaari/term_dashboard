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
# iCloud can re-add Finder metadata while signing a bundle on Desktop.
# Keep the verified build outside the source checkout as well as the installed runtime.
app="$HOME/Library/Caches/term-dashboard/TD.app"
if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
  build_dir="$(mktemp -d /tmp/td-menubar-build.XXXXXX)"
  trap 'rm -rf "$build_dir"' EXIT
  echo 'Building native terminal workspace…'
  swiftc "$src" -o "$build_dir/TD" -framework Cocoa
  codesign --verify "$build_dir/TD"
  [[ "$("$build_dir/TD" --version)" == 'TD native workspace 2.0' ]] || {
    echo 'The compiled app did not pass its startup check.' >&2; exit 1;
  }
  backup="${TD_CONFIG_DIR:-$HOME/.config/td}/menubar-before-workspace"
  if [[ ! -e "$backup/TD" && -f /Applications/TD.app/Contents/MacOS/TD ]]; then
    mkdir -p "$backup"
    cp /Applications/TD.app/Contents/MacOS/TD "$backup/TD"
    cp /Applications/TD.app/Contents/Info.plist "$backup/Info.plist"
  fi
  cp "$build_dir/TD" "$bin"
fi
# Assemble and sign before replacing the active application. Never delete the bundle.
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/TD"
mkdir -p "$app/Contents/Resources/dashboard" "$app/Contents/Resources/lib"
cp "$ROOT/menubar/runtime.sh" "$app/Contents/Resources/td"
chmod 755 "$app/Contents/Resources/td"
for module in __init__ bridge core native cli; do
  cp "$ROOT/dashboard/$module.py" "$app/Contents/Resources/dashboard/$module.py"
done
cp "$ROOT/lib/awake.sh" "$ROOT/lib/tile.sh" "$app/Contents/Resources/lib/"
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
# Verify the packaged companion without touching live terminals or requiring a browser.
python3 -B -I - "$app/Contents/Resources/td" <<'PY'
import json, os, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="td-bundle-check-") as config:
    result = subprocess.run([sys.argv[1], "workspace", "--demo"], input="{}", text=True,
                            capture_output=True, cwd="/", timeout=15,
                            env=dict(os.environ, TD_CONFIG_DIR=config))
    if result.returncode:
        raise SystemExit("Bundled workspace check failed: " + result.stderr)
    state = json.loads(result.stdout)["state"]
    if not state["demo"] or state["counts"]["total"] != 6:
        raise SystemExit("Bundled workspace returned an unexpected demo inventory.")
print("Bundled workspace verified.")
PY
if [[ "$action" == build ]]; then echo "Built: $app"; exit 0; fi
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
  mkdir -p /Applications/TD.app/Contents/Resources/dashboard /Applications/TD.app/Contents/Resources/lib
  cp "$app/Contents/Resources/td" /Applications/TD.app/Contents/Resources/td
  cp "$app/Contents/Resources/dashboard/"*.py /Applications/TD.app/Contents/Resources/dashboard/
  cp "$app/Contents/Resources/lib/"*.sh /Applications/TD.app/Contents/Resources/lib/
  installed=/Applications/TD.app
fi
xattr -dr com.apple.FinderInfo "$installed" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$installed" 2>/dev/null || true
codesign --verify --strict "$installed"
open "$installed" --args --show
echo 'TD is in your menu bar. Click the session count to expand; double-tap Caps Lock for Quick Add.'
