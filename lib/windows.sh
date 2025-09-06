#!/bin/bash

# Core window management functions for place-window

# Window positioning and management functions
# Provides core window detection and ordering capabilities

# Interactive window selection
pick_window() {
    echo "Click on a window to select it..." >&2
    xdotool selectwindow
}

# Get current window geometry (frame coordinates)
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

# --- Frame extents: left,right,top,bottom (defaults to 0s if missing) ---
get_frame_extents() {  # $1: window id
    local id="$1"
    local ext
    ext=$(xprop -id "$id" _NET_FRAME_EXTENTS 2>/dev/null | awk -F' = ' '{print $2}')
    if [[ -n "$ext" ]]; then
        echo "$ext" | awk -F', ' '{print $1","$2","$3","$4}'
    else
        echo "0,0,0,0"
    fi
}

# --- Read CLIENT geometry consistently as x,y,w,h ---
get_window_client_geometry() {
    local id="$1"
    local info x y w h L R T B
    info=$(xwininfo -id "$id")
    x=$(awk '/Absolute upper-left X:/ {print $NF}' <<<"$info")
    y=$(awk '/Absolute upper-left Y:/ {print $NF}' <<<"$info")
    w=$(awk '/Width:/ {print $NF}' <<<"$info")
    h=$(awk '/Height:/ {print $NF}' <<<"$info")
    IFS=',' read -r L R T B <<<"$(xprop -id "$id" _NET_FRAME_EXTENTS 2>/dev/null | awk -F' = ' '{print $2}' | sed 's/, /,/g')"
    [[ -z "$L" ]] && L=0 R=0 T=0 B=0
    echo "$((x + L)),$((y + T)),$w,$h"
}

# --- Apply CLIENT geometry directly ---
place_window_client_geometry() {  # $1:id $2:x $3:y $4:w $5:h
    local id="$1" x="$2" y="$3" w="$4" h="$5"
    wmctrl -i -r "$id" -e "0,${x},${y},${w},${h}" 2>/dev/null
}

# ----- Stable geometry helpers (wmctrl) -----

# Read FRAME geometry using wmctrl itself (id -> "x,y,w,h")
get_window_frame_geometry_wmctrl() {
    # Normalize id to lowercase (wmctrl prints lowercase)
    local id="${1,,}"
    # wmctrl -i -lG: $1=id $3=x $4=y $5=w $6=h
    wmctrl -i -lG | awk -v id="$id" '$1==id{print $3","$4","$5","$6; f=1} END{if(!f) exit 1}'
}

# Apply geometry using wmctrl (expects either frame or client X/Y depending on WM)
_apply_with_wmctrl() {  # id x y w h
    wmctrl -i -r "$1" -e "0,$2,$3,$4,$5" 2>/dev/null
}

# Optional: client geometry (from xwininfo + frame extents)
_get_client_geom() {  # id -> "x,y,w,h"
    local id="$1" info x y w h L R T B
    info=$(xwininfo -id "$id")
    x=$(awk '/Absolute upper-left X:/ {print $NF}' <<<"$info")
    y=$(awk '/Absolute upper-left Y:/ {print $NF}' <<<"$info")
    w=$(awk '/Width:/ {print $NF}' <<<"$info")
    h=$(awk '/Height:/ {print $NF}' <<<"$info")
    read -r L R T B < <(xprop -id "$id" _NET_FRAME_EXTENTS 2>/dev/null \
                       | awk -F' = ' '{print $2}' | sed 's/, / /g')
    : "${L:=0}"; : "${T:=0}"
    echo "$((x + L)),$((y + T)),$w,$h"
}

