#!/bin/bash

# set -e is intentionally omitted: the daemon runs many fallible probes
# (grep -c on possibly-empty input, optional xprop reads) where a non-zero
# exit is the normal "no data" path and must not terminate the loop.
# CAUTION: omitting -e here is NOT sufficient on its own — this file is
# sourced by place-window, which runs `set -euo pipefail`, and `set -uo
# pipefail` does not clear an inherited -e. watch_daemon_with_ipc runs an
# explicit `set +e` at daemon entry; keep it, or the daemon silently dies
# on the first BadWindow race (see commit 886c867 and the July 2026
# crash investigation).
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

# --- Daemon-specific state tracking ---
# Dirty tracking for daemon's reconciliation logic.
# WINDOW_IDS holds the last-seen membership (sorted, space-joined window IDs)
# per (workspace, monitor); WINDOW_COUNT is kept alongside for log messages.
declare -Ag WINDOW_DIRTY WINDOW_COUNT WINDOW_IDS 2>/dev/null || true

# Hold map to protect manual operations from immediate reconciliation
declare -Ag HOLD_UNTIL_MS 2>/dev/null || true

# Monitor detection caching for CPU optimization
declare -ag SCREEN_INFO_CACHE=()
SCREEN_INFO_CACHE_TIME=0

# Debouncing for rapid changes — per-monitor so an apply on one monitor
# never gates an apply on a different monitor.
declare -Ag LAST_CHANGE_TIME 2>/dev/null || true
DEBOUNCE_DELAY=2  # seconds, per (workspace,monitor)

# Event watcher state (xprop -spy on root atoms; events drive monitor_tick)
WATCHER_PID=""
EVENT_TAG="__EVENT__"
SAFETY_TICK=30  # heartbeat seconds — events do most of the work

# Root atoms the watcher spies on — see start_event_watcher for the rationale
# per atom. Kept as a variable so tests can assert coverage.
WATCHED_ROOT_ATOMS="_NET_CLIENT_LIST _NET_CLIENT_LIST_STACKING _NET_CURRENT_DESKTOP _NET_ACTIVE_WINDOW"

# Classify an event line for the main loop's tick rate limit. Atoms that fire
# on every click/raise (_NET_ACTIVE_WINDOW, _NET_CLIENT_LIST_STACKING) are
# rate-limited to one tick per second; rare, meaningful events (window
# open/close, workspace switch) always tick immediately. NB:
# _NET_CLIENT_LIST is a prefix of _NET_CLIENT_LIST_STACKING — the STACKING
# pattern must be tested so a plain client-list event is never misclassified.
event_is_rate_limited() {  # arg: raw tagged event line
    case "$1" in
        *_NET_ACTIVE_WINDOW*|*_NET_CLIENT_LIST_STACKING*) return 0 ;;
        *) return 1 ;;
    esac
}

# Milliseconds since epoch without forking date: $EPOCHREALTIME is
# "seconds<radix>microseconds" (radix char is locale-dependent — strip
# either), so dropping the radix and dividing by 1000 gives ms.
now_ms() { NOW_MS=$(( ${EPOCHREALTIME/[.,]/} / 1000 )); }

hold_now() {  # ws mon_name [ms]
  local ws="$1" mon="$2" ms="${3:-900}"
  now_ms
  local k="workspace_${ws}_monitor_${mon}"
  HOLD_UNTIL_MS["$k"]=$(( NOW_MS + ms ))
}

should_hold() {  # ws mon_name
  local ws="$1" mon="$2" k
  now_ms
  k="workspace_${ws}_monitor_${mon}"
  [[ ${HOLD_UNTIL_MS["$k"]-0} -gt $NOW_MS ]]
}

# Daemon maps are keyed "workspace_<ws>_monitor_<mon>", built inline at each
# site — a $(helper) command substitution would fork on the tick path.

