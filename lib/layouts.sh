#!/bin/bash

# Layout functionality for place-window
#
# This file owns the meta-layout primitives (atomic per-monitor functions
# that take a pre-computed window list) and the per-monitor / multi-monitor
# auto-layout dispatchers that route to them.
#
# Functions defined here are called from daemon.sh (watch loop) and from
# place-window directly. Bash resolves function names at call time, so
# forward references to daemon-only helpers (e.g., trigger_daemon_reapply)
# work even though daemon.sh is sourced after this file.

#========================================
# SHARED HELPERS
#========================================

# Initialize layout variables in caller's scope. Callers must pre-declare
# these as `local` so they stay scoped to the caller; otherwise they leak
# into the global namespace.
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

#========================================
# META-LAYOUT PRIMITIVES (single monitor)
#========================================

apply_meta_maximize_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    # Maximize first window with decoration space, minimize others
    apply_geometry "${window_list[0]}" "$final_x" "$final_y" "$final_w" "$final_h"
    for ((i=1; i<${#window_list[@]}; i++)); do
        xdotool windowminimize "${window_list[i]}" 2>/dev/null
    done
}

apply_meta_columns_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    local num_windows=${#window_list[@]}
    local available_w=$((final_w - gap * (num_windows - 1)))
    local column_w=$((available_w / num_windows))

    for ((i=0; i<num_windows; i++)); do
        local x=$((final_x + i * (column_w + gap)))
        apply_geometry "${window_list[i]}" "$x" "$final_y" "$column_w" "$final_h"
    done
}

apply_meta_main_sidebar_single_monitor() {
    local monitor="$1"
    local main_width_percent="$2"
    shift 2
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    local num_windows=${#window_list[@]}

    if [[ $num_windows -eq 1 ]]; then
        apply_meta_maximize_single_monitor "$monitor" "${window_list[@]}"
        return
    fi

    # Gap + decoration between main and sidebar columns
    local gap_between=$((gap + decoration_w))
    local available_w=$((final_w - gap_between))
    local main_w=$((available_w * main_width_percent / 100))
    local sidebar_w=$((available_w - main_w))
    local sidebar_x=$((final_x + main_w + gap_between))

    apply_geometry "${window_list[0]}" "$final_x" "$final_y" "$main_w" "$final_h"

    # Sidebar windows stacked vertically, accounting for decorations between
    local sidebar_windows=$((num_windows - 1))
    local gap_vertical=$((gap + decoration_h))
    local available_sidebar_h=$((final_h - gap_vertical * (sidebar_windows - 1)))
    local sidebar_h=$((available_sidebar_h / sidebar_windows))

    for ((i=1; i<num_windows; i++)); do
        local sidebar_y=$((final_y + (i - 1) * (sidebar_h + gap_vertical)))
        apply_geometry "${window_list[i]}" "$sidebar_x" "$sidebar_y" "$sidebar_w" "$sidebar_h"
    done
}

apply_meta_grid_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    local num_windows=${#window_list[@]}
    local cols=$(( (num_windows + 1) / 2 ))
    local rows=$(( (num_windows + cols - 1) / cols ))

    local gap_vertical=$((gap + decoration_h))

    # Gaps between cells: rows account for decoration_h, columns use raw gap.
    # (DECORATION_WIDTH is typically 0 on dom0 XFCE so the asymmetry is
    # invisible in practice; revisit if column spacing looks tight.)
    local available_w=$((usable_w - gap * 2 - gap * (cols - 1)))
    local available_h=$((usable_h - gap * 2 - gap_vertical * (rows - 1)))
    local cell_w=$((available_w / cols))
    local cell_h=$((available_h / rows))

    for ((i=0; i<num_windows; i++)); do
        local col=$((i % cols))
        local row=$((i / cols))
        local x=$((usable_x + gap + col * (cell_w + gap)))
        local y=$((usable_y + gap + row * (cell_h + gap_vertical)))
        apply_geometry "${window_list[i]}" "$x" "$y" "$cell_w" "$cell_h"
    done
}

apply_meta_topbar_main_single_monitor() {
    local monitor="$1"
    local topbar_height_percent="$2"
    shift 2
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    local num_windows=${#window_list[@]}

    if [[ $num_windows -eq 1 ]]; then
        apply_meta_maximize_single_monitor "$monitor" "${window_list[@]}"
        return
    fi

    # Topbar row + main row, separated by gap+decoration
    local gap_vertical=$((gap + decoration_h))
    local available_h=$((final_h - gap_vertical))
    local topbar_h=$((available_h * topbar_height_percent / 100))
    local main_h=$((available_h - topbar_h))
    local main_y=$((final_y + topbar_h + gap_vertical))

    # Main window takes full width at bottom
    apply_geometry "${window_list[0]}" "$final_x" "$main_y" "$final_w" "$main_h"

    # Topbar windows split the top row in equal columns
    local topbar_windows=$((num_windows - 1))
    if [[ $topbar_windows -gt 0 ]]; then
        local available_topbar_w=$((final_w - gap * (topbar_windows - 1)))
        local topbar_column_w=$((available_topbar_w / topbar_windows))

        for ((i=1; i<num_windows; i++)); do
            local topbar_x=$((final_x + (i - 1) * (topbar_column_w + gap)))
            apply_geometry "${window_list[i]}" "$topbar_x" "$final_y" "$topbar_column_w" "$topbar_h"
        done
    fi
}

apply_meta_center_corners_single_monitor() {
    local monitor="$1"
    shift
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    local gap_vertical=$((gap + decoration_h))
    local available_w=$((usable_w - gap * 4))
    local available_h=$((usable_h - gap * 2 - gap_vertical * 2 - decoration_h))

    local corner_w=$((available_w * 30 / 100))
    local corner_h=$((available_h * 40 / 100))
    local center_w=$((available_w - corner_w * 2))
    local center_h=$((available_h - corner_h * 2))

    local center_x=$((usable_x + gap + corner_w + gap))
    local center_y=$((usable_y + gap + corner_h + gap_vertical))

    # Center window first, then four corners
    apply_geometry "${window_list[0]}" "$center_x" "$center_y" "$center_w" "$center_h"
    apply_geometry "${window_list[1]}" $((usable_x + gap)) $((usable_y + gap)) "$corner_w" "$corner_h"
    apply_geometry "${window_list[2]}" $((usable_x + usable_w - gap - corner_w)) $((usable_y + gap)) "$corner_w" "$corner_h"

    local bottom_corner_y=$((usable_y + gap + corner_h + gap_vertical + center_h + gap_vertical))
    apply_geometry "${window_list[3]}" $((usable_x + gap)) "$bottom_corner_y" "$corner_w" "$corner_h"
    apply_geometry "${window_list[4]}" $((usable_x + usable_w - gap - corner_w)) "$bottom_corner_y" "$corner_w" "$corner_h"
}

apply_meta_center_sidebar_single_monitor() {
    local monitor="$1"
    local center_width_percent="$2"
    shift 2
    local window_list=("$@")

    local layout_area usable_x usable_y usable_w usable_h
    local gap decoration_h decoration_w final_x final_y final_w final_h
    init_layout_vars "$monitor"

    local num_windows=${#window_list[@]}
    if [[ $num_windows -eq 1 ]]; then
        apply_meta_maximize_single_monitor "$monitor" "${window_list[@]}"
        return
    fi

    if [[ $num_windows -eq 2 ]]; then
        apply_meta_main_sidebar_single_monitor "$monitor" "$center_width_percent" "${window_list[@]}"
        return
    fi

    # 3+ windows: left sidebar | center | right sidebar
    local gap_between=$((gap + decoration_w))
    local available_w=$((final_w - gap_between * 2))
    local center_w=$((available_w * center_width_percent / 100))
    local sidebar_total_w=$((available_w - center_w))
    local sidebar_w=$((sidebar_total_w / 2))

    local left_sidebar_x=$final_x
    local center_x=$((final_x + sidebar_w + gap_between))
    local right_sidebar_x=$((center_x + center_w + gap_between))

    apply_geometry "${window_list[0]}" "$center_x" "$final_y" "$center_w" "$final_h"

    # Distribute remaining windows between the two sidebars
    local sidebar_windows=$((num_windows - 1))
    local left_sidebar_count=$((sidebar_windows / 2))
    local right_sidebar_count=$((sidebar_windows - left_sidebar_count))

    if [[ $left_sidebar_count -gt 0 ]]; then
        local gap_vertical=$((gap + decoration_h))
        local available_sidebar_h=$((final_h - gap_vertical * (left_sidebar_count - 1)))
        local left_sidebar_h=$((available_sidebar_h / left_sidebar_count))
        for ((i=1; i<=left_sidebar_count; i++)); do
            local y=$((final_y + (i - 1) * (left_sidebar_h + gap_vertical)))
            apply_geometry "${window_list[i]}" "$left_sidebar_x" "$y" "$sidebar_w" "$left_sidebar_h"
        done
    fi

    if [[ $right_sidebar_count -gt 0 ]]; then
        local gap_vertical=$((gap + decoration_h))
        local available_sidebar_h=$((final_h - gap_vertical * (right_sidebar_count - 1)))
        local right_sidebar_h=$((available_sidebar_h / right_sidebar_count))
        for ((i=0; i<right_sidebar_count; i++)); do
            local window_idx=$((left_sidebar_count + 1 + i))
            local y=$((final_y + i * (right_sidebar_h + gap_vertical)))
            apply_geometry "${window_list[window_idx]}" "$right_sidebar_x" "$y" "$sidebar_w" "$right_sidebar_h"
        done
    fi
}

#========================================
# AUTO-LAYOUT DISPATCHERS
#========================================

# Apply auto-layout to a single monitor based on its window count and the
# user's saved per-workspace, per-monitor preference.
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

    local workspace
    workspace=$(get_current_workspace)
    local default_layout=""

    case $window_count in
        1) default_layout=${AUTO_LAYOUT_1:-maximize} ;;
        2) default_layout=${AUTO_LAYOUT_2:-equal} ;;
        3) default_layout=${AUTO_LAYOUT_3:-main-two-side} ;;
        4) default_layout=${AUTO_LAYOUT_4:-grid} ;;
        5) default_layout=${AUTO_LAYOUT_5:-grid-wide-bottom} ;;
        *) default_layout="grid" ;;
    esac

    local layout
    layout=$(get_workspace_monitor_layout "$workspace" "$monitor_name" "$window_count" "$default_layout")

    case $layout in
        maximize)
            apply_meta_maximize_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
        equal)
            apply_meta_columns_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
        primary-secondary)
            apply_meta_main_sidebar_single_monitor "$monitor" 70 "${windows_on_monitor[@]}" ;;
        secondary-primary)
            apply_meta_main_sidebar_single_monitor "$monitor" 30 "${windows_on_monitor[@]}" ;;
        main-two-side)
            apply_meta_main_sidebar_single_monitor "$monitor" 60 "${windows_on_monitor[@]}" ;;
        three-columns)
            apply_meta_columns_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
        center-sidebars)
            apply_meta_center_sidebar_single_monitor "$monitor" 50 "${windows_on_monitor[@]}" ;;
        grid)
            apply_meta_grid_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
        main-three-side)
            apply_meta_main_sidebar_single_monitor "$monitor" 50 "${windows_on_monitor[@]}" ;;
        three-top-bottom)
            apply_meta_topbar_main_single_monitor "$monitor" 30 "${windows_on_monitor[@]}" ;;
        center-corners)
            apply_meta_center_corners_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
        two-three-columns)
            apply_meta_columns_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
        grid-wide-bottom)
            apply_meta_topbar_main_single_monitor "$monitor" 40 "${windows_on_monitor[@]}" ;;
        *)
            apply_meta_grid_single_monitor "$monitor" "${windows_on_monitor[@]}" ;;
    esac

    echo "Applied $layout layout to monitor $monitor_name"
}

