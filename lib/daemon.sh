#!/bin/bash

# Watch daemon functionality for place-window

# Set up IPC pipes for daemon communication
setup_daemon_ipc() {
    # Create pipe directory
    mkdir -p "$DAEMON_PIPE_DIR"
    
    # Remove old pipes if they exist
    rm -f "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    
    # Create named pipes
    mkfifo "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    
    # Set permissions
    chmod 600 "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    
    echo "IPC pipes created: $DAEMON_CMD_PIPE, $DAEMON_RESP_PIPE"
}

# Clean up IPC pipes
cleanup_daemon_ipc() {
    rm -f "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    rmdir "$DAEMON_PIPE_DIR" 2>/dev/null || true
    echo "IPC pipes cleaned up"
}

# Auto-layout state management
AUTO_LAYOUT_ENABLED_FILE="${CONFIG_DIR}/auto-layout-enabled"

# Check if auto-layout is enabled
is_auto_layout_enabled() {
    [[ -f "$AUTO_LAYOUT_ENABLED_FILE" ]]
}

# Enable auto-layout
enable_auto_layout() {
    touch "$AUTO_LAYOUT_ENABLED_FILE"
    echo "$(date): Auto-layout enabled"
}

# Disable auto-layout
disable_auto_layout() {
    rm -f "$AUTO_LAYOUT_ENABLED_FILE"
    echo "$(date): Auto-layout disabled"
}

# Toggle auto-layout state
toggle_auto_layout() {
    if is_auto_layout_enabled; then
        disable_auto_layout
        echo "Auto-layout disabled - daemon will run but not apply layouts automatically"
    else
        enable_auto_layout  
        echo "Auto-layout enabled - daemon will automatically apply layouts on window changes"
    fi
}

# Combined daemon that handles both window monitoring and IPC commands
watch_daemon_with_ipc() {
    # Initialize window lists for daemon context
    ensure_initialized_once
    
    # Set up cleanup on exit
    trap 'cleanup_daemon_ipc; echo "Watch daemon stopped"; exit 0' SIGINT SIGTERM
    trap 'echo "$(date): Received reload signal - reapplying layouts"; apply_workspace_layout' SIGUSR1
    
    echo "$(date): Watch daemon with IPC started"
    
    # Initialize auto-layout as enabled by default
    if [[ ! -f "$AUTO_LAYOUT_ENABLED_FILE" ]]; then
        enable_auto_layout
    fi
    
    # Start background window monitoring
    watch_daemon_monitor &
    local monitor_pid=$!
    
    # Handle IPC commands in foreground
    daemon_command_loop
    
    # Clean up when done
    kill "$monitor_pid" 2>/dev/null || true
    cleanup_daemon_ipc
}

# Generate current master state for comparison (extracted from watch_daemon_internal)
get_current_master_state() {
    local current_workspace
    current_workspace=$(get_current_workspace)
    
    # Add small delay to ensure workspace switch is complete
    sleep 0.05
    
    get_screen_info
    local combined_state="workspace:$current_workspace|"
    
    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
        
        # Get window list for this monitor (current workspace only)
        local master_list
        master_list=$(get_window_list "$current_workspace" "$monitor_name")
        
        # Validate that all windows in the list are actually on current workspace
        local validated_list=""
        for window_id in $master_list; do
            if [[ -n "$window_id" ]]; then
                local window_desktop
                window_desktop=$(wmctrl -l | grep "^$window_id " | awk '{print $2}')
                if [[ "$window_desktop" == "$current_workspace" || "$window_desktop" == "-1" ]]; then
                    validated_list="$validated_list $window_id"
                fi
            fi
        done
        master_list=$(echo "$validated_list" | xargs)
        
        # Also get window states to detect minimize/restore
        local window_states=""
        while IFS= read -r window_id; do
            if [[ -n "$window_id" ]]; then
                local state
                state=$(xprop -id "$window_id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN|MAXIMIZED" || echo "NORMAL")
                window_states="${window_states}${window_id}:${state};"
            fi
        done <<< "$master_list"
        
        combined_state="${combined_state}${monitor_name}=[${master_list// /,}]:${window_states}|"
    done
    
    echo "$combined_state"
}

# Apply layout when master state changes (extracted from watch_daemon_internal)
apply_workspace_layout() {
    local current_workspace
    current_workspace=$(get_current_workspace)
    
    get_screen_info
    for monitor in "${MONITORS[@]}"; do
        # Use the shared function for each monitor
        reapply_saved_layout_for_monitor "$current_workspace" "$monitor"
    done
}

# Background window monitoring (simplified from watch_daemon_internal)
watch_daemon_monitor() {
    echo "$(date): Window monitoring started"
    local last_master_state=""
    
    while true; do
        local current_state
        current_state=$(get_current_master_state)
        
        if [[ "$current_state" != "$last_master_state" ]]; then
            echo "$(date): Window state changed"
            
            # Only apply layouts if auto-layout is enabled
            if is_auto_layout_enabled; then
                echo "$(date): Auto-layout enabled - applying layouts"
                apply_workspace_layout
            else
                echo "$(date): Auto-layout disabled - skipping layout application"
            fi
            
            last_master_state="$current_state"
        fi
        
        sleep 0.5  # Check every 500ms
    done
}

# IPC command loop - listens for commands on the pipe
daemon_command_loop() {
    echo "$(date): IPC command listener started"
    
    while true; do
        # Read command from pipe (blocks until command received)
        if read -r command < "$DAEMON_CMD_PIPE" 2>/dev/null; then
            echo "$(date): Received command: $command"
            
            # Handle the command and get response
            local response
            response=$(handle_daemon_command "$command")
            
            # Send response back
            echo "$response" > "$DAEMON_RESP_PIPE" 2>/dev/null || echo "Error: Failed to send response"
        else
            # Pipe was closed or error occurred
            echo "$(date): Command pipe closed - daemon exiting"
            break
        fi
    done
}

