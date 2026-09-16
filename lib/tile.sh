#!/usr/bin/env bash
# tile.sh — tile iTerm2 windows on current Space, auto-detect browser / main app

td_tile() {
  local gap=4
  local main_pct=50
  local no_main=false
  local with_app=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --gap) gap="$2"; shift 2 ;;
      --main-size) main_pct="$2"; shift 2 ;;
      --with) with_app="$2"; shift 2 ;;
      --no-main) no_main=true; shift ;;
      *) shift ;;
    esac
  done

  local onscreen_data
  onscreen_data="$(get_onscreen_windows)"

  local screen_rows
  screen_rows="$(printf '%s\n' "$onscreen_data" | awk -F '\t' '$1 == "SCREEN"')"
  if [[ -z "$screen_rows" ]]; then
    echo "No displays found"
    return 1
  fi

  local tiled_any=false
  local record display_id x y width height ids
  local main_row main_app main_x main_y main_w main_h
  local term_x term_y term_w term_h leftover leftover_pct
  while IFS=$'\t' read -r record display_id x y width height; do
    ids="$(printf '%s\n' "$onscreen_data" | awk -F '\t' -v wanted="$display_id" '
      $1 == "ITERM" && $3 == wanted {
        ids = ids separator $2
        separator = ","
      }
      END { print ids }
    ')"
    [[ -z "$ids" ]] && continue

    term_x="$x"; term_y="$y"; term_w="$width"; term_h="$height"
    main_app=""

    if [[ "$no_main" == false ]]; then
      main_row="$(printf '%s\n' "$onscreen_data" | awk -F '\t' -v wanted="$display_id" -v desired="$with_app" '
        $1 == "MAIN" && $3 == wanted && (desired == "" || $4 == desired) {
          area = ($7 + 0) * ($8 + 0)
          if (area > best) {
            best = area
            row = $0
          }
        }
        END { print row }
      ')"
      if [[ -n "$main_row" ]]; then
        IFS=$'\t' read -r _ _ _ main_app main_x main_y main_w main_h <<< "$main_row"
        read -r term_x term_y term_w term_h < <(remaining_rect "$x" "$y" "$width" "$height" "$main_x" "$main_y" "$main_w" "$main_h")
        leftover="$term_w"
        leftover_pct=0
        if (( width > 0 )); then
          leftover_pct=$(( leftover * 100 / width ))
        fi
        if (( leftover_pct < 30 )) && is_scriptable_browser "$main_app"; then
          main_w=$(( width * main_pct / 100 ))
          main_x="$x"
          main_y="$y"
          main_h="$height"
          if snap_main_window "$main_app" "$main_x" "$main_y" "$main_w" "$main_h"; then
            term_x=$(( x + main_w ))
            term_y="$y"
            term_w=$(( width - main_w ))
            term_h="$height"
          fi
        fi
        if (( term_w < 280 && term_h < 280 )); then
          term_x="$x"; term_y="$y"; term_w="$width"; term_h="$height"
        fi
      fi
    fi

    tile_layout \
      "$gap" \
      "" \
      "$main_pct" \
      "$ids" \
      "$term_x" \
      "$term_y" \
      "$term_w" \
      "$term_h"
    tiled_any=true
  done <<< "$screen_rows"

  if [[ "$tiled_any" == false ]]; then
    echo "No iTerm2 windows found"
  fi
}

# Largest leftover strip on a display after subtracting the main window.
remaining_rect() {
  local dx="$1" dy="$2" dw="$3" dh="$4"
  local mx="$5" my="$6" mw="$7" mh="$8"
  local dx2=$((dx + dw)) dy2=$((dy + dh))
  local mx2=$((mx + mw)) my2=$((my + mh))
  local ix="$mx" iy="$my" ix2="$mx2" iy2="$my2"
  (( ix < dx )) && ix="$dx"
  (( iy < dy )) && iy="$dy"
  (( ix2 > dx2 )) && ix2="$dx2"
  (( iy2 > dy2 )) && iy2="$dy2"
  if (( ix2 <= ix || iy2 <= iy )); then
    echo "$dx $dy $dw $dh"
    return
  fi
  local left=$((ix - dx))
  local right=$((dx2 - ix2))
  local top=$((iy - dy))
  local bottom=$((dy2 - iy2))
  local best="right" bestv="$right"
  if (( left > bestv )); then best="left"; bestv="$left"; fi
  if (( top > bestv )); then best="top"; bestv="$top"; fi
  if (( bottom > bestv )); then best="bottom"; bestv="$bottom"; fi
  case "$best" in
    right) echo "$ix2 $dy $right $dh" ;;
    left) echo "$dx $dy $left $dh" ;;
    bottom) echo "$dx $iy2 $dw $bottom" ;;
    top) echo "$dx $dy $dw $top" ;;
  esac
}

