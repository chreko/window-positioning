#!/bin/bash

# Advanced features for place-window

# Find windows adjacent to target window for simultaneous resize
find_adjacent_windows() {
    local target_id="$1"
    local target_geom=$(get_window_geometry "$target_id")
    IFS=',' read -r tx ty tw th <<< "$target_geom"
    
    local adjacent=()
    local windows=($(get_visible_windows_by_position))
    
    for id in "${windows[@]}"; do
        [[ "$id" == "$target_id" ]] && continue
        
        local geom=$(get_window_geometry "$id")
        IFS=',' read -r x y w h <<< "$geom"
        
        # Check if windows share an edge (horizontally or vertically adjacent)
        local gap_tolerance=20  # Allow for small gaps
        
        # Horizontal adjacency (side by side)
        if [[ $((ty - gap_tolerance)) -le $((y + h)) && $((ty + th + gap_tolerance)) -ge $y ]]; then
            # Left adjacent
            if [[ $((tx - gap_tolerance)) -le $((x + w)) && $((tx - gap_tolerance)) -ge $x ]]; then
                adjacent+=("$id:left")
            fi
            # Right adjacent  
            if [[ $((tx + tw + gap_tolerance)) -ge $x && $((tx + tw - gap_tolerance)) -le $((x + w)) ]]; then
                adjacent+=("$id:right")
            fi
        fi
        
        # Vertical adjacency (stacked)
        if [[ $((tx - gap_tolerance)) -le $((x + w)) && $((tx + tw + gap_tolerance)) -ge $x ]]; then
            # Top adjacent
            if [[ $((ty - gap_tolerance)) -le $((y + h)) && $((ty - gap_tolerance)) -ge $y ]]; then
                adjacent+=("$id:top")
            fi
            # Bottom adjacent
            if [[ $((ty + th + gap_tolerance)) -ge $y && $((ty + th - gap_tolerance)) -le $((y + h)) ]]; then
                adjacent+=("$id:bottom")
            fi
        fi
    done
    
    printf '%s\n' "${adjacent[@]}"
}

# Simultaneous resize function (xpytile-inspired)
simultaneous_resize() {
    local direction="$1"  # expand-right, shrink-right, expand-down, shrink-down
    local amount="${2:-50}"  # pixels to resize
    
    local target_id=$(pick_window)
    echo "Finding adjacent windows..."
    
    local adjacent=($(find_adjacent_windows "$target_id"))
    if [[ ${#adjacent[@]} -eq 0 ]]; then
        echo "No adjacent windows found for simultaneous resize"
        return 1
    fi
    
    echo "Found ${#adjacent[@]} adjacent window(s)"
    
    local target_geom=$(get_window_geometry "$target_id")
    IFS=',' read -r tx ty tw th <<< "$target_geom"
    
    case "$direction" in
        expand-right|shrink-right)
            local new_tw=$((tw + (direction == "expand-right" ? amount : -amount)))
            apply_geometry "$target_id" $tx $ty $new_tw $th
            
            # Adjust right-adjacent windows
            for adj in "${adjacent[@]}"; do
                local adj_id="${adj%:*}"
                local adj_dir="${adj#*:}"
                if [[ "$adj_dir" == "right" ]]; then
                    local adj_geom=$(get_window_geometry "$adj_id")
                    IFS=',' read -r ax ay aw ah <<< "$adj_geom"
                    local new_ax=$((ax + (direction == "expand-right" ? amount : -amount)))
                    local new_aw=$((aw + (direction == "expand-right" ? -amount : amount)))
                    apply_geometry "$adj_id" $new_ax $ay $new_aw $ah
                fi
            done
            ;;
        expand-down|shrink-down)
            local new_th=$((th + (direction == "expand-down" ? amount : -amount)))
            apply_geometry "$target_id" $tx $ty $tw $new_th
            
            # Adjust bottom-adjacent windows
            for adj in "${adjacent[@]}"; do
                local adj_id="${adj%:*}"
                local adj_dir="${adj#*:}"
                if [[ "$adj_dir" == "bottom" ]]; then
                    local adj_geom=$(get_window_geometry "$adj_id")
                    IFS=',' read -r ax ay aw ah <<< "$adj_geom"
                    local new_ay=$((ay + (direction == "expand-down" ? amount : -amount)))
                    local new_ah=$((ah + (direction == "expand-down" ? -amount : amount)))
                    apply_geometry "$adj_id" $new_ax $new_ay $aw $new_ah
                fi
            done
            ;;
    esac
    
    echo "Simultaneous resize completed"
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

# Minimize all windows except the active one
minimize_others() {
    local active_id=$(xdotool getactivewindow 2>/dev/null)
    
    if [[ -z "$active_id" || "$active_id" == "0" ]]; then
        echo "No active window found"
        return 1
    fi
    
    # Convert to decimal in case it's in hex format
    active_id=$(printf "%d" "$active_id" 2>/dev/null || echo "$active_id")
    
    local active_title=$(xdotool getwindowname "$active_id" 2>/dev/null || echo "Window $active_id")
    echo "Active window ID: $active_id ($active_title)"
    
    local minimized_count=0
    local kept_count=0
    local visible_windows=($(get_visible_windows_by_position))
    
    echo "Found ${#visible_windows[@]} visible windows to process"
    
    for window_id in "${visible_windows[@]}"; do
        # Convert to decimal for comparison
        local window_decimal=$(printf "%d" "$window_id" 2>/dev/null || echo "$window_id")
        
        if [[ "$window_decimal" != "$active_id" ]]; then
            local title=$(xdotool getwindowname "$window_id" 2>/dev/null || echo "Window $window_id")
            echo "Minimizing: $title (ID: $window_id)"
            xdotool windowminimize "$window_id" 2>/dev/null
            minimized_count=$((minimized_count + 1))
            # Small delay between minimizations to allow X11 events to propagate
            sleep 0.05
        else
            kept_count=$((kept_count + 1))
            echo "Keeping: $active_title (ID: $window_id)"
        fi
    done
    
    # Automatically apply layout to remaining window if daemon is running
    if [[ $minimized_count -gt 0 ]]; then
        if is_daemon_running; then
            echo "Daemon detected - applying layout to remaining window(s)"
            sleep 0.2  # Brief delay to ensure minimization is complete
            
            # Apply appropriate layout to the current monitor
            get_screen_info
            local current_monitor=$(get_current_monitor)
            IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
            
            # Get current workspace and check for saved layout
            local current_workspace=$(get_current_workspace)
            local monitor_layout=$(get_workspace_monitor_layout "$current_workspace" "$monitor_name" 1 "")
            
            # Get windows from persistent list after minimization
            local current_list=$(get_window_list "$current_workspace" "$monitor_name")
            local windows_on_monitor=()
            if [[ -n "$current_list" ]]; then
                read -ra windows_on_monitor <<< "$current_list"
            fi
            
            if [[ ${#windows_on_monitor[@]} -gt 0 ]]; then
                if [[ -n "$monitor_layout" ]]; then
                    echo "Applying saved monitor layout: $monitor_layout"
                    if [[ "$monitor_layout" == "auto" ]]; then
                        auto_layout_single_monitor "$current_monitor" "${windows_on_monitor[@]}"
                    elif [[ "$monitor_layout" =~ ^master[[:space:]](.+)$ ]]; then
                        local master_params="${BASH_REMATCH[1]}"
                        read -r orientation percentage <<< "$master_params"
                        
                        # Reuse existing atomic functions
                        if [[ "$orientation" == "center" ]]; then
                            apply_meta_center_sidebar_single_monitor "$current_monitor" "${percentage:-50}" "${windows_on_monitor[@]}"
                        elif [[ "$orientation" == "vertical" ]]; then
                            apply_meta_main_sidebar_single_monitor "$current_monitor" "${percentage:-60}" "${windows_on_monitor[@]}"
                        else
                            apply_meta_topbar_main_single_monitor "$current_monitor" "${percentage:-60}" "${windows_on_monitor[@]}"
                        fi
                    fi
                else
                    echo "Applying auto-layout to current monitor"
                    auto_layout_single_monitor "$current_monitor" "${windows_on_monitor[@]}"
                fi
            fi
        fi
    fi
    
    if [[ $kept_count -eq 0 ]]; then
        echo "Warning: Active window was not found in visible windows list!"
    fi
    
    echo "Minimized $minimized_count window(s), kept $kept_count active window"
}

# Focus navigation
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