# Start the daemon directly without subprocess
watch_daemon() {
    echo "Watch daemon started (PID: $$)"
    
    # Set up IPC pipes for command handling
    setup_daemon_ipc
    
    # Start both window monitoring and command listening
    watch_daemon_with_ipc
}

# Internal daemon implementation with intelligent polling and master window list
watch_daemon_internal() {
    echo "$(date): Intelligent polling watch daemon started"
    echo "$(date): Using master window list as single source of truth"
    
    local last_master_state=""
    
    # Trap signals for clean exit and immediate reapplication
    trap 'echo "Watch daemon stopped"; exit 0' SIGINT SIGTERM
    trap 'echo "$(date): Received reload signal - reapplying layouts"; apply_workspace_layout' SIGUSR1
    
    # Function to generate current master state for comparison
    get_current_master_state() {
        local current_workspace
        current_workspace=$(get_current_workspace)
        
        # Add small delay to ensure workspace switch is complete
        sleep 0.05
        
        get_screen_info
        local combined_state="workspace:$current_workspace|"
        
        echo "$(date): DEBUG - Processing workspace $current_workspace" >&2
        
        for monitor in "${MONITORS[@]}"; do
            IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
            
            # Get master window list for this monitor (current workspace only)
            local master_list
            master_list=$(get_or_create_master_window_list "$current_workspace" "$monitor")
            
            # Validate that all windows in the list are actually on current workspace
            local validated_list=""
            for window_id in $master_list; do
                if [[ -n "$window_id" ]]; then
                    local window_desktop
                    window_desktop=$(wmctrl -l | grep "^$window_id " | awk '{print $2}')
                    if [[ "$window_desktop" == "$current_workspace" || "$window_desktop" == "-1" ]]; then
                        validated_list="$validated_list $window_id"
                    fi
                fi
            done
            master_list=$(echo "$validated_list" | xargs)
            
            # Also get window states to detect minimize/restore
            local window_states=""
            while IFS= read -r window_id; do
                if [[ -n "$window_id" ]]; then
                    local state
                    state=$(xprop -id "$window_id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN|MAXIMIZED" || echo "NORMAL")
                    window_states="${window_states}${window_id}:${state};"
                fi
            done <<< "$master_list"
            
            combined_state="${combined_state}${monitor_name}=[${master_list// /,}]:${window_states}|"
        done
        
        echo "$combined_state"
    }
    
    # Function to apply layout when master state changes
    apply_workspace_layout() {
        local current_workspace
        current_workspace=$(get_current_workspace)
        
        get_screen_info
        for monitor in "${MONITORS[@]}"; do
            # Use the shared function for each monitor
            reapply_saved_layout_for_monitor "$current_workspace" "$monitor"
        done
    }
    
    echo "$(date): Using intelligent polling with master window list tracking"
    echo "$(date): Polling interval: 0.1 seconds for instant response"
    
    local last_workspace=""
    
    while true; do
        # Check for workspace changes and stabilize before processing
        local current_workspace_check
        current_workspace_check=$(get_current_workspace)
        if [[ "$current_workspace_check" != "$last_workspace" ]]; then
            echo "$(date): Workspace changed from $last_workspace to $current_workspace_check - stabilizing..."
            last_workspace="$current_workspace_check"
            sleep 0.2  # Allow workspace change to complete
            continue
        fi
        
        # Get current master state for all monitors (current workspace only)
        local current_master_state
        current_master_state=$(get_current_master_state)
        
        # Compare with previous state, but reset state on workspace change
        local state_key="${current_workspace_check}:${current_master_state}"
        if [[ "$state_key" != "$last_master_state" ]]; then
            # Check if this is just a workspace change (no action needed)
            if [[ "$current_workspace_check" != "${last_master_state%%:*}" ]]; then
                echo "$(date): Workspace changed - resetting state tracking"
            elif [[ -n "$last_master_state" ]]; then
                echo "$(date): Master window state changed on workspace $current_workspace_check - triggering layout"
                
                # Minimal delay to ensure changes are complete
                sleep 0.05
                apply_workspace_layout
            fi
            last_master_state="$state_key"
        fi
        
        # Fast polling interval for instant response
        sleep 0.1
    done
}

# Check if watch daemon is running
is_daemon_running() {
    pgrep -f "place-window.*watch.*daemon" > /dev/null
}

# Get daemon PID if running
get_daemon_pid() {
    pgrep -f "place-window.*watch.*daemon"
}

# Stop watch daemon
stop_daemon() {
    if is_daemon_running; then
        echo "Stopping watch mode daemon..."
        pkill -f "place-window.*watch.*daemon"
        
        # Give daemon time to clean up
        sleep 1
        
        # Force cleanup pipes if daemon didn't do it
        cleanup_daemon_ipc 2>/dev/null || true
        
        echo "Watch mode stopped"
        return 0
    else
        echo "Watch mode is not running"
        return 1
    fi
}

# Start daemon in background
start_daemon_background() {
    if is_daemon_running; then
        echo "Watch mode already running (PID: $(get_daemon_pid))"
        return 1
    fi
    
    echo "Starting watch mode daemon..."
    exec "$0" watch daemon &
    local daemon_pid=$!
    echo "Watch daemon started in background (PID: $daemon_pid)"
    echo "Use 'place-window watch stop' to stop it"
    return 0
}

# Toggle auto-layout on/off (daemon keeps running)
toggle_daemon() {
    if ! is_daemon_running; then
        echo "Daemon is not running. Start with: place-window watch start"
        return 1
    fi
    
    toggle_auto_layout
}

# Show daemon status
show_daemon_status() {
    if is_daemon_running; then
        echo "Watch mode is running (PID: $(get_daemon_pid))"
        if is_auto_layout_enabled; then
            echo "Auto-layout: ENABLED (daemon will apply layouts automatically)"
        else
            echo "Auto-layout: DISABLED (daemon monitoring only, no automatic layouts)"
        fi
    else
        echo "Watch mode is not running"
        echo "Start with: place-window watch start"
    fi
}

#========================================
# DAEMON-ONLY WINDOW LIST FUNCTIONS
# These functions need initialized window lists and run in daemon context
#========================================

