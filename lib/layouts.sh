#!/bin/bash

# Layout functionality for place-window
#
# This file owns the meta-layout primitives (atomic per-monitor functions
# that take a pre-computed window list) and the per-monitor / multi-monitor
# auto-layout dispatchers that route to them.
#
# Functions defined here are called from daemon.sh (watch loop) and from
# place-window directly. Bash resolves function names at call time, so
# forward references to daemon-only helpers work even though daemon.sh is
# sourced after this file.

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
    # Vertical decoration BUDGET: what a window's frame consumes beyond its
    # client height = title bar (T) + bottom border (B). Positioning uses T
    # alone (apply_geometry lands the client T below the target); budgeting
    # with T only made every window B px too tall, so the bottom gap and
    # every inter-row gap came out B px smaller than the top gap
    # (user-visible "more space above windows than below").
    decoration_h=$((DECORATION_HEIGHT + DECORATION_BOTTOM))
    decoration_w=$DECORATION_WIDTH
    final_x=$((usable_x + gap))
    final_y=$((usable_y + gap))
    final_w=$((usable_w - gap * 2 - decoration_w))
    final_h=$((usable_h - gap * 2 - decoration_h))
}

# Split a strip into N windows separated by `gap_between`. Distributes the
# integer-division remainder across the first windows so the last window's
# trailing edge lands exactly on `start + total - 1`. Without this, a strip
# of three 968-pixel sidebars rounds to 322 each (966 pixels used),
# leaving a visible 2-pixel gap at the bottom.
#
# Usage: split_strip <total> <count> <gap_between> <out_sizes_array>
# Result: out_sizes_array[0..count-1] holds each window's size; the sum of
# sizes plus (count-1)*gap_between equals total exactly.
split_strip() {
    local total="$1" count="$2" gap_between="$3"
    local -n _out="$4"
    _out=()

    if (( count <= 0 )); then
        return
    fi

    local content=$(( total - gap_between * (count - 1) ))
    local base=$(( content / count ))
    local extra=$(( content - base * count ))   # 0 .. count-1

    local i
    for ((i = 0; i < count; i++)); do
        if (( i < extra )); then
            _out+=( $((base + 1)) )
        else
            _out+=( $base )
        fi
    done
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
    local widths=()
    split_strip "$final_w" "$num_windows" "$gap" widths

    local x=$final_x i
    for ((i=0; i<num_windows; i++)); do
        apply_geometry "${window_list[i]}" "$x" "$final_y" "${widths[i]}" "$final_h"
        x=$((x + widths[i] + gap))
    done
}

apply_meta_main_sidebar_single_monitor() {
    # $1 monitor, $2 main_width_percent, [$3 side: left|right (optional)], $@... window IDs
    # Side defaults to "left" (main on left, sidebar on right). "right" flips it.
    # Detection: $3 is the side keyword only if it is exactly "left" or "right";
    # otherwise it is the first window ID and side stays at default.
    local monitor="$1"
    local main_width_percent="$2"
    shift 2
    local side="left"
    if [[ "${1:-}" == "left" || "${1:-}" == "right" ]]; then
        side="$1"
        shift
    fi
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

    local main_x sidebar_x
    if [[ "$side" == "right" ]]; then
        sidebar_x=$final_x
        main_x=$((final_x + sidebar_w + gap_between))
    else
        main_x=$final_x
        sidebar_x=$((final_x + main_w + gap_between))
    fi

    apply_geometry "${window_list[0]}" "$main_x" "$final_y" "$main_w" "$final_h"

    # Sidebar windows stacked vertically, accounting for decorations between
    local sidebar_windows=$((num_windows - 1))
    local gap_vertical=$((gap + decoration_h))
    local heights=()
    split_strip "$final_h" "$sidebar_windows" "$gap_vertical" heights

    local y=$final_y i
    for ((i=1; i<num_windows; i++)); do
        local h=${heights[i-1]}
        apply_geometry "${window_list[i]}" "$sidebar_x" "$y" "$sidebar_w" "$h"
        y=$((y + h + gap_vertical))
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

    # Distribute width across cols and height across rows, absorbing the
    # integer-division remainder so the right and bottom edges align with
    # the usable area. Columns use raw gap; rows use gap_vertical because
    # row separators must clear the lower row's title bar.
    #
    # Like final_w/final_h in init_layout_vars, the strips subtract the
    # decoration once: window heights are CLIENT heights, so the first
    # row's title bar (and side borders) must come out of the strip or
    # the bottom row overflows the usable area by one decoration height.
    # The original modular grid (efeec97) had this term; the faf2fd7
    # consolidation dropped it — 4-window auto layouts then tiled as if
    # the monitor extended one title-bar height below its real bottom.
    local strip_w=$((usable_w - gap * 2 - decoration_w))
    local strip_h=$((usable_h - gap * 2 - decoration_h))
    local cell_widths=() cell_heights=()
    split_strip "$strip_w" "$cols" "$gap" cell_widths
    split_strip "$strip_h" "$rows" "$gap_vertical" cell_heights

    # Pre-compute strip start offsets so each cell knows where its column
    # and row begins.
    local col_x=() row_y=()
    local cx=$((usable_x + gap)) ci
    for ((ci=0; ci<cols; ci++)); do
        col_x+=("$cx")
        cx=$((cx + cell_widths[ci] + gap))
    done
    local cy=$((usable_y + gap)) ri
    for ((ri=0; ri<rows; ri++)); do
        row_y+=("$cy")
        cy=$((cy + cell_heights[ri] + gap_vertical))
    done

    for ((i=0; i<num_windows; i++)); do
        local col=$((i % cols))
        local row=$((i / cols))
        apply_geometry "${window_list[i]}" \
            "${col_x[col]}" "${row_y[row]}" \
            "${cell_widths[col]}" "${cell_heights[row]}"
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
        local topbar_widths=()
        split_strip "$final_w" "$topbar_windows" "$gap" topbar_widths

        local x=$final_x i
        for ((i=1; i<num_windows; i++)); do
            local w=${topbar_widths[i-1]}
            apply_geometry "${window_list[i]}" "$x" "$final_y" "$w" "$topbar_h"
            x=$((x + w + gap))
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

    local gap_vertical=$((gap + decoration_h))

    if [[ $left_sidebar_count -gt 0 ]]; then
        local left_heights=()
        split_strip "$final_h" "$left_sidebar_count" "$gap_vertical" left_heights
        local y=$final_y i
        for ((i=1; i<=left_sidebar_count; i++)); do
            local h=${left_heights[i-1]}
            apply_geometry "${window_list[i]}" "$left_sidebar_x" "$y" "$sidebar_w" "$h"
            y=$((y + h + gap_vertical))
        done
    fi

    if [[ $right_sidebar_count -gt 0 ]]; then
        local right_heights=()
        split_strip "$final_h" "$right_sidebar_count" "$gap_vertical" right_heights
        local y=$final_y i
        for ((i=0; i<right_sidebar_count; i++)); do
            local window_idx=$((left_sidebar_count + 1 + i))
            local h=${right_heights[i]}
            apply_geometry "${window_list[window_idx]}" "$right_sidebar_x" "$y" "$sidebar_w" "$h"
            y=$((y + h + gap_vertical))
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
    done < <(get_windows_ordered "$monitor_name" "" "$workspace")

    auto_layout_single_monitor "$monitor" "${windows_on_monitor[@]}"
}

