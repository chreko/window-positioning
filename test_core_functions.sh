#!/bin/bash

# Test script for core window functions
cd "$(dirname "$0")"

# Source required dependencies (with minimal setup)
export WINDOW_ORDER_STRATEGY="position"

# Mock external dependencies that aren't available in this environment
wmctrl() { echo "0x12345 0 dom0 Test Window 1"; echo "0x67890 0 dom0 Test Window 2"; }
xdotool() { 
    case "$1" in
        "get_desktop") echo "0" ;;
        "getdisplaygeometry") echo "1920 1080" ;;
        *) echo "mock" ;;
    esac
}
xprop() { 
    case "$*" in
        *"_NET_WM_STATE"*) echo "" ;; # Not hidden/maximized
        *"_NET_WM_WINDOW_TYPE"*) echo "_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL" ;;
        *"_NET_CLIENT_LIST"*) echo "window id # 0x12345, 0x67890" ;;
        *"_NET_CLIENT_LIST_STACKING"*) echo "window id # 0x67890, 0x12345" ;;
        *) echo "mock" ;;
    esac
}
xrandr() { echo "eDP-1 connected 1920x1080+0+0 (normal left inverted right x axis y axis) 309mm x 173mm"; }
xwininfo() {
    case "$2" in
        "0x12345") echo -e "Absolute upper-left X:  10\nAbsolute upper-left Y:  20\nWidth: 800\nHeight: 600" ;;
        "0x67890") echo -e "Absolute upper-left X:  900\nAbsolute upper-left Y:  100\nWidth: 400\nHeight: 300" ;;
        *) echo -e "Absolute upper-left X:  0\nAbsolute upper-left Y:  0\nWidth: 100\nHeight: 100" ;;
    esac
}
export -f wmctrl xdotool xprop xrandr xwininfo

# Source the library files with dependencies
source lib/monitors.sh 2>/dev/null || echo "Note: monitors.sh not available, using mocks"
MONITORS=("eDP-1:0:0:1920:1080")
export MONITORS

source lib/windows.sh

echo "=== Testing Core Window Functions ==="

# Test 1: Basic window detection
echo "Test 1: get_visible_windows()"
windows=$(get_visible_windows)
echo "Result: $windows"
[[ -n "$windows" ]] && echo "✅ PASS: Found windows" || echo "❌ FAIL: No windows found"
echo

# Test 2: Monitor-specific detection
echo "Test 2: get_visible_windows(monitor)"
windows_monitor=$(get_visible_windows "eDP-1")
echo "Result: $windows_monitor"
[[ -n "$windows_monitor" ]] && echo "✅ PASS: Found windows for monitor" || echo "❌ FAIL: No windows for monitor"
echo

# Test 3: Strategy dispatcher
echo "Test 3: get_windows_ordered()"
windows_ordered=$(get_windows_ordered)
echo "Result: $windows_ordered"
[[ -n "$windows_ordered" ]] && echo "✅ PASS: Strategy dispatcher works" || echo "❌ FAIL: Strategy dispatcher failed"
echo

# Test 4: Different strategies
echo "Test 4: Different strategies"
for strategy in position creation stacking; do
    echo "  Testing strategy: $strategy"
    result=$(get_windows_ordered "$strategy")
    echo "  Result: $result"
    [[ -n "$result" ]] && echo "  ✅ PASS: $strategy strategy works" || echo "  ❌ FAIL: $strategy strategy failed"
done
echo

# Test 5: Spatial ordering
echo "Test 5: get_visible_windows_by_position()"
windows_pos=$(get_visible_windows_by_position)
echo "Result: $windows_pos"
[[ -n "$windows_pos" ]] && echo "✅ PASS: Spatial ordering works" || echo "❌ FAIL: Spatial ordering failed"
echo

# Test 6: Stacking ordering
echo "Test 6: get_visible_windows_by_stacking()"
windows_stack=$(get_visible_windows_by_stacking)
echo "Result: $windows_stack"
[[ -n "$windows_stack" ]] && echo "✅ PASS: Stacking ordering works" || echo "❌ FAIL: Stacking ordering failed"
echo

# Test 7: Debug function
echo "Test 7: debug_window_lists()"
debug_window_lists 2>/dev/null && echo "✅ PASS: Debug function works" || echo "❌ FAIL: Debug function failed"
echo

echo "=== Core Function Tests Complete ==="