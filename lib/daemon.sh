#!/bin/bash

# set -e is intentionally omitted: the daemon runs many fallible probes
# (grep -c on possibly-empty input, optional xprop reads) where a non-zero
# exit is the normal "no data" path and must not terminate the loop.
set -uo pipefail

# Watch daemon functionality for place-window

# Configuration defaults
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${CONFIG_DIR:=$XDG_CONFIG_HOME/window-positioning}"
: "${XDG_RUNTIME_DIR:=/tmp}"

# Dependency checks
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required dependency: $1" >&2; exit 127; }; }
need xdotool
need wmctrl
need xprop

# Error handling function
die() { echo "Error: $*" >&2; exit 1; }

# Get the directory where daemon.sh is located
DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required modules that daemon functions depend on
source "$DAEMON_DIR/config.sh"
source "$DAEMON_DIR/monitors.sh"
source "$DAEMON_DIR/windows.sh"
source "$DAEMON_DIR/layouts.sh"

# --- Daemon-specific state tracking (SSOT is in windows.sh) ---
# Dirty and generation tracking for daemon's reconciliation logic
declare -Ag WINDOW_DIRTY WINDOW_GEN WINDOW_COUNT 2>/dev/null || true

# Hold map to protect manual operations from immediate reconciliation
declare -Ag HOLD_UNTIL_MS 2>/dev/null || true

# Monitor detection caching for CPU optimization
declare -ag SCREEN_INFO_CACHE=()
SCREEN_INFO_CACHE_TIME=0

# Debouncing for rapid changes
LAST_CHANGE_TIME=0
DEBOUNCE_DELAY=2  # seconds

hold_now() {  # ws mon_name [ms]
  local ws="$1" mon="$2" ms="${3:-900}"
  local now; now=$(date +%s%3N)
  local k="workspace_${ws}_monitor_${mon}"
  HOLD_UNTIL_MS["$k"]=$(( now + ms ))
}

should_hold() {  # ws mon_name
  local ws="$1" mon="$2" now k
  now=$(date +%s%3N)
  k="workspace_${ws}_monitor_${mon}"
  [[ ${HOLD_UNTIL_MS["$k"]-0} -gt $now ]]
}

# Locks are no-ops in single-process mode; harmless if you later add flock
state_lock()   { :; }
state_unlock() { :; }

# Key helper matching windows.sh format for daemon maps
key_wsmon() {  # args: workspace monitor_name
  printf "workspace_%s_monitor_%s" "$1" "$2"
}

# Cooldown helpers (monitor uses these even before watch loop starts)
: "${COOLDOWN_UNTIL_MS:=0}"
cooldown_now() {                # args: [ms]
  local ms="${1:-600}" now; now=$(date +%s%3N)
  COOLDOWN_UNTIL_MS=$(( now + ms ))
}
monitor_should_apply() {
  local now; now=$(date +%s%3N)
  (( now >= COOLDOWN_UNTIL_MS ))
}

# Geometry helper functions for stateless cycle operations
# get_window_geometry() moved to windows.sh (comma-separated format) to avoid duplication

# Window functions moved to windows.sh

# get_visible_windows_by_creation_for_workspace() moved to windows.sh to avoid duplication