# Trigger daemon to immediately reapply layouts (called by manual commands)
trigger_daemon_reapply() {
    if is_daemon_running; then
        local daemon_pid
        daemon_pid=$(get_daemon_pid)
        echo "Triggering daemon to reapply layouts..."
        kill -SIGUSR1 "$daemon_pid" 2>/dev/null
        return $?
    else
        return 1
    fi
}

# IPC Communication for daemon commands
DAEMON_PIPE_DIR="${XDG_RUNTIME_DIR:-/tmp}/window-positioning"
DAEMON_CMD_PIPE="$DAEMON_PIPE_DIR/commands"
DAEMON_RESP_PIPE="$DAEMON_PIPE_DIR/responses"

# Send command to daemon and get response
send_daemon_command() {
    local command="$1"
    
    if ! is_daemon_running; then
        echo "Error: Daemon is not running. Start with: place-window watch start"
        return 1
    fi
    
    # Ensure pipes exist
    if [[ ! -p "$DAEMON_CMD_PIPE" ]]; then
        echo "Error: Daemon command pipe not found"
        return 1
    fi
    
    # Send command and wait for response
    echo "$command" > "$DAEMON_CMD_PIPE"
    
    # Read response (with timeout)
    if read -t 5 response < "$DAEMON_RESP_PIPE" 2>/dev/null; then
        echo "$response"
        return 0
    else
        echo "Error: No response from daemon"
        return 1
    fi
}

# Handle incoming commands in daemon context
handle_daemon_command() {
    local command="$1"
    local response=""
    
    case "$command" in
        "auto")
            response=$(auto_layout_current_monitor 2>&1)
            ;;
        "auto --all")
            response=$(auto_layout_all_monitors 2>&1)
            ;;
        master*)
            # Parse master command: "master vertical 60", "master center 50", "master vertical --all 60"
            read -ra cmd_parts <<< "$command"
            local orientation="${cmd_parts[1]}"
            
            if [[ "$orientation" == "center" ]]; then
                local percentage="${cmd_parts[2]:-50}"
                response=$(center_master_layout_current_monitor "$percentage" 2>&1)
            elif [[ "${cmd_parts[2]}" == "--all" ]]; then
                local percentage="${cmd_parts[3]:-60}"
                response=$(master_stack_layout "$orientation" "$percentage" 2>&1)
            else
                local percentage="${cmd_parts[2]:-60}"
                response=$(master_stack_layout_current_monitor "$orientation" "$percentage" 2>&1)
            fi
            ;;
        cycle*)
            if [[ "$command" == *"counter-clockwise"* ]]; then
                response=$(reverse_cycle_window_positions 2>&1)
            else
                response=$(cycle_window_positions 2>&1)
            fi
            ;;
        "swap")
            response=$(swap_window_positions 2>&1)
            ;;
        focus*)
            read -ra cmd_parts <<< "$command"
            local direction="${cmd_parts[1]}"
            response=$(focus_window "$direction" 2>&1)
            ;;
        *)
            response="Error: Unknown daemon command: $command"
            ;;
    esac
    
    echo "$response"
}

