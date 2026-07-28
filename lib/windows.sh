#!/bin/bash

# Core window management functions for place-window

# Window positioning and management functions
# Provides core window detection and ordering capabilities

# Interactive window selection
# Rejects desktop/dock/panel windows and re-prompts, to prevent the caller
# from resizing the root or xfdesktop window and breaking the background.
pick_window() {
    local id type
    while true; do
        echo "Click on a window to select it..." >&2
        id=$(xdotool selectwindow 2>/dev/null) || return 1
        [[ -z "$id" ]] && return 1

        type=$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)
        if echo "$type" | grep -qE "DESKTOP|DOCK|TOOLBAR|MENU|SPLASH|NOTIFICATION"; then
            echo "Skipped: that is a desktop/panel, not a manageable window. Try again." >&2
            continue
        fi
        echo "$id"
        return 0
    done
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

# --- Read CLIENT geometry consistently as x,y,w,h ---
get_window_client_geometry() {
    local id="$1" x y w h L T
    read -r x y w h < <(xwininfo -id "$id" | awk '
        /Absolute upper-left X:/ {x=$NF}
        /Absolute upper-left Y:/ {y=$NF}
        /Width:/ {w=$NF}
        /Height:/ {h=$NF}
        END {print x, y, w, h}')
    _read_frame_extents_lt "$id"
    echo "$((x + FRAME_L)),$((y + FRAME_T)),$w,$h"
}

# Parse _NET_FRAME_EXTENTS (L, R, T, B) into FRAME_L / FRAME_T — the only two
# values any caller uses. Var-return with a pure-bash parse: the old awk|sed
# pipeline plus command substitution forked 3 extra processes per window per
# apply on the daemon's hot path; now only the (mandatory, fresh-per-call)
# xprop itself forks. Missing property (fresh window) yields 0 0, as before.
_read_frame_extents_lt() {
    local ext
    ext=$(xprop -id "$1" _NET_FRAME_EXTENTS 2>/dev/null)
    if [[ "$ext" =~ =\ ([0-9]+),\ [0-9]+,\ ([0-9]+), ]]; then
        FRAME_L=${BASH_REMATCH[1]} FRAME_T=${BASH_REMATCH[2]}
    else
        FRAME_L=0 FRAME_T=0
    fi
}

# ----- Stable geometry helpers (wmctrl) -----

# Read FRAME geometry using wmctrl itself (id -> "x,y,w,h")
get_window_frame_geometry_wmctrl() {
    # Normalize id to lowercase (wmctrl prints lowercase)
    local id="${1,,}"
    # wmctrl -i -lG: $1=id $3=x $4=y $5=w $6=h
    wmctrl -i -lG | awk -v id="$id" '$1==id{print $3","$4","$5","$6; f=1} END{if(!f) exit 1}'
}

# Apply one wmctrl request that lands the window's position (xwininfo space)
# exactly at (fx, fy), by subtracting the window's own frame extents — the
# pattern validated in commit 407b3e4 and docs/DEVELOPMENT.md. Extents are
# fetched fresh on every call: freshly-mapped windows may not have
# _NET_FRAME_EXTENTS yet (defaults to 0), and the retry in the callers then
# re-applies with the real values once the WM has set them.
#
# The gravity field is EXPLICITLY NorthWest ("1,"), never 0. Gravity 0 means
# "use the window's own WM_NORMAL_HINTS gravity": GTK apps hint NorthWest
# (frame is positioned at the request), but kitty and Qt apps (Qube Manager,
# most qubes-* tools) hint Static (client is positioned at the request) —
# those landed one title-bar height higher than their neighbors in the same
# layout. Forcing NorthWest makes every window obey the same rule regardless
# of what its toolkit asked for.
_apply_frame_exact() {  # id fx fy w h
    local id="$1" fx="$2" fy="$3" w="$4" h="$5"
    _read_frame_extents_lt "$id"
    wmctrl -i -r "$id" -e "1,$((fx - FRAME_L)),$((fy - FRAME_T)),${w},${h}" 2>/dev/null
}

# Place a window's frame at an ABSOLUTE xwininfo position (fx, fy), with
# settle-wait and one drift-corrected retry. This is the right call for
# round-trip applies: coordinates that were read back from X (presets saved
# via save_position, etc.) and must land exactly where they were read.
#
# Replaces the former detect_wmctrl_coord_mode/apply_geom_adaptive machinery:
# the coord-mode probe could not classify xfwm4 (a no-op apply never moves,
# so it always concluded "frame"/pass-through) and raw pass-through shifted
# every apply down by the title-bar height. See docs/DEVELOPMENT.md.
apply_geom_adaptive() {  # id targetFrameX targetFrameY width height
    local id="$1" fx="$2" fy="$3" w="$4" h="$5"
    echo "$(date '+%H:%M:%S.%3N') apply_geom_adaptive id=$id -> X=$fx Y=$fy W=$w H=$h"
    _apply_frame_exact "$id" "$fx" "$fy" "$w" "$h"
    wait_window_settled "$id"
    if _geom_drift_exceeds "$id" "$fx" "$fy" "$w" "$h"; then
        _apply_frame_exact "$id" "$fx" "$fy" "$w" "$h"
        wait_window_settled "$id"
    fi
}

# Wait for the WM to finish applying a geometry change to a window. Polls
# xdotool getwindowgeometry until two consecutive samples match (the window
# is no longer moving/resizing) or the deadline elapses. This serializes
# layout applies so xfwm4 isn't asked to place window N+1 while it's still
# settling window N — the cause of pixel-imperfect first-pass tiling.
#
# Total budget: ~250 ms per window. In the steady case a stable window
# settles in 30-60 ms; the timeout only fires for misbehaving toolkits
# that don't emit a configure event we can observe.
wait_window_settled() {
    local id="$1"
    local prev="" stable=0
    # $EPOCHREALTIME (µs after stripping the radix char, which is
    # locale-dependent) instead of $(date +%s%3N): the old form forked date
    # once per 20 ms poll.
    local deadline=$(( ${EPOCHREALTIME/[.,]/} + 250000 ))

    while (( ${EPOCHREALTIME/[.,]/} < deadline )); do
        # Compare the raw --shell output: field order is fixed, and the
        # constant WINDOW=/SCREEN= lines compare equal anyway — the old
        # grep|sort filter cost 2 forks per poll for nothing.
        local cur
        cur=$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)
        if [[ -n "$cur" && "$cur" == "$prev" ]]; then
            stable=$((stable + 1))
            (( stable >= 2 )) && return 0
        else
            stable=0
            prev="$cur"
        fi
        # ~20 ms cadence — long enough to give the WM a slice, short
        # enough that a settled window returns within ~40 ms total.
        sleep 0.02
    done
    return 0
}