# Cached screen info for CPU optimization - monitors rarely change
get_screen_info_cached() {
    local now=$(date +%s)
    if (( ${#SCREEN_INFO_CACHE[@]} == 0 )) || (( now - SCREEN_INFO_CACHE_TIME > 30 )); then
        get_screen_info  # Calls original function from monitors.sh
        SCREEN_INFO_CACHE=("${MONITORS[@]}")
        SCREEN_INFO_CACHE_TIME=$now
        echo "$(date): Monitor info refreshed (cache TTL: 30s)"
    else
        # Restore cached monitors
        MONITORS=("${SCREEN_INFO_CACHE[@]}")
    fi
}


# Set up IPC pipes for daemon communication
setup_daemon_ipc() {
    # Set secure umask before creating directory
    local old_umask=$(umask)
    umask 077
    
    # Create pipe directory with secure permissions
    mkdir -p "$DAEMON_PIPE_DIR"
    chmod 700 "$DAEMON_PIPE_DIR"
    
    # Remove old pipes if they exist
    rm -f "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    
    # Create named pipes
    mkfifo "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    
    # Set permissions (redundant with umask but explicit)
    chmod 600 "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE"
    
    # Restore original umask
    umask "$old_umask"
    
    echo "IPC pipes created: $DAEMON_CMD_PIPE, $DAEMON_RESP_PIPE"
}

# Clean up IPC pipes
cleanup_daemon_ipc() {
    rm -f "$DAEMON_CMD_PIPE" "$DAEMON_RESP_PIPE" "$PID_FILE"
    # Only remove directory if it's empty (other processes might use XDG_RUNTIME_DIR)
    rmdir "$DAEMON_PIPE_DIR" 2>/dev/null || true
    echo "IPC pipes and PID file cleaned up"
}

# Auto-layout state management
AUTO_LAYOUT_ENABLED_FILE="${CONFIG_DIR}/auto-layout-enabled"
DAEMON_PIPE_DIR="${XDG_RUNTIME_DIR}/window-positioning"
DAEMON_CMD_PIPE="$DAEMON_PIPE_DIR/commands"
DAEMON_RESP_PIPE="$DAEMON_PIPE_DIR/responses"
PID_FILE="$DAEMON_PIPE_DIR/daemon.pid"

# Check if auto-layout is enabled
is_auto_layout_enabled() {
    [[ -f "$AUTO_LAYOUT_ENABLED_FILE" ]]
}

# Enable auto-layout
enable_auto_layout() {
    mkdir -p "$CONFIG_DIR"
    printf 'enabled %s\n' "$(date -Is)" > "$AUTO_LAYOUT_ENABLED_FILE"
    echo "$(date): Auto-layout enabled"
}

# Disable auto-layout
disable_auto_layout() {
    rm -f "$AUTO_LAYOUT_ENABLED_FILE"
    echo "$(date): Auto-layout disabled"
}

# Toggle auto-layout state
toggle_auto_layout() {
    if is_auto_layout_enabled; then
        disable_auto_layout
        echo "Auto-layout disabled - daemon enters idle mode for maximum CPU savings"
        echo "All window monitoring and processing paused until re-enabled"
    else
        enable_auto_layout
        echo "Auto-layout enabled - daemon will automatically apply layouts on window changes"
        echo "Window monitoring and layout processing resumed"
    fi

    # Send SIGUSR2 to daemon to wake it from idle sleep
    local daemon_pid=$(get_daemon_pid)
    if [[ -n "$daemon_pid" ]]; then
        kill -USR2 "$daemon_pid" 2>/dev/null || true
    fi
}

# Enable auto-layout directly (daemon must be running)
enable_daemon_auto_layout() {
    if ! is_daemon_running; then
        echo "Daemon is not running. Start with: place-window watch start"
        return 1
    fi

    if is_auto_layout_enabled; then
        echo "Auto-layout is already enabled"
        return 0
    fi

    enable_auto_layout
    echo "Auto-layout enabled - daemon will automatically apply layouts on window changes"
    echo "Window monitoring and layout processing resumed"

    # Send SIGUSR2 to daemon to wake it from idle sleep
    local daemon_pid=$(get_daemon_pid)
    if [[ -n "$daemon_pid" ]]; then
        kill -USR2 "$daemon_pid" 2>/dev/null || true
    fi
    return 0
}

# Disable auto-layout directly (daemon keeps running)
disable_daemon_auto_layout() {
    if ! is_daemon_running; then
        echo "Daemon is not running. Start with: place-window watch start"
        return 1
    fi

    if ! is_auto_layout_enabled; then
        echo "Auto-layout is already disabled"
        return 0
    fi

    disable_auto_layout
    echo "Auto-layout disabled - daemon enters idle mode for maximum CPU savings"
    echo "All window monitoring and processing paused until re-enabled"
    return 0
}

# Combined daemon that handles both window monitoring and IPC commands
watch_daemon_with_ipc() {
    # Single-process daemon: command loop + monitor tick in one place
    trap 'cleanup_daemon_ipc; echo "Watch daemon stopped"; exit 0' SIGINT SIGTERM
    trap 'echo "$(date): SIGUSR1 -> reapply layouts"; apply_workspace_layout' SIGUSR1
    trap 'echo "$(date): SIGUSR2 -> wake from idle"' SIGUSR2

    echo "$(date): Watch daemon with IPC started (single loop)"
    
    # Create IPC and write PID (deterministic readiness)
    setup_daemon_ipc
    umask 077
    : "${PID_FILE:=$DAEMON_PIPE_DIR/daemon.pid}"
    echo $$ > "$PID_FILE"

    # Auto-layout state: WATCH_AUTO_LAYOUT is authoritative on each daemon start.
    # Runtime `watch on`/`watch off` still toggles the marker, but the config wins
    # on the next daemon restart.
    if [[ "${WATCH_AUTO_LAYOUT:-true}" == "true" ]]; then
        enable_auto_layout
    else
        disable_auto_layout
    fi

    # Initialize monitor information for daemon functions
    get_screen_info

    # SSOT, lock, and cooldown functions now defined in global scope

    # Open FIFOs once
    exec 3<>"$DAEMON_CMD_PIPE"
    exec 4<>"$DAEMON_RESP_PIPE"

    local TICK=1.5  # seconds - optimized for better CPU efficiency while maintaining responsiveness

    echo "$(date): entering main loop"
    while true; do
        local cmd
        if read -t "$TICK" -r cmd <&3; then
            # Handle a single command. The response body may be empty or
            # contain many newlines; an explicit sentinel terminates the
            # message so the client knows when to stop reading.
            local resp
            resp="$(handle_daemon_command "$cmd" 2>&1)"
            if [[ -n "$resp" ]]; then
                printf '%s\n' "$resp" >&4
            fi
            printf '__DAEMON_RESP_END__\n' >&4
            # Let WM settle; also keep monitor from clobbering right away
            cooldown_now 600
            continue
        fi

        # ---- monitor tick ----
        monitor_tick
    done
}

# Generate current master state for comparison
get_current_master_state() {
    local current_workspace
    current_workspace=$(get_current_workspace)
    
    # Add small delay to ensure workspace switch is complete
    sleep 0.05
    
    get_screen_info_cached
    local combined_state="workspace:$current_workspace|"
    
    for monitor in "${MONITORS[@]}"; do
        IFS=':' read -r monitor_name mx my mw mh <<< "$monitor"
        
        # Get window list for this monitor (current workspace only)
        local master_list
        master_list=$(get_windows_ordered "$monitor_name")
        
        # Validate that all windows in the list are actually on current workspace
        local validated_list=""
        for window_id in $master_list; do
            if [[ -n "$window_id" ]]; then
                local window_desktop
                window_desktop=$(wmctrl -l | grep "^$window_id " | awk '{print $2}')
                if [[ "$window_desktop" == "$current_workspace" || "$window_desktop" == "-1" ]]; then
                    validated_list="$validated_list $window_id"
                fi
            fi
        done
        master_list=$(echo "$validated_list" | xargs)
        
        # Also get window states to detect minimize/restore
        local window_states=""
        while IFS= read -r window_id; do
            if [[ -n "$window_id" ]]; then
                local state
                state=$(xprop -id "$window_id" _NET_WM_STATE 2>/dev/null | grep -E "HIDDEN|MAXIMIZED" || echo "NORMAL")
                window_states="${window_states}${window_id}:${state};"
            fi
        done <<< "$master_list"
        
        combined_state="${combined_state}${monitor_name}=[${master_list// /,}]:${window_states}|"
    done
    
    echo "$combined_state"
}

# Apply layout when master state changes
apply_workspace_layout() {
    local current_workspace
    current_workspace=$(get_current_workspace)
    
    get_screen_info
    for monitor in "${MONITORS[@]}"; do
        # Use the shared function for each monitor
        reapply_saved_layout_for_monitor "$current_workspace" "$monitor"
    done
}

# Background window monitoring
watch_daemon_monitor() {
    echo "$(date): Window monitoring started"
    local last_master_state=""
    
    # Set up signal handler to wake from idle sleep
    trap 'echo "$(date): Woken from idle by toggle signal"' SIGUSR2
    
    while true; do
        # Enter true idle mode when auto-layout is disabled
        if ! is_auto_layout_enabled; then
            echo "$(date): Auto-layout disabled - entering zero-CPU idle mode"
            # Sleep indefinitely until SIGUSR2 signal (zero CPU usage)
            sleep infinity &
            wait $!
            echo "$(date): Waking from idle mode"
            # Reset state for fresh rebuild when re-enabled
            last_master_state=""
            continue
        fi
        
        local current_state
        current_state=$(get_current_master_state)
        
        if [[ "$current_state" != "$last_master_state" ]]; then
            echo "$(date): Window state changed"
            echo "$(date): Auto-layout enabled - applying layouts"
            apply_workspace_layout
            last_master_state="$current_state"
        fi
        
        sleep 0.75  # Check every 750ms for better battery life
    done
}

# IPC command loop - listens for commands on the pipe
daemon_command_loop() {
    echo "$(date): IPC command listener started"
    
    while true; do
        # Read command from pipe (blocks until command received)
        if read -r command < "$DAEMON_CMD_PIPE" 2>/dev/null; then
            echo "$(date): Received command: $command"
            
            # Handle the command and get response
            local response
            response=$(handle_daemon_command "$command")
            
            # Send response back
            echo "$response" > "$DAEMON_RESP_PIPE" 2>/dev/null || echo "Error: Failed to send response"
        else
            # Pipe was closed or error occurred
            echo "$(date): Command pipe closed - daemon exiting"
            break
        fi
    done
}

# Start the daemon directly without subprocess
watch_daemon() {
    echo "Watch daemon started (PID: $$)"
    
    # Set up IPC pipes for command handling
    setup_daemon_ipc
    
    # Start both window monitoring and command listening
    watch_daemon_with_ipc
}

# Check if watch daemon is running
is_daemon_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# Get daemon PID if running
get_daemon_pid() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
}

# Stop watch daemon
stop_daemon() {
    if is_daemon_running; then
        echo "Stopping watch mode daemon..."
        local pid=$(get_daemon_pid)
        kill "$pid" 2>/dev/null || true
        
        # Give daemon time to clean up
        sleep 1
        
        # Force cleanup pipes and PID file if daemon didn't do it
        cleanup_daemon_ipc 2>/dev/null || true
        rm -f "$PID_FILE"
        
        echo "Watch mode stopped"
        return 0
    else
        echo "Watch mode is not running"
        return 1
    fi
}

# Start daemon in background
start_daemon_background() {
    if is_daemon_running; then
        echo "Watch mode already running (PID: $(get_daemon_pid))"
        return 1
    fi
    
    echo "Starting watch mode daemon..."
    nohup "$0" watch daemon >/dev/null 2>&1 &
    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"
    disown || true
    echo "Watch daemon started in background (PID: $daemon_pid)"
    echo "Use 'place-window watch stop' to stop it"
    return 0
}

# Toggle auto-layout on/off (daemon keeps running)
toggle_daemon() {
    if ! is_daemon_running; then
        echo "Daemon is not running. Start with: place-window watch start"
        return 1
    fi

    if is_auto_layout_enabled; then
        disable_daemon_auto_layout
    else
        enable_daemon_auto_layout
    fi
}

# Show daemon status
show_daemon_status() {
    if is_daemon_running; then
        echo "Watch mode: RUNNING (PID: $(get_daemon_pid))"
        if is_auto_layout_enabled; then
            echo "Auto-layout: ON (actively monitoring and applying layouts)"
        else
            echo "Auto-layout: OFF (daemon idle - zero CPU usage)"
        fi
        return 0
    else
        echo "Watch mode: NOT RUNNING"
        echo "Start with: place-window watch start"
        return 1
    fi
}

# SSOT functions now defined at top of file in global scope

# detect_current_ids_for_ws_mon removed - using list_windows_on_monitor_for_workspace directly

# Simple window change detection - no persistence of window IDs
reconcile_ws_mon() {  # args: workspace monitor_name
    local ws="$1" mon="$2"
    local k; k="$(key_wsmon "$ws" "$mon")"
    
    # Quick window count check first (fast path for stable windows)
    local quick_count
    quick_count=$(wmctrl -l 2>/dev/null | awk -v ws="$ws" '$2==ws || $2==-1' | wc -l)
    local last_count="${WINDOW_COUNT["$k"]-0}"
    
    # Early exit if count unchanged (major CPU savings)
    if [[ "$quick_count" -eq "$last_count" ]]; then
        return 0
    fi
    
    # Full reconciliation only when count changed
    local current_windows
    current_windows="$(get_windows_ordered "$mon")"
    local current_count
    current_count=$(echo "$current_windows" | grep -c . 2>/dev/null || echo 0)
    
    # Update tracking
    if [[ "$current_count" -ne "$last_count" ]]; then
        WINDOW_DIRTY["$k"]=1
        WINDOW_COUNT["$k"]=$current_count
        WINDOW_GEN["$k"]=$(( ${WINDOW_GEN["$k"]-0} + 1 ))
        echo "$(date): Window count changed on monitor $mon: $last_count -> $current_count"
    fi
}

monitor_tick() {
    # Skip all processing if auto-layout is disabled (maximum CPU savings)
    if ! is_auto_layout_enabled; then
        echo "$(date): Auto-layout disabled - daemon idle (maximum CPU savings)"
        return 0
    fi
    
    # Iterate just the current workspace; your layouts also operate per monitor.
    local ws mon k
    ws="$(get_current_workspace)"
    get_screen_info_cached  # refresh monitors (cached for CPU efficiency)
    for mon in "${MONITORS[@]}"; do
        IFS=':' read -r monitor_name mx my mw mh <<< "$mon"

        # Skip reconcile/apply during manual operation hold
        if should_hold "$ws" "$monitor_name"; then
            continue
        fi

        reconcile_ws_mon "$ws" "$monitor_name"

        k="$(key_wsmon "$ws" "$monitor_name")"
        local dirty="${WINDOW_DIRTY["$k"]-0}"
        if is_auto_layout_enabled && [[ "$dirty" -eq 1 ]] && monitor_should_apply; then
            # Debounce rapid changes to avoid excessive layout applications
            local now=$(date +%s)
            local time_since_last_change=$((now - LAST_CHANGE_TIME))
            
            if [[ $time_since_last_change -ge $DEBOUNCE_DELAY ]]; then
                # Apply layout after debounce delay
                echo "$(date): Applying debounced layout to monitor $monitor_name"
                reapply_saved_layout_for_monitor "$ws" "$mon"
                WINDOW_DIRTY["$k"]=0
                LAST_CHANGE_TIME=$now
            else
                # Still within debounce period, keep dirty flag
                echo "$(date): Debouncing changes on monitor $monitor_name (${time_since_last_change}s < ${DEBOUNCE_DELAY}s)"
            fi
        fi
    done
}

# list_windows_on_monitor_for_workspace now defined at top of file

#========================================
# DAEMON-ONLY WINDOW LIST FUNCTIONS
# These functions need initialized window lists and run in daemon context
#========================================

# Trigger daemon to immediately reapply layouts (called by manual commands)
trigger_daemon_reapply() {
    if is_daemon_running; then
        local daemon_pid
        daemon_pid=$(get_daemon_pid)
        echo "Triggering daemon to reapply layouts..."
        kill -SIGUSR1 "$daemon_pid" 2>/dev/null
        return $?
    else
        return 1
    fi
}

# IPC Communication (variables defined at top of file)

# Send command to daemon and get response
send_daemon_command() {
    local command="$1"
    
    if ! is_daemon_running; then
        die "Daemon is not running. Start with: place-window watch start"
    fi
    
    # Ensure pipes exist
    [[ -p "$DAEMON_CMD_PIPE" ]] || die "Daemon command pipe not found at $DAEMON_CMD_PIPE"
    [[ -p "$DAEMON_RESP_PIPE" ]] || die "Daemon response pipe not found at $DAEMON_RESP_PIPE"
    
    # Send command and wait for response. The daemon terminates each
    # response with the sentinel line __DAEMON_RESP_END__, so we accumulate
    # lines until we see it or the deadline passes.
    echo "$command" > "$DAEMON_CMD_PIPE" || die "Failed to send command to daemon"

    local response="" line got_response=0
    local deadline=$(( $(date +%s) + 5 ))

    exec 5<"$DAEMON_RESP_PIPE"
    while (( $(date +%s) < deadline )); do
        if IFS= read -r -t 1 line <&5; then
            if [[ "$line" == "__DAEMON_RESP_END__" ]]; then
                got_response=1
                break
            fi
            response+="${response:+$'\n'}$line"
        fi
    done
    exec 5<&-

    if (( got_response )); then
        [[ -n "$response" ]] && printf '%s\n' "$response"
        return 0
    else
        die "No response from daemon (timeout after 5 seconds)"
    fi
}

# Handle incoming commands in daemon context
handle_daemon_command() {
    local command="$1"
    local response=""
    
    case "$command" in
        ping)
            response="pong $(date +%s)"
            ;;
        "auto")
            response=$(auto_layout_current_monitor 2>&1)
            ;;
        "auto --all")
            response=$(auto_layout_all_monitors 2>&1)
            ;;
        "reapply")
            response=$(apply_workspace_layout 2>&1)
            ;;
        master*)
            # Parse master command: "master vertical 60", "master center 50", "master increase/decrease"
            read -ra cmd_parts <<< "$command"
            local orientation="${cmd_parts[1]}"
            
            if [[ "$orientation" == "increase" || "$orientation" == "decrease" ]]; then
                response=$(adjust_master_size "$orientation" 2>&1)
            elif [[ "$orientation" == "center" ]]; then
                local percentage="${cmd_parts[2]:-50}"
                response=$(center_master_layout_current_monitor "$percentage" 2>&1)
            elif [[ "${cmd_parts[2]}" == "--all" ]]; then
                local percentage="${cmd_parts[3]:-60}"
                response=$(master_stack_layout "$orientation" "$percentage" 2>&1)
            else
                local percentage="${cmd_parts[2]:-60}"
                response=$(master_stack_layout_current_monitor "$orientation" "$percentage" 2>&1)
            fi
            ;;
        cycle*)
            if [[ "$command" == *"counter-clockwise"* ]]; then
                response=$(reverse_cycle_window_positions 2>&1)
            else
                response=$(cycle_window_positions 2>&1)
            fi
            ;;
        "swap")
            response=$(swap_window_positions 2>&1)
            ;;
        focus*)
            read -ra cmd_parts <<< "$command"
            local direction="${cmd_parts[1]}"
            response=$(focus_window "$direction" 2>&1)
            ;;
        *)
            response="Error: Unknown daemon command: $command"
            ;;
    esac
    
    echo "$response"
}

