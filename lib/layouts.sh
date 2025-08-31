#!/bin/bash

# Meta-layout system for place-window

# Initialize common layout variables (DRY principle)
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


# Maximize single window, minimize others
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

# Equal-width columns layout
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

# Main window with sidebar stack
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

# Grid layout (automatic rows/columns)
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

# Top bar with main content area
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

# Center with four corner windows
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

# Center-sidebar layout (3-column: left sidebar | center master | right sidebar)
# Uses stable stacking order - most recently active window becomes center master
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

# Apply auto-layout to a single monitor based on window count
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

# Auto-layout with monitor reset functionality  
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

# Reapply saved layout for a specific workspace/monitor
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

# Auto-layout current monitor only
auto_layout_current_monitor() {
    get_screen_info
    local current_monitor=$(get_current_monitor)
    auto_layout_and_reset_monitor "$current_monitor"
}

# Auto-layout all monitors with coordination
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

# Main auto-layout entry point
auto_layout() {
    auto_layout_current_monitor
}