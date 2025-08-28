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
    
    # Get windows on the current monitor only
    local windows_on_monitor=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && windows_on_monitor+=("$line")
    done < <(get_visible_windows_on_monitor_by_position "$current_monitor")
    
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
    save_workspace_monitor_layout "$workspace" "$monitor_name" "$num_windows" "master $orientation $percentage"
}

# Master-stack layouts for all monitors
master_stack_layout() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    local windows=($(get_visible_windows_by_position))
    local count=${#windows[@]}
    
    if [[ $count -lt 2 ]]; then
        echo "Master-stack requires at least 2 windows"
        return 1
    fi
    
    # Group windows by monitor and apply master-stack layout to each monitor
    get_screen_info
    local monitors_with_windows=()
    
    # Group windows by monitor
    for monitor in "${MONITORS[@]}"; do
        local windows_on_monitor=()
        for window_id in "${windows[@]}"; do
            local window_monitor=$(get_window_monitor "$window_id")
            if [[ "$window_monitor" == "$monitor" ]]; then
                windows_on_monitor+=("$window_id")
            fi
        done
        
        if [[ ${#windows_on_monitor[@]} -gt 0 ]]; then
            monitors_with_windows+=("$monitor")
            local num_windows=${#windows_on_monitor[@]}
            
            IFS=':' read -r name mx my mw mh <<< "$monitor"
            echo "Monitor $name: Applying master-stack ($orientation, ${percentage}%) to $num_windows window(s)"
            
            if [[ "$orientation" == "vertical" ]]; then
                # Master on left, stack on right - use main-sidebar atomic function
                apply_meta_main_sidebar_single_monitor "$monitor" "$percentage" "${windows_on_monitor[@]}"
            else
                # Master on top, stack on bottom - use topbar-main atomic function  
                apply_meta_topbar_main_single_monitor "$monitor" "$percentage" "${windows_on_monitor[@]}"
            fi
        fi
    done
    
    echo "Master-stack layout ($orientation) applied to ${#monitors_with_windows[@]} monitor(s)"
}

# Center master layout for current monitor only
center_master_layout_current_monitor() {
    local percentage="${1:-50}"
    
    get_screen_info
    local current_monitor=$(get_current_monitor)
    
    local windows_on_monitor=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && windows_on_monitor+=("$line")
    done < <(get_visible_windows_on_monitor_by_position "$current_monitor")
    
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
    save_workspace_monitor_layout "$workspace" "$monitor_name" "$num_windows" "master center $percentage"
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
            
            # Get windows on current monitor after minimization
            local windows_on_monitor=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && windows_on_monitor+=("$line")
            done < <(get_visible_windows_on_monitor_by_position "$current_monitor")
            
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
    
    local geom1=$(get_window_geometry "$window1")
    local geom2=$(get_window_geometry "$window2")
    
    IFS=',' read -r x1 y1 w1 h1 <<< "$geom1"
    IFS=',' read -r x2 y2 w2 h2 <<< "$geom2"
    
    # Swap positions (keeping original sizes)
    apply_geometry "$window1" "$x2" "$y2" "$w1" "$h1"
    apply_geometry "$window2" "$x1" "$y1" "$w2" "$h2"
    
    echo "Windows swapped successfully"
}

# Cycle window positions clockwise
cycle_window_positions() {
    local windows=($(get_visible_windows_by_position))
    local count=${#windows[@]}
    
    if [[ $count -lt 2 ]]; then
        echo "Need at least 2 windows to cycle"
        return 1
    fi
    
    echo "Cycling positions of $count windows clockwise..."
    
    # Get all geometries
    local geometries=()
    for window_id in "${windows[@]}"; do
        geometries+=("$(get_window_geometry "$window_id")")
    done
    
    # Apply each window the geometry of the previous window (cycling)
    for ((i=0; i<count; i++)); do
        local prev_index=$(( (i - 1 + count) % count ))
        local geom="${geometries[prev_index]}"
        IFS=',' read -r x y w h <<< "$geom"
        apply_geometry "${windows[i]}" "$x" "$y" "$w" "$h"
    done
    
    echo "Window positions cycled clockwise"
}

# Reverse cycle window positions (counter-clockwise)
reverse_cycle_window_positions() {
    local windows=($(get_visible_windows_by_position))
    local count=${#windows[@]}
    
    if [[ $count -lt 2 ]]; then
        echo "Need at least 2 windows to cycle"
        return 1
    fi
    
    echo "Cycling positions of $count windows counter-clockwise..."
    
    # Get all geometries
    local geometries=()
    for window_id in "${windows[@]}"; do
        geometries+=("$(get_window_geometry "$window_id")")
    done
    
    # Apply each window the geometry of the next window (reverse cycling)
    for ((i=0; i<count; i++)); do
        local next_index=$(( (i + 1) % count ))
        local geom="${geometries[next_index]}"
        IFS=',' read -r x y w h <<< "$geom"
        apply_geometry "${windows[i]}" "$x" "$y" "$w" "$h"
    done
    
    echo "Window positions cycled counter-clockwise"
}