# Master-stack layout for current monitor only
master_stack_layout_current_monitor() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local current_workspace=$(get_current_workspace)
    
    # Get windows using live snapshot with configured ordering strategy
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    local windows_on_monitor=()
    mapfile -t windows_on_monitor < <(get_windows_ordered "$monitor_name")
    
    if [[ ${#windows_on_monitor[@]} -eq 0 ]]; then
        echo "No visible windows on current monitor"
        return 1
    fi
    
    IFS=':' read -r name mx my mw mh <<< "$current_monitor"
    local num_windows=${#windows_on_monitor[@]}
    echo "Monitor $name: Applying master-stack ($orientation, ${percentage}%) to $num_windows window(s)"
    
    if [[ "$orientation" == "vertical" ]]; then
        # Master on left, stack on right - use main-sidebar atomic function
        apply_meta_main_sidebar_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
    else
        # Master on top, stack on bottom - use topbar-main atomic function  
        apply_meta_topbar_main_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
    fi
    
    echo "Master-stack layout ($orientation) applied to current monitor"
    
    # Save per-monitor layout
    local workspace=$(get_current_workspace)
    IFS=':' read -r monitor_name rest <<< "$current_monitor"
    save_workspace_monitor_layout "$workspace" "$monitor_name" "master $orientation $percentage" ""
    
    # Trigger daemon to immediately reapply with new preference
    trigger_daemon_reapply >/dev/null 2>&1
}

# Master-stack layouts for all monitors (reuses single-monitor function)
master_stack_layout() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    get_screen_info
    local current_monitor=$(get_current_monitor)
    
    local monitors_applied=0
    local total_windows=0
    
    echo "Applying master-stack ($orientation, ${percentage}%) to all monitors on workspace $((current_workspace + 1))"
    
    # Apply master-stack layout to each monitor by temporarily switching context
    for monitor in "${MONITORS[@]}"; do
        # Get windows from persistent list for this monitor
        IFS=':' read -r name mx my mw mh <<< "$monitor"
        local current_list=$(get_windows_ordered "$name")
        local windows_on_monitor=()
        if [[ -n "$current_list" ]]; then
            read -ra windows_on_monitor <<< "$current_list"
        fi
        
        local num_windows=${#windows_on_monitor[@]}
        total_windows=$((total_windows + num_windows))
        
        if [[ $num_windows -gt 0 ]]; then
            IFS=':' read -r name mx my mw mh <<< "$monitor"
            echo "Monitor $name: $num_windows window(s)"
            
            # Temporarily override current monitor context for the single-monitor function
            local original_monitor="$current_monitor"

            # Save and override get_current_monitor to return this specific monitor
            local _saved_get_current_monitor
            _saved_get_current_monitor="$(declare -f get_current_monitor)"
            get_current_monitor() { echo "$monitor"; }

            # Apply master-stack layout to this monitor using the single-monitor function
            master_stack_layout_current_monitor "$orientation" "$percentage"

            # Restore original get_current_monitor function
            unset -f get_current_monitor
            [[ -n "$_saved_get_current_monitor" ]] && eval "$_saved_get_current_monitor"
            
            monitors_applied=$((monitors_applied + 1))
        else
            IFS=':' read -r name mx my mw mh <<< "$monitor"
            echo "Monitor $name: No windows to arrange"
        fi
    done
    
    if [[ $total_windows -lt 2 ]]; then
        echo "Master-stack requires at least 2 windows across all monitors (found $total_windows)"
        return 1
    fi
    
    echo "Master-stack layout ($orientation) applied to $monitors_applied monitor(s) with $total_windows total windows"
}

# Center master layout for current monitor only
center_master_layout_current_monitor() {
    local percentage="${1:-50}"
    
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local current_workspace=$(get_current_workspace)
    
    # Get windows using live snapshot with configured ordering strategy
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    local windows_on_monitor=()
    mapfile -t windows_on_monitor < <(get_windows_ordered "$monitor_name")
    
    if [[ ${#windows_on_monitor[@]} -eq 0 ]]; then
        echo "No visible windows on current monitor"
        return 1
    fi
    
    IFS=':' read -r name mx my mw mh <<< "$current_monitor"
    local num_windows=${#windows_on_monitor[@]}
    echo "Monitor $name: Applying center master layout (${percentage}%) to $num_windows window(s)"
    
    apply_meta_center_sidebar_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
    
    echo "Center master layout applied to current monitor"
    
    # Save per-monitor layout
    local workspace=$(get_current_workspace)
    IFS=':' read -r monitor_name rest <<< "$current_monitor"
    save_workspace_monitor_layout "$workspace" "$monitor_name" "master center $percentage" ""
    
    # Trigger daemon to immediately reapply with new preference
    trigger_daemon_reapply >/dev/null 2>&1
}

# Adjust master window size by 5% increments
adjust_master_size() {
    local action="$1"  # increase or decrease
    
    get_screen_info
    local current_monitor=$(get_current_monitor)
    local current_workspace=$(get_current_workspace)
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    
    # Get current saved layout for this workspace/monitor
    local current_layout=$(get_workspace_monitor_layout "$current_workspace" "$monitor_name" "" "")
    
    if [[ -z "$current_layout" || ! "$current_layout" =~ ^master[[:space:]](.+)$ ]]; then
        echo "Error: No active master layout found on current monitor"
        echo "Use 'place-window master vertical/horizontal/center' to set a master layout first"
        return 1
    fi
    
    # Parse current layout: "master vertical 60" or "master center 50"
    local master_params="${BASH_REMATCH[1]}"
    read -r orientation percentage <<< "$master_params"
    
    # Calculate new percentage (5% increment/decrement)
    local new_percentage
    if [[ "$action" == "increase" ]]; then
        new_percentage=$((percentage + 5))
    else
        new_percentage=$((percentage - 5))
    fi
    
    # Validate ranges based on layout type
    if [[ "$orientation" == "center" ]]; then
        if [[ $new_percentage -lt 20 || $new_percentage -gt 80 ]]; then
            echo "Error: Center master percentage must be between 20% and 80% (current: ${percentage}%)"
            return 1
        fi
    else
        if [[ $new_percentage -lt 10 || $new_percentage -gt 90 ]]; then
            echo "Error: Master percentage must be between 10% and 90% (current: ${percentage}%)"
            return 1
        fi
    fi
    
    echo "${action^}ing master size from ${percentage}% to ${new_percentage}%"
    
    # Apply the new layout with adjusted percentage
    if [[ "$orientation" == "center" ]]; then
        center_master_layout_current_monitor "$new_percentage"
    else
        master_stack_layout_current_monitor "$orientation" "$new_percentage"
    fi
}

# Window operation functions live in windows.sh; layout/auto-layout
# functions live in layouts.sh.