is_scriptable_browser() {
  case "$1" in
    "Google Chrome"|"Google Chrome Canary"|"Chromium"|"Arc"|"Safari"|"Safari Technology Preview"|"Firefox"|"Brave Browser"|"Microsoft Edge"|"Dia"|"Orion"|"Zen Browser"|"Vivaldi"|"Opera"|"Comet") return 0 ;;
    *) return 1 ;;
  esac
}

snap_main_window() {
  local app="$1" x="$2" y="$3" w="$4" h="$5"
  local right=$((x + w)) bottom=$((y + h))
  osascript - "$app" "$x" "$y" "$right" "$bottom" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set appName to item 1 of argv
  set targetLeft to item 2 of argv as integer
  set targetTop to item 3 of argv as integer
  set targetRight to item 4 of argv as integer
  set targetBottom to item 5 of argv as integer
  tell application appName
    set bestWindow to missing value
    set bestArea to 0
    repeat with candidateWindow in every window
      try
        set candidateBounds to bounds of candidateWindow
        set overlapLeft to item 1 of candidateBounds
        if overlapLeft < targetLeft then set overlapLeft to targetLeft
        set overlapTop to item 2 of candidateBounds
        if overlapTop < targetTop then set overlapTop to targetTop
        set overlapRight to item 3 of candidateBounds
        if overlapRight > targetRight then set overlapRight to targetRight
        set overlapBottom to item 4 of candidateBounds
        if overlapBottom > targetBottom then set overlapBottom to targetBottom
        if overlapRight > overlapLeft and overlapBottom > overlapTop then
          set overlapArea to (overlapRight - overlapLeft) * (overlapBottom - overlapTop)
          if overlapArea > bestArea then
            set bestArea to overlapArea
            set bestWindow to candidateWindow
          end if
        end if
      end try
    end repeat
    if bestWindow is missing value and (count of windows) > 0 then
      set bestWindow to window 1
    end if
    if bestWindow is missing value then error "no window"
    set bounds of bestWindow to {targetLeft, targetTop, targetRight, targetBottom}
  end tell
end run
APPLESCRIPT
}

# Emit tab-separated display frames and current-Space window assignments.
# Window bounds and display frames both use CoreGraphics' top-left coordinate space.
get_onscreen_windows() {
  swift -e '
import AppKit
import CoreGraphics

struct Display {
    let id: CGDirectDisplayID
    let visibleFrame: CGRect
}

let displays: [Display] = NSScreen.screens.compactMap { screen in
    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
        return nil
    }

    let displayBounds = CGDisplayBounds(displayID)
    let frame = screen.frame
    let visible = screen.visibleFrame
    let leftInset = visible.minX - frame.minX
    let topInset = frame.maxY - visible.maxY
    let visibleFrame = CGRect(
        x: displayBounds.minX + leftInset,
        y: displayBounds.minY + topInset,
        width: visible.width,
        height: visible.height
    )

    return Display(id: displayID, visibleFrame: visibleFrame)
}

for display in displays {
    let frame = display.visibleFrame
    print("SCREEN\t\(display.id)\t\(Int(frame.minX.rounded()))\t\(Int(frame.minY.rounded()))\t\(Int(frame.width.rounded()))\t\(Int(frame.height.rounded()))")
}

func displayID(containing windowBounds: CGRect) -> (CGDirectDisplayID, CGRect)? {
    var bestDisplayID: CGDirectDisplayID?
    var bestFrame = CGRect.null
    var bestArea: CGFloat = 0

    for display in displays {
        let intersection = display.visibleFrame.intersection(windowBounds)
        guard !intersection.isNull, !intersection.isInfinite else { continue }
        let area = intersection.width * intersection.height
        if area > bestArea {
            bestArea = area
            bestDisplayID = display.id
            bestFrame = display.visibleFrame
        }
    }

    guard let bestDisplayID else { return nil }
    return (bestDisplayID, bestFrame)
}

let deny: Set<String> = [
    "TD", "Dock", "Window Server", "Control Center", "Notification Center",
    "NotificationCentre", "Spotlight", "Wallpaper", "loginwindow",
    "SystemUIServer", "Cua Driver", "Grab", "Screenshot", "Item-0",
    "Wi-Fi", "Raycast", "Alfred", "Rectangle", "Magnet", "AltTab",
    "Hidden Bar", "Bartender", "Stats", "iStat Menus", "Amphetamine",
    "MonitorControl", "TextInputMenuAgent", "UserNotificationCenter",
    "OSDUIHelper", "Paste", "Contexts", "HazeOver", "Flux"
]
let alwaysMain: Set<String> = [
    "Google Chrome", "Google Chrome Canary", "Chromium", "Arc", "Safari",
    "Safari Technology Preview", "Firefox", "Brave Browser", "Microsoft Edge",
    "Dia", "Orion", "Zen Browser", "Vivaldi", "Opera", "Comet", "Slack",
    "Calendar", "Telegram", "Code", "Cursor", "Notes", "Preview", "Figma",
    "Notion", "Linear", "Mail", "Messages", "Spotify", "zoom.us", "Discord",
    "Things", "Obsidian", "Numbers", "Pages", "Keynote", "Xcode"
]

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }

for w in list {
    guard let owner = w["kCGWindowOwnerName"] as? String,
          let layer = w["kCGWindowLayer"] as? Int,
          let wid = w["kCGWindowNumber"] as? Int,
          let boundsDictionary = w["kCGWindowBounds"] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
          let assignment = displayID(containing: bounds),
          layer == 0 else { continue }

    if owner == "iTerm" || owner == "iTerm2" {
        print("ITERM\t\(wid)\t\(assignment.0)")
        continue
    }

    if deny.contains(owner) { continue }
    if bounds.width < 400 || bounds.height < 300 { continue }

    let displayFrame = assignment.1
    let coverage = (bounds.width * bounds.height) / max(displayFrame.width * displayFrame.height, 1)
    if owner == "Finder" && coverage > 0.8 { continue }
    if coverage > 0.9 && !alwaysMain.contains(owner) { continue }

    print("MAIN\t\(wid)\t\(assignment.0)\t\(owner)\t\(Int(bounds.minX.rounded()))\t\(Int(bounds.minY.rounded()))\t\(Int(bounds.width.rounded()))\t\(Int(bounds.height.rounded()))")
}
' 2>/dev/null
}

# Tile iTerm windows into one rectangle so they all fit.
tile_layout() {
  local gap="$1" main_app="$2" main_pct="$3" id_filter="$4"
  local screen_x="$5" screen_y="$6" screen_w="$7" screen_h="$8"

  local result
  result=$(osascript <<APPLESCRIPT
set screenX to ${screen_x}
set screenY to ${screen_y}
set usableW to ${screen_w}
set usableH to ${screen_h}
set gap to ${gap}

set idsText to "${id_filter}"
set filterByID to (length of idsText > 0)

tell application "iTerm2"
    set allWindows to every window
    set windowsToTile to {}

    if filterByID then
        set AppleScript's text item delimiters to ","
        set idItems to text items of idsText
        set AppleScript's text item delimiters to ""
        set idNums to {}
        repeat with anId in idItems
            set end of idNums to (anId as integer)
        end repeat

        repeat with w in allWindows
            try
                if id of w is in idNums then
                    set end of windowsToTile to w
                end if
            end try
        end repeat
    else
        set windowsToTile to allWindows
    end if

    set winCount to count of windowsToTile

    if winCount is 0 then
        return "No iTerm2 windows to tile"
    end if

    -- Pack a grid that always has a cell for every window.
    set gridC to 1
    set gridR to winCount
    if winCount is 1 then
        set gridC to 1
        set gridR to 1
    else if usableW is greater than usableH then
        if winCount is less than or equal to 3 then
            set gridC to winCount
            set gridR to 1
        else if winCount is less than or equal to 6 then
            set gridC to 3
            set gridR to 2
        else if winCount is less than or equal to 8 then
            set gridC to 4
            set gridR to 2
        else if winCount is less than or equal to 12 then
            set gridC to 4
            set gridR to 3
        else
            set gridC to 5
            set gridR to ((winCount + 4) div 5)
        end if
    else
        if winCount is less than or equal to 3 then
            set gridC to 1
            set gridR to winCount
        else if winCount is less than or equal to 4 then
            set gridC to 2
            set gridR to 2
        else if winCount is less than or equal to 6 then
            set gridC to 2
            set gridR to 3
        else if winCount is less than or equal to 8 then
            set gridC to 2
            set gridR to 4
        else if winCount is less than or equal to 9 then
            set gridC to 3
            set gridR to 3
        else if winCount is less than or equal to 12 then
            set gridC to 3
            set gridR to 4
        else
            set gridC to 4
            set gridR to ((winCount + 3) div 4)
        end if
    end if
    if (gridC * gridR) is less than winCount then
        set gridR to ((winCount + gridC - 1) div gridC)
    end if

    set cellW to ((usableW - (gap * (gridC + 1))) / gridC) as integer
    set cellH to ((usableH - (gap * (gridR + 1))) / gridR) as integer

    repeat with i from 1 to winCount
        set c to ((i - 1) mod gridC)
        set r to ((i - 1) div gridC)

        set x to screenX + gap + (c * (cellW + gap))
        set y to screenY + gap + (r * (cellH + gap))

        set rightEdge to x + cellW
        if c is (gridC - 1) then
            set rightEdge to screenX + usableW
        end if

        if r is (gridR - 1) then
            set bottomEdge to screenY + usableH
        else
            set bottomEdge to y + cellH
        end if

        set targetBounds to {x, y, rightEdge, bottomEdge}

        try
            set bounds of (item i of windowsToTile) to targetBounds
        end try
    end repeat

    activate
end tell

return (winCount as text) & " windows tiled " & (gridC as text) & "x" & (gridR as text)
APPLESCRIPT
  )
  echo "$result"
}
