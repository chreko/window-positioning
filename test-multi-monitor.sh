#!/bin/bash

# Test script for multi-monitor window positioning

# Source required libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/monitors.sh"
source "$SCRIPT_DIR/lib/windows.sh"

echo "=== Multi-Monitor Window Positioning Test ==="
echo

# Initialize configuration
load_config

# Get monitor information
get_screen_info

echo "Detected ${#MONITORS[@]} monitor(s):"
for monitor in "${MONITORS[@]}"; do
    IFS=':' read -r name mx my mw mh <<< "$monitor"
    echo "  Monitor: $name at position ($mx,$my) size ${mw}x${mh}"
done
echo

# Get current workspace
current_ws=$(get_current_workspace)
echo "Current workspace: $current_ws"
echo

# Check windows on each monitor
echo "Windows per monitor:"
for monitor in "${MONITORS[@]}"; do
    IFS=':' read -r name mx my mw mh <<< "$monitor"
    echo "  Monitor $name:"

    # Get windows that should be on this monitor
    local windows_on_monitor=()
    mapfile -t windows_on_monitor < <(get_visible_windows "$name")

    for window_id in "${windows_on_monitor[@]}"; do
        [[ -z "$window_id" ]] && continue

        # Get actual monitor for this window
        actual_monitor=$(get_window_monitor "$window_id")
        IFS=':' read -r actual_name amx amy amw amh <<< "$actual_monitor"

        # Get window geometry
        geom=$(get_window_geometry "$window_id")
        IFS=',' read -r wx wy ww wh <<< "$geom"

        # Get window title
        title=$(xdotool getwindowname "$window_id" 2>/dev/null || echo "Unknown")

        if [[ "$actual_name" == "$name" ]]; then
            echo "    ✓ Window $window_id: '$title' at ($wx,$wy) [CORRECT MONITOR]"
        else
            echo "    ✗ Window $window_id: '$title' at ($wx,$wy) [WRONG: on $actual_name]"
        fi
    done
done
echo

# Test layout application
echo "Testing layout application on each monitor..."
for monitor in "${MONITORS[@]}"; do
    IFS=':' read -r name mx my mw mh <<< "$monitor"

    # Get layout area for this monitor
    layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"

    echo "  Monitor $name:"
    echo "    Full area: ($mx,$my) ${mw}x${mh}"
    echo "    Usable area: ($usable_x,$usable_y) ${usable_w}x${usable_h}"

    # Calculate a test position in the middle of this monitor
    test_x=$((usable_x + usable_w / 4))
    test_y=$((usable_y + usable_h / 4))
    test_w=$((usable_w / 2))
    test_h=$((usable_h / 2))

    echo "    Test position would be: ($test_x,$test_y) ${test_w}x${test_h}"

    # Check if this position is within monitor bounds
    if [[ $test_x -ge $mx && $test_x -lt $((mx + mw)) &&
          $test_y -ge $my && $test_y -lt $((my + mh)) ]]; then
        echo "    ✓ Test position is within monitor bounds"
    else
        echo "    ✗ Test position is OUTSIDE monitor bounds!"
    fi
done

echo
echo "=== Test Complete ==="
echo
echo "To apply a test layout, run:"
echo "  $SCRIPT_DIR/place-window auto"
echo
echo "To check daemon status:"
echo "  $SCRIPT_DIR/place-window watch status"