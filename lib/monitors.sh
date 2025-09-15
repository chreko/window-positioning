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
        # Match both "connected" and "connected primary" patterns
        if [[ $line =~ ^([^[:space:]]+)[[:space:]]+connected([[:space:]]+primary)?[[:space:]]+([0-9]+x[0-9]+\+[0-9]+\+[0-9]+) ]]; then
            local name="${BASH_REMATCH[1]}"
            local geometry="${BASH_REMATCH[3]}"  # Note: index 3 because of the optional primary group
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

    # IMPORTANT: Must ensure MONITORS array is populated before using it
    if [[ ${#MONITORS[@]} -eq 0 ]]; then
        get_screen_info
    fi

    local geom=$(get_window_geometry "$window_id")
    IFS=',' read -r wx wy ww wh <<< "$geom"

    # Check if we got valid geometry
    if [[ -z "$geom" || "$wx" == "" || "$wy" == "" ]]; then
        echo ""  # Return empty string for invalid geometry
        return 1
    fi

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

    # If no overlap found, return empty instead of defaulting to primary monitor
    # This prevents incorrect assignment during daemon startup
    if [[ -z "$best_monitor" ]]; then
        echo ""  # Return empty string instead of defaulting to primary monitor
        return 1
    fi

    echo "$best_monitor"
}

# Global cache variables for panel detection
CACHED_PANELS=()
CACHED_PANELS_TIMESTAMP=0
PANEL_CACHE_DURATION=300  # Cache for 5 minutes

# Detect all XFCE panels and their properties (with caching)
detect_xfce_panels() {
    local current_time=$(date +%s)
    local cache_age=$((current_time - CACHED_PANELS_TIMESTAMP))

    # Return cached results if cache is still valid
    if [[ $cache_age -lt $PANEL_CACHE_DURATION && ${#CACHED_PANELS[@]} -gt 0 ]]; then
        printf '%s\n' "${CACHED_PANELS[@]}"
        return 0
    fi

    # Cache is stale or empty - refresh panel detection
    local panels=()

    # Query all panels from XFCE configuration
    if command -v xfconf-query >/dev/null 2>&1; then
        local panel_ids
        panel_ids=$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+$' || echo "")

        for panel_id in $panel_ids; do
            local position size autohide
            position=$(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/position" 2>/dev/null || echo "")
            size=$(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/size" 2>/dev/null || echo "30")
            autohide=$(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/autohide-behavior" 2>/dev/null || echo "0")

            if [[ -n "$position" ]]; then
                # Parse position: p=N;x=X;y=Y
                if [[ $position =~ p=([0-9]+)\;x=([0-9]+)\;y=([0-9]+) ]]; then
                    local pos_code="${BASH_REMATCH[1]}"
                    local panel_x="${BASH_REMATCH[2]}"
                    local panel_y="${BASH_REMATCH[3]}"

                    # Determine panel placement from position code
                    local placement=""
                    case $pos_code in
                        1|2|3) placement="bottom" ;;    # Bottom Left/Center/Right
                        4|5|6) placement="top" ;;       # Top Left/Center/Right
                        9|10|11) placement="left" ;;    # Left Top/Center/Bottom
                        12|13|14) placement="right" ;;  # Right Top/Center/Bottom
                        *) placement="top" ;;           # Default fallback
                    esac

                    # Convert autohide (0=never, 1=intelligently, 2=always)
                    local hides="false"
                    if [[ "$autohide" != "0" ]]; then
                        hides="true"
                    fi

                    panels+=("${panel_id}:${panel_x}:${panel_y}:${size}:${placement}:${hides}")
                fi
            fi
        done
    fi

    # Update cache
    CACHED_PANELS=("${panels[@]}")
    CACHED_PANELS_TIMESTAMP=$current_time

    printf '%s\n' "${panels[@]}"
}

# Force refresh of panel cache (useful for testing or manual refresh)
refresh_panel_cache() {
    CACHED_PANELS=()
    CACHED_PANELS_TIMESTAMP=0
    detect_xfce_panels >/dev/null
}

# Find which monitor contains a panel based on coordinates
get_panel_monitor() {
    local panel_x="$1" panel_y="$2"

    # IMPORTANT: Must ensure MONITORS array is populated
    if [[ ${#MONITORS[@]} -eq 0 ]]; then
        get_screen_info
    fi

    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r name mx my mw mh <<< "$monitor"

        # Check if panel coordinates are within this monitor
        if [[ $panel_x -ge $mx && $panel_x -lt $((mx + mw)) &&
              $panel_y -ge $my && $panel_y -lt $((my + mh)) ]]; then
            echo "$monitor"
            return 0
        fi
    done

    # Fallback: return primary monitor if no exact match
    get_primary_monitor
}

# Get monitor-specific layout area with dynamic panel detection
get_monitor_layout_area() {
    local monitor="$1"
    IFS=':' read -r name mx my mw mh <<< "$monitor"

    local usable_x=$mx
    local usable_y=$my
    local usable_w=$mw
    local usable_h=$mh

    # Detect all XFCE panels
    local detected_panels
    readarray -t detected_panels < <(detect_xfce_panels)

    # Apply panel space reductions for panels on this monitor
    for panel_info in "${detected_panels[@]}"; do
        if [[ -z "$panel_info" ]]; then continue; fi

        IFS=':' read -r panel_id panel_x panel_y panel_size panel_placement panel_hides <<< "$panel_info"

        # Skip if panel auto-hides
        if [[ "$panel_hides" == "true" ]]; then
            continue
        fi

        # Check if this panel is on the current monitor
        local panel_monitor
        panel_monitor=$(get_panel_monitor "$panel_x" "$panel_y")
        IFS=':' read -r panel_monitor_name _ _ _ _ <<< "$panel_monitor"

        if [[ "$panel_monitor_name" == "$name" ]]; then
            # Apply panel space reduction based on placement
            case "$panel_placement" in
                "top")
                    if [[ $panel_y -le $my ]]; then
                        # Panel at top of monitor
                        usable_y=$((usable_y + panel_size))
                        usable_h=$((usable_h - panel_size))
                    fi
                    ;;
                "bottom")
                    if [[ $panel_y -ge $((my + mh - panel_size)) ]]; then
                        # Panel at bottom of monitor
                        usable_h=$((usable_h - panel_size))
                    fi
                    ;;
                "left")
                    if [[ $panel_x -le $mx ]]; then
                        # Panel at left of monitor
                        usable_x=$((usable_x + panel_size))
                        usable_w=$((usable_w - panel_size))
                    fi
                    ;;
                "right")
                    if [[ $panel_x -ge $((mx + mw - panel_size)) ]]; then
                        # Panel at right of monitor
                        usable_w=$((usable_w - panel_size))
                    fi
                    ;;
            esac
        fi
    done

    # Fallback to legacy behavior if no panels detected
    if [[ ${#detected_panels[@]} -eq 0 || -z "${detected_panels[0]}" ]]; then
        local panel_height=$PANEL_HEIGHT
        local panel_autohide="${PANEL_AUTOHIDE:-false}"

        # Get the primary monitor for legacy behavior
        local primary_monitor
        primary_monitor=$(get_primary_monitor)
        IFS=':' read -r primary_name _ _ _ _ <<< "$primary_monitor"

        # Apply legacy panel logic only to primary monitor
        if [[ "$name" == "$primary_name" && "$panel_autohide" != "true" ]]; then
            # Legacy: assume panel at top of primary monitor
            usable_y=$((my + panel_height))
            usable_h=$((mh - panel_height))
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