#!/bin/bash

# Monitor and layout detection for place-window

# Get current monitor containing the focused window
get_current_monitor() {
    local focused_window=$(xdotool getwindowfocus 2>/dev/null)
    if [[ -n "$focused_window" && "$focused_window" != "0" ]]; then
        get_window_monitor "$focused_window"
    else
        # Fallback to primary monitor if no focused window
        get_primary_monitor
    fi
}

# Get comprehensive screen and monitor information
get_screen_info() {
    # Get total screen dimensions
    local screen_geom
    screen_geom=$(xdotool getdisplaygeometry)
    read -r SCREEN_W SCREEN_H <<< "$screen_geom"
    export SCREEN_W SCREEN_H
    
    # Get monitor information using xrandr
    MONITORS=()
    while IFS= read -r line; do
        if [[ $line =~ ^([^[:space:]]+)[[:space:]]+connected[[:space:]]+([0-9]+x[0-9]+\+[0-9]+\+[0-9]+) ]]; then
            local name="${BASH_REMATCH[1]}"
            local geometry="${BASH_REMATCH[2]}"
            # Parse geometry: WIDTHxHEIGHT+X+Y
            if [[ $geometry =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
                local w="${BASH_REMATCH[1]}"
                local h="${BASH_REMATCH[2]}"
                local x="${BASH_REMATCH[3]}"
                local y="${BASH_REMATCH[4]}"
                MONITORS+=("$name:$x:$y:$w:$h")
            fi
        fi
    done < <(xrandr --query 2>/dev/null)
    
    export MONITORS
    
    # If no monitors detected, create a fallback for the entire screen
    if [[ ${#MONITORS[@]} -eq 0 ]]; then
        MONITORS=("default:0:0:$SCREEN_W:$SCREEN_H")
    fi
}

# Get the primary monitor (where the panel is located)
get_primary_monitor() {
    # Try xrandr primary detection first
    local primary_output=$(xrandr --query 2>/dev/null | grep " primary " | cut -d' ' -f1)
    
    if [[ -n "$primary_output" ]]; then
        # Find the monitor entry that matches the primary output
        for monitor in "${MONITORS[@]}"; do
            IFS=':' read -r name x y w h <<< "$monitor"
            if [[ "$name" == "$primary_output" ]]; then
                echo "$monitor"
                return 0
            fi
        done
    fi
    
    # Fallback: assume monitor at coordinates 0,0 is primary (panel location)
    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r name x y w h <<< "$monitor"
        if [[ $x -eq 0 && $y -eq 0 ]]; then
            echo "$monitor"
            return 0
        fi
    done
    
    # Last resort: use first monitor
    echo "${MONITORS[0]}"
}

# Get which monitor a window is primarily on
get_window_monitor() {
    local window_id="$1"
    local geom=$(get_window_geometry "$window_id")
    IFS=':' read -r wx wy ww wh <<< "$geom"
    
    local best_monitor=""
    local best_overlap=0
    
    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r name mx my mw mh <<< "$monitor"
        
        # Calculate overlap area
        local overlap_x1=$((wx > mx ? wx : mx))
        local overlap_y1=$((wy > my ? wy : my))
        local overlap_x2=$(((wx + ww) < (mx + mw) ? (wx + ww) : (mx + mw)))
        local overlap_y2=$(((wy + wh) < (my + mh) ? (wy + wh) : (my + mh)))
        
        if [[ $overlap_x2 -gt $overlap_x1 && $overlap_y2 -gt $overlap_y1 ]]; then
            local overlap_area=$(((overlap_x2 - overlap_x1) * (overlap_y2 - overlap_y1)))
            if [[ $overlap_area -gt $best_overlap ]]; then
                best_overlap=$overlap_area
                best_monitor="$monitor"
            fi
        fi
    done
    
    # If no overlap found, use first monitor
    [[ -z "$best_monitor" ]] && best_monitor="${MONITORS[0]}"
    echo "$best_monitor"
}

# Get monitor-specific layout area (clean - only accounts for panel space)
get_monitor_layout_area() {
    local monitor="$1"
    IFS=':' read -r name mx my mw mh <<< "$monitor"
    
    local panel_height=$PANEL_HEIGHT
    local panel_autohide="${PANEL_AUTOHIDE:-false}"
    
    # Get the actual primary monitor (where panel is located)
    local primary_monitor=$(get_primary_monitor)
    IFS=':' read -r primary_name primary_x primary_y primary_w primary_h <<< "$primary_monitor"
    
    local usable_x=$mx
    local usable_y=$my
    local usable_w=$mw
    local usable_h
    
    # Check if this monitor is the primary monitor (has the panel)
    local is_primary=false
    if [[ "$name" == "$primary_name" ]]; then
        is_primary=true
    fi
    
    # Handle panel space - only subtract panel height from primary monitor
    if [[ "$panel_autohide" == "true" ]]; then
        # Panel auto-hides - use full monitor space (windows can overlap panel area)
        # No height reduction needed since panel hides automatically
        usable_h=$mh
    else
        # Panel reserves space - start windows below it and reduce height
        if [[ "$is_primary" == "true" ]]; then
            # Panel at top reserves space, so start windows below it
            usable_y=$((my + panel_height))
            usable_h=$((mh - panel_height))
        else
            # No panel on this monitor - use full monitor space
            usable_h=$mh
        fi
    fi
    
    echo "$usable_x:$usable_y:$usable_w:$usable_h"
}

# Function to ensure minimum window size
ensure_minimum_size() {
    local w="$1" h="$2"
    w=$((w < MIN_WIDTH ? MIN_WIDTH : w))
    h=$((h < MIN_HEIGHT ? MIN_HEIGHT : h))
    echo "$w,$h"
}