# ----- Detect how wmctrl -e interprets X/Y on this WM -----
# Caches in WMCTRL_COORD_MODE: "frame" or "client"
detect_wmctrl_coord_mode() {
    [[ -n "${WMCTRL_COORD_MODE:-}" ]] && return 0
    # Pick the currently active window
    local active
    active=$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk -F'# ' '{print $2}')
    [[ -z "$active" ]] && { export WMCTRL_COORD_MODE="frame"; return 0; }

    # Baselines
    local fx fy fw fh cx cy cw ch
    IFS=',' read -r fx fy fw fh <<<"$(get_window_frame_geometry_wmctrl "$active")"
    IFS=',' read -r cx cy cw ch <<<"$(_get_client_geom "$active")"

    # Try a no-op apply using FRAME coords
    _apply_with_wmctrl "$active" "$fx" "$fy" "$fw" "$fh"
    sleep 0.02
    # Read back frame position
    local nfx nfy
    IFS=',' read -r nfx nfy _ _ <<<"$(get_window_frame_geometry_wmctrl "$active")"

    if [[ "$nfx" == "$fx" && "$nfy" == "$fy" ]]; then
        export WMCTRL_COORD_MODE="frame"
    else
        # Try no-op using CLIENT coords
        _apply_with_wmctrl "$active" "$cx" "$cy" "$cw" "$ch"
        sleep 0.02
        IFS=',' read -r nfx nfy _ _ <<<"$(get_window_frame_geometry_wmctrl "$active")"
        # If moving to client coords is a no-op, wmctrl wants client
        if [[ "$nfx" == "$fx" && "$nfy" == "$fy" ]]; then
            # Some WMs still end up identical; prefer client if first try shifted
            export WMCTRL_COORD_MODE="client"
        else
            export WMCTRL_COORD_MODE="client"
        fi
    fi
}

# Apply geometry in the coordinate space that wmctrl expects on this WM
apply_geom_adaptive() {  # id targetFrameX targetFrameY width height
    detect_wmctrl_coord_mode
    local id="$1" fx="$2" fy="$3" w="$4" h="$5"
    if [[ "$WMCTRL_COORD_MODE" == "client" ]]; then
        # Convert frame X/Y -> client X/Y (only when needed)
        local cx cy cw ch L R T B info x y
        IFS=',' read -r cx cy cw ch <<<"$(_get_client_geom "$id")"  # current client
        # We only need L,T; get from current window
        read -r L R T B < <(xprop -id "$id" _NET_FRAME_EXTENTS 2>/dev/null \
                           | awk -F' = ' '{print $2}' | sed 's/, / /g')
        : "${L:=0}"; : "${T:=0}"
        _apply_with_wmctrl "$id" "$((fx + L))" "$((fy + T))" "$w" "$h"
    else
        _apply_with_wmctrl "$id" "$fx" "$fy" "$w" "$h"
    fi
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
    local f
    f=$(get_window_frame_geometry_wmctrl "$id") || { echo "Window not found"; return 1; }
    grep -v "^${name}=" "$PRESETS_FILE" > "${PRESETS_FILE}.tmp" 2>/dev/null || true
    mv "${PRESETS_FILE}.tmp" "$PRESETS_FILE"
    echo "${name}=${f}" >> "$PRESETS_FILE"
    echo "Saved '$name' as $f"
}

# Load saved position from presets
load_position() {
    local name="$1" id="$2"
    local geom
    geom=$(grep "^${name}=" "$PRESETS_FILE" 2>/dev/null | cut -d= -f2)
    [[ -z "$geom" ]] && { echo "Preset '$name' not found"; return 1; }
    IFS=',' read -r fx fy w h <<<"$geom"
    apply_geom_adaptive "$id" "$fx" "$fy" "$w" "$h"
}

