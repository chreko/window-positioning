#!/usr/bin/env bash
# test-window-list-persistence.sh: Test to identify window list persistence issues
# 
# HYPOTHESIS: Window lists are not properly persisted in daemon memory.
# - Cycle command creates local window list instead of using daemon's persistent list
# - Layout reapplication uses default window order instead of user-modified order
# - This explains why second cycle fails and layout reapplication reverts

set -x  # Enable debug output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="/tmp/window-list-persistence-test.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== WINDOW LIST PERSISTENCE TEST ==="
echo "Date: $(date)"
echo "Hypothesis: Window lists are not persistent between commands"
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
ensure_initialized_once

# Get current workspace and monitor info
current_workspace=$(get_current_workspace)
get_screen_info
current_monitor=$(get_current_monitor)
monitor_name=$(echo "$current_monitor" | cut -d':' -f1)

echo "=== INITIAL STATE ==="
echo "Current workspace: $current_workspace"
echo "Current monitor: $current_monitor"
echo "Monitor name: $monitor_name"
echo ""

# Test 1: Check initial window list creation
echo "=== TEST 1: Initial Window List Creation ==="
echo "Getting initial window list..."

# Method 1: Direct function call (what cycle might be doing)
echo "Method 1: get_visible_windows_by_creation_for_workspace"
direct_list=$(get_visible_windows_by_creation_for_workspace "$current_workspace")
echo "Direct list: [$direct_list]"

# Method 2: Persistent storage (what daemon should maintain)
echo "Method 2: get_window_list from persistent storage"
stored_list=$(get_window_list "$current_workspace" "$monitor_name")
echo "Stored list: [$stored_list]"

# Check if they match
if [[ "$direct_list" == "$stored_list" ]]; then
    echo "✓ Lists match initially"
else
    echo "✗ Lists differ initially - this could be the problem!"
fi
echo ""

# Test 2: Simulate cycle operation step by step
echo "=== TEST 2: Cycle Operation Breakdown ==="

if [[ -n "$stored_list" ]]; then
    list_array=($stored_list)
    count=${#list_array[@]}
    echo "Original stored list: ${list_array[@]} (count: $count)"
    
    if [[ $count -ge 2 ]]; then
        # Simulate cycle logic
        new_list="${list_array[-1]}"
        for ((j=0; j<count-1; j++)); do
            new_list="$new_list ${list_array[j]}"
        done
        echo "After cycle logic: $new_list"
        
        # Update persistent storage
        echo "Updating persistent storage..."
        set_window_list "$current_workspace" "$monitor_name" "$new_list"
        
        # Verify update
        updated_list=$(get_window_list "$current_workspace" "$monitor_name")
        echo "Stored list after update: [$updated_list]"
        
        if [[ "$updated_list" == "$new_list" ]]; then
            echo "✓ Persistent storage updated correctly"
        else
            echo "✗ Persistent storage update failed!"
        fi
    else
        echo "Not enough windows to test cycle (need at least 2)"
    fi
else
    echo "No stored list to test cycle with"
fi
echo ""

# Test 3: Check what happens during layout reapplication
echo "=== TEST 3: Layout Reapplication Window Source ==="

# What does reapply_saved_layout_for_monitor actually use?
echo "Testing reapply_saved_layout_for_monitor window source..."

# Trace where reapply gets its window list
echo "Current saved layout: $(get_workspace_monitor_layout "$current_workspace" "$monitor_name" "" "")"

# Create a mock function to trace get_visible_windows_by_creation calls
original_get_visible_windows_by_creation=$(declare -f get_visible_windows_by_creation_for_workspace)

get_visible_windows_by_creation_for_workspace() {
    echo "TRACE: get_visible_windows_by_creation_for_workspace called with workspace: $1" >&2
    local result=$(echo "$original_get_visible_windows_by_creation" | tail -n +2 | bash -c "$(cat); get_visible_windows_by_creation_for_workspace \"\$@\"" -- "$@")
    echo "TRACE: get_visible_windows_by_creation_for_workspace returned: [$result]" >&2
    echo "$result"
}

# Also trace get_window_list calls
original_get_window_list=$(declare -f get_window_list)

get_window_list() {
    echo "TRACE: get_window_list called with workspace: $1, monitor: $2" >&2
    local result=$(echo "$original_get_window_list" | tail -n +2 | bash -c "$(cat); get_window_list \"\$@\"" -- "$@")
    echo "TRACE: get_window_list returned: [$result]" >&2
    echo "$result"
}

echo "Calling reapply_saved_layout_for_monitor with tracing..."
reapply_saved_layout_for_monitor "$current_workspace" "$current_monitor"

echo ""

# Test 4: Multiple cycle simulation
echo "=== TEST 4: Multiple Consecutive Cycles ==="

echo "Simulating multiple cycles to identify the pattern..."
for i in {1..3}; do
    echo "--- Cycle $i ---"
    
    # Get current state
    before_list=$(get_window_list "$current_workspace" "$monitor_name")
    echo "Before cycle $i: [$before_list]"
    
    # Perform cycle
    if [[ -n "$before_list" ]]; then
        array=($before_list)
        if [[ ${#array[@]} -ge 2 ]]; then
            # Cycle logic
            new_cycled="${array[-1]}"
            for ((j=0; j<${#array[@]}-1; j++)); do
                new_cycled="$new_cycled ${array[j]}"
            done
            
            # Update storage
            set_window_list "$current_workspace" "$monitor_name" "$new_cycled"
            
            # Check result
            after_list=$(get_window_list "$current_workspace" "$monitor_name")
            echo "After cycle $i: [$after_list]"
            
            if [[ "$after_list" == "$new_cycled" ]]; then
                echo "✓ Cycle $i succeeded"
            else
                echo "✗ Cycle $i failed - storage inconsistent"
            fi
        else
            echo "Not enough windows for cycle $i"
            break
        fi
    else
        echo "No window list for cycle $i"
        break
    fi
    
    echo ""
done

# Test 5: Daemon vs Client Context
echo "=== TEST 5: Daemon vs Client Context ==="

echo "Testing if window list functions behave differently in daemon vs client context..."

# Check if DAEMON_MODE affects behavior
echo "Current DAEMON_MODE: ${DAEMON_MODE:-false}"

# Test with DAEMON_MODE=true
echo "Testing with DAEMON_MODE=true:"
DAEMON_MODE=true
daemon_list=$(get_window_list "$current_workspace" "$monitor_name")
echo "Daemon mode list: [$daemon_list]"

# Test with DAEMON_MODE=false  
echo "Testing with DAEMON_MODE=false:"
DAEMON_MODE=false
client_list=$(get_window_list "$current_workspace" "$monitor_name")
echo "Client mode list: [$client_list]"

if [[ "$daemon_list" == "$client_list" ]]; then
    echo "✓ Lists consistent between daemon/client mode"
else
    echo "✗ Lists differ between daemon/client mode!"
fi

echo ""
echo "=== TEST COMPLETE ==="
echo "Log saved to: $LOG_FILE"
echo ""
echo "KEY QUESTIONS TO ANSWER:"
echo "1. Do stored lists match direct window detection?"
echo "2. Are cycle updates properly persisted?"
echo "3. Does reapply use stored lists or recreate them?"
echo "4. Do multiple cycles work or reset to original order?"
echo "5. Is there daemon vs client context difference?"
echo ""
echo "Run this in dom0 and analyze the output to identify the root cause."