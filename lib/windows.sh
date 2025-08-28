#!/bin/bash

# Core window management functions for place-window

# Interactive window selection
pick_window() {
    echo "Click on a window to select it..." >&2
    xdotool selectwindow
}

# Get current window geometry
get_window_geometry() {
    local id="$1"
    xwininfo -id "$id" | awk '
        /Absolute upper-left X:/ {x=$NF}
        /Absolute upper-left Y:/ {y=$NF}
        /Width:/ {w=$NF}
        /Height:/ {h=$NF}
        END {print x","y","w","h}
    '
}

# Apply geometry to window
apply_geometry() {
    local id="$1" x="$2" y="$3" w="$4" h="$5"
    wmctrl -i -r "$id" -e "0,${x},${y},${w},${h}"
    echo "Window positioned at: X=$x, Y=$y, Width=$w, Height=$h"
}

# Move window to workspace
move_to_workspace() {
    local id="$1" ws="$2"
    wmctrl -i -r "$id" -t "$ws"
    echo "Window moved to workspace $((ws + 1))"
}

# Save window position to presets
save_position() {
    local name="$1" id="$2"
    local geom=$(get_window_geometry "$id")
    
    # Remove existing entry if exists
    grep -v "^${name}=" "$PRESETS_FILE" > "${PRESETS_FILE}.tmp" || true
    mv "${PRESETS_FILE}.tmp" "$PRESETS_FILE"
    
    # Add new entry
    echo "${name}=${geom}" >> "$PRESETS_FILE"
    echo "Position saved as '$name': $geom"
}

# Load saved position from presets
load_position() {
    local name="$1" id="$2"
    local geom=$(grep "^${name}=" "$PRESETS_FILE" 2>/dev/null | cut -d= -f2)
    
    if [[ -z "$geom" ]]; then
        echo "Error: Preset '$name' not found"
        echo "Available presets:"
        grep -v '^#' "$PRESETS_FILE" | cut -d= -f1 | sed 's/^/  - /'
        exit 1
    fi
    
    IFS=',' read -r x y w h <<< "$geom"
    apply_geometry "$id" "$x" "$y" "$w" "$h"
}

# Get all visible windows on current desktop
get_visible_windows() {
    local current_desktop=$(xdotool get_desktop)
    wmctrl -l | while read -r line; do
        local id=$(echo "$line" | awk '{print $1}')
        local desktop=$(echo "$line" | awk '{print $2}')
        
        # Skip windows not on current desktop
        [[ "$desktop" != "$current_desktop" && "$desktop" != "-1" ]] && continue
        
        # Check if window is minimized or maximized
        local state=$(xprop -id "$id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN|MAXIMIZED")
        [[ -n "$state" ]] && continue
        
        # Skip panels, docks, and desktop
        local type=$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)
        if echo "$type" | grep -qE "DOCK|DESKTOP|TOOLBAR|MENU|SPLASH|NOTIFICATION"; then
            continue
        fi
        
        echo "$id"
    done
}

# Get windows sorted by spatial position (left-to-right, top-to-bottom) instead of chronological order
get_visible_windows_by_position() {
    local current_desktop=$(xdotool get_desktop)
    
    # Get stacking order from X11 (bottom to top)
    local stacking_order=()
    local stacking_raw=$(xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | grep "window id" | sed 's/.*window id # //; s/,//g')
    if [[ -n "$stacking_raw" ]]; then
        read -ra stacking_order <<< "$stacking_raw"
    fi
    
    # Get all visible windows with their positions
    local window_data=()
    
    # Use process substitution to avoid subshell
    while IFS= read -r line; do
        local id=$(echo "$line" | awk '{print $1}')
        local desktop=$(echo "$line" | awk '{print $2}')
        
        # Skip windows not on current desktop
        [[ "$desktop" != "$current_desktop" && "$desktop" != "-1" ]] && continue
        
        # Check if window is minimized or maximized
        local state=$(xprop -id "$id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN|MAXIMIZED")
        [[ -n "$state" ]] && continue
        
        # Skip panels, docks, and desktop
        local type=$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)
        if echo "$type" | grep -qE "DOCK|DESKTOP|TOOLBAR|MENU|SPLASH|NOTIFICATION"; then
            continue
        fi
        
        # Get window geometry
        local geom=$(get_window_geometry "$id")
        if [[ -n "$geom" ]]; then
            IFS=',' read -r x y w h <<< "$geom"
            
            # Find Z-order index (lower index = higher in stack)
            local z_index=999
            for ((i=0; i<${#stacking_order[@]}; i++)); do
                if [[ "${stacking_order[i]}" == "$id" ]]; then
                    z_index=$i
                    break
                fi
            done
            
            # Store: "id:x:y:z_index"
            window_data+=("$id:$x:$y:$z_index")
        fi
    done < <(wmctrl -l)
    
    # Sort by Y coordinate (top to bottom), then X coordinate (left to right), then Z-order
    printf '%s\n' "${window_data[@]}" | sort -t: -k3,3n -k2,2n -k4,4n | cut -d: -f1
}

# Get visible windows on specific monitor, sorted by position
get_visible_windows_on_monitor_by_position() {
    local monitor="$1"
    get_visible_windows_by_position | while read -r id; do
        local window_monitor=$(get_window_monitor "$id")
        if [[ "$window_monitor" == "$monitor" ]]; then
            echo "$id"
        fi
    done
}