# Get all visible windows on current desktop
get_visible_windows() {
    local monitor_name="$1"  # Optional: if provided, filter by this monitor
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
        
        # Skip ignored applications from config
        local class=$(xprop -id "$id" WM_CLASS 2>/dev/null | sed -n 's/.*= \(.*\)/\1/p' | tr -d '"')
        local title=$(xprop -id "$id" _NET_WM_NAME 2>/dev/null | sed -n 's/.*= "\(.*\)"/\1/p')
        [[ -z "$title" ]] && title=$(xprop -id "$id" WM_NAME 2>/dev/null | sed -n 's/.*= "\(.*\)"/\1/p')
        if [[ -n "$IGNORED_APPS" && (-n "$class" || -n "$title") ]]; then
            # Convert comma-separated list to array (zsh/bash compatible)
            local IFS=','
            local ignored_array=($IGNORED_APPS)
            local should_skip=false
            for app in "${ignored_array[@]}"; do
                # Trim whitespace
                app=$(echo "$app" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$app" ]] && continue
                
                # Check for case-sensitive prefix
                local case_sensitive=false
                if [[ "$app" == cs:* ]]; then
                    case_sensitive=true
                    app="${app#cs:}"
                fi
                
                # Convert wildcards (* and ?) to regex patterns
                local pattern="$app"
                # Escape special regex characters except * and ?
                pattern=$(echo "$pattern" | sed 's/\([[\\.^$()+{}|]\)/\\\1/g')
                # Now convert wildcards
                pattern=$(echo "$pattern" | sed 's/\*/\.\*/g; s/\?/\./g')
                # If no wildcards present, make it an exact match with anchors
                if [[ "$app" != *"*"* && "$app" != *"?"* ]]; then
                    pattern="^${pattern}$"
                fi
                
                # Apply case sensitivity and check both class and title
                local match=false
                if [[ "$case_sensitive" == true ]]; then
                    if echo "$class" | grep -q "$pattern" || echo "$title" | grep -q "$pattern"; then
                        match=true
                    fi
                else
                    if echo "$class" | grep -qi "$pattern" || echo "$title" | grep -qi "$pattern"; then
                        match=true
                    fi
                fi
                
                if [[ "$match" == true ]]; then
                    should_skip=true
                    break
                fi
            done
            if [[ "$should_skip" == true ]]; then
                continue
            fi
        fi
        
        # If monitor specified, check if window is on that monitor
        if [[ -n "$monitor_name" ]]; then
            local window_mon=$(get_window_monitor "$id" | cut -d: -f1)
            [[ "$window_mon" != "$monitor_name" ]] && continue
        fi
        
        echo "$id"
    done
}

# Get windows sorted by spatial position (left-to-right, top-to-bottom) instead of chronological order
get_visible_windows_by_position() {
    local monitor_name="$1"  # Optional: if provided, filter by this monitor
    
    # Get stacking order from X11 (bottom to top)
    local stacking_order=()
    local stacking_raw=$(xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | grep "window id" | sed 's/.*window id # //; s/,//g')
    if [[ -n "$stacking_raw" ]]; then
        read -ra stacking_order <<< "$stacking_raw"
    fi
    
    # Get all visible windows with their positions
    local window_data=()
    
    # Use get_visible_windows() for proper filtering
    while IFS= read -r id; do
        # Get window client geometry for consistent positioning
        local geom=$(get_window_client_geometry "$id")
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
    done < <(get_visible_windows "$monitor_name")
    
    # Sort by Y coordinate (top to bottom), then X coordinate (left to right), then Z-order
    printf '%s\n' "${window_data[@]}" | sort -t: -k3,3n -k2,2n -k4,4n | cut -d: -f1
}



# Get windows sorted by stacking order (most recently active first) - stable for master layouts
get_visible_windows_by_stacking() {
    local monitor_name="$1"  # Optional: if provided, filter by this monitor
    
    # Get stacking order from X11 (bottom to top)
    local stacking_order=()
    local stacking_raw=$(xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | grep "window id" | sed 's/.*window id # //; s/,//g')
    if [[ -n "$stacking_raw" ]]; then
        read -ra stacking_order <<< "$stacking_raw"
    fi
    
    # Get all visible windows with their Z-order
    local window_data=()
    
    # Use get_visible_windows() for proper filtering
    while IFS= read -r id; do
        # Find Z-order index (higher index = more recent = lower sort value)
        local z_index=-1
        for ((i=${#stacking_order[@]}-1; i>=0; i--)); do
            if [[ "${stacking_order[i]}" == "$id" ]]; then
                z_index=$((${#stacking_order[@]} - i))  # Reverse so most recent is first
                break
            fi
        done
        
        # Store: "id:z_index"
        window_data+=("$id:$z_index")
    done < <(get_visible_windows "$monitor_name")
    
    # Sort by Z-order (most recent first)
    printf '%s\n' "${window_data[@]}" | sort -t: -k2,2nr | cut -d: -f1
}

# Get visible windows on specific monitor, sorted by position


# Get visible windows on specific monitor, sorted by creation order (oldest first)

# Helper function to trigger daemon reapplication
trigger_daemon_reapply() {
    # Send SIGUSR1 to the daemon to trigger immediate layout reapplication
    local daemon_pid=$(pgrep -f "place-window.*watch")
    if [[ -n "$daemon_pid" ]]; then
        kill -SIGUSR1 "$daemon_pid" 2>/dev/null
    fi
}

# Initialize window lists for all workspaces and monitors
initialize_all_workspace_lists() {
    # Get current monitor info
    get_screen_info
    
    # Get total number of workspaces
    local total_workspaces=$(wmctrl -d 2>/dev/null | wc -l)
    if [[ $total_workspaces -eq 0 ]]; then
        total_workspaces=1
    fi
    
    for ((workspace=0; workspace<total_workspaces; workspace++)); do
        for monitor in "${MONITORS[@]}"; do
            IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
            
            
            # Check if list is empty and needs population
            local existing_list=$(get_visible_windows "$monitor_name")
            if [[ -z "$existing_list" ]]; then
                # Get windows for this workspace/monitor using creation order 
                local -a windows_for_workspace=()
                while IFS= read -r id; do
                    windows_for_workspace+=("$id")
                done < <(get_visible_windows "$monitor_name")
                
            fi
        done
    done
}


# Debug function to show current window detection
debug_window_lists() {
    echo "=== Window Detection Debug ==="
    echo "Current context:"
    echo "  Current workspace: $(get_current_workspace)"
    get_screen_info
    local current_monitor=$(get_current_monitor)
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    echo "  Current monitor: $monitor_name"
    
    # Test current window detection
    local current_list=$(get_visible_windows "$monitor_name")
    echo "  Windows on current monitor: '$current_list'"
    
    echo "=== End Debug ==="
}

# Test function to debug initialization
test_initialization() {
    echo "=== Testing Initialization ==="
    
    # Test workspace detection
    echo "Current workspace: $(get_current_workspace)"
    echo "Total workspaces: $(wmctrl -d 2>/dev/null | wc -l)"
    
    # Test monitor detection
    get_screen_info
    echo "Detected monitors: ${#MONITORS[@]}"
    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r name mx my mw mh <<< "$monitor"
        echo "  Monitor: $name (${mw}x${mh}+${mx}+${my})"
    done
    
    # Test window detection on current workspace
    local current_workspace=$(get_current_workspace)
    echo "Testing window detection on current workspace $current_workspace:"
    local windows_current=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && windows_current+=("$line")
    done < <(get_visible_windows)
    echo "  Found ${#windows_current[@]} windows: ${windows_current[*]}"
    
    # Test monitor assignment for each window
    for window_id in "${windows_current[@]}"; do
        local window_monitor=$(get_window_monitor "$window_id")
        echo "  Window $window_id -> Monitor: $window_monitor"
    done
    
    echo "=== End Test ==="
}

# Export functions for use in subshells (needed for process substitution)


#========================================
# WINDOW OPERATIONS
#========================================

# Apply geometry to window using wmctrl
place_window_geometry() {
    local wid="$1" x="$2" y="$3" w="$4" h="$5"
    # Apply geometry using wmctrl
    wmctrl -i -r "$wid" -e "0,$x,$y,$w,$h" 2>/dev/null
}

# Get current workspace
get_current_workspace() {
    wmctrl -d | grep '*' | cut -d' ' -f1
}



# Focus window navigation
focus_window() {
    local direction="$1"  # next, prev, up, down, left, right
    local current_id=$(xdotool getactivewindow 2>/dev/null || echo "")
    
    if [[ -z "$current_id" ]]; then
        echo "No active window found"
        return 1
    fi
    
    # Get current monitor for the active window
    get_current_context
    local windows=($(get_windows_ordered "$CURRENT_MONITOR_NAME"))
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
            local current_geom=$(get_window_client_geometry "$current_id")
            IFS=',' read -r cx cy cw ch <<< "$current_geom"
            local center_x=$((cx + cw / 2))
            local center_y=$((cy + ch / 2))
            
            local best_window=""
            local best_distance=99999
            
            for window_id in "${windows[@]}"; do
                [[ "$window_id" == "$current_id" ]] && continue
                
                local geom=$(get_window_client_geometry "$window_id")
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

# Find windows adjacent to target window for simultaneous resize
find_adjacent_windows() {
    local target_id="$1"
    local target_geom=$(get_window_client_geometry "$target_id")
    IFS=',' read -r tx ty tw th <<< "$target_geom"
    
    # Get current monitor for the target window
    get_current_context
    local adjacent=()
    local windows=($(get_windows_ordered "$CURRENT_MONITOR_NAME"))
    
    for id in "${windows[@]}"; do
        [[ "$id" == "$target_id" ]] && continue
        
        local geom=$(get_window_client_geometry "$id")
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
    
    # Initialize screen info before getting current context
    get_screen_info
    # Get current monitor for the active window  
    get_current_context
    local minimized_count=0
    local kept_count=0
    local visible_windows=($(get_windows_ordered "$CURRENT_MONITOR_NAME"))
    
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
            
            # Get current windows on monitor  
            local windows_on_monitor=()
            while IFS= read -r id; do
                [[ -n "$id" ]] && windows_on_monitor+=("$id")
            done < <(get_visible_windows "$monitor_name")
            
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
            
            # Swap CLIENT geometries
            local g1 g2 x1 y1 w1 h1 x2 y2 w2 h2
            g1=$(get_window_client_geometry "$window1")
            g2=$(get_window_client_geometry "$window2")
            
            if [[ -n "$g1" && -n "$g2" ]]; then
                IFS=',' read -r x1 y1 w1 h1 <<<"$g1"
                IFS=',' read -r x2 y2 w2 h2 <<<"$g2"

                place_window_client_geometry "$window1" "$x2" "$y2" "$w2" "$h2"
                place_window_client_geometry "$window2" "$x1" "$y1" "$w1" "$h1"

                echo "Swapped client geometries of $window1 and $window2"
                
                echo "Window geometries have been swapped successfully"
            else
                echo "Warning: Could not get geometry for one or both windows"
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

# Helper function to swap two windows' geometries directly
swap_window_geometries() {
    local win1="$1" win2="$2"

    # Get frame extents to calculate coordinate offset
    local L1 R1 T1 B1 L2 R2 T2 B2
    read -r L1 R1 T1 B1 < <(xprop -id "$win1" _NET_FRAME_EXTENTS 2>/dev/null \
                           | awk -F' = ' '{print $2}' | sed 's/, / /g')
    read -r L2 R2 T2 B2 < <(xprop -id "$win2" _NET_FRAME_EXTENTS 2>/dev/null \
                           | awk -F' = ' '{print $2}' | sed 's/, / /g')
    : "${L1:=0}"; : "${T1:=0}"; : "${L2:=0}"; : "${T2:=0}"

    # Use xwininfo for client coordinates
    local info1 info2 x1 y1 w1 h1 x2 y2 w2 h2
    info1=$(xwininfo -id "$win1")
    info2=$(xwininfo -id "$win2")
    
    x1=$(awk '/Absolute upper-left X:/ {print $NF}' <<<"$info1")
    y1=$(awk '/Absolute upper-left Y:/ {print $NF}' <<<"$info1")
    w1=$(awk '/Width:/ {print $NF}' <<<"$info1")
    h1=$(awk '/Height:/ {print $NF}' <<<"$info1")
    
    x2=$(awk '/Absolute upper-left X:/ {print $NF}' <<<"$info2")
    y2=$(awk '/Absolute upper-left Y:/ {print $NF}' <<<"$info2")
    w2=$(awk '/Width:/ {print $NF}' <<<"$info2")
    h2=$(awk '/Height:/ {print $NF}' <<<"$info2")

    # Convert to coordinates wmctrl expects (subtract frame extents)
    local wmctrl_x1=$((x1 - L1)) wmctrl_y1=$((y1 - T1))
    local wmctrl_x2=$((x2 - L2)) wmctrl_y2=$((y2 - T2))

    # Swap using wmctrl with corrected coordinates
    wmctrl -i -r "$win1" -e "0,$wmctrl_x2,$wmctrl_y2,$w2,$h2"
    wmctrl -i -r "$win2" -e "0,$wmctrl_x1,$wmctrl_y1,$w1,$h1"
}

cycle_window_positions() {
    # Prevent the daemon from immediately reapplying a saved layout.
    get_current_context
    if declare -f hold_now >/dev/null 2>&1; then
        prevent_relayout "$CURRENT_WS" "$CURRENT_MONITOR_NAME"
    fi

    mapfile -t windows < <(get_windows_ordered)
    local n=${#windows[@]}
    echo "DEBUG: Found ${n} windows to cycle" >&2
    (( n < 2 )) && { echo "DEBUG: Not enough windows to cycle (need at least 2)" >&2; return 0; }
    # Clockwise: A B C -> C A B
    for (( i = 1; i < n; i++ )); do
        swap_window_geometries "${windows[0]}" "${windows[$i]}"
    done
}

reverse_cycle_window_positions() {
    get_current_context
    if declare -f hold_now >/dev/null 2>&1; then
        prevent_relayout "$CURRENT_WS" "$CURRENT_MONITOR_NAME"
    fi

    mapfile -t windows < <(get_windows_ordered)
    local n=${#windows[@]}
    (( n < 2 )) && return 0
    # Counter-clockwise: A B C -> B C A
    for (( i = n - 1; i > 0; i-- )); do
        swap_window_geometries "${windows[0]}" "${windows[$i]}"
    done
}

#========================================
# HELPER FUNCTIONS - DRY PRINCIPLE
#========================================

# Parse monitor info string into components
parse_monitor_info() {
    local monitor="$1"
    IFS=':' read -r MONITOR_NAME MONITOR_X MONITOR_Y MONITOR_W MONITOR_H <<< "$monitor"
    export MONITOR_NAME MONITOR_X MONITOR_Y MONITOR_W MONITOR_H
}

# Get current workspace and monitor context
get_current_context() {
    CURRENT_WS="$(get_current_workspace)"
    CURRENT_MONITOR="$(get_current_monitor)"
    parse_monitor_info "$CURRENT_MONITOR"
    CURRENT_MONITOR_NAME="$MONITOR_NAME"
    export CURRENT_WS CURRENT_MONITOR CURRENT_MONITOR_NAME
}

# Prevent relayout after window operations
prevent_relayout() {
    local ws="${1:-$CURRENT_WS}"
    local mon_name="${2:-$CURRENT_MONITOR_NAME}"
    hold_now "$ws" "$mon_name" 900
    cooldown_now 600
}

# Validate window list not empty
validate_windows() {
    local count="$1"
    local message="${2:-No visible windows}"
    if [[ $count -eq 0 ]]; then
        echo "$message"
        return 1
    fi
    return 0
}

# Find full monitor info by name
find_monitor_by_name() {
    local monitor_name="$1"
    for mon in "${MONITORS[@]}"; do
        if [[ "$mon" == "$monitor_name":* ]]; then
            echo "$mon"
            return 0
        fi
    done
    # Not found, return the name as-is
    echo "$monitor_name"
}

#========================================
# CONFIGURABLE WINDOW ORDERING SYSTEM
#========================================

# Default window ordering strategy (can be overridden in config)
WINDOW_ORDER_STRATEGY="${WINDOW_ORDER_STRATEGY:-position}"

# Get windows using the configured ordering strategy
get_windows_ordered() {
    local monitor_name="${1:-}"  # Optional monitor filter
    local strategy="${2:-$WINDOW_ORDER_STRATEGY}"
    
    case "$strategy" in
        position|spatial)
            get_visible_windows_by_position "$monitor_name"
            ;;
        creation|chronological)
            get_visible_windows "$monitor_name"
            ;;
        stacking|focus)
            get_visible_windows_by_stacking "$monitor_name"
            ;;
        *)
            echo "Warning: Unknown window ordering strategy '$strategy', defaulting to position" >&2
            get_visible_windows_by_position "$monitor_name"
            ;;
    esac
}

# Get windows on monitor using the configured ordering strategy

# Get windows for workspace/monitor using the configured ordering strategy

# Set window ordering strategy
set_window_order_strategy() {
    local strategy="$1"
    case "$strategy" in
        position|spatial|creation|chronological|stacking|focus)
            WINDOW_ORDER_STRATEGY="$strategy"
            echo "Window ordering strategy set to: $strategy"
            ;;
        *)
            echo "Error: Invalid window ordering strategy '$strategy'"
            echo "Valid strategies: position, spatial, creation, chronological, stacking, focus"
            return 1
            ;;
    esac
}

# Show current window ordering strategy
show_window_order_strategy() {
    echo "Current window ordering strategy: $WINDOW_ORDER_STRATEGY"
    echo ""
    echo "Available strategies:"
    echo "  position/spatial     - Order by position (left-to-right, top-to-bottom)"
    echo "  creation/chronological - Order by window creation time"
    echo "  stacking/focus       - Order by stacking/focus history (most recent first)"
    echo ""
    echo "Usage: set_window_order_strategy <strategy>"
}