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
# find_adjacent_windows() moved to windows.sh

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


# minimize_others() moved to windows.sh

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

