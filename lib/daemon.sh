#!/bin/bash

# Watch daemon functionality for place-window

# Start the daemon directly without subprocess
watch_daemon() {
    echo "Watch daemon started (PID: $$)"
    watch_daemon_internal
}

# Internal daemon implementation
watch_daemon_internal() {
    # Efficient event-driven daemon - monitors key X11 properties to avoid process explosion
    echo "$(date): Efficient event-driven watch daemon started"
    echo "$(date): Using combined monitoring approach to prevent resource exhaustion"
    
    # Trap signals for clean exit
    local monitor_pids=()
    trap 'echo "Watch daemon stopped"; for pid in "${monitor_pids[@]}"; do kill $pid 2>/dev/null; done; exit 0' SIGINT SIGTERM
    
    # Function to apply layout when window state changes
    apply_workspace_layout() {
        local trigger_reason="$1"
        
        local current_workspace
        current_workspace=$(get_current_workspace)
        
        # First, try to apply per-monitor layouts
        get_screen_info
        local any_monitor_layout_applied=false
        
        for monitor in "${MONITORS[@]}"; do
            IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
            
            # Check if there's a layout saved for this specific monitor
            local monitor_layout
            monitor_layout=$(get_workspace_monitor_layout "$current_workspace" "$monitor_name" 2>/dev/null)
            
            # Get windows on this monitor
            local windows_on_monitor=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && windows_on_monitor+=("$line")
            done < <(get_visible_windows_on_monitor_by_creation "$monitor")
            
            if [[ ${#windows_on_monitor[@]} -gt 0 ]]; then
                if [[ -n "$monitor_layout" ]]; then
                    echo "$(date): $trigger_reason - applying monitor-specific layout '$monitor_layout' to monitor $monitor_name"
                    
                    # Parse and apply the monitor-specific layout
                    if [[ "$monitor_layout" == "auto" ]]; then
                        # Skip auto-layout to prevent unwanted window repositioning
                        echo "$(date): Skipping saved auto-layout for monitor $monitor_name to prevent repositioning"
                        any_monitor_layout_applied=true
                    elif [[ "$monitor_layout" =~ ^master[[:space:]](.+)$ ]]; then
                        local master_params="${BASH_REMATCH[1]}"
                        echo "$(date): Applying master layout to monitor $monitor_name: $master_params"
                        
                        # Parse master parameters (e.g., "vertical 60", "center 50")
                        read -r orientation percentage <<< "$master_params"
                        
                        # Apply to specific monitor
                        if [[ "$orientation" == "center" ]]; then
                            apply_meta_center_sidebar_single_monitor "$monitor" "${percentage:-50}" "${windows_on_monitor[@]}"
                        else
                            # vertical or horizontal
                            if [[ "$orientation" == "vertical" ]]; then
                                apply_meta_main_sidebar_single_monitor "$monitor" "${percentage:-60}" "${windows_on_monitor[@]}"
                            else
                                apply_meta_topbar_main_single_monitor "$monitor" "${percentage:-60}" "${windows_on_monitor[@]}"
                            fi
                        fi
                        any_monitor_layout_applied=true
                    fi
                else
                    # No layout saved for this monitor - apply auto-layout for this monitor only
                    echo "$(date): $trigger_reason - applying auto-layout to monitor $monitor_name (${#windows_on_monitor[@]} windows)"
                    auto_layout_single_monitor "$monitor" "${windows_on_monitor[@]}"
                    any_monitor_layout_applied=true
                fi
            fi
        done
        
        # If no monitor-specific layouts were applied, fall back to workspace-wide layout
        if [[ "$any_monitor_layout_applied" == "false" ]]; then
            echo "$(date): $trigger_reason - no monitor layouts applied, skipping workspace layout to prevent cursor issues"
            # Disable workspace-wide layout execution to prevent cursor issues
            # This prevents the daemon from executing potentially malformed layout commands
            # that could trigger pick_window() and show the cursor
        fi
    }
    
    echo "$(date): Starting efficient X11 property monitoring"
    
    # Monitor window creation/destruction with _NET_CLIENT_LIST
    echo "$(date): Monitoring window creation/destruction events"
    xprop -spy -root _NET_CLIENT_LIST 2>/dev/null | while IFS= read -r line; do
        if [[ -n "$line" && "$line" =~ _NET_CLIENT_LIST ]]; then
            echo "$(date): Window list changed (create/destroy)"
            apply_workspace_layout "Window list change"
        fi
    done &
    
    local client_list_pid=$!
    monitor_pids+=($client_list_pid)
    
    # Monitor window minimize/restore with _NET_CLIENT_LIST_STACKING
    echo "$(date): Monitoring window stacking/state events"
    xprop -spy -root _NET_CLIENT_LIST_STACKING 2>/dev/null | while IFS= read -r line; do
        if [[ -n "$line" && "$line" =~ _NET_CLIENT_LIST_STACKING ]]; then
            echo "$(date): Window stacking changed (minimize/restore/reorder)"
            
            # Brief delay to avoid rapid-fire during multi-window operations
            sleep 0.1
            apply_workspace_layout "Window stacking change"
        fi
    done &
    
    local stacking_pid=$!
    monitor_pids+=($stacking_pid)
    
    # Optional: Monitor workspace changes if supported
    if xprop -root _NET_CURRENT_DESKTOP >/dev/null 2>&1; then
        echo "$(date): Monitoring workspace changes"
        xprop -spy -root _NET_CURRENT_DESKTOP 2>/dev/null | while IFS= read -r line; do
            if [[ -n "$line" && "$line" =~ _NET_CURRENT_DESKTOP ]]; then
                echo "$(date): Workspace changed"
                # Small delay to let workspace switch complete
                sleep 0.3
                apply_workspace_layout "Workspace change"
            fi
        done &
        
        local workspace_pid=$!
        monitor_pids+=($workspace_pid)
    fi
    
    echo "$(date): Event-driven daemon initialized with ${#monitor_pids[@]} monitoring processes"
    echo "$(date): Maximum resource usage: ${#monitor_pids[@]} background processes (vs potentially 100s with per-window monitoring)"
    
    # Wait for all monitoring processes
    wait
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