# Clear saved layout for a monitor and re-derive a fresh auto-layout.
auto_layout_and_reset_monitor() {
    local monitor="$1"
    IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"

    local workspace
    workspace=$(get_current_workspace)
    clear_workspace_monitor_layout "$workspace" "$monitor_name"

    local windows_on_monitor=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && windows_on_monitor+=("$line")
    done < <(get_windows_ordered "$monitor_name")

    auto_layout_single_monitor "$monitor" "${windows_on_monitor[@]}"

    # Daemon-side helper; defined in daemon.sh and resolved at call time.
    trigger_daemon_reapply >/dev/null 2>&1
}

# Reapply the saved layout (or fall back to auto) for one monitor.
reapply_saved_layout_for_monitor() {
    local workspace="$1"
    local monitor="$2"

    IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"

    local master_windows=()
    local window_list
    window_list=$(get_windows_ordered "$monitor_name")
    if [[ -n "$window_list" ]]; then
        readarray -t master_windows <<< "$window_list"
    fi

    if [[ ${#master_windows[@]} -gt 0 ]]; then
        local num_windows=${#master_windows[@]}
        local monitor_layout
        monitor_layout=$(get_workspace_monitor_layout "$workspace" "$monitor_name" "" "")

        if [[ -n "$monitor_layout" ]]; then
            echo "Reapplying saved layout '$monitor_layout' to monitor $monitor_name ($num_windows windows)"

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
            echo "No saved preference - applying default auto-layout to monitor $monitor_name ($num_windows windows)"
            auto_layout_single_monitor "$monitor" "${master_windows[@]}"
        fi
    fi
}

auto_layout_current_monitor() {
    get_screen_info
    local current_monitor
    current_monitor=$(get_current_monitor)
    auto_layout_and_reset_monitor "$current_monitor"
}

auto_layout_all_monitors() {
    get_screen_info

    local workspace
    workspace=$(get_current_workspace)
    echo "Auto-arranging windows on workspace $((workspace + 1)) across ${#MONITORS[@]} monitor(s)..."

    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"

        local windows_on_monitor=()
        local window_list
        window_list=$(get_windows_ordered "$monitor_name")
        if [[ -n "$window_list" ]]; then
            readarray -t windows_on_monitor <<< "$window_list"
        fi

        if [[ ${#windows_on_monitor[@]} -gt 0 ]]; then
            auto_layout_single_monitor "$monitor" "${windows_on_monitor[@]}"
        else
            echo "Monitor $monitor_name: No windows to arrange"
        fi
    done

    echo "Auto-layout completed on all monitors"
}

auto_layout() {
    auto_layout_current_monitor
}