# Returns 0 (shell-true) iff the window's actual FRAME position/size (xwininfo
# space, as read back via `wmctrl -lG`) differs from the ABSOLUTE frame target
# (fx,fy,tw,th) by more than EPS px on any axis. Returns 1 on no drift OR
# readback failure (window destroyed mid-apply, etc.) so the caller's
# "if exceeds; then retry; fi" simply does nothing on failure — fail-soft.
#
# Both callers (apply_geometry, apply_geom_adaptive) now apply via
# _apply_frame_exact, which subtracts the window's own extents — so the
# expected readback IS the target, with no per-window (L, T) shift. This also
# means a first apply made while _NET_FRAME_EXTENTS was still unset (fresh
# window, extents defaulted to 0) is detected as drift and corrected by the
# retry using the by-then-real extents.
_geom_drift_exceeds() {
    local id="$1" fx="$2" fy="$3" tw="$4" th="$5"
    local eps=2
    local back rx ry rw rh
    back=$(get_window_frame_geometry_wmctrl "$id") || return 1
    [[ -z "$back" ]] && return 1
    IFS=',' read -r rx ry rw rh <<<"$back"
    local dx=$(( rx - fx )); (( dx < 0 )) && dx=$(( -dx ))
    local dy=$(( ry - fy )); (( dy < 0 )) && dy=$(( -dy ))
    local dw=$(( rw - tw )); (( dw < 0 )) && dw=$(( -dw ))
    local dh=$(( rh - th )); (( dh < 0 )) && dh=$(( -dh ))
    (( dx > eps || dy > eps || dw > eps || dh > eps ))
}