# Reapply the saved layout (or fall back to auto) for one monitor.
reapply_saved_layout_for_monitor() {
    local workspace="$1"
    local monitor="$2"
    local _t0_ms=$(date +%s%3N)

    IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"

    # Pass workspace through so the window-list filter is consistent with the
    # saved-layout lookup below. Without this, a workspace switch during the
    # apply (these calls take 5-7s end-to-end) lets get_visible_windows read
    # the new desktop live via xdotool, and we end up applying the stale
    # workspace's default-auto fallback to fresh-workspace windows.
    local master_windows=()
    local window_list
    window_list=$(get_windows_ordered "$monitor_name" "" "$workspace")
    if [[ -n "$window_list" ]]; then
        readarray -t master_windows <<< "$window_list"
    fi

    if [[ ${#master_windows[@]} -gt 0 ]]; then
        local num_windows=${#master_windows[@]}
        local monitor_layout
        monitor_layout=$(get_workspace_monitor_layout "$workspace" "$monitor_name" "" "")

        if [[ -n "$monitor_layout" ]]; then
            if [[ "$monitor_layout" == "auto" ]]; then
                { echo "$(date): reapply ws=$workspace monitor=$monitor_name count=$num_windows -> saved='auto'"; } >&6 2>/dev/null
                auto_layout_single_monitor "$monitor" "${master_windows[@]}"
            elif [[ "$monitor_layout" =~ ^master[[:space:]](.+)$ ]]; then
                { echo "$(date): reapply ws=$workspace monitor=$monitor_name count=$num_windows -> saved='$monitor_layout'"; } >&6 2>/dev/null
                local master_params="${BASH_REMATCH[1]}"
                read -r orientation percentage <<< "$master_params"

                case "$orientation" in
                    center)
                        apply_meta_center_sidebar_single_monitor "$monitor" "${percentage:-50}" "${master_windows[@]}"
                        ;;
                    vertical)
                        apply_meta_main_sidebar_single_monitor "$monitor" "${percentage:-60}" left "${master_windows[@]}"
                        ;;
                    vertical-right)
                        apply_meta_main_sidebar_single_monitor "$monitor" "${percentage:-60}" right "${master_windows[@]}"
                        ;;
                    *)
                        apply_meta_topbar_main_single_monitor "$monitor" "${percentage:-60}" "${master_windows[@]}"
                        ;;
                esac
            else
                { echo "$(date): reapply ws=$workspace monitor=$monitor_name count=$num_windows -> unrecognized='$monitor_layout' (falling back to auto)"; } >&6 2>/dev/null
                auto_layout_single_monitor "$monitor" "${master_windows[@]}"
            fi
        else
            { echo "$(date): reapply ws=$workspace monitor=$monitor_name count=$num_windows -> no-saved (applying default auto-layout)"; } >&6 2>/dev/null
            auto_layout_single_monitor "$monitor" "${master_windows[@]}"
        fi

        local _elapsed_ms=$(( $(date +%s%3N) - _t0_ms ))
        { echo "$(date): reapply DONE ws=$workspace monitor=$monitor_name count=$num_windows elapsed=${_elapsed_ms}ms"; } >&6 2>/dev/null
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
        window_list=$(get_windows_ordered "$monitor_name" "" "$workspace")
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
