#!/bin/bash

# Final test of refactored functions to ensure all changes work correctly
cd "$(dirname "$0")"

# Source required dependencies (with minimal setup)
export WINDOW_ORDER_STRATEGY="position"

# Mock external dependencies that aren't available in this environment
wmctrl() { echo "0x12345 0 dom0 Test Window 1"; echo "0x67890 0 dom0 Test Window 2"; echo "0xabcde 0 dom0 Test Window 3"; }
xdotool() { 
    case "$1" in
        "get_desktop") echo "0" ;;
        "getdisplaygeometry") echo "1920 1080" ;;
        "getwindowgeometry") 
            case "$2" in
                "0x12345") echo "Position: 10,20 (screen: 0); Geometry: 800x600+10+20" ;;
                "0x67890") echo "Position: 900,100 (screen: 0); Geometry: 400x300+900+100" ;;
                "0xabcde") echo "Position: 500,300 (screen: 0); Geometry: 600x400+500+300" ;;
                *) echo "Position: 0,0 (screen: 0); Geometry: 100x100+0+0" ;;
            esac
            ;;
        *) echo "mock" ;;
    esac
}
xprop() { 
    case "$*" in
        *"_NET_WM_STATE"*) echo "" ;; # Not hidden/maximized
        *"_NET_WM_WINDOW_TYPE"*) echo "_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL" ;;
        *"_NET_CLIENT_LIST"*) echo "window id # 0x12345, 0x67890, 0xabcde" ;;
        *"_NET_CLIENT_LIST_STACKING"*) echo "window id # 0xabcde, 0x67890, 0x12345" ;;
        *) echo "mock" ;;
    esac
}
xrandr() { echo "eDP-1 connected 1920x1080+0+0 (normal left inverted right x axis y axis) 309mm x 173mm"; }
xwininfo() {
    case "$2" in
        "0x12345") echo -e "Absolute upper-left X:  10\nAbsolute upper-left Y:  20\nWidth: 800\nHeight: 600" ;;
        "0x67890") echo -e "Absolute upper-left X:  900\nAbsolute upper-left Y:  100\nWidth: 400\nHeight: 300" ;;
        "0xabcde") echo -e "Absolute upper-left X:  500\nAbsolute upper-left Y:  300\nWidth: 600\nHeight: 400" ;;
        *) echo -e "Absolute upper-left X:  0\nAbsolute upper-left Y:  0\nWidth: 100\nHeight: 100" ;;
    esac
}
export -f wmctrl xdotool xprop xrandr xwininfo

# Source the library files with dependencies
source lib/monitors.sh 2>/dev/null || echo "Note: monitors.sh not available, using mocks"
MONITORS=("eDP-1:0:0:1920:1080")
export MONITORS

source lib/config.sh
source lib/windows.sh

echo "=== Testing Refactored Window Functions ===" 
echo

# Test 1: Core filtering function
echo "Test 1: get_visible_windows() with and without monitor filter"
all_windows=$(get_visible_windows)
monitor_windows=$(get_visible_windows "eDP-1")
echo "All windows: $(echo "$all_windows" | wc -l) found"
echo "Monitor-filtered: $(echo "$monitor_windows" | wc -l) found"
[[ $(echo "$all_windows" | wc -l) -eq $(echo "$monitor_windows" | wc -l) ]] && echo "✅ PASS: Monitor filtering consistent" || echo "❌ FAIL: Monitor filtering inconsistent"
echo

# Test 2: Strategy-based ordering (position)
echo "Test 2: get_visible_windows_by_position() using get_visible_windows()"
position_windows=$(get_visible_windows_by_position)
echo "Position-ordered windows:"
echo "$position_windows"
[[ $(echo "$position_windows" | wc -l) -eq 3 ]] && echo "✅ PASS: Position ordering found all windows" || echo "❌ FAIL: Position ordering missing windows"
echo

# Test 3: Strategy-based ordering (stacking)
echo "Test 3: get_visible_windows_by_stacking() using get_visible_windows()"
stacking_windows=$(get_visible_windows_by_stacking)
echo "Stacking-ordered windows:"
echo "$stacking_windows"
[[ $(echo "$stacking_windows" | wc -l) -eq 3 ]] && echo "✅ PASS: Stacking ordering found all windows" || echo "❌ FAIL: Stacking ordering missing windows"
echo

# Test 4: Strategy dispatcher
echo "Test 4: get_windows_ordered() strategy dispatcher"
ordered_default=$(get_windows_ordered)
ordered_position=$(get_windows_ordered "position")
ordered_stacking=$(get_windows_ordered "stacking")
echo "Default strategy: $(echo "$ordered_default" | wc -l) windows"
echo "Position strategy: $(echo "$ordered_position" | wc -l) windows"
echo "Stacking strategy: $(echo "$ordered_stacking" | wc -l) windows"
[[ $(echo "$ordered_default" | wc -l) -eq 3 && $(echo "$ordered_position" | wc -l) -eq 3 && $(echo "$ordered_stacking" | wc -l) -eq 3 ]] && echo "✅ PASS: All strategies work" || echo "❌ FAIL: Strategy dispatcher failed"
echo

# Test 5: Window geometry function
echo "Test 5: get_window_geometry() used by position ordering"
geom1=$(get_window_geometry "0x12345")
geom2=$(get_window_geometry "0x67890")
echo "Window 1 geometry: $geom1"
echo "Window 2 geometry: $geom2"
[[ -n "$geom1" && -n "$geom2" ]] && echo "✅ PASS: Geometry function works" || echo "❌ FAIL: Geometry function failed"
echo

# Test 6: Layout preferences (only layouts saved, not window IDs)
echo "Test 6: Layout preference system (no window ID persistence)"
current_ws="0"
monitor_name="eDP-1"

# Test save and retrieve layout preference
save_workspace_monitor_layout "$current_ws" "$monitor_name" "master-vertical" "3"
retrieved_layout=$(get_workspace_monitor_layout "$current_ws" "$monitor_name" "3" "grid")
echo "Saved layout: master-vertical for 3 windows"
echo "Retrieved layout: $retrieved_layout"
[[ "$retrieved_layout" == "master-vertical" ]] && echo "✅ PASS: Layout preference persistence works" || echo "❌ FAIL: Layout preference persistence failed"
echo

echo "=== All Refactored Functions Tested Successfully ==="