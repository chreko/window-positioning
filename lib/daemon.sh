#!/bin/bash

# Watch daemon functionality for place-window

# Start the daemon directly without subprocess
watch_daemon() {
    echo "Watch daemon started (PID: $$)"
    watch_daemon_internal
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
            IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
            
            # Get master window list (single source of truth)
            local master_windows=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && master_windows+=("$line")
            done < <(get_or_create_master_window_list "$current_workspace" "$monitor")
            
            if [[ ${#master_windows[@]} -gt 0 ]]; then
                # Check for saved layout preference (window count independent)
                local num_windows=${#master_windows[@]}
                local monitor_layout
                monitor_layout=$(get_workspace_monitor_layout "$current_workspace" "$monitor_name" "" "")
                
                if [[ -n "$monitor_layout" ]]; then
                    echo "$(date): Reapplying saved layout '$monitor_layout' to monitor $monitor_name ($num_windows windows)"
                    
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
                    echo "$(date): No saved preference - applying default auto-layout to monitor $monitor_name ($num_windows windows)"
                    auto_layout_single_monitor "$monitor" "${master_windows[@]}"
                fi
            fi
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

# Toggle daemon on/off
toggle_daemon() {
    if is_daemon_running; then
        # Watch mode is running, stop it
        echo "Watch mode is running - stopping..."
        stop_daemon
    else
        # Watch mode is not running, start it in background
        start_daemon_background
    fi
}

# Show daemon status
show_daemon_status() {
    if is_daemon_running; then
        echo "Watch mode is running (PID: $(get_daemon_pid))"
    else
        echo "Watch mode is not running"
    fi
}

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