# Cooldown helpers (monitor uses these even before watch loop starts)
: "${COOLDOWN_UNTIL_MS:=0}"
cooldown_now() {                # args: [ms]
  local ms="${1:-600}"
  now_ms
  COOLDOWN_UNTIL_MS=$(( NOW_MS + ms ))
}
monitor_should_apply() {
  now_ms
  (( NOW_MS >= COOLDOWN_UNTIL_MS ))
}

# Cached screen info for CPU optimization - monitors rarely change
get_screen_info_cached() {
    local now=$EPOCHSECONDS
    if (( ${#SCREEN_INFO_CACHE[@]} == 0 )) || (( now - SCREEN_INFO_CACHE_TIME > 30 )); then
        get_screen_info  # Calls original function from monitors.sh
        SCREEN_INFO_CACHE=("${MONITORS[@]}")
        SCREEN_INFO_CACHE_TIME=$now
        echo "$(date): Monitor info refreshed (cache TTL: 30s)" >&2
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

# Spawn xprop -spy on root atoms; respawn if it dies. Each event line is
# tagged and pushed into the IPC pipe so the main loop can multiplex events
# and commands through a single read.
#
# Atoms watched (WATCHED_ROOT_ATOMS):
#   _NET_CLIENT_LIST           window create / destroy
#   _NET_CURRENT_DESKTOP       workspace switch
#   _NET_ACTIVE_WINDOW         focus change — the proxy that makes minimize/
#                              restore event-driven (minimizing moves focus).
#                              Fires on every click, so it is rate-limited to
#                              one tick per second in the main loop (pending
#                              ticks flush within ~1s, heartbeat is the final
#                              backstop).
#   _NET_CLIENT_LIST_STACKING  restack — the ONLY root atom that fires when a
#                              window is moved to another workspace without a
#                              focus change (pager drag, wmctrl/script move):
#                              _NET_WM_DESKTOP is a per-window property the
#                              root spy cannot see, but xfwm4 restacks the
#                              window into the destination workspace. Mostly
#                              fires on the same clicks as _NET_ACTIVE_WINDOW,
#                              so it shares the same 1s rate limit
#                              (event_is_rate_limited) and adds no idle cost.
start_event_watcher() {
    [[ -n "$WATCHER_PID" ]] && kill -0 "$WATCHER_PID" 2>/dev/null && return 0

    (
        # Subshell: reap child xprop/awk on signal so they don't outlive the daemon.
        # $$ inside a subshell is still the parent's PID — use $BASHPID for our own.
        trap 'pkill -P "$BASHPID" 2>/dev/null; exit 0' SIGTERM SIGINT
        while true; do
            # shellcheck disable=SC2086 — atom list must word-split
            xprop -spy -root $WATCHED_ROOT_ATOMS 2>/dev/null \
              | awk -v tag="$EVENT_TAG" '{ printf "%s %s\n", tag, $0; fflush() }' \
              > "$DAEMON_CMD_PIPE"
            # xprop died (X server gone, atom missing, etc) — back off then retry
            sleep 1
        done
    ) &
    WATCHER_PID=$!
    echo "$(date): Event watcher started (PID $WATCHER_PID)"
}

stop_event_watcher() {
    if [[ -n "$WATCHER_PID" ]]; then
        kill "$WATCHER_PID" 2>/dev/null || true
        WATCHER_PID=""
    fi
}

# Resolve X display authorization dynamically. Under the systemd user
# unit there is no session environment: DISPLAY comes from the unit, but
# the X cookie location depends on the display manager (lightdm:
# /run/lightdm/<user>/xauthority; GDM: /run/user/<uid>/gdm/Xauthority;
# most others: ~/.Xauthority). Probe candidates until an X call actually
# succeeds rather than hardcoding any single manager's path — a cookie
# file existing does not mean it holds a valid cookie for this DISPLAY.
# When started from a session (legacy nohup path), the inherited
# environment already works and the first probe short-circuits.
ensure_x_authority() {
    : "${DISPLAY:=:0}"; export DISPLAY
    if xdotool getdisplaygeometry >/dev/null 2>&1; then
        return 0  # already authorized (session env or valid default)
    fi
    local xa
    for xa in "${XAUTHORITY:-}" \
              "/run/lightdm/$(id -un)/xauthority" \
              "/run/user/$(id -u)/gdm/Xauthority" \
              "$HOME/.Xauthority"; do
        [[ -n "$xa" && -r "$xa" ]] || continue
        if XAUTHORITY="$xa" xdotool getdisplaygeometry >/dev/null 2>&1; then
            export XAUTHORITY="$xa"
            echo "$(date): X authority resolved to $xa"
            return 0
        fi
    done
    echo "$(date): ERROR: no working X authority found for DISPLAY=$DISPLAY" >&2
    return 1
}

# Combined daemon that handles both window monitoring and IPC commands
watch_daemon_with_ipc() {
    # errexit OFF for the daemon's lifetime. place-window runs under
    # `set -euo pipefail`, and this file's `set -uo pipefail` header does
    # NOT clear an inherited -e when sourced — `set` only adds options.
    # Commit 886c867 removed -e from the header to stop unguarded nonzero
    # probes from silently terminating the daemon, but the -e inherited
    # from place-window survived that fix, so the daemon kept dying: any
    # window closing between the window-list snapshot and the geometry
    # apply makes wmctrl/xdotool exit 1 (BadWindow) and errexit kills the
    # whole process with no message. Root-caused 2026-07-13 via the
    # EXIT-trap instrumentation below.
    set +e

    # Exit 1 (not 0) if X is unreachable so the systemd unit's
    # Restart=on-failure retries — this self-heals the race where the
    # unit starts before the X session is fully up at login. The burst
    # limit (10/min) stops the loop if X genuinely never comes.
    if ! ensure_x_authority; then
        exit 1
    fi

    # Single-process daemon: event watcher + command loop + safety-net tick.
    trap 'stop_event_watcher; cleanup_daemon_ipc; echo "Watch daemon stopped"; exit 0' SIGINT SIGTERM
    trap 'echo "$(date): SIGUSR1 -> reapply layouts"; apply_workspace_layout' SIGUSR1
    trap 'echo "$(date): SIGUSR2 -> wake from idle"' SIGUSR2

    # Post-mortem instrumentation (field crashes, July 2026): the daemon has
    # died with no bash error in the log, no journal entry, the cleanup trap
    # never firing, and its watcher children surviving — i.e. something that
    # bypasses every handler above. Log every remaining exit path so the next
    # death identifies itself:
    #   - EXIT fires on normal exits, shell fatal errors (set -u), and any
    #     trapped signal. It CANNOT fire on SIGKILL — so a death that leaves
    #     no "daemon EXIT" line at all means SIGKILL.
    #   - The signals below terminate silently by default and are not logged
    #     by the kernel. Trapping them converts a silent death into a logged
    #     one. Exit codes follow the 128+N convention. The HUP trap is a
    #     no-op under nohup (bash keeps entry-time SIG_IGN) — that is fine;
    #     it matters for daemons started without nohup (XDG autostart Exec).
    # NB: capture $? FIRST — a $(date) earlier in the same trap string
    # would overwrite it with the substitution's own (always 0) status,
    # which is exactly how the errexit death initially masqueraded as a
    # clean "status=0" exit during the July 2026 investigation.
    trap '_rc=$?; echo "$(date): daemon EXIT status=$_rc pid=$$"' EXIT
    trap 'echo "$(date): SIGHUP received - exiting"; exit 129' SIGHUP
    trap 'echo "$(date): SIGPIPE received - exiting"; exit 141' SIGPIPE
    trap 'echo "$(date): SIGALRM received - exiting"; exit 142' SIGALRM
    trap 'echo "$(date): SIGQUIT received - exiting"; exit 131' SIGQUIT
    trap 'echo "$(date): SIGABRT received - exiting"; exit 134' SIGABRT

    echo "$(date): Watch daemon with IPC started (single loop, event-driven)"

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

    # Open FIFOs once. Bidirectional open keeps EOF away when transient writers close.
    exec 3<>"$DAEMON_CMD_PIPE"
    exec 4<>"$DAEMON_RESP_PIPE"

    # fd 6 = diagnostic log channel that survives the 2>&1 capture in
    # handle_daemon_command. Without this, log lines emitted from inside
    # IPC-initiated commands (auto, master, reapply, …) get sent to the
    # IPC response instead of daemon.log, making bug-diagnosis impossible.
    # Inherits the daemon's stdout, which `place-window` redirects to
    # ~/.config/window-positioning/daemon.log via nohup.
    exec 6>&1

    # Spawn the X11 event watcher AFTER FD 3 is open so its writes never block
    # waiting for a reader.
    start_event_watcher

    # First-pass layout for any windows already on screen at startup.
    monitor_tick

    # Track workspace for transition logging (helps diagnose layout-reset bugs
    # where a workspace switch is the unrecorded trigger).
    local LAST_KNOWN_WS
    LAST_KNOWN_WS=$(get_current_workspace 2>/dev/null || echo "?")

    echo "$(date): entering main loop (heartbeat ${SAFETY_TICK}s)"
    # Suspend/resume detection: a loop iteration normally takes at most
    # SAFETY_TICK seconds (read timeout) plus a few seconds of processing.
    # A much larger wall-clock gap means the machine was suspended. After
    # resume the xprop -spy watcher can hold a stale X connection that
    # neither delivers events nor exits — its wrapper subshell stays alive,
    # so the heartbeat's kill -0 respawn check never fires and the daemon
    # goes permanently deaf. Detect the gap, restart the watcher
    # unconditionally, drop caches, and force a full reconcile.
    local LAST_LOOP_TS
    LAST_LOOP_TS=$EPOCHSECONDS
    # Event-tick rate limit: _NET_ACTIVE_WINDOW fires on every focus click,
    # so cap event-driven reconciles at one per second. A rate-limited event
    # sets PENDING_EVENT_TICK instead of being dropped; the read timeout
    # shrinks to 1s while a tick is pending, so the trailing edge of a
    # click-storm is reconciled within ~1s of the last event. Costs nothing
    # at idle — no events, no wakeups, the read just waits SAFETY_TICK.
    local LAST_EVENT_TICK_TS=0 PENDING_EVENT_TICK=0
    while true; do
        local _now_ts
        _now_ts=$EPOCHSECONDS
        if (( _now_ts - LAST_LOOP_TS > SAFETY_TICK * 2 + 5 )); then
            echo "$(date): wall-clock gap of $((_now_ts - LAST_LOOP_TS))s detected — assuming suspend/resume; restarting event watcher"
            stop_event_watcher
            start_event_watcher
            SCREEN_INFO_CACHE_TIME=0            # monitors may have changed
            WINDOW_COUNT=()                     # force dirty on next reconcile
            WINDOW_IDS=()                       # membership snapshot is stale too
            HOLD_UNTIL_MS=()                    # stale holds from before suspend
            COOLDOWN_UNTIL_MS=0
            monitor_tick
        fi
        LAST_LOOP_TS=$_now_ts

        local cmd _read_timeout="$SAFETY_TICK"
        (( PENDING_EVENT_TICK )) && _read_timeout=1
        if read -t "$_read_timeout" -r cmd <&3; then
            case "$cmd" in
                "$EVENT_TAG"\ *)
                    if [[ "$cmd" == *"_NET_CURRENT_DESKTOP"* ]]; then
                        local _new_ws
                        _new_ws=$(get_current_workspace 2>/dev/null || echo "?")
                        if [[ "$_new_ws" != "$LAST_KNOWN_WS" ]]; then
                            echo "$(date): workspace switch $LAST_KNOWN_WS -> $_new_ws"
                            LAST_KNOWN_WS="$_new_ws"
                        fi
                    fi
                    # Rate limit applies only to click-frequency atoms
                    # (_NET_ACTIVE_WINDOW, _NET_CLIENT_LIST_STACKING — see
                    # event_is_rate_limited). _NET_CLIENT_LIST (window
                    # open/close) and _NET_CURRENT_DESKTOP (workspace switch)
                    # are rare, meaningful events and always tick immediately
                    # — else a new window launched right after a click
                    # (launcher, menu) lands inside the 1s window and waits
                    # for the flush.
                    if event_is_rate_limited "$cmd" \
                       && (( EPOCHSECONDS - LAST_EVENT_TICK_TS < 1 )); then
                        PENDING_EVENT_TICK=1
                    else
                        # Brief sleep coalesces follow-up property updates
                        # that the WM emits in quick succession.
                        sleep 0.1
                        LAST_EVENT_TICK_TS=$EPOCHSECONDS
                        PENDING_EVENT_TICK=0
                        monitor_tick
                    fi
                    ;;
                "")
                    # Empty line — ignore.
                    ;;
                *)
                    # IPC client command. Response body may be empty or contain
                    # many newlines; sentinel line tells the client where to stop.
                    local resp
                    resp="$(handle_daemon_command "$cmd" 2>&1)"
                    # Drain orphaned bytes from the response pipe before
                    # writing. A client that times out leaves its response
                    # unread in the FIFO forever (fd 4 is open read-write, so
                    # there is no EOF-based cleanup); enough orphans fill the
                    # 64KB pipe buffer and the printf below then blocks the
                    # daemon permanently — verified experimentally. A new
                    # command arriving means no client is legitimately
                    # mid-read, so anything still in the pipe is stale.
                    local _stale
                    while IFS= read -r -t 0.01 -u 4 _stale; do :; done
                    if [[ -n "$resp" ]]; then
                        printf '%s\n' "$resp" >&4
                    fi
                    printf '__DAEMON_RESP_END__\n' >&4
                    # Cool down so own apply_geometry traffic doesn't immediately
                    # bounce back through monitor_tick.
                    cooldown_now 600
                    ;;
            esac
            continue
        fi

        # Read timed out. Either a rate-limited event tick is pending (1s
        # timeout — flush it now) or this is the SAFETY_TICK heartbeat that
        # catches anything the watched atoms miss. Also respawns the watcher
        # if it died silently.
        if [[ -n "$WATCHER_PID" ]] && ! kill -0 "$WATCHER_PID" 2>/dev/null; then
            echo "$(date): Event watcher died; respawning"
            WATCHER_PID=""
            start_event_watcher
        fi
        LAST_EVENT_TICK_TS=$EPOCHSECONDS
        PENDING_EVENT_TICK=0
        monitor_tick
    done
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

# Check if watch daemon is running
is_daemon_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# Get daemon PID if running
get_daemon_pid() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
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

# Detect window-set changes for a single (workspace, monitor). No persistence
# of window IDs — we track the post-filter, per-monitor window count and only
# flip the dirty bit when it actually moves.
#
# The previous "fast path" compared a workspace-wide raw count from `wmctrl
# -l` against this per-monitor filtered count. Those two numbers are not
# comparable (one includes docks/menus and spans monitors), so the early exit
# was always false and full reconciliation ran every tick. With the daemon
# now event-driven, ticks are rare anyway — drop the shortcut entirely and
# always do the real comparison.
reconcile_ws_mon() {  # args: workspace monitor_name
    local ws="$1" mon="$2"
    local k="workspace_${ws}_monitor_${mon}"

    # Membership count only — use the unordered list. get_windows_ordered's
    # spatial sort reads per-window geometry (one xwininfo+xprop per window)
    # that a count can never use. Same filter, same membership, fewer forks.
    local current_windows
    current_windows="$(get_visible_windows "$mon" "$ws")"
    local -a _cur=()
    [[ -n "$current_windows" ]] && mapfile -t _cur <<< "$current_windows"
    local current_count=${#_cur[@]}

    # Compare MEMBERSHIP, not just count. A window moved in from another
    # workspace while one left (swap-rearrange via the pager), or moved in
    # after another closed, keeps the count identical — a count-only compare
    # never flags it and the moved window is never re-positioned. Sorted,
    # space-joined IDs make the comparison order-independent.
    local current_ids=""
    if [[ -n "$current_windows" ]]; then
        current_ids=$(printf '%s\n' "$current_windows" | sort | tr '\n' ' ')
    fi

    local last_count="${WINDOW_COUNT["$k"]-0}"
    local last_ids="${WINDOW_IDS["$k"]-}"
    if [[ "$current_ids" != "$last_ids" ]]; then
        WINDOW_DIRTY["$k"]=1
        WINDOW_COUNT["$k"]=$current_count
        WINDOW_IDS["$k"]="$current_ids"
        if [[ "$current_count" -ne "$last_count" ]]; then
            echo "$(date): Window count changed on monitor $mon: $last_count -> $current_count"
        else
            echo "$(date): Window membership changed on monitor $mon (count unchanged: $current_count)"
        fi
    fi
}

monitor_tick() {
    # Skip all processing if auto-layout is disabled (maximum CPU savings).
    # Log only on the disabled→enabled→disabled transition, not on every tick;
    # otherwise this line floods daemon.log every heartbeat (30s) plus every
    # X11 event for as long as the user keeps auto-layout off.
    if ! is_auto_layout_enabled; then
        if [[ "${MONITOR_TICK_DISABLED_LOGGED:-0}" -eq 0 ]]; then
            echo "$(date): Auto-layout disabled - daemon idle (maximum CPU savings)"
            MONITOR_TICK_DISABLED_LOGGED=1
        fi
        return 0
    fi
    MONITOR_TICK_DISABLED_LOGGED=0


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

        k="workspace_${ws}_monitor_${monitor_name}"
        local dirty="${WINDOW_DIRTY["$k"]-0}"
        if is_auto_layout_enabled && [[ "$dirty" -eq 1 ]] && monitor_should_apply; then
            # Per-monitor debounce: if THIS monitor was just applied, skip until
            # DEBOUNCE_DELAY elapses. Other monitors are unaffected.
            local now=$EPOCHSECONDS
            local last="${LAST_CHANGE_TIME["$k"]-0}"
            local time_since_last_change=$((now - last))

            if [[ $time_since_last_change -ge $DEBOUNCE_DELAY ]]; then
                echo "$(date): Applying debounced layout to monitor $monitor_name"
                reapply_saved_layout_for_monitor "$ws" "$mon"
                WINDOW_DIRTY["$k"]=0
                LAST_CHANGE_TIME["$k"]=$now
            else
                # Still within this monitor's own debounce window; leave dirty flag.
                echo "$(date): Debouncing changes on monitor $monitor_name (${time_since_last_change}s < ${DEBOUNCE_DELAY}s)"
            fi
        fi
    done
}

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

    # 15s deadline, not 5: a full layout apply takes multiple seconds
    # (settle-waits are ~250ms per window, and the daemon may be
    # mid-tick when the command arrives). With a 5s deadline, heavier
    # commands routinely timed out and orphaned their responses in the
    # pipe — feeding the pipe-fill failure mode drained above.
    local response="" line got_response=0
    local deadline=$(( EPOCHSECONDS + 15 ))

    exec 5<"$DAEMON_RESP_PIPE"
    while (( EPOCHSECONDS < deadline )); do
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
                response=$(cycle_window_positions counter-clockwise 2>&1)
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

# Master-stack layout for one monitor (defaults to the current monitor;
# master_stack_layout passes each monitor explicitly for --all).
master_stack_layout_current_monitor() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    local current_monitor="${3:-}"  # optional monitor override ("name:x:y:w:h")

    get_screen_info
    [[ -z "$current_monitor" ]] && current_monitor=$(get_current_monitor)
    local current_workspace=$(get_current_workspace)

    # Get windows using live snapshot with configured ordering strategy.
    # Pass current_workspace so the filter stays consistent with what we'll
    # save under save_workspace_monitor_layout below — even if the user
    # switches workspaces while the apply is running.
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    local windows_on_monitor=()
    mapfile -t windows_on_monitor < <(get_windows_ordered "$monitor_name" "" "$current_workspace")

    if [[ ${#windows_on_monitor[@]} -eq 0 ]]; then
        echo "No visible windows on current monitor"
        return 1
    fi

    IFS=':' read -r name mx my mw mh <<< "$current_monitor"
    local num_windows=${#windows_on_monitor[@]}
    echo "Monitor $name: Applying master-stack ($orientation, ${percentage}%) to $num_windows window(s)"
    
    case "$orientation" in
        vertical)
            # Master on left, stack on right
            apply_meta_main_sidebar_single_monitor "$current_monitor" "$percentage" left "${windows_on_monitor[@]}"
            ;;
        vertical-right)
            # Master on right, stack on left
            apply_meta_main_sidebar_single_monitor "$current_monitor" "$percentage" right "${windows_on_monitor[@]}"
            ;;
        *)
            # Master on top, stack on bottom (horizontal default)
            apply_meta_topbar_main_single_monitor "$current_monitor" "$percentage" "${windows_on_monitor[@]}"
            ;;
    esac
    
    echo "Master-stack layout ($orientation) applied to current monitor"
    
    # Save per-monitor layout
    local workspace=$(get_current_workspace)
    IFS=':' read -r monitor_name rest <<< "$current_monitor"
    save_workspace_monitor_layout "$workspace" "$monitor_name" "master $orientation $percentage" ""
}

# Master-stack layouts for all monitors (reuses single-monitor function)
master_stack_layout() {
    local orientation="$1"  # vertical or horizontal
    local percentage="${2:-60}"  # master window percentage (default 60%)
    
    # Get current workspace and monitor info
    local current_workspace=$(get_current_workspace)
    get_screen_info

    local monitors_applied=0
    local total_windows=0
    
    echo "Applying master-stack ($orientation, ${percentage}%) to all monitors on workspace $((current_workspace + 1))"
    
    # Apply master-stack layout to each monitor by temporarily switching context
    for monitor in "${MONITORS[@]}"; do
        # Get windows from persistent list for this monitor
        IFS=':' read -r name mx my mw mh <<< "$monitor"
        local current_list=$(get_windows_ordered "$name" "" "$current_workspace")
        local windows_on_monitor=()
        if [[ -n "$current_list" ]]; then
            read -ra windows_on_monitor <<< "$current_list"
        fi
        
        local num_windows=${#windows_on_monitor[@]}
        total_windows=$((total_windows + num_windows))
        
        if [[ $num_windows -gt 0 ]]; then
            IFS=':' read -r name mx my mw mh <<< "$monitor"
            echo "Monitor $name: $num_windows window(s)"

            master_stack_layout_current_monitor "$orientation" "$percentage" "$monitor"

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

    # Pass current_workspace to keep the window-list filter consistent with the
    # save key below — see master_stack_layout_current_monitor for the reason.
    IFS=':' read -r monitor_name mx my mw mh <<< "$current_monitor"
    local windows_on_monitor=()
    mapfile -t windows_on_monitor < <(get_windows_ordered "$monitor_name" "" "$current_workspace")

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
