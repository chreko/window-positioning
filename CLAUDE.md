# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the window-positioning project.

## Overview

This is a comprehensive window positioning and management tool designed specifically for Qubes OS dom0. It provides advanced tiling window management functionality including automatic layouts, watch mode daemon, multi-monitor support, master-stack layouts, focus navigation, and simultaneous resize capabilities.

## Project Structure

### Core Components
- **place-window**: Main executable command dispatcher
- **lib/**: Modular library architecture with focused components
  - **lib/config.sh**: Configuration management and workspace state
  - **lib/monitors.sh**: Multi-monitor detection and layout areas
  - **lib/windows.sh**: Core window operations, geometry, focus, swap/cycle, minimize-others, simultaneous resize, window-list discovery and ordering
  - **lib/layouts.sh**: Meta-layout system, master-stack layouts, per-monitor auto-layout, saved-layout reapply
  - **lib/daemon.sh**: Watch-mode daemon — event loop, IPC server, debounce, command routing
  - **lib/interactive.sh**: Interactive menu system and quick presets
- **install.sh**: Installation script — installs deps, sets up config, installs the systemd user unit
- **README.md**: User documentation
- **TODO.md**: Active pending work and investigation notes (consult before starting new work)

### Key Features
- **Interactive Mode**: Click-to-select windows with user-friendly menu
- **Watch Mode**: Background daemon for automatic window tiling as windows appear/close
- **Multi-Monitor Support**: Per-monitor layout management with boundary detection
- **Auto-Layout System**: Intelligent window arrangements based on window count (1-5 windows)
- **Master-Stack Layouts**: Traditional tiling WM layouts with configurable ratios
- **Fibonacci Layouts**: `fibonacci` (spiral, winds inward) and `dwindle` (into the bottom-right corner), ratio applied at every split (default 62, the golden ratio)
- **Focus Navigation**: Directional window navigation (up/down/left/right/next)
- **Simultaneous Resize**: xpytile-inspired resize with automatic adjacent window adjustment
- **Gap Management**: Configurable pixel gaps around windows with real-time adjustment
- **Preset System**: Save/load custom window arrangements
- **Workspace Management**: Workspace-aware operations and window movement

## Architecture

### Modular Architecture
The project follows a modular design with separated concerns. Note: there is no `lib/advanced.sh` — everything that once lived there (focus, swap, cycle, minimize-others, simultaneous resize) now lives in `lib/windows.sh`/`lib/layouts.sh`. `install.sh` deletes a stale copy from the install dir.

#### Main Script (`place-window`)
- **Command Dispatcher**: Sources all `lib/*.sh` modules, routes args to handlers
- **Daemon Routing**: Many subcommands (`auto`, `reapply`, `master`, `focus`, `cycle`) call `send_daemon_command` instead of running locally — see "Daemon IPC model" below

#### Configuration Module (`lib/config.sh`)
- **Config Files**: `~/.config/window-positioning/{settings.conf,presets.conf,workspace-state.conf,workspace-<N>-monitor.conf}`
- **Settings Management**: Gap, panel height/auto-hide, decoration dimensions, ignored apps, watch auto-layout, window-order strategy
- **Workspace State**: Per-(workspace, monitor) saved layout strings (e.g. `master vertical 75`)

#### Monitor Detection Module (`lib/monitors.sh`)
- **Xrandr Detection**: Monitor list, primary detection, boundary calculation
- **Layout Areas**: Per-monitor usable rect with gap and (primary-only) panel reserved
- **Window→Monitor Mapping**: Overlap-area assignment for straddling windows

#### Window Management Module (`lib/windows.sh`)
This is the largest module and owns most window-side logic:
- **Core Operations**: `pick_window`, geometry get/set via `_apply_frame_exact` (subtracts each window's own `_NET_FRAME_EXTENTS`, forces NorthWest gravity). Two public wrappers with **different** coordinate semantics: `apply_geometry` (layout space — frame lands at `y + DECORATION_HEIGHT`) and `apply_geom_adaptive` (absolute xwininfo space — for round-trips like presets and simultaneous-resize). `wait_window_settled` serializes applies.
- **Window Discovery**: `get_visible_windows`, `get_visible_windows_by_position`, `get_visible_windows_by_stacking`, `get_windows_ordered`
- **Focus & Reorder**: `focus_window` (directional), `swap_window_positions`, `swap_window_geometries`, `cycle_window_positions`, `reverse_cycle_window_positions`
- **Window Operations**: `minimize_others`, `find_adjacent_windows`
- **Position Persistence**: `save_position`/`load_position` (presets)
- **Simultaneous Resize**: `simultaneous_resize` — detects adjacent windows and resizes them in lockstep, xpytile-style

#### Layout System Module (`lib/layouts.sh`)
- **Meta layouts**: `apply_meta_{maximize,columns,main_sidebar,grid,topbar_main,center_corners,center_sidebar}_single_monitor`
- **Fibonacci layouts**: `apply_meta_fibonacci_single_monitor` — dwm's fibonacci patch. Takes a `spiral`/`dwindle` variant and a split ratio applied at *every* split. The variant name arrives untranslated from the CLI, so anything that is not `dwindle` spirals (`fibonacci` is the user-facing name for `spiral`). Ratio defaults to `FIBONACCI_RATIO` (62, golden); stops splitting and shares the leftover box once a tile would fall under `FIBONACCI_MIN_TILE`
- **Auto-layout engine**: `auto_layout_single_monitor` — picks layout from `AUTO_LAYOUT_<N>` preferences
- **Saved-layout reapply**: `reapply_saved_layout_for_monitor` reads `MONITOR_<name>_LAYOUT_=` and re-applies; falls back to auto-layout if value is unrecognized
- **Per-(workspace, monitor) state**: `clear_workspace_monitor_layout`, `get_workspace_monitor_layout`

#### Daemon Module (`lib/daemon.sh`)
The daemon is much larger than the rest of the codebase combined and is the primary owner of shared state:
- **Event watcher**: `xprop -spy` on `_NET_CLIENT_LIST`, `_NET_CURRENT_DESKTOP`, `_NET_ACTIVE_WINDOW` (the last is the proxy for minimize/restore, event-driven, not polling)
- **Event-tick rate limit**: `_NET_ACTIVE_WINDOW` fires on every focus click, so reconciles from it are capped at 1/sec. Window open/close and workspace switches are exempt.
- **Suspend/resume detection**: A wall-clock gap between loop iterations is treated as suspend/resume — the event watcher is restarted and stale holds are cleared, otherwise the daemon would keep listening to a dead `xprop` after resume.
- **Single-loop multiplexer**: One `read` loop on the IPC FIFO; X11 events and IPC client commands are tagged and demultiplexed
- **IPC server**: Named pipes `DAEMON_CMD_PIPE` / `DAEMON_RESP_PIPE`; responses framed with explicit end sentinel so clients know where to stop reading
- **Debounce**: Per-`(workspace, monitor)` debounce window — applying on monitor A no longer blocks monitor B
- **SIGUSR1**: Triggers `apply_workspace_layout` for manual reapply

#### Interactive Module (`lib/interactive.sh`)
- Click-to-select menu, quick presets (`ul`, `ur`, `c`, …), interactive gap/panel adjustment, manual coordinate entry

### Multi-Monitor Architecture
- **Per-Monitor Layouts**: Each monitor maintains independent window arrangements
- **Boundary Awareness**: Windows constrained to their monitor's usable area
- **Smart Panel Handling**: Panel height only applied to primary monitor
- **Coordinated Auto-Layout**: Global auto-layout respects per-monitor groupings

### Watch Mode Daemon
- **Event-driven**: `xprop -spy` on X11 properties, not polling (see Daemon Module above for the specific properties watched)
- **Workspace-aware**: Only processes windows on the current workspace
- **Layout persistence**: Reapplies saved per-(workspace, monitor) layout preferences after window list changes
- **Auto-start**: systemd user unit (`window-positioning.service`), installed by `install.sh`, which also deletes any legacy `~/.config/autostart/window-positioning.desktop` so the two cannot race. An earlier systemd attempt was reverted to XDG autostart in Aug 2025 because the systemd user manager does not inherit the session's X cookie and the daemon could not reach X. That root cause is now fixed in the daemon itself (`ensure_x_authority` probes candidate cookie paths and exits 1 if none work, so `Restart=on-failure` retries until the X session is up) — do not "simplify" it back to XDG without re-reading that function. The unit also uses `StandardOutput=append:` so `daemon.log` survives restarts instead of being truncated.

### Daemon IPC model
The daemon is the single owner of state that requires a stable view of windows over time (window lists, ordering, saved per-(workspace, monitor) layouts, master ratios). User commands that need this state route through it instead of running in the calling shell:

- `place-window auto` / `auto --all`
- `place-window reapply`
- `place-window master {vertical,vertical-right,horizontal,center,increase,decrease} [pct]`
- `place-window focus {next,prev,up,down,left,right}`
- `place-window cycle [clockwise|counter-clockwise]`

These dispatch to `send_daemon_command` (see `place-window`), which writes to `DAEMON_CMD_PIPE` and reads the reply (terminated by an explicit end sentinel) from `DAEMON_RESP_PIPE`. **If the daemon is not running, these commands fail.** Standalone commands (`ul`/`ur`/`save`/`load`/`ws`/`minimize-others`/`swap`/`resize`/`config`) run directly in the calling shell and do not need the daemon.

`WATCH_AUTO_LAYOUT` controls only the *automatic* layout response to X11 events; the daemon's IPC server is always active while the daemon runs. Use `place-window watch on/off/toggle` to flip auto-layout without stopping the daemon.

## Configuration

### Settings File (`~/.config/window-positioning/settings.conf`)
Key configuration options:
```bash
GAP=10                    # Pixel gap around windows
PANEL_HEIGHT=30           # Panel height (primary monitor only)
PANEL_AUTOHIDE=false      # Whether panel auto-hides
DECORATION_HEIGHT=24      # Window title bar height
DECORATION_WIDTH=0        # Window border width
MIN_WIDTH=400             # Minimum window dimensions
MIN_HEIGHT=300

# Daemon behavior
WATCH_AUTO_LAYOUT=true    # Authoritative on every daemon start; flipped at runtime by `watch on/off/toggle`
WINDOW_ORDER_STRATEGY=position   # `position` (spatial) or `stacking` — used by swap/cycle/focus

# Apps the daemon ignores when auto-tiling. Comma-separated; supports glob patterns.
# Match is against window titles ("cs:" prefix matches WM_CLASS). Includes XFCE
# settings dialogs and the panel itself so they never get tiled.
IGNORED_APPS="About,ulauncher*,cs:Warning*,cs:Settings,*Preferences,cs:xfce4-panel,xfce4-*-settings,..."

# Auto-layout preferences per window count
AUTO_LAYOUT_1="maximize"
AUTO_LAYOUT_2="equal"
AUTO_LAYOUT_3="main-two-side"
AUTO_LAYOUT_4="grid"
AUTO_LAYOUT_5="grid-wide-bottom"
```

### Available Layout Options
- **1 window**: maximize
- **2 windows**: equal, primary-secondary, secondary-primary  
- **3 windows**: main-two-side, three-columns, center-sidebars
- **4 windows**: grid, main-three-side, three-top-bottom
- **5 windows**: center-corners, two-three-columns, grid-wide-bottom

### Presets File (`~/.config/window-positioning/presets.conf`)
Custom window positions in format: `NAME=X,Y,WIDTH,HEIGHT`

## Commands

### Installation
```bash
./install.sh    # Auto-detects user, installs dependencies, sets up config
```

### Basic Usage
```bash
place-window                    # Interactive mode (click to select)
place-window ul                 # Quick upper-left positioning
place-window 100 50 800 600     # Custom coordinates
place-window auto               # Auto-arrange all windows
```

### Advanced Layout Management
All of these route through the daemon (see "Daemon IPC model"):
```bash
place-window auto                                # Auto-arrange current monitor
place-window auto --all                          # Auto-arrange all monitors
place-window reapply                             # Reapply saved layout (preserves choice)
place-window master vertical [pct]               # Master on left, stack on right (10–90, default 60)
place-window master vertical-right [pct]         # Master on right, stack on left
place-window master horizontal [pct]             # Master on top, stack on bottom
place-window master center [pct]                 # Center-focused (20–80, default 50)
place-window master fibonacci [ratio]            # Spiral tiling, winds inward (default 62, golden)
place-window master dwindle [ratio]              # Spiral tiling, into the bottom-right corner
place-window master vertical --all [pct]         # Apply to all monitors
place-window master increase                     # +5% to current master ratio
place-window master decrease                     # -5% to current master ratio
```

### Watch Mode (systemd user service)
The daemon is auto-started by the `window-positioning.service` systemd user unit (installed by `install.sh`). Every subcommand below prefers systemd and falls back to a `nohup` launch when the user manager is unavailable (`_watch_systemd_available` gates this), so the same commands work either way. Control it through `place-window`:
```bash
place-window watch start        # Start the daemon
place-window watch stop         # Stop the daemon
place-window watch restart      # Restart the daemon
place-window watch status       # Show PID + auto-layout state + unit enabled/active state
place-window watch logs         # Tail ~/.config/window-positioning/daemon.log

# Toggle automatic layout response without stopping the daemon (IPC stays up):
place-window watch on           # Enable WATCH_AUTO_LAYOUT
place-window watch off          # Disable WATCH_AUTO_LAYOUT
place-window watch toggle       # Flip it

# Auto-start on login:
place-window watch enable       # systemctl --user enable window-positioning.service
place-window watch disable      # Disable the unit, and remove a legacy XDG entry if present
```
`systemctl --user start/stop/status window-positioning` also works directly. A legacy
`~/.config/autostart/window-positioning.desktop` from a pre-systemd install is removed by
`install.sh` and by `watch disable`, so the two launchers cannot race.

### Focus and Navigation
```bash
place-window focus {next|prev|up|down|left|right}   # Routed through daemon
place-window swap                                   # Pick two windows, swap them
place-window cycle                                  # Cycle clockwise (daemon)
place-window cycle counter-clockwise                # Cycle counter-clockwise (daemon)
```

### Window Operations
```bash
place-window minimize-others             # Minimize all except active
place-window resize expand-right 100     # Simultaneous resize (also: shrink-right, expand-down, shrink-down)
place-window ws 2                        # Move to workspace 2
place-window monitors                    # Show detected monitors and usable areas
place-window debug-lists                 # Dump cached daemon window lists
```

### Configuration
```bash
place-window config gap 15     # Set 15px gaps
place-window config panel 40   # Set panel height
place-window config show       # Display all settings
```

## Testing

### Manual Testing
```bash
# Test basic functionality
place-window                   # Should open interactive menu
place-window auto             # Should arrange all visible windows
place-window ul               # Should position selected window

# Test multi-monitor
place-window monitors         # Should show detected monitors
```

### Watch Mode Testing
```bash
# Start daemon and test automatic tiling
place-window watch start
# Open several applications - should auto-tile
place-window watch stop
```

### Configuration Testing
```bash
# Test gap changes
place-window config gap 20
place-window auto             # Should show larger gaps
place-window config gap 5     # Reset to smaller gaps
```

## Pending Work

See `TODO.md` for active investigations and pending tasks. Notable open items:
- `master vertical 75` occasionally resets to default ~60% — needs dom0 diagnostics (see TODO.md for the suspect-paths analysis and the diagnostic commands to run)
- Drag-and-drop swap zone mapping for non-vertical layouts (`feature/drag-swap-improvements` branch)
- Bottom-decoration detection in `config decoration-detect`

For project history, use `git log` — do not maintain a parallel log here.

## Dependencies

### Required Packages
- `xdotool`: Window manipulation and mouse interaction
- `wmctrl`: Window management and workspace operations

### Installation Dependencies
Auto-installed via `qubes-dom0-update` during installation.

## QubesOS Integration

### Dom0 Specific Features
- **Xen Integration**: Works with Qubes OS's Xen-based window management
- **XFCE Compatibility**: Designed for dom0's XFCE environment  
- **Security Conscious**: No external network dependencies
- **Permission Handling**: Proper user/root permission management in installer

### Keyboard Shortcut Integration
The tool integrates with XFCE's keyboard shortcut system. Suggested shortcuts are provided in `keyboard-shortcuts.txt`.

## Important Notes

### Usage Considerations
- **Dom0 Only**: This tool is specifically designed for Qubes OS dom0
- **Window Selection**: Uses mouse selection to work with any AppVM window
- **Configuration Persistence**: Settings survive reboots and sessions
- **Multi-Monitor Aware**: Handles complex multi-monitor setups intelligently

### Development Guidelines
- **Daemon owns shared state**: Anything that needs a stable view of window lists, ordering, master ratios, or saved per-(workspace, monitor) layouts must go through the daemon. Don't reintroduce the same caches in the calling shell.
- **Saved layout strings are the source of truth**: `MONITOR_<name>_LAYOUT_=` in `workspace-<N>-monitor.conf`. When adding a new master orientation, update both the writer (`master` command path) and `reapply_saved_layout_for_monitor` so reapply doesn't silently fall through.
- **Geometry application — pick the right wrapper**: `apply_geometry(id, x, y, w, h)` for **layout math** (frame lands at `y + DECORATION_HEIGHT` regardless of that window's own extents — this is what preserves the hand-tuned math in `lib/layouts.sh`). `apply_geom_adaptive(id, fx, fy, w, h)` for **round-trips** where `fx/fy` were read back from X (presets, `simultaneous_resize`). Both apply via `_apply_frame_exact`, wait for settle, and retry once on drift. Never call `wmctrl -e` directly and never assume the move took effect.
- **`AUTO_LAYOUT_3=main-two-side` looks identical to `master vertical 60`**: when a saved master layout silently disappears, the visual fallback is indistinguishable from the active layout. Reproduce by checking `place-window watch logs` for `Reapplying saved layout …` vs `No saved preference …`.
- **xfwm4 wmctrl quirk**: `wmctrl -e` with NorthWest gravity lands the window at xwininfo `(X+L, Y+T)`, not `(X, Y)`, using each window's OWN frame extents. All applies subtract per-window extents via `_apply_frame_exact` AND pass gravity `1` (NorthWest) explicitly — gravity `0` defers to `WM_NORMAL_HINTS`, and Static-gravity toolkits (kitty, Qt/Qube Manager) then land a title-bar height higher than GTK windows. See `docs/DEVELOPMENT.md` for the deeper writeup.

### Security Notes
- **Local Only**: No network operations or external dependencies
- **File Permissions**: Proper ownership handling in installer
- **Config Safety**: Safe defaults with user override capability