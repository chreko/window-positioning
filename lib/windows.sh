#!/bin/bash

# Core window management functions for place-window

# In-memory window list management
# Each (workspace, monitor) pair has its own ordered list
# Position 0 is the master window

# Global associative array to store window lists  
# Key format: "workspace_N_monitor_NAME"
# Guard against re-declaration if sourced multiple times
if ! declare -p WINDOW_LISTS &>/dev/null; then
    declare -gA WINDOW_LISTS=()
fi

# In-memory guard for one-time initialization per process
declare -g __WINDOW_POSITIONING_INITIALIZED=""

# Ensure initialization happens only once per process execution
ensure_initialized_once() {
    # Fast in-memory check - avoids all expensive operations on subsequent calls
    [[ "$__WINDOW_POSITIONING_INITIALIZED" == "1" ]] && return 0
    
    # Run initialization once per process
    initialize_all_workspace_lists
    __WINDOW_POSITIONING_INITIALIZED="1"
}

# Initialize window list for a workspace/monitor if it doesn't exist
init_window_list() {
    local workspace="$1"
    local monitor_name="$2"
    local key="workspace_${workspace}_monitor_${monitor_name}"
    
    # Initialize key if it doesn't exist
    if [[ -z "${WINDOW_LISTS[$key]:-}" ]]; then
        WINDOW_LISTS[$key]=""
    fi
}

# Get window list for workspace/monitor
get_window_list() {
    local workspace="$1"
    local monitor_name="$2"
    local key="workspace_${workspace}_monitor_${monitor_name}"
    
    echo "${WINDOW_LISTS[$key]:-}"
}

# Set window list for workspace/monitor
set_window_list() {
    local workspace="$1"
    local monitor_name="$2"
    local window_list="$3"  # Space-separated list
    local key="workspace_${workspace}_monitor_${monitor_name}"
    
    WINDOW_LISTS[$key]="$window_list"
}

# Add window to end of list (when created)
add_window_to_list() {
    local workspace="$1"
    local monitor_name="$2"
    local window_id="$3"
    
    local current_list=$(get_window_list "$workspace" "$monitor_name")
    
    # Check if window already exists in list
    for wid in $current_list; do
        if [[ "$wid" == "$window_id" ]]; then
            return  # Already in list
        fi
    done
    
    # Add to end
    if [[ -z "$current_list" ]]; then
        set_window_list "$workspace" "$monitor_name" "$window_id"
    else
        set_window_list "$workspace" "$monitor_name" "$current_list $window_id"
    fi
}

# Remove window from list (when closed/moved)
remove_window_from_list() {
    local workspace="$1"
    local monitor_name="$2"
    local window_id="$3"
    
    local current_list=$(get_window_list "$workspace" "$monitor_name")
    local new_list=""
    
    for wid in $current_list; do
        if [[ "$wid" != "$window_id" ]]; then
            if [[ -z "$new_list" ]]; then
                new_list="$wid"
            else
                new_list="$new_list $wid"
            fi
        fi
    done
    
    set_window_list "$workspace" "$monitor_name" "$new_list"
}

# Swap two windows in the list
swap_windows_in_list() {
    local workspace="$1"
    local monitor_name="$2"
    local window1="$3"
    local window2="$4"
    
    local current_list=$(get_window_list "$workspace" "$monitor_name")
    local list_array=($current_list)
    local window1_pos=-1
    local window2_pos=-1
    
    # Find positions
    for i in "${!list_array[@]}"; do
        if [[ "${list_array[$i]}" == "$window1" ]]; then
            window1_pos=$i
        elif [[ "${list_array[$i]}" == "$window2" ]]; then
            window2_pos=$i
        fi
    done
    
    # Swap if both found
    if [[ $window1_pos -ge 0 && $window2_pos -ge 0 ]]; then
        local temp="${list_array[$window1_pos]}"
        list_array[$window1_pos]="${list_array[$window2_pos]}"
        list_array[$window2_pos]="$temp"
        
        # Update list
        set_window_list "$workspace" "$monitor_name" "${list_array[*]}"
        
        # Return success with positions
        echo "$window1_pos $window2_pos"
        return 0
    fi
    
    return 1
}

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

# Get windows sorted by creation order (oldest first) - stable for master layouts
get_visible_windows_by_creation() {
    local current_desktop=$(xdotool get_desktop)
    
    # wmctrl -l lists windows in creation order (oldest first)
    wmctrl -l | while read -r line; do
        local id=$(echo "$line" | awk '{print $1}')
        local desktop=$(echo "$line" | awk '{print $2}')
        
        # Skip windows not on current desktop
        [[ "$desktop" != "$current_desktop" && "$desktop" != "-1" ]] && continue
        
        # Check if window is minimized
        local state=$(xprop -id "$id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN")
        [[ -n "$state" ]] && continue
        
        # Skip panels, docks, and desktop
        local type=$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)
        if echo "$type" | grep -qE "DOCK|DESKTOP|TOOLBAR|MENU|SPLASH|NOTIFICATION"; then
            continue
        fi
        
        echo "$id"
    done
}

