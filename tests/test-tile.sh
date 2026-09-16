#!/usr/bin/env bash
# tests/test-tile.sh — regression tests for per-display tiling orchestration

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/lib/tile.sh"

PASS=0
FAIL=0
FIXTURE=""
TILE_CALLS=""

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

assert_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$description"
  else
    fail "$description"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

get_onscreen_windows() {
  printf '%s\n' "$FIXTURE"
}

tile_layout() {
  local call="$1|$2|$3|$4|$5|$6|$7|$8"
  if [[ -n "$TILE_CALLS" ]]; then
    TILE_CALLS="${TILE_CALLS}"$'\n'"${call}"
  else
    TILE_CALLS="$call"
  fi
}

snap_main_window() {
  return 1
}

FIXTURE=$'SCREEN\t1\t0\t34\t1440\t866\nSCREEN\t2\t-1920\t0\t1920\t1080\nITERM\t101\t1\nITERM\t102\t1\nITERM\t201\t2\nMAIN\t301\t1\tGoogle Chrome\t0\t34\t792\t866\nMAIN\t302\t2\tSafari\t-1920\t0\t1056\t1080'

echo ""
echo "Test 1: each display tiles terminals into the leftover half beside the main window"
TILE_CALLS=""
td_tile >/dev/null
assert_equals \
  "two independent leftover layouts are requested" \
  $'4||50|101,102|792|34|648|866\n4||50|201|-864|0|864|1080' \
  "$TILE_CALLS"

echo ""
echo "Test 2: --no-main is applied independently to every display"
TILE_CALLS=""
td_tile --no-main --gap 8 >/dev/null
assert_equals \
  "both displays use their full terminal grids" \
  $'8||50|101,102|0|34|1440|866\n8||50|201|-1920|0|1920|1080' \
  "$TILE_CALLS"

echo ""
echo "Test 3: --with filters main-window selection without moving displays"
TILE_CALLS=""
td_tile --with Safari --main-size 60 >/dev/null
assert_equals \
  "Safari is used only on the display where it is present" \
  $'4||60|101,102|0|34|1440|866\n4||60|201|-864|0|864|1080' \
  "$TILE_CALLS"

echo ""
echo "Test 4: displays without iTerm windows are left untouched"
FIXTURE=$'SCREEN\t1\t0\t34\t1440\t866\nSCREEN\t2\t1440\t0\t1920\t1080\nITERM\t201\t2\nMAIN\t301\t1\tGoogle Chrome\t0\t34\t792\t866'
TILE_CALLS=""
td_tile >/dev/null
assert_equals \
  "only the display containing iTerm is tiled" \
  '4||50|201|1440|0|1920|1080' \
  "$TILE_CALLS"

echo ""
echo "Test 5: no-window state remains clear"
FIXTURE=$'SCREEN\t1\t0\t34\t1440\t866'
TILE_CALLS=""
message="$(td_tile)"
assert_equals "no-window message is preserved" "No iTerm2 windows found" "$message"
assert_equals "no layout is requested" "" "$TILE_CALLS"

echo ""
echo "Test 6: Slack-sized main windows leave the other half for terminals"
FIXTURE=$'SCREEN\t1\t0\t34\t1496\t933\nITERM\t11\t1\nITERM\t12\t1\nMAIN\t99\t1\tSlack\t0\t34\t823\t933'
TILE_CALLS=""
td_tile >/dev/null
assert_equals \
  "terminals are packed into the leftover laptop half" \
  '4||50|11,12|823|34|673|933' \
  "$TILE_CALLS"

echo ""
echo "Test 7: remaining_rect keeps negative display origins"
assert_equals \
  "right leftover on an upper-left monitor" \
  "-864 -1080 864 1080" \
  "$(remaining_rect -1920 -1080 1920 1080 -1920 -1080 1056 1080)"

echo ""
echo "Test 8: the largest main window on a display wins"
FIXTURE=$'SCREEN\t3\t740\t-1080\t1920\t1080\nITERM\t1\t3\nITERM\t2\t3\nMAIN\t10\t3\tGoogle Chrome\t1111\t-970\t500\t931\nMAIN\t11\t3\tGoogle Chrome\t740\t-1055\t1056\t1055'
TILE_CALLS=""
td_tile >/dev/null
assert_equals \
  "terminals sit beside the largest Chrome window" \
  '4||50|1,2|1796|-1080|864|1080' \
  "$TILE_CALLS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