# Master-stack layout for current monitor only
master_stack_layout_current_monitor() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local current_workspace=$(get_current_workspace)
    
    # Get windows from the persistent window list (respects swap/cycle order)
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    local current_list=$(get_window_list "$current_workspace" "$monitor_name")
    local windows_on_monitor=()
    if [[ -n "$current_list" ]]; then
        read -ra windows_on_monitor <<< "$current_list"
    fi
    
    if [[ ${#windows_on_monitor[@]} -eq 0 ]]; then
        echo "No visible windows on current monitor"
        return 1
    fi
    
    IFS=':' read -r name mx my mw mh <<< "$current_monitor"
    local num_windows=${#windows_on_monitor[@]}
    echo "Monitor $name: Applying master-stack ($orientation, ${percentage}%) to $num_windows window(s)"
    
    if [[ "$orientation" == "vertical" ]]; then
        # Master on left, stack on right - use main-sidebar atomic function
        apply_meta_main_sidebar_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
    else
        # Master on top, stack on bottom - use topbar-main atomic function  
        apply_meta_topbar_main_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
    fi
    
    echo "Master-stack layout ($orientation) applied to current monitor"
    
    # Save per-monitor layout
    local workspace=$(get_current_workspace)
    IFS=':' read -r monitor_name rest <<< "$current_monitor"
    save_workspace_monitor_layout "$workspace" "$monitor_name" "master $orientation $percentage" ""
    
    # Trigger daemon to immediately reapply with new preference
    trigger_daemon_reapply >/dev/null 2>&1
}

# Master-stack layouts for all monitors (reuses single-monitor function)
master_stack_layout() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    get_screen_info
    local current_monitor=$(get_current_monitor)
    
    local monitors_applied=0
    local total_windows=0
    
    echo "Applying master-stack ($orientation, ${percentage}%) to all monitors on workspace $((current_workspace + 1))"
    
    # Apply master-stack layout to each monitor by temporarily switching context
    for monitor in "${MONITORS[@]}"; do
        # Get windows from persistent list for this monitor
        IFS=':' read -r name mx my mw mh <<< "$monitor"
        local current_list=$(get_window_list "$current_workspace" "$name")
        local windows_on_monitor=()
        if [[ -n "$current_list" ]]; then
            read -ra windows_on_monitor <<< "$current_list"
        fi
        
        local num_windows=${#windows_on_monitor[@]}
        total_windows=$((total_windows + num_windows))
        
        if [[ $num_windows -gt 0 ]]; then
            IFS=':' read -r name mx my mw mh <<< "$monitor"
            echo "Monitor $name: $num_windows window(s)"
            
            # Temporarily override current monitor context for the single-monitor function
            local original_monitor="$current_monitor"
            
            # Mock get_current_monitor to return this specific monitor
            get_current_monitor() { echo "$monitor"; }
            
            # Apply master-stack layout to this monitor using the single-monitor function
            master_stack_layout_current_monitor "$orientation" "$percentage"
            
            # Restore original get_current_monitor function
            unset -f get_current_monitor
            
            monitors_applied=$((monitors_applied + 1))
        else
            IFS=':' read -r name mx my mw mh <<< "$monitor"
            echo "Monitor $name: No windows to arrange"
        fi
    done
    
    if [[ $total_windows -lt 2 ]]; then
        echo "Master-stack requires at least 2 windows across all monitors (found $total_windows)"
        return 1
    fi
    
    echo "Master-stack layout ($orientation) applied to $monitors_applied monitor(s) with $total_windows total windows"
}

# Center master layout for current monitor only
center_master_layout_current_monitor() {
    local percentage="${1:-50}"
    
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local current_workspace=$(get_current_workspace)
    
    # Get windows from the persistent window list (respects swap/cycle order)
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    local current_list=$(get_window_list "$current_workspace" "$monitor_name")
    local windows_on_monitor=()
    if [[ -n "$current_list" ]]; then
        read -ra windows_on_monitor <<< "$current_list"
    fi
    
    if [[ ${#windows_on_monitor[@]} -eq 0 ]]; then
        echo "No visible windows on current monitor"
        return 1
    fi
    
    IFS=':' read -r name mx my mw mh <<< "$current_monitor"
    local num_windows=${#windows_on_monitor[@]}
    echo "Monitor $name: Applying center master layout (${percentage}%) to $num_windows window(s)"
    
    apply_meta_center_sidebar_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
    
    echo "Center master layout applied to current monitor"
    
    # Save per-monitor layout
    local workspace=$(get_current_workspace)
    IFS=':' read -r monitor_name rest <<< "$current_monitor"
    save_workspace_monitor_layout "$workspace" "$monitor_name" "master center $percentage" ""
    
    # Trigger daemon to immediately reapply with new preference
    trigger_daemon_reapply >/dev/null 2>&1
}
# Focus window navigation
focus_window() {
    local direction="$1"  # next, prev, up, down, left, right
    local current_id=$(xdotool getactivewindow 2>/dev/null || echo "")
    
    if [[ -z "$current_id" ]]; then
        echo "No active window found"
        return 1
    fi
    
    local windows=($(get_visible_windows_by_position))
    local count=${#windows[@]}
    
    if [[ $count -le 1 ]]; then
        echo "Not enough windows for navigation"
        return 1
    fi
    
    case "$direction" in
        next|prev)
            # Find current window index
            local current_index=-1
            for ((i=0; i<count; i++)); do
                if [[ "${windows[i]}" == "$current_id" ]]; then
                    current_index=$i
                    break
                fi
            done
            
            if [[ $current_index -eq -1 ]]; then
                echo "Current window not found in visible windows list"
                return 1
            fi
            
            local next_index
            if [[ "$direction" == "next" ]]; then
                next_index=$(( (current_index + 1) % count ))
            else
                next_index=$(( (current_index - 1 + count) % count ))
            fi
            
            local target_window="${windows[next_index]}"
            xdotool windowactivate "$target_window"
            echo "Focused ${direction} window ($(xdotool getwindowname "$target_window" 2>/dev/null || echo "ID: $target_window"))"
            ;;
        up|down|left|right)
            # Geometric navigation
            local current_geom=$(get_window_geometry "$current_id")
            IFS=',' read -r cx cy cw ch <<< "$current_geom"
            local center_x=$((cx + cw / 2))
            local center_y=$((cy + ch / 2))
            
            local best_window=""
            local best_distance=99999
            
            for window_id in "${windows[@]}"; do
                [[ "$window_id" == "$current_id" ]] && continue
                
                local geom=$(get_window_geometry "$window_id")
                IFS=',' read -r x y w h <<< "$geom"
                local other_center_x=$((x + w / 2))
                local other_center_y=$((y + h / 2))
                
                local valid=false
                local distance=0
                
                case "$direction" in
                    up)
                        if [[ $other_center_y -lt $center_y ]]; then
                            distance=$(( (center_x - other_center_x) * (center_x - other_center_x) + (center_y - other_center_y) * (center_y - other_center_y) ))
                            valid=true
                        fi
                        ;;
                    down)
                        if [[ $other_center_y -gt $center_y ]]; then
                            distance=$(( (center_x - other_center_x) * (center_x - other_center_x) + (other_center_y - center_y) * (other_center_y - center_y) ))
                            valid=true
                        fi
                        ;;
                    left)
                        if [[ $other_center_x -lt $center_x ]]; then
                            distance=$(( (center_x - other_center_x) * (center_x - other_center_x) + (center_y - other_center_y) * (center_y - other_center_y) ))
                            valid=true
                        fi
                        ;;
                    right)
                        if [[ $other_center_x -gt $center_x ]]; then
                            distance=$(( (other_center_x - center_x) * (other_center_x - center_x) + (center_y - other_center_y) * (center_y - other_center_y) ))
                            valid=true
                        fi
                        ;;
                esac
                
                if [[ $valid == true && $distance -lt $best_distance ]]; then
                    best_distance=$distance
                    best_window="$window_id"
                fi
            done
            
            if [[ -n "$best_window" ]]; then
                xdotool windowactivate "$best_window"
                echo "Focused window to the $direction ($(xdotool getwindowname "$best_window" 2>/dev/null || echo "ID: $best_window"))"
            else
                echo "No window found in $direction direction"
                return 1
            fi
            ;;
    esac
}

# Window swapping functionality
swap_window_positions() {
    echo "Select first window to swap:"
    local window1=$(pick_window)
    echo "Select second window to swap:"
    local window2=$(pick_window)
    
    if [[ "$window1" == "$window2" ]]; then
        echo "Cannot swap window with itself"
        return 1
    fi
    
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    local monitor1=$(get_window_monitor "$window1")
    local monitor2=$(get_window_monitor "$window2")
    
    # Get workspace for each window to verify they're on current workspace
    local window1_workspace=$(wmctrl -l 2>/dev/null | grep "^$window1 " | awk '{print $2}')
    local window2_workspace=$(wmctrl -l 2>/dev/null | grep "^$window2 " | awk '{print $2}')
    
    # Check if both windows are on the same monitor AND same workspace
    if [[ "$monitor1" == "$monitor2" ]]; then
        # Verify both windows are on current workspace (or sticky windows with -1)
        if [[ ("$window1_workspace" == "$current_workspace" || "$window1_workspace" == "-1") && 
              ("$window2_workspace" == "$current_workspace" || "$window2_workspace" == "-1") ]]; then
            
            local monitor_name=$(echo "$monitor1" | cut -d':' -f1)
            
            # Swap windows in the persistent window list only
            local result=$(swap_windows_in_list "$current_workspace" "$monitor_name" "$window1" "$window2")
            
            if [[ -n "$result" ]]; then
                read -r window1_pos window2_pos <<< "$result"
                
                # Directly reapply the saved layout for this monitor
                reapply_saved_layout_for_monitor "$current_workspace" "$monitor1"
                
                # Inform user about the master order swap
                if [[ $window1_pos -eq 0 ]]; then
                    echo "Former master window (position 0) swapped with window at position $window2_pos"
                elif [[ $window2_pos -eq 0 ]]; then
                    echo "Window at position $window1_pos became the new master (position 0)"
                else
                    echo "Windows at positions $window1_pos and $window2_pos swapped in master order"
                fi
                
                echo "Master order updated - layout reapplied"
            else
                echo "Warning: One or both windows not found in window list"
            fi
        else
            echo "Cannot swap windows: both windows must be on the current workspace"
            echo "Window 1 workspace: $window1_workspace, Window 2 workspace: $window2_workspace, Current: $current_workspace"
        fi
    else
        echo "Cannot swap windows on different monitors"
        echo "Window 1 monitor: $monitor1"
        echo "Window 2 monitor: $monitor2"
    fi
}

# Cycle window positions clockwise (current monitor only)
cycle_window_positions() {
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local monitor_name=$(echo "$current_monitor" | cut -d':' -f1)
    
    # Get current window list directly (trust persistent storage)
    local current_list=$(get_window_list "$current_workspace" "$monitor_name")
    
    if [[ -z "$current_list" ]]; then
        echo "No windows found on current monitor to cycle"
        return 1
    fi
    
    local list_array=($current_list)
    local count=${#list_array[@]}
    
    if [[ $count -lt 2 ]]; then
        echo "Need at least 2 windows on current monitor to cycle"
        return 1
    fi
    
    echo "Cycling master order of $count windows clockwise on current monitor..."
    
    # Build new cycled list: last element moves to first position
    local new_list="${list_array[-1]}"
    for ((j=0; j<count-1; j++)); do
        new_list="$new_list ${list_array[j]}"
    done
    
    # Update the persistent window list
    set_window_list "$current_workspace" "$monitor_name" "$new_list"
    
    # Directly reapply the saved layout for this monitor
    reapply_saved_layout_for_monitor "$current_workspace" "$current_monitor"
    
    echo "Window master order cycled clockwise - layout reapplied"
}

# Reverse cycle window positions (counter-clockwise, current monitor only)
reverse_cycle_window_positions() {
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local monitor_name=$(echo "$current_monitor" | cut -d':' -f1)
    
    # Get current window list directly (trust persistent storage)
    local current_list=$(get_window_list "$current_workspace" "$monitor_name")
    
    if [[ -z "$current_list" ]]; then
        echo "No windows found on current monitor to cycle"
        return 1
    fi
    
    local list_array=($current_list)
    local count=${#list_array[@]}
    
    if [[ $count -lt 2 ]]; then
        echo "Need at least 2 windows on current monitor to cycle"
        return 1
    fi
    
    echo "Cycling master order of $count windows counter-clockwise on current monitor..."
    
    # Build new reverse-cycled list: first element moves to last position
    local new_list=""
    for ((j=1; j<count; j++)); do
        new_list="$new_list ${list_array[j]}"
    done
    new_list="$new_list ${list_array[0]}"
    new_list=$(echo "$new_list" | xargs)  # Trim whitespace
    
    # Update the persistent window list
    set_window_list "$current_workspace" "$monitor_name" "$new_list"
    
    # Directly reapply the saved layout for this monitor
    reapply_saved_layout_for_monitor "$current_workspace" "$current_monitor"
    
    echo "Window master order cycled counter-clockwise - layout reapplied"
}

#========================================
# AUTO-LAYOUT AND META FUNCTIONS
# Moved from layouts.sh - these need window lists
#========================================

# Initialize layout variables (sets variables in caller's scope)
init_layout_vars() {
    local monitor="$1"
    layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    
    gap=$GAP
    decoration_h=$DECORATION_HEIGHT
    decoration_w=$DECORATION_WIDTH
    final_x=$((usable_x + gap))
    final_y=$((usable_y + gap))
    final_w=$((usable_w - gap * 2 - decoration_w))
    final_h=$((usable_h - gap * 2 - decoration_h))
}

# apply_meta_maximize_single_monitor
apply_meta_maximize_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")
    
    local layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    local gap=$GAP
    local decoration_h=$DECORATION_HEIGHT
    local decoration_w=$DECORATION_WIDTH
    
    # Maximize first window with decoration space, minimize others
    local final_w=$((usable_w - gap * 2 - decoration_w))
    local final_h=$((usable_h - gap * 2 - decoration_h))
    apply_geometry "${window_list[0]}" $((usable_x + gap)) $((usable_y + gap)) $final_w $final_h
    for ((i=1; i<${#window_list[@]}; i++)); do
        xdotool windowminimize "${window_list[i]}" 2>/dev/null
    done
}

# apply_meta_columns_single_monitor
apply_meta_columns_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")
    
    local layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    
    local gap=$GAP
    local decoration_h=$DECORATION_HEIGHT
    local decoration_w=$DECORATION_WIDTH
    local final_x=$((usable_x + gap))
    local final_y=$((usable_y + gap))
    local final_w=$((usable_w - gap * 2 - decoration_w))
    local final_h=$((usable_h - gap * 2 - decoration_h))
    
    local num_windows=${#window_list[@]}
    local available_w=$((final_w - gap * (num_windows - 1)))
    local column_w=$((available_w / num_windows))
    
    for ((i=0; i<num_windows; i++)); do
        local x=$((final_x + i * (column_w + gap)))
        apply_geometry "${window_list[i]}" $x $final_y $column_w $final_h
    done
}

# apply_meta_main_sidebar_single_monitor
apply_meta_main_sidebar_single_monitor() {
    local monitor="$1"
    local main_width_percent="$2"
    shift 2
    local window_list=("$@")
    
    # Use helper function to avoid duplicate variable initialization (DRY principle)
    init_layout_vars "$monitor"
    
    local num_windows=${#window_list[@]}
    
    # If only 1 window, use maximize atomic function
    if [[ $num_windows -eq 1 ]]; then
        apply_meta_maximize_single_monitor "$monitor" "${window_list[@]}"
        return
    fi
    
    # For 2+ windows, do main-sidebar layout
    local gap_between=$((gap + decoration_w))  # Gap + decoration between main and sidebar
    local available_w=$((final_w - gap_between))  # Total width minus gap between windows
    local main_w=$((available_w * main_width_percent / 100))
    local sidebar_w=$((available_w - main_w))
    local sidebar_x=$((final_x + main_w + gap_between))
    
    # Position main window
    apply_geometry "${window_list[0]}" $final_x $final_y $main_w $final_h
    
    # Position sidebar windows (stacked) - account for decorations in vertical spacing
    local sidebar_windows=$((num_windows - 1))
    local gap_vertical=$((gap + decoration_h))  # Gap + decoration between stacked windows
    local available_sidebar_h=$((final_h - gap_vertical * (sidebar_windows - 1)))
    local sidebar_h=$((available_sidebar_h / sidebar_windows))
    
    for ((i=1; i<num_windows; i++)); do
        local sidebar_y=$((final_y + (i - 1) * (sidebar_h + gap_vertical)))
        apply_geometry "${window_list[i]}" $sidebar_x $sidebar_y $sidebar_w $sidebar_h
    done
}

# apply_meta_grid_single_monitor
apply_meta_grid_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")
    
    local layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    
    local num_windows=${#window_list[@]}
    local cols=$(( (num_windows + 1) / 2 ))
    local rows=$(( (num_windows + cols - 1) / cols ))
    
    local gap=$GAP
    local decoration_h=$DECORATION_HEIGHT
    local decoration_w=$DECORATION_WIDTH
    local gap_vertical=$((gap + decoration_h))  # Gap + decoration for vertical spacing
    
    # Account for gaps and decorations between rows
    local available_w=$((usable_w - gap * (cols + 1)))  # Left, right, and between columns
    local available_h=$((usable_h - gap * 2 - gap_vertical * (rows - 1) - decoration_h))  # Top/bottom gaps, vertical gaps, decoration
    local cell_w=$((available_w / cols))
    local cell_h=$((available_h / rows))
    
    for ((i=0; i<num_windows; i++)); do
        local col=$((i % cols))
        local row=$((i / cols))
        local x=$((usable_x + gap + col * (cell_w + gap)))
        local y=$((usable_y + gap + row * (cell_h + gap_vertical)))
        apply_geometry "${window_list[i]}" $x $y $cell_w $cell_h
    done
}

# apply_meta_topbar_main_single_monitor
apply_meta_topbar_main_single_monitor() {
    local monitor="$1"
    local topbar_height_percent="$2"
    shift 2
    local window_list=("$@")
    
    local layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    
    local gap=$GAP
    local decoration_h=$DECORATION_HEIGHT
    local decoration_w=$DECORATION_WIDTH
    local final_x=$((usable_x + gap))
    local final_y=$((usable_y + gap))
    local final_w=$((usable_w - gap * 2 - decoration_w))
    local final_h=$((usable_h - gap * 2 - decoration_h))  # Account for decorations in height only
    
    local num_windows=${#window_list[@]}
    
    # If only 1 window, use maximize atomic function
    if [[ $num_windows -eq 1 ]]; then
        apply_meta_maximize_single_monitor "$monitor" "${window_list[@]}"
        return
    fi
    
    # Calculate topbar and main heights with gap and decoration between them
    local gap_vertical=$((gap + decoration_h))  # Gap + decoration between topbar and main
    local available_h=$((final_h - gap_vertical))  # Available height minus vertical gap
    local topbar_h=$((available_h * topbar_height_percent / 100))
    local main_h=$((available_h - topbar_h))
    local main_y=$((final_y + topbar_h + gap_vertical))
    
    # Position main window (first window) - takes full width at bottom
    apply_geometry "${window_list[0]}" $final_x $main_y $final_w $main_h
    
    # Position topbar windows (all except first) in columns
    local topbar_windows=$((num_windows - 1))
    if [[ $topbar_windows -gt 0 ]]; then
        local available_topbar_w=$((final_w - gap * (topbar_windows - 1)))
        local topbar_column_w=$((available_topbar_w / topbar_windows))
        
        for ((i=1; i<num_windows; i++)); do
            local topbar_x=$((final_x + (i - 1) * (topbar_column_w + gap)))
            apply_geometry "${window_list[i]}" $topbar_x $final_y $topbar_column_w $topbar_h
        done
    fi
}

# apply_meta_center_corners_single_monitor
apply_meta_center_corners_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")
    
    local layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    
    local gap=$GAP
    local decoration_h=$DECORATION_HEIGHT
    local decoration_w=$DECORATION_WIDTH
    
    # Account for decorations in height calculation only
    local gap_vertical=$((gap + decoration_h))  # Gap + decoration for vertical spacing
    local available_w=$((usable_w - gap * 4))  # Left, right, and 2 side gaps
    local available_h=$((usable_h - gap * 2 - gap_vertical * 2 - decoration_h))  # Top/bottom gaps + 2 vertical decoration gaps
    
    local corner_w=$((available_w * 30 / 100))
    local corner_h=$((available_h * 40 / 100))
    local center_w=$((available_w - corner_w * 2))
    local center_h=$((available_h - corner_h * 2))
    
    # Calculate positions (no decoration offset in positioning)
    local center_x=$((usable_x + gap + corner_w + gap))
    local center_y=$((usable_y + gap + corner_h + gap_vertical))
    
    # Position center window first (ids[0])
    apply_geometry "${window_list[0]}" $center_x $center_y $center_w $center_h
    
    # Position corner windows
    # Top corners (ids[1], ids[2])
    apply_geometry "${window_list[1]}" $((usable_x + gap)) $((usable_y + gap)) $corner_w $corner_h
    apply_geometry "${window_list[2]}" $((usable_x + usable_w - gap - corner_w)) $((usable_y + gap)) $corner_w $corner_h
    
    # Bottom corners (ids[3], ids[4]) - account for decoration in vertical spacing
    local bottom_corner_y=$((usable_y + gap + corner_h + gap_vertical + center_h + gap_vertical))
    apply_geometry "${window_list[3]}" $((usable_x + gap)) $bottom_corner_y $corner_w $corner_h
    apply_geometry "${window_list[4]}" $((usable_x + usable_w - gap - corner_w)) $bottom_corner_y $corner_w $corner_h
}

# apply_meta_center_sidebar_single_monitor
apply_meta_center_sidebar_single_monitor() {
    local monitor="$1"
    local center_width_percent="$2"
    shift 2
    local window_list=("$@")
    
    init_layout_vars "$monitor"
    
    local num_windows=${#window_list[@]}
    if [[ $num_windows -eq 1 ]]; then
        # Only one window - use maximize atomic function
        apply_meta_maximize_single_monitor "$monitor" "${window_list[@]}"
        return
    fi
    
    if [[ $num_windows -eq 2 ]]; then
        # Two windows - use main-sidebar atomic function with specified percentage
        apply_meta_main_sidebar_single_monitor "$monitor" "$center_width_percent" "${window_list[@]}"
        return
    fi
    
    # For 3+ windows, create the proper center-sidebar layout:
    # Left sidebar: (100-X)/2 width | Center: X% width | Right sidebar: (100-X)/2 width
    
    # Calculate three-column widths with gaps between them
    local gap_between=$((gap + decoration_w))  # Gap + decoration between columns
    local available_w=$((final_w - gap_between * 2))  # Total width minus 2 gaps between columns
    local center_w=$((available_w * center_width_percent / 100))
    local sidebar_total_w=$((available_w - center_w))
    local sidebar_w=$((sidebar_total_w / 2))
    
    # Calculate column positions
    local left_sidebar_x=$final_x
    local center_x=$((final_x + sidebar_w + gap_between))
    local right_sidebar_x=$((center_x + center_w + gap_between))
    
    # Position center window (first window in stable list)
    apply_geometry "${window_list[0]}" $center_x $final_y $center_w $final_h
    
    # Distribute remaining windows between left and right sidebars
    local sidebar_windows=$((num_windows - 1))
    local left_sidebar_count=$((sidebar_windows / 2))
    local right_sidebar_count=$((sidebar_windows - left_sidebar_count))
    
    # Position left sidebar windows (stacked vertically)
    if [[ $left_sidebar_count -gt 0 ]]; then
        local gap_vertical=$((gap + decoration_h))  # Gap + decoration between stacked windows
        local available_sidebar_h=$((final_h - gap_vertical * (left_sidebar_count - 1)))
        local left_sidebar_h=$((available_sidebar_h / left_sidebar_count))
        for ((i=1; i<=left_sidebar_count; i++)); do
            local y=$((final_y + (i - 1) * (left_sidebar_h + gap_vertical)))
            apply_geometry "${window_list[i]}" $left_sidebar_x $y $sidebar_w $left_sidebar_h
        done
    fi
    
    # Position right sidebar windows (stacked vertically)  
    if [[ $right_sidebar_count -gt 0 ]]; then
        local gap_vertical=$((gap + decoration_h))  # Gap + decoration between stacked windows
        local available_sidebar_h=$((final_h - gap_vertical * (right_sidebar_count - 1)))
        local right_sidebar_h=$((available_sidebar_h / right_sidebar_count))
        for ((i=0; i<right_sidebar_count; i++)); do
            local window_idx=$((left_sidebar_count + 1 + i))
            local y=$((final_y + i * (right_sidebar_h + gap_vertical)))
            apply_geometry "${window_list[window_idx]}" $right_sidebar_x $y $sidebar_w $right_sidebar_h
        done
    fi
}

# auto_layout_single_monitor
auto_layout_single_monitor() {
    local monitor="$1"
    shift
    local windows_on_monitor=("$@")
    
    local window_count=${#windows_on_monitor[@]}
    if [[ $window_count -eq 0 ]]; then
        return
    fi
    
    IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
    echo "Monitor $monitor_name: Applying auto-layout to $window_count window(s)"
    
    # Get workspace and monitor-specific layout preference
    local workspace=$(get_current_workspace)
    local default_layout=""
    
    # Get the default layout for this window count
    case $window_count in
        1) default_layout=${AUTO_LAYOUT_1:-maximize} ;;
        2) default_layout=${AUTO_LAYOUT_2:-equal} ;;
        3) default_layout=${AUTO_LAYOUT_3:-main-two-side} ;;
        4) default_layout=${AUTO_LAYOUT_4:-grid} ;;
        5) default_layout=${AUTO_LAYOUT_5:-grid-wide-bottom} ;;
        *) default_layout="grid" ;;
    esac
    
    # Get saved layout preference for this workspace and monitor
    local layout=$(get_workspace_monitor_layout "$workspace" "$monitor_name" "$window_count" "$default_layout")
    
    # Apply the appropriate layout
    case $layout in
        maximize)
            apply_meta_maximize_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
        equal)
            apply_meta_columns_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
        primary-secondary)
            apply_meta_main_sidebar_single_monitor "$monitor" 70 "${windows_on_monitor[@]}"
            ;;
        secondary-primary) 
            apply_meta_main_sidebar_single_monitor "$monitor" 30 "${windows_on_monitor[@]}"
            ;;
        main-two-side)
            apply_meta_main_sidebar_single_monitor "$monitor" 60 "${windows_on_monitor[@]}"
            ;;
        three-columns)
            apply_meta_columns_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
        center-sidebars)
            apply_meta_center_sidebar_single_monitor "$monitor" 50 "${windows_on_monitor[@]}"
            ;;
        grid)
            apply_meta_grid_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
        main-three-side)
            apply_meta_main_sidebar_single_monitor "$monitor" 50 "${windows_on_monitor[@]}"
            ;;
        three-top-bottom)
            apply_meta_topbar_main_single_monitor "$monitor" 30 "${windows_on_monitor[@]}"
            ;;
        center-corners)
            apply_meta_center_corners_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
        two-three-columns)
            apply_meta_columns_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
        grid-wide-bottom)
            apply_meta_topbar_main_single_monitor "$monitor" 40 "${windows_on_monitor[@]}"
            ;;
        *)
            # Fallback to grid layout
            apply_meta_grid_single_monitor "$monitor" "${windows_on_monitor[@]}"
            ;;
    esac
    
    echo "Applied $layout layout to monitor $monitor_name"
}