# Get windows sorted by creation order for specific workspace - stable for master layouts  
get_visible_windows_by_creation_for_workspace() {
    local target_workspace="$1"
    
    # wmctrl -l lists windows in creation order (oldest first)
    wmctrl -l | while read -r line; do
        local id=$(echo "$line" | awk '{print $1}')
        local desktop=$(echo "$line" | awk '{print $2}')
        
        # Skip windows not on target workspace
        [[ "$desktop" != "$target_workspace" && "$desktop" != "-1" ]] && continue
        
        # Check if window is minimized
        local state=$(xprop -id "$id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN")
        [[ -n "$state" ]] && continue
        
        # Skip panels, docks, and desktop
        local type=$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)
        if echo "$type" | grep -qE "DOCK|DESKTOP|TOOLBAR|MENU|SPLASH|NOTIFICATION"; then
            continue
        fi
        
        echo "$id"
    done
}

# Get windows sorted by stacking order (most recently active first) - stable for master layouts
get_visible_windows_by_stacking() {
    local current_desktop=$(xdotool get_desktop)
    
    # Get stacking order from X11 (bottom to top)
    local stacking_order=()
    local stacking_raw=$(xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | grep "window id" | sed 's/.*window id # //; s/,//g')
    if [[ -n "$stacking_raw" ]]; then
        read -ra stacking_order <<< "$stacking_raw"
    fi
    
    # Get all visible windows with their Z-order
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
    done < <(wmctrl -l)
    
    # Sort by Z-order (most recent first)
    printf '%s\n' "${window_data[@]}" | sort -t: -k2,2nr | cut -d: -f1
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

# Get visible windows on specific monitor, sorted by stacking (most recent first)
get_visible_windows_on_monitor_by_stacking() {
    local monitor="$1"
    get_visible_windows_by_stacking | while read -r id; do
        local window_monitor=$(get_window_monitor "$id")
        if [[ "$window_monitor" == "$monitor" ]]; then
            echo "$id"
        fi
    done
}

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
            
            # Initialize this workspace/monitor combination
            init_window_list "$workspace" "$monitor_name"
            
            # Check if list is empty and needs population
            local existing_list=$(get_window_list "$workspace" "$monitor_name")
            if [[ -z "$existing_list" ]]; then
                # Get windows for this workspace/monitor using creation order (fixed subshell issue)
                local -a windows_for_workspace=()
                
                # Filter by monitor
                while IFS= read -r id; do
                    local window_monitor=$(get_window_monitor "$id")
                    if [[ "$window_monitor" == "$monitor" ]]; then
                        windows_for_workspace+=("$id")
                    fi
                done < <(get_visible_windows_by_creation_for_workspace "$workspace")
                
                # Store initial list if any windows found
                if [[ ${#windows_for_workspace[@]} -gt 0 ]]; then
                    set_window_list "$workspace" "$monitor_name" "${windows_for_workspace[*]}"
                fi
            fi
        done
    done
}


# Debug function to show all stored window lists
debug_window_lists() {
    echo "=== All Stored Window Lists ==="
    
    # Verify WINDOW_LISTS is properly declared
    if declare -p WINDOW_LISTS &>/dev/null; then
        declare -p WINDOW_LISTS
        echo "✅ WINDOW_LISTS is properly declared"
    else
        echo "❌ WINDOW_LISTS is not declared"
        return 1
    fi
    
    # Show all keys and values - use safe expansion for empty arrays
    local list_count=${#WINDOW_LISTS[@]}
    if [[ $list_count -eq 0 ]]; then
        echo "No window lists stored in memory"
    else
        echo "Total stored lists: $list_count"
        # Safe iteration over keys - handles empty array case
        for key in ${!WINDOW_LISTS[@]+"${!WINDOW_LISTS[@]}"}; do
            local value="${WINDOW_LISTS[$key]}"
            local window_count=0
            if [[ -n "$value" ]]; then
                window_count=$(echo "$value" | wc -w)
            fi
            echo "  Key: '$key' -> Value: '$value' ($window_count windows)"
        done
    fi
    
    echo ""
    echo "Current context:"
    echo "  Current workspace: $(get_current_workspace)"
    get_screen_info
    local current_monitor=$(get_current_monitor)
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    echo "  Current monitor: $monitor_name"
    echo "  Expected key: 'workspace_$(get_current_workspace)_monitor_$monitor_name'"
    
    # Test direct access to current workspace/monitor list
    local current_list=$(get_window_list "$(get_current_workspace)" "$monitor_name")
    echo "  Current list result: '$current_list'"
    
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
    done < <(get_visible_windows_by_creation_for_workspace "$current_workspace")
    echo "  Found ${#windows_current[@]} windows: ${windows_current[*]}"
    
    # Test monitor assignment for each window
    for window_id in "${windows_current[@]}"; do
        local window_monitor=$(get_window_monitor "$window_id")
        echo "  Window $window_id -> Monitor: $window_monitor"
    done
    
    echo "=== End Test ==="
}

# Export functions for use in subshells (needed for process substitution)
export -f get_window_list
export -f set_window_list
export -f swap_windows_in_list

# Get visible windows on monitor sorted by creation order (backward compatibility)
get_visible_windows_on_monitor_by_creation() {
    local monitor="$1"
    
    # Simple fallback to creation order for backward compatibility
    get_visible_windows_by_creation | while read -r id; do
        local window_monitor=$(get_window_monitor "$id")
        if [[ "$window_monitor" == "$monitor" ]]; then
            echo "$id"
        fi
    done
}