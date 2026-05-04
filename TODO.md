# Window Positioning TODO List

## Pending Tasks

### Restore Event-Driven Daemon (CPU Regression)
- **Task**: Replace the polling-based `monitor_tick` heartbeat with event-driven X11 monitoring; current daemon burns ~20% CPU at idle
- **Symptom**: Steady ~20% CPU load with the watch daemon running, even with no window activity
- **Root cause #1 (immediate, in `lib/daemon.sh:494-521` `reconcile_ws_mon`)**:
  - `quick_count` counts ALL windows on the workspace via `wmctrl -l | awk '$2==ws || $2==-1' | wc -l` — includes XFCE panel/dock and other DOCK/DESKTOP/MENU/HIDDEN windows
  - `last_count` (= `WINDOW_COUNT[$k]`) is per-(workspace,monitor) and stores the post-filter, per-monitor count from `current_count` after `get_windows_ordered`
  - The two are never comparable → "early exit" never fires → full reconciliation runs every 1.5s tick
  - Full reconciliation fans out into ~12 subprocess spawns per visible window via `get_visible_windows` (4–5 `xprop`s) + `get_window_client_geometry` (`xwininfo` + `xprop` + awks); on dom0/Xen this drives the ~20% CPU
- **Root cause #2 (architectural regression)**:
  - Commit `5bbcc7c` (2025-09-07, "Optimize daemon CPU usage with event-driven architecture") used `xprop -spy` / `xev` event-driven monitoring; reported "~50% constant → ~0–1% idle"
  - Current `watch_daemon_with_ipc` (lib/daemon.sh:224) is pure polling at TICK=1.5s — `xprop -spy` no longer present anywhere in the tree
- **Plan (option #2 chosen — restore event-driven architecture)**:
  1. Inspect commit `5bbcc7c` to recover the prior watcher topology (which X11 root properties, IPC contract with the main loop)
  2. Design integration into the current single-loop daemon: `xprop -spy _NET_CLIENT_LIST _NET_ACTIVE_WINDOW _NET_CURRENT_DESKTOP -root` as a child process whose stdout is piped into the main `read` loop alongside the IPC FIFO; events trigger `monitor_tick`
  3. Demote the 1.5s tick to a slow safety-net heartbeat (e.g. 30s) so steady-state CPU drops to ~0
  4. Implement watcher process; ensure it is reaped on SIGTERM/SIGINT and respawned if it dies
  5. Fix `reconcile_ws_mon` count comparison so the fast path also works on event-driven ticks (compare per-monitor post-filter counts, or drop the shortcut entirely now that ticks are rare)
  6. Static-check (`bash -n`, `shellcheck`) and trace-through for: idle, single-window open/close, workspace switch, daemon shutdown
- **Note on commit `12d3316` (`wait_window_settled`)**: the 20ms poll only runs *during* `apply_geometry`, not at idle — not the cause of steady-state CPU
- **Priority**: High
- **Status**: Pending — to be done on a different machine where dom0 can be exercised

### Multimonitor Auto-Layout Fix
- **Task**: Fix multimonitor autolayout functionality
- **Description**: Address issues with auto-layout not working correctly across multiple monitors
- **Priority**: High
- **Status**: Pending

### Drag-and-Drop Swap Detection
- **Task**: Improve drag-and-drop swap detection and zone mapping for all layouts
- **Description**: Complete the implementation of drag-and-drop window swapping with proper zone mapping
- **Current State**: Basic implementation exists in feature/drag-swap-improvements branch with zone mapping for master vertical layout only
- **Issues to address**:
  - Zone mapping only implemented for master vertical (70/30 split)
  - Detection may confuse layout applications with user drags
  - Need zone definitions for all layout types (master horizontal, grid, center-master, etc.)
  - Target window selection needs refinement
- **Branch**: feature/drag-swap-improvements
- **Priority**: Medium
- **Status**: Pending

### Decoration Detection Enhancement
- **Task**: Add calculation of bottom decoration to decoration auto-detection
- **Description**: Extend the `place-window config decoration-detect` functionality to detect bottom window decorations in addition to the current top decoration (title bar) detection
- **Current State**: Only top decoration height is calculated via window geometry differences
- **Goal**: Calculate total decoration height including any bottom borders/decorations that some window managers or themes might have
- **Priority**: Low
- **Status**: Pending

## Completed Tasks

### Dynamic XFCE Panel Detection ✅ (Latest)
- Implemented dynamic XFCE panel detection with caching
- Added proper panel height detection for accurate layout calculations

### Auto-Layout Primary Monitor Fix ✅
- Fixed auto-layout incorrectly moving windows to primary monitor
- Improved multi-monitor window placement accuracy

### Multi-Monitor Support Enhancement ✅
- Fixed multi-monitor support and improved cross-platform compatibility
- Better handling of monitor boundaries and window placement

### Swap Command Functionality ✅
- Fixed swap command functionality with proper spatial window ordering
- Improved window rotation and swapping reliability

### Zero-CPU Idle Mode ✅
- Achieved zero-CPU idle mode using sleep infinity and SIGUSR2
- Optimized daemon performance for background operation

### Single Window Layout on Daemon Start ✅
- Fixed single window not getting layout on daemon start
- Improved initial state handling for daemon

### CPU Optimization ✅
- Implemented safe CPU optimizations while maintaining full functionality
- Added true idle mode when auto-layout is toggled off

### Dialog Filtering ✅
- Added 'Unlock Keyring' dialog to ignored applications
- Improved application filtering for better automation

### Per-Monitor Layout System ✅
- Implemented comprehensive per-monitor layout saving and restoration
- Added monitor-aware daemon with hierarchical preference system
- Made auto and master commands consistent (current monitor by default, --all for all monitors)

### Minimize-Others Command ✅
- Added `place-window minimize-others` command
- Integrated with daemon for automatic layout application after minimization
- Reuses existing atomic functions for consistent behavior

### Auto Command Reset Behavior ✅
- Fixed auto command to properly clear saved master layout preferences
- Added `clear_workspace_monitor_layout()` function
- Ensured `auto --all` applies same reset logic to all monitors individually

### Master Layout Monitor Awareness ✅
- Made master layouts apply to current monitor by default
- Added --all flag for workspace-wide application
- Implemented per-monitor state persistence

### DRY Principle Enforcement ✅
- Consolidated master layout commands
- Created reusable atomic functions
- Eliminated code duplication across layout functions

### Window Decoration Spacing ✅
- Fixed decoration-aware gap calculations in all atomic layout functions
- Added configurable decoration dimensions with auto-detection
- Applied proper spacing for both horizontal and vertical layouts

---

*This file tracks ongoing development tasks for the window-positioning system.*