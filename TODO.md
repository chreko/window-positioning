# Window Positioning TODO List

## Pending Tasks

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