# Apply geometry to window (LAYOUT semantics). Waits for the WM to commit the
# change, then verifies the result and re-applies once if drift exceeds the
# eps threshold.
#
# Landing rule: the window's FRAME lands at (x, y + DECORATION_HEIGHT),
# regardless of that window's own frame extents. Historically this function
# passed x/y raw to `wmctrl -e`, which on xfwm4 lands the frame at
# (x + L, y + T) using each window's OWN extents — all layout math in
# lib/layouts.sh and lib/interactive.sh was tuned around that landing for
# standard windows (L≈1, T=DECORATION_HEIGHT). Windows with different extents
# (client-side-decorated dom0 apps vs xfwm4-decorated AppVM windows in Qubes)
# therefore landed a title-bar-height higher than their neighbors in the same
# layout. Normalizing to DECORATION_HEIGHT keeps standard windows exactly
# where they always were while pulling odd-extents windows into alignment —
# no layout re-tuning needed. See docs/DEVELOPMENT.md.
apply_geometry() {
    local id="$1" x="$2" y="$3" w="$4" h="$5"
    echo "$(date '+%H:%M:%S.%3N') apply_geometry id=$id -> X=$x Y=$y W=$w H=$h"
    local fx=$x
    local fy=$(( y + ${DECORATION_HEIGHT:-24} ))
    _apply_frame_exact "$id" "$fx" "$fy" "$w" "$h"
    wait_window_settled "$id"
    if _geom_drift_exceeds "$id" "$fx" "$fy" "$w" "$h"; then
        _apply_frame_exact "$id" "$fx" "$fy" "$w" "$h"
        wait_window_settled "$id"
    fi
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
    # Optional 2nd arg: workspace ID to filter by. Defaults to the live desktop.
    # Pass this from inside the daemon's apply path so the window list is
    # consistent with the workspace captured at decision time — otherwise the
    # live xdotool read can drift mid-apply if the user switches workspaces,
    # and a stale-workspace lookup ends up applying to fresh-workspace windows.
    local workspace_override="${2:-}"
    local current_desktop="${workspace_override:-$(xdotool get_desktop)}"

    # -lG: geometry comes free in the listing call we already make, so the
    # monitor filter below matches in pure bash — the old per-window
    # get_window_monitor call forked xwininfo+awk+cut for every window on
    # every daemon tick, the largest remaining fork cost on the hot path.
    wmctrl -lG | while read -r id desktop wx wy ww wh _; do
        # Skip windows not on current desktop
        [[ "$desktop" != "$current_desktop" && "$desktop" != "-1" ]] && continue

        # Fetch ALL needed properties with a single xprop call (was 4-5
        # separate forks per window) and parse in bash. Fork rate is the CPU
        # budget on dom0 — see compile_ignored_patterns in lib/config.sh.
        local props
        props=$(xprop -id "$id" _NET_WM_STATE _NET_WM_WINDOW_TYPE WM_TRANSIENT_FOR WM_CLASS _NET_WM_NAME WM_NAME 2>/dev/null)

        local line state="" type="" transient="" class="" net_name="" wm_name=""
        while IFS= read -r line; do
            case "$line" in
                _NET_WM_STATE*)       state="$line" ;;
                _NET_WM_WINDOW_TYPE*) type="$line" ;;
                WM_TRANSIENT_FOR*)    transient="$line" ;;
                WM_CLASS*)            class="${line#*= }"; class="${class//\"/}" ;;
                _NET_WM_NAME*)        [[ "$line" =~ =\ \"(.*)\" ]] && net_name="${BASH_REMATCH[1]}" ;;
                WM_NAME*)             [[ "$line" =~ =\ \"(.*)\" ]] && wm_name="${BASH_REMATCH[1]}" ;;
            esac
        done <<< "$props"

        # Skip minimized or maximized windows (matches MAXIMIZED_VERT/_HORZ)
        [[ "$state" == *HIDDEN* || "$state" == *MAXIMIZED* ]] && continue

        # Skip non-tileable window types. DIALOG, TOOLTIP, and UTILITY are
        # excluded because short-lived popups of these types (file pickers,
        # modal confirmations) would otherwise enter the tileable set and
        # trigger an N -> N+1 -> N reapply cycle when they close, snapping
        # user windows away and back across the daemon's debounce window.
        if [[ "$type" =~ DOCK|DESKTOP|TOOLBAR|MENU|SPLASH|NOTIFICATION|DIALOG|TOOLTIP|UTILITY ]]; then
            continue
        fi

        # Skip sub-windows that are transient for another window (modal
        # popups, attached dialogs). Same reasoning as the type filter.
        [[ "$transient" == *"window id"* ]] && continue

        # Skip ignored applications (precompiled patterns, zero forks)
        local title="$net_name"
        [[ -z "$title" ]] && title="$wm_name"
        if [[ -n "$IGNORED_APPS" && (-n "$class" || -n "$title") ]]; then
            matches_ignored_app "$class" "$title" && continue
        fi

        # If monitor specified, check if window is on that monitor.
        # wmctrl -lG positions are xwininfo-space (same as get_window_monitor
        # read via xwininfo); the few-px frame-size difference can never flip
        # the best-overlap monitor. Empty MONITOR_MATCH = detection failed —
        # skip, as before.
        if [[ -n "$monitor_name" ]]; then
            monitor_for_geometry "$wx" "$wy" "$ww" "$wh"
            [[ "${MONITOR_MATCH%%:*}" != "$monitor_name" ]] && continue
        fi

        echo "$id"
    done
}

# Get windows sorted by spatial position (left-to-right, top-to-bottom) instead of chronological order
get_visible_windows_by_position() {
    local monitor_name="$1"  # Optional: if provided, filter by this monitor
    local workspace_override="${2:-}"  # see get_visible_windows()

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
    done < <(get_visible_windows "$monitor_name" "$workspace_override")

    # Sort by Y coordinate (top to bottom), then X coordinate (left to right), then Z-order
    printf '%s\n' "${window_data[@]}" | sort -t: -k3,3n -k2,2n -k4,4n | cut -d: -f1
}



# Get windows sorted by stacking order (most recently active first) - stable for master layouts
get_visible_windows_by_stacking() {
    local monitor_name="$1"  # Optional: if provided, filter by this monitor
    local workspace_override="${2:-}"  # see get_visible_windows()

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
    done < <(get_visible_windows "$monitor_name" "$workspace_override")

    # Sort by Z-order (most recent first)
    printf '%s\n' "${window_data[@]}" | sort -t: -k2,2nr | cut -d: -f1
}

#========================================
# WINDOW OPERATIONS
#========================================

# Get current workspace (single fork; the old wmctrl -d | grep | cut
# pipeline forked 3 — this runs on every daemon tick)
get_current_workspace() {
    xdotool get_desktop
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
    
    # Automatically apply layout to the remaining window(s) if daemon is running.
    # reapply_saved_layout_for_monitor handles the saved-master/auto/no-saved
    # dispatch — the same logic the daemon's tick uses.
    if [[ $minimized_count -gt 0 ]] && is_daemon_running; then
        echo "Daemon detected - applying layout to remaining window(s)"
        sleep 0.2  # Brief delay to ensure minimization is complete
        reapply_saved_layout_for_monitor "$(get_current_workspace)" "$(get_current_monitor)"
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
    
    # Initialize monitor info first
    get_screen_info
    
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    local monitor1=$(get_window_monitor "$window1")
    local monitor2=$(get_window_monitor "$window2")
    
    # Convert window IDs to hex format for wmctrl (xdotool returns decimal)
    local window1_hex=$(printf "0x%08x" "$window1")
    local window2_hex=$(printf "0x%08x" "$window2")
    
    # Get workspace for each window to verify they're on current workspace
    local window1_workspace=$(wmctrl -l 2>/dev/null | grep -i "^$window1_hex " | awk '{print $2}')
    local window2_workspace=$(wmctrl -l 2>/dev/null | grep -i "^$window2_hex " | awk '{print $2}')
    
    # Check if both windows are on the same monitor AND same workspace
    if [[ "$monitor1" == "$monitor2" ]]; then
        # Verify both windows are on current workspace (or sticky windows with -1)
        if [[ ("$window1_workspace" == "$current_workspace" || "$window1_workspace" == "-1") && 
              ("$window2_workspace" == "$current_workspace" || "$window2_workspace" == "-1") ]]; then
            
            local monitor_name=$(echo "$monitor1" | cut -d':' -f1)
            
            # Use the proper swap function that handles frame/client conversion correctly
            swap_window_geometries "$window1" "$window2"
            echo "Window geometries have been swapped successfully"
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

# Helper function to swap two windows' geometries directly.
# _apply_frame_exact is the `wmctrl -e "1,(X-L),(Y-T)"` pattern settled on in
# commit 407b3e4: it lands each window's frame at the other's exact xwininfo
# position regardless of per-window extents or toolkit gravity. Both
# geometries are read before either window moves.
swap_window_geometries() {
    local win1="$1" win2="$2"
    local x1 y1 w1 h1 x2 y2 w2 h2
    IFS=',' read -r x1 y1 w1 h1 <<<"$(get_window_geometry "$win1")"
    IFS=',' read -r x2 y2 w2 h2 <<<"$(get_window_geometry "$win2")"
    _apply_frame_exact "$win1" "$x2" "$y2" "$w2" "$h2"
    wait_window_settled "$win1"
    _apply_frame_exact "$win2" "$x1" "$y1" "$w1" "$h1"
    wait_window_settled "$win2"
}

# Rotate all window positions on the current monitor.
# Arg: clockwise (default, A B C -> C A B) or counter-clockwise (A B C -> B C A).
# Positions are xwininfo coordinates; _apply_frame_exact subtracts each
# destination window's own (L, T) and forces NorthWest gravity — the 407b3e4
# pattern that keeps Static-gravity toolkits (kitty, Qt) on the same rule.
cycle_window_positions() {
    local step=1
    [[ "${1:-}" == "counter-clockwise" ]] && step=-1

    get_current_context
    mapfile -t windows < <(get_windows_ordered)
    local n=${#windows[@]}
    (( n < 2 )) && return 0

    local geometries=()
    for window in "${windows[@]}"; do
        geometries+=("$(get_window_geometry "$window")")
    done

    for (( i = 0; i < n; i++ )); do
        local geom="${geometries[$(( (i + step + n) % n ))]}"
        IFS=',' read -r x y w h <<< "$geom"
        _apply_frame_exact "${windows[$i]}" "$x" "$y" "$w" "$h"
        wait_window_settled "${windows[$i]}"
    done

    # After rotation, check if we should reapply layout
    # Skip reapplying for master layouts that have specific window role assignments
    # as rotation is intended to change which window has which role
    local current_layout=$(get_workspace_monitor_layout "$CURRENT_WS" "$CURRENT_MONITOR_NAME" "" "")
    if [[ -n "$current_layout" && "$current_layout" =~ ^master[[:space:]] ]]; then
        echo "Skipping layout reapplication for master layout to preserve rotation"
        # Set a brief hold to prevent daemon from immediately reapplying
        prevent_relayout "$CURRENT_WS" "$CURRENT_MONITOR_NAME"
    elif declare -f reapply_saved_layout_for_monitor >/dev/null 2>&1; then
        sleep 0.1  # Brief delay for window movements to complete
        reapply_saved_layout_for_monitor "$CURRENT_WS" "$CURRENT_MONITOR"
    fi
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

#========================================
# CONFIGURABLE WINDOW ORDERING SYSTEM
#========================================

# Default window ordering strategy (can be overridden in config)
WINDOW_ORDER_STRATEGY="${WINDOW_ORDER_STRATEGY:-position}"

# Get windows using the configured ordering strategy
get_windows_ordered() {
    local monitor_name="${1:-}"  # Optional monitor filter
    local strategy="${2:-$WINDOW_ORDER_STRATEGY}"
    local workspace_override="${3:-}"  # see get_visible_windows()

    case "$strategy" in
        position|spatial)
            get_visible_windows_by_position "$monitor_name" "$workspace_override"
            ;;
        creation|chronological)
            get_visible_windows "$monitor_name" "$workspace_override"
            ;;
        stacking|focus)
            get_visible_windows_by_stacking "$monitor_name" "$workspace_override"
            ;;
        *)
            echo "Warning: Unknown window ordering strategy '$strategy', defaulting to position" >&2
            get_visible_windows_by_position "$monitor_name" "$workspace_override"
            ;;
    esac
}

# Simultaneous resize (xpytile-inspired): resize the selected window and
# shift/shrink its adjacent windows so shared edges stay shared.
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

    # Sign of the change: +1 for expand, -1 for shrink. Computed by string
    # match — bash arithmetic evaluates non-numeric identifiers as 0, so
    # `(direction == "expand-right" ? a : -a)` is always (0 == 0 ? a : -a) = a,
    # which silently turns shrink-* into expand-* and breaks adjacent windows.
    local sign=1
    [[ "$direction" == shrink-* ]] && sign=-1

    case "$direction" in
        expand-right|shrink-right)
            # Coordinates here are read back from xwininfo (absolute frame
            # positions), so use the absolute apply — apply_geometry's layout
            # semantics would shift the window down by DECORATION_HEIGHT on
            # every resize.
            local new_tw=$((tw + sign * amount))
            apply_geom_adaptive "$target_id" $tx $ty $new_tw $th

            # Adjust right-adjacent windows
            for adj in "${adjacent[@]}"; do
                local adj_id="${adj%:*}"
                local adj_dir="${adj#*:}"
                if [[ "$adj_dir" == "right" ]]; then
                    local adj_geom=$(get_window_geometry "$adj_id")
                    IFS=',' read -r ax ay aw ah <<< "$adj_geom"
                    local new_ax=$((ax + sign * amount))
                    local new_aw=$((aw - sign * amount))
                    apply_geom_adaptive "$adj_id" $new_ax $ay $new_aw $ah
                fi
            done
            ;;
        expand-down|shrink-down)
            local new_th=$((th + sign * amount))
            apply_geom_adaptive "$target_id" $tx $ty $tw $new_th

            # Adjust bottom-adjacent windows
            for adj in "${adjacent[@]}"; do
                local adj_id="${adj%:*}"
                local adj_dir="${adj#*:}"
                if [[ "$adj_dir" == "bottom" ]]; then
                    local adj_geom=$(get_window_geometry "$adj_id")
                    IFS=',' read -r ax ay aw ah <<< "$adj_geom"
                    local new_ay=$((ay + sign * amount))
                    local new_ah=$((ah - sign * amount))
                    apply_geom_adaptive "$adj_id" $new_ax $new_ay $aw $new_ah
                fi
            done
            ;;
    esac

    echo "Simultaneous resize completed"
}