#!/usr/bin/env bash
# tile.sh — tile iTerm2 windows (current Space only), with optional main app

td_tile() {
  local gap=4
  local menu_bar=38
  local main_app=""
  local main_pct=55
  local tile_all=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --gap) gap="$2"; shift 2 ;;
      --menu-bar) menu_bar="$2"; shift 2 ;;
      --with) main_app="$2"; shift 2 ;;
      --no-main) main_app="NONE"; shift ;;
      --main-size) main_pct="$2"; shift 2 ;;
      --all) tile_all=true; shift ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  # Get on-screen window info (current Space only) via CoreGraphics
  local onscreen_data
  onscreen_data="$(get_onscreen_windows)"

  local iterm_ids browser_app
  iterm_ids="$(echo "$onscreen_data" | grep '^ITERM:' | sed 's/^ITERM://')"
  browser_app="$(echo "$onscreen_data" | grep '^BROWSER:' | sed 's/^BROWSER://' | sed -n '1p')"

  # Override browser with flags
  if [[ -n "$main_app" ]]; then
    if [[ "$main_app" == "NONE" ]]; then
      browser_app=""
    else
      browser_app="$main_app"
    fi
  fi

  local id_filter=""
  if [[ "$tile_all" == false ]]; then
    if [[ -z "$iterm_ids" ]]; then
      echo "No iTerm2 windows on current Space"
      return
    fi
    id_filter="$(echo "$iterm_ids" | tr '\n' ',' | sed 's/,$//')"
  fi

  if [[ -n "$browser_app" ]]; then
    tile_layout "$gap" "$menu_bar" "$browser_app" "$main_pct" "$id_filter"
  else
    tile_layout "$gap" "$menu_bar" "" "0" "$id_filter"
  fi
}

# Use CoreGraphics via Swift to get on-screen windows (current Space only)
get_onscreen_windows() {
  swift -e '
import CoreGraphics
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
let browsers = ["Google Chrome", "Arc", "Safari", "Firefox", "Brave Browser"]
var seenBrowser = false
for w in list {
    guard let owner = w["kCGWindowOwnerName"] as? String,
          let layer = w["kCGWindowLayer"] as? Int,
          let wid = w["kCGWindowNumber"] as? Int,
          layer == 0 else { continue }
    if owner == "iTerm" || owner == "iTerm2" { print("ITERM:\(wid)") }
    if !seenBrowser && browsers.contains(owner) { print("BROWSER:\(owner)"); seenBrowser = true }
}
' 2>/dev/null
}

# Unified tiling: handles both with-main and full-grid layouts
tile_layout() {
  local gap="$1" menu_bar="$2" main_app="$3" main_pct="$4" id_filter="$5"

  local has_main="false"
  [[ -n "$main_app" ]] && has_main="true"

  local result
  result=$(osascript <<APPLESCRIPT
tell application "Finder"
    set db to bounds of window of desktop
    set screenW to item 3 of db
    set screenH to item 4 of db
end tell

set topY to ${menu_bar}
set usableH to screenH - topY
set usableW to screenW
set gap to ${gap}
set hasMain to ${has_main}
set mainPct to ${main_pct}

-- Position main app on the LEFT, terminals on the RIGHT
set termAreaW to usableW
set termStartX to 0
if hasMain then
    set mainW to ((usableW * mainPct) / 100) as integer
    set termStartX to mainW
    set termAreaW to usableW - mainW

    try
        tell application "${main_app}"
            set bounds of window 1 to {0, topY, mainW, topY + usableH}
        end tell
    end try
end if

-- Collect iTerm windows to tile
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
        if hasMain then
            return "${main_app} positioned, no iTerm windows on this Space"
        else
            return "No iTerm2 windows to tile"
        end if
    end if

    -- Calculate grid dimensions
    if hasMain then
        -- Vertical stack for narrow left portion
        if winCount is 1 then
            set gridC to 1
            set gridR to 1
        else if winCount is less than or equal to 2 then
            set gridC to 1
            set gridR to 2
        else if winCount is less than or equal to 4 then
            set gridC to 2
            set gridR to 2
        else if winCount is less than or equal to 6 then
            set gridC to 2
            set gridR to 3
        else if winCount is less than or equal to 8 then
            set gridC to 2
            set gridR to 4
        else
            set gridC to 3
            set gridR to ((winCount + 2) div 3)
        end if
    else
        -- Full screen grid
        if winCount is 1 then
            set gridC to 1
            set gridR to 1
        else if winCount is 2 then
            set gridC to 2
            set gridR to 1
        else if winCount is less than or equal to 4 then
            set gridC to 2
            set gridR to 2
        else if winCount is less than or equal to 6 then
            set gridC to 3
            set gridR to 2
        else if winCount is less than or equal to 9 then
            set gridC to 3
            set gridR to 3
        else if winCount is less than or equal to 12 then
            set gridC to 4
            set gridR to 3
        else
            set gridC to 4
            set gridR to 4
        end if
    end if

    -- Base cell sizes
    set cellW to ((termAreaW - (gap * (gridC + 1))) / gridC) as integer
    set cellH to ((usableH - (gap * (gridR + 1))) / gridR) as integer

    repeat with i from 1 to winCount
        set c to ((i - 1) mod gridC)
        set r to ((i - 1) div gridC)

        set x to termStartX + gap + (c * (cellW + gap))
        set y to topY + gap + (r * (cellH + gap))

        -- Right edge: last column stretches to fill rounding gap
        if c is (gridC - 1) then
            set rightEdge to usableW - gap
        else
            set rightEdge to x + cellW
        end if

        -- Bottom edge: last row stretches to fill
        if r is (gridR - 1) then
            set bottomEdge to topY + usableH
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

if hasMain then
    return (winCount as text) & " terminals + ${main_app} (" & (gridC as text) & "x" & (gridR as text) & ")"
else
    return (winCount as text) & " windows tiled " & (gridC as text) & "x" & (gridR as text)
end if
APPLESCRIPT
  )
  echo "$result"
}