# auto_layout_and_reset_monitor
auto_layout_and_reset_monitor() {
    local monitor="$1"
    IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
    
    # Clear saved layouts for this monitor on current workspace
    local workspace=$(get_current_workspace) 
    clear_workspace_monitor_layout "$workspace" "$monitor_name"
    
    # Get windows for this monitor (workspace-aware for persistent ordering)
    local windows_on_monitor=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && windows_on_monitor+=("$line")
    done < <(get_visible_windows_on_monitor_by_creation "$monitor" "$workspace")
    
    # Apply fresh auto-layout
    auto_layout_single_monitor "$monitor" "${windows_on_monitor[@]}"
    
    # Trigger daemon to immediately apply after clearing preferences
    trigger_daemon_reapply >/dev/null 2>&1
}

# reapply_saved_layout_for_monitor
reapply_saved_layout_for_monitor() {
    local workspace="$1"
    local monitor="$2"  # Full monitor string
    
    IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
    
    # Get window list directly from persistent storage and validate
    local master_windows=()
    local window_list=$(get_window_list "$workspace" "$monitor_name")
    if [[ -n "$window_list" ]]; then
        local all_windows=()
        read -ra all_windows <<< "$window_list"
        
        # Filter out dead windows
        for window_id in "${all_windows[@]}"; do
            if [[ -n "$window_id" ]] && xdotool getwindowgeometry "$window_id" >/dev/null 2>&1; then
                local window_desktop=$(wmctrl -l 2>/dev/null | grep "^$window_id " | awk '{print $2}')
                if [[ "$window_desktop" == "$workspace" || "$window_desktop" == "-1" ]]; then
                    master_windows+=("$window_id")
                fi
            fi
        done
        
        # Update the persistent list if we removed dead windows
        if [[ ${#master_windows[@]} -ne ${#all_windows[@]} ]]; then
            set_window_list "$workspace" "$monitor_name" "${master_windows[*]}"
            echo "Cleaned up $(( ${#all_windows[@]} - ${#master_windows[@]} )) dead window(s) from persistent list"
        fi
    fi
    
    if [[ ${#master_windows[@]} -gt 0 ]]; then
        # Check for saved layout preference (window count independent)
        local num_windows=${#master_windows[@]}
        local monitor_layout
        monitor_layout=$(get_workspace_monitor_layout "$workspace" "$monitor_name" "" "")
        
        if [[ -n "$monitor_layout" ]]; then
            echo "Reapplying saved layout '$monitor_layout' to monitor $monitor_name ($num_windows windows)"
            
            # Reapply the saved layout using master window order
            if [[ "$monitor_layout" == "auto" ]]; then
                auto_layout_single_monitor "$monitor" "${master_windows[@]}"
            elif [[ "$monitor_layout" =~ ^master[[:space:]](.+)$ ]]; then
                local master_params="${BASH_REMATCH[1]}"
                read -r orientation percentage <<< "$master_params"
                
                if [[ "$orientation" == "center" ]]; then
                    apply_meta_center_sidebar_single_monitor "$monitor" "${percentage:-50}" "${master_windows[@]}"
                elif [[ "$orientation" == "vertical" ]]; then
                    apply_meta_main_sidebar_single_monitor "$monitor" "${percentage:-60}" "${master_windows[@]}"
                else
                    apply_meta_topbar_main_single_monitor "$monitor" "${percentage:-60}" "${master_windows[@]}"
                fi
            fi
        else
            # No saved layout preference - default to auto-layout
            echo "No saved preference - applying default auto-layout to monitor $monitor_name ($num_windows windows)"
            auto_layout_single_monitor "$monitor" "${master_windows[@]}"
        fi
    fi
}

# auto_layout_current_monitor
auto_layout_current_monitor() {
    get_screen_info
    local current_monitor=$(get_current_monitor)
    auto_layout_and_reset_monitor "$current_monitor"
}

# auto_layout_all_monitors
auto_layout_all_monitors() {
    get_screen_info
    
    local workspace=$(get_current_workspace)
    echo "Auto-arranging windows on workspace $((workspace + 1)) across ${#MONITORS[@]} monitor(s)..."
    
    # Process each monitor independently
    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
        
        # Get windows from persistent list (respects swap/cycle order)
        local current_list=$(get_window_list "$workspace" "$monitor_name")
        local windows_on_monitor=()
        if [[ -n "$current_list" ]]; then
            read -ra windows_on_monitor <<< "$current_list"
        fi
        
        # Apply layout to this monitor
        if [[ ${#windows_on_monitor[@]} -gt 0 ]]; then
            auto_layout_single_monitor "$monitor" "${windows_on_monitor[@]}"
        else
            echo "Monitor $monitor_name: No windows to arrange"
        fi
    done
    
    echo "Auto-layout completed on all monitors"
}

# auto_layout
auto_layout() {
    auto_layout_current_monitor
}