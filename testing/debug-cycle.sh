#!/usr/bin/env bash
# debug-cycle.sh: Debug script for cycle command issues

set -x  # Enable debug output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== CYCLE DEBUG SCRIPT ==="
echo "Date: $(date)"
echo ""

# Source all libraries
source lib/config.sh
source lib/monitors.sh
source lib/windows.sh
source lib/layouts.sh
source lib/daemon.sh
source lib/interactive.sh
source lib/advanced.sh

# Initialize config
init_config
load_config

echo "=== Step 1: Check window detection ==="
echo "Current workspace: $(get_current_workspace)"
echo "Windows on system:"
wmctrl -l

echo ""
echo "=== Step 2: Check monitor detection ==="
get_screen_info
echo "Monitors detected: ${#MONITORS[@]}"
for monitor in "${MONITORS[@]}"; do
    echo "  - $monitor"
done
echo "Current monitor: $(get_current_monitor)"

echo ""
echo "=== Step 3: Check initialization ==="
echo "Running ensure_initialized_once..."
ensure_initialized_once
echo "Initialization complete"

echo ""
echo "=== Step 4: Check window lists ==="
current_workspace=$(get_current_workspace)
current_monitor=$(get_current_monitor)
monitor_name=$(echo "$current_monitor" | cut -d':' -f1)

echo "Workspace: $current_workspace"
echo "Monitor name: $monitor_name"

# Check the window list
window_list=$(get_window_list "$current_workspace" "$monitor_name")
echo "Window list content: [$window_list]"

if [[ -z "$window_list" ]]; then
    echo "ERROR: Window list is empty!"
    
    echo ""
    echo "=== Step 5: Try to populate window list manually ==="
    echo "Getting visible windows by creation..."
    visible_windows=$(get_visible_windows_by_creation)
    echo "Visible windows: $visible_windows"
    
    echo ""
    echo "Getting windows for current workspace..."
    workspace_windows=$(get_visible_windows_by_creation_for_workspace "$current_workspace")
    echo "Workspace windows: $workspace_windows"
    
    echo ""
    echo "=== Step 6: Check window-monitor assignment ==="
    for wid in $visible_windows; do
        window_monitor=$(get_window_monitor "$wid")
        echo "Window $wid -> Monitor: $window_monitor"
    done
else
    echo "Window list has content: $window_list"
    list_array=($window_list)
    echo "Number of windows in list: ${#list_array[@]}"
    
    echo ""
    echo "=== Step 5: Test cycle logic ==="
    if [[ ${#list_array[@]} -lt 2 ]]; then
        echo "Not enough windows to cycle (need at least 2)"
    else
        echo "Current order: ${list_array[@]}"
        
        # Test the cycle logic
        new_list="${list_array[-1]}"
        for ((j=0; j<${#list_array[@]}-1; j++)); do
            new_list="$new_list ${list_array[j]}"
        done
        echo "After cycle: $new_list"
    fi
fi

echo ""
echo "=== Step 7: Test cycle command directly ==="
echo "Calling cycle_window_positions..."
cycle_window_positions

echo ""
echo "=== Step 8: Check saved layouts ==="
saved_layout=$(get_workspace_monitor_layout "$current_workspace" "$monitor_name" "" "")
echo "Saved layout for this workspace/monitor: [$saved_layout]"

echo ""
echo "=== DEBUGGING COMPLETE ==="
echo "Please share this output to diagnose the cycle issue"