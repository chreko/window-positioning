# NOTE: The following functions have been moved to daemon.sh:
# - master_stack_layout_current_monitor()
# - master_stack_layout()
# - center_master_layout_current_monitor()
# - focus_window()
# - swap_window_positions()
# - cycle_window_positions()
# - reverse_cycle_window_positions()

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
# MOVED TO daemon.sh
# MOVED TO daemon.sh


# Master-stack layouts for all monitors (reuses single-monitor function)
# MOVED TO daemon.sh
# MOVED TO daemon.sh


# Center master layout for current monitor only
# MOVED TO daemon.sh
# MOVED TO daemon.sh


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
# MOVED TO daemon.sh
# MOVED TO daemon.sh


# Window swapping functionality
# MOVED TO daemon.sh
# MOVED TO daemon.sh


# Cycle window positions clockwise (current monitor only)
# MOVED TO daemon.sh
# MOVED TO daemon.sh


# Reverse cycle window positions (counter-clockwise, current monitor only)
# MOVED TO daemon.sh
# MOVED TO daemon.sh

