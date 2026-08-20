#!/bin/bash

# Tests for the fibonacci (spiral / dwindle) layout engine in lib/layouts.sh.
#
# The expected tiles are read off dwm's reference art, which is the contract
# both variants implement (https://dwm.suckless.org/patches/fibonacci/):
#
#   spiral                        dwindle
#   +-----------+-----------+     +-----------+-----------+
#   |           |     2     |     |           |     2     |
#   |     1     +--+--+-----+     |     1     +-----+-----+
#   |           | 5|-.|     |     |           |     |  4  |
#   |           +--+--+  3  |     |           |  3  +--+--+
#   |           |  4  |     |     |           |     | 5|-.|
#   +-----------+-----+-----+     +-----------+-----+-----+
#
# Spiral winds counter-clockwise inward (the taken side rotates
# left/top/right/bottom); dwindle always takes left/top, so the leftover
# marches into the bottom-right corner.

cd "$(dirname "$0")"

# Mock external X tools (not available / not wanted in the dev qube).
xdotool() { echo "0"; }
wmctrl() { :; }
export -f xdotool wmctrl

# Geometry inputs: a clean 1000x1000 area, no gaps or decorations, so the
# expected tiles stay exact halves and the arithmetic is readable.
GAP=0
DECORATION_HEIGHT=0
DECORATION_BOTTOM=0
DECORATION_WIDTH=0

source lib/layouts.sh

# Stub the monitor area so the engine runs without X.
get_monitor_layout_area() { echo "$LAYOUT_AREA"; }
LAYOUT_AREA="0:0:1000:1000"

# Record placements instead of moving real windows.
TILES=()
apply_geometry() { TILES+=("$1:$2:$3:$4:$5"); }

PASS=0
FAIL=0

check() {  # args: description expected actual
    if [[ "$2" == "$3" ]]; then
        echo "✅ PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: $1"
        echo "        expected: $2"
        echo "        actual:   $3"
        FAIL=$((FAIL + 1))
    fi
}

# Run the layout over `count` synthetic window IDs (w1..wN) and return the
# recorded tiles as a space-separated "id:x:y:w:h" list, ordered by window.
run_layout() {  # args: variant ratio count
    local variant="$1" ratio="$2" count="$3"
    local windows=() i
    for ((i = 1; i <= count; i++)); do
        windows+=("w$i")
    done

    TILES=()
    apply_meta_fibonacci_single_monitor "eDP-1:0:0:1000:1000" "$variant" "$ratio" "${windows[@]}"
    echo "${TILES[*]}"
}

echo "=== single window ==="

check "one window fills the area" \
      "w1:0:0:1000:1000" \
      "$(run_layout spiral 50 1)"

echo
echo "=== first two splits (identical in both variants) ==="

# Window 1 always takes the left half; window 2 the top of the remainder.
check "spiral: 2 windows split left/right" \
      "w1:0:0:500:1000 w2:500:0:500:1000" \
      "$(run_layout spiral 50 2)"
check "dwindle: 2 windows split left/right" \
      "w1:0:0:500:1000 w2:500:0:500:1000" \
      "$(run_layout dwindle 50 2)"
check "spiral: 3rd window takes the bottom of the remainder" \
      "w1:0:0:500:1000 w2:500:0:500:500 w3:500:500:500:500" \
      "$(run_layout spiral 50 3)"
check "dwindle: 3rd window takes the bottom of the remainder" \
      "w1:0:0:500:1000 w2:500:0:500:500 w3:500:500:500:500" \
      "$(run_layout dwindle 50 3)"

echo
echo "=== where the variants diverge (4+ windows) ==="

# Spiral's 3rd split takes the RIGHT side, so window 4 lands to its left.
check "spiral: window 3 on the right, window 4 to its left" \
      "w1:0:0:500:1000 w2:500:0:500:500 w3:750:500:250:500 w4:500:500:250:500" \
      "$(run_layout spiral 50 4)"

# Dwindle's 3rd split takes the LEFT side, so window 4 lands to its right.
check "dwindle: window 3 on the left, window 4 to its right" \
      "w1:0:0:500:1000 w2:500:0:500:500 w3:500:500:250:500 w4:750:500:250:500" \
      "$(run_layout dwindle 50 4)"

# Spiral's 4th split takes the BOTTOM, so window 5 sits above window 4.
check "spiral: window 4 at the bottom, window 5 above it" \
      "w1:0:0:500:1000 w2:500:0:500:500 w3:750:500:250:500 w4:500:750:250:250 w5:500:500:250:250" \
      "$(run_layout spiral 50 5)"

# Dwindle's 4th split takes the TOP, so window 5 sits below window 4.
check "dwindle: window 4 at the top, window 5 below it" \
      "w1:0:0:500:1000 w2:500:0:500:500 w3:500:500:250:500 w4:750:500:250:250 w5:750:750:250:250" \
      "$(run_layout dwindle 50 5)"

echo
echo "=== the name the command line uses ==="

# `fibonacci` is what the CLI, the daemon command and the saved layout string
# all call this layout; `spiral` is the engine's internal name for the same
# thing. The engine must answer to both, or `place-window master fibonacci`
# silently lays out a dwindle -- the variant name is carried untranslated from
# `place-window master $2` all the way down to $variant here.
check "fibonacci produces the same tiles as spiral" \
      "$(run_layout spiral 50 5)" \
      "$(run_layout fibonacci 50 5)"

check "fibonacci does not produce dwindle's tiles" \
      "differs" \
      "$([[ "$(run_layout fibonacci 50 5)" == "$(run_layout dwindle 50 5)" ]] && echo same || echo differs)"

echo
echo "=== split ratio ==="

# 62% approximates the golden ratio, the ratio that makes the tiles trace an
# actual Fibonacci spiral (xmonad's Spiral takes the same parameter).
check "ratio 62 gives the first window 62% of the width" \
      "w1:0:0:620:1000 w2:620:0:380:1000" \
      "$(run_layout spiral 62 2)"
check "ratio 30 gives the first window 30% of the width" \
      "w1:0:0:300:1000 w2:300:0:700:1000" \
      "$(run_layout spiral 30 2)"

# The ratio is applied at EVERY split, not just the first: with 70, each
# window takes 70% of whatever the previous one left behind.
check "ratio 70 applies at every split" \
      "w1:0:0:700:1000 w2:700:0:300:700 w3:700:700:300:300" \
      "$(run_layout spiral 70 3)"
check "ratio 70 keeps applying at the third split" \
      "w1:0:0:1344:1080 w2:1344:0:576:756 w3:1517:756:403:324 w4:1344:756:173:324" \
      "$(LAYOUT_AREA="0:0:1920:1080"; run_layout spiral 70 4)"
check "dwindle honours the ratio the same way" \
      "w1:0:0:700:1000 w2:700:0:300:700 w3:700:700:300:300" \
      "$(run_layout dwindle 70 3)"

echo
echo "=== gaps and decorations ==="

# Tiles are separated by gap+decoration on each axis, matching the other
# meta-layout engines; the outer edge is inset by one gap.
GAP=10
check "gap insets the area and separates the columns" \
      "w1:10:10:485:980 w2:505:10:485:980" \
      "$(run_layout spiral 50 2)"

DECORATION_WIDTH=6
check "horizontal separation includes the decoration width" \
      "w1:10:10:479:980 w2:505:10:479:980" \
      "$(run_layout spiral 50 2)"

DECORATION_WIDTH=0
DECORATION_HEIGHT=24
check "vertical separation includes the title bar height" \
      "w1:10:10:485:956 w2:505:10:485:461 w3:505:505:485:461" \
      "$(run_layout spiral 50 3)"

GAP=0
DECORATION_HEIGHT=0

echo
echo "=== deep spirals stay on screen ==="

# Halving 1000px runs out of room around the 8th window. Beyond that the
# engine must stop splitting and share the leftover box, or it hands the
# last windows zero and then negative sizes (wmctrl errors, stacked windows).
deep_tiles=$(run_layout spiral 50 12)
bad=""
for tile in $deep_tiles; do
    IFS=':' read -r id x y w h <<< "$tile"
    if (( w <= 0 || h <= 0 )); then
        bad="$bad $id(${w}x${h})"
    fi
done
check "12 windows all get positive sizes" "" "$bad"

# Every window must be placed exactly once, however deep the spiral goes.
check "12 windows all get placed" "12" "$(echo "$deep_tiles" | wc -w)"

# And nothing may escape the layout area.
outside=""
for tile in $deep_tiles; do
    IFS=':' read -r id x y w h <<< "$tile"
    if (( x < 0 || y < 0 || x + w > 1000 || y + h > 1000 )); then
        outside="$outside $id($x,$y,${w}x${h})"
    fi
done
check "12 windows all stay inside the layout area" "" "$outside"

echo
echo "=== configurable tile floor ==="

# The floor decides how deep the spiral goes before the leftover box is shared
# out. Skewed ratios reach it sooner, so it has to be tunable rather than baked
# in: at 70/30 on a 1080p-shaped area the 4th split leaves 98px.
LAYOUT_AREA="0:0:1920:1080"
FIBONACCI_MIN_TILE=100
check "the default floor stops the spiral and shares the leftover" \
      "w1:0:0:1344:1080 w2:1344:0:576:756 w3:1517:756:403:324 w4:1344:756:173:162 w5:1344:918:173:162" \
      "$(run_layout spiral 70 5)"

FIBONACCI_MIN_TILE=50
check "a lower floor lets the same spiral keep winding" \
      "w1:0:0:1344:1080 w2:1344:0:576:756 w3:1517:756:403:324 w4:1344:854:173:226 w5:1344:756:173:98" \
      "$(run_layout spiral 70 5)"

FIBONACCI_MIN_TILE=100
LAYOUT_AREA="0:0:1000:1000"

echo
echo "=== daemon command routing ==="

# The layout is reached through the daemon socket, so the "master fibonacci"
# command must survive parsing with and without --all, and the saved-layout
# reapply path must route back to the same engine after a workspace switch.
# Source first, then stub: daemon.sh defines these same functions, so
# defining the stubs ahead of the source would just get them overwritten.
source lib/daemon.sh 2>/dev/null

# The stubs echo rather than set a variable: handle_daemon_command captures
# each handler with response=$(...), so an assignment would die in that subshell.
master_stack_layout_current_monitor() { echo "single:$1:$2"; }
master_stack_layout() { echo "all:$1:$2"; }
center_master_layout_current_monitor() { echo "center:$1"; }
adjust_master_size() { echo "adjust:$1"; }

route() { handle_daemon_command "$1" 2>/dev/null; }

check "master fibonacci 70 routes to the current monitor" \
      "single:fibonacci:70" "$(route "master fibonacci 70")"
check "master dwindle 62 routes to the current monitor" \
      "single:dwindle:62" "$(route "master dwindle 62")"
check "master fibonacci --all 70 routes to all monitors" \
      "all:fibonacci:70" "$(route "master fibonacci --all 70")"
check "master increase still routes to the size adjuster" \
      "adjust:increase" "$(route "master increase")"
check "master vertical 60 still routes to the current monitor" \
      "single:vertical:60" "$(route "master vertical 60")"

# A saved "master fibonacci 70" must come back as a fibonacci layout, not as
# the horizontal-master fallback the unrecognised branch would give it.
REAPPLIED=""
apply_meta_fibonacci_single_monitor() { REAPPLIED="fibonacci:$2:$3"; }
get_current_workspace() { echo "0"; }
get_windows_ordered() { echo "w1"; }
get_workspace_monitor_layout() { echo "$SAVED_LAYOUT"; }

reapply() { SAVED_LAYOUT="$1"; REAPPLIED=""; reapply_saved_layout_for_monitor 0 "eDP-1:0:0:1000:1000" >/dev/null 2>&1; echo "$REAPPLIED"; }

check "saved fibonacci layout is reapplied as fibonacci" \
      "fibonacci:fibonacci:70" "$(reapply "master fibonacci 70")"
check "saved dwindle layout is reapplied as dwindle" \
      "fibonacci:dwindle:62" "$(reapply "master dwindle 62")"

echo
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
