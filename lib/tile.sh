#!/usr/bin/env bash
# tile.sh — tile iTerm2 windows on current Space, auto-detect browser

td_tile() {
  local gap=4
  local menu_bar=38
  local main_pct=55
  local no_main=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --gap) gap="$2"; shift 2 ;;
      --main-size) main_pct="$2"; shift 2 ;;
      --no-main) no_main=true; shift ;;
      *) shift ;;
    esac
  done

  # Detect what's on the current Space via CoreGraphics
  local onscreen_data
  onscreen_data="$(get_onscreen_windows)"

  local iterm_ids
  iterm_ids="$(echo "$onscreen_data" | grep '^ITERM:' | sed 's/^ITERM://' || true)"

  # Auto-detect browser on current Space
  local browser_app=""
  if [[ "$no_main" == false ]]; then
    browser_app="$(echo "$onscreen_data" | grep '^BROWSER:' | sed 's/^BROWSER://' | sed -n '1p' || true)"
  fi

  if [[ -z "$iterm_ids" ]]; then
    echo "No iTerm2 windows found"
    return
  fi

  local id_filter
  id_filter="$(echo "$iterm_ids" | tr '\n' ',' | sed 's/,$//')"

  if [[ -n "$browser_app" ]]; then
    tile_layout "$gap" "$menu_bar" "$browser_app" "$main_pct" "$id_filter"
  else
    tile_layout "$gap" "$menu_bar" "" "0" "$id_filter"
  fi
}

# Detect windows on current Space via CoreGraphics
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

    -- Cap terminal width to half screen (terminals should never be wider than 50%)
    set maxTermW to (usableW / 2) as integer

    -- Base cell sizes
    set rawCellW to ((termAreaW - (gap * (gridC + 1))) / gridC) as integer
    if rawCellW > maxTermW then
        set cellW to maxTermW
    else
        set cellW to rawCellW
    end if
    set cellH to ((usableH - (gap * (gridR + 1))) / gridR) as integer

    -- When width was capped and no main app, right-align the terminal grid
    if not hasMain and cellW < rawCellW then
        set termStartX to usableW - (gridC * cellW) - ((gridC + 1) * gap)
    end if

    repeat with i from 1 to winCount
        set c to ((i - 1) mod gridC)
        set r to ((i - 1) div gridC)

        set x to termStartX + gap + (c * (cellW + gap))
        set y to topY + gap + (r * (cellH + gap))

        set rightEdge to x + cellW

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
