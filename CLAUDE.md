# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the window-positioning project.

## Overview

This is a comprehensive window positioning and management tool designed specifically for Qubes OS dom0. It provides advanced tiling window management functionality including automatic layouts, watch mode daemon, multi-monitor support, master-stack layouts, focus navigation, and simultaneous resize capabilities.

## Project Structure

### Core Components
- **place-window**: Main executable script (382 lines) - modular command dispatcher
- **lib/**: Modular library architecture with focused components
  - **lib/config.sh**: Configuration management and workspace state
  - **lib/monitors.sh**: Multi-monitor detection and layout areas
  - **lib/windows.sh**: Core window operations and geometry management
  - **lib/layouts.sh**: Meta-layout system with atomic layout functions
  - **lib/daemon.sh**: Watch mode daemon functionality
  - **lib/interactive.sh**: Interactive menu system and presets
  - **lib/advanced.sh**: Master layouts, focus navigation, and window operations
- **install.sh**: Installation script with dependency management and configuration setup
- **README.md**: Complete user documentation and usage guide

### Key Features
- **Interactive Mode**: Click-to-select windows with user-friendly menu
- **Watch Mode**: Background daemon for automatic window tiling as windows appear/close
- **Multi-Monitor Support**: Per-monitor layout management with boundary detection
- **Auto-Layout System**: Intelligent window arrangements based on window count (1-5 windows)
- **Master-Stack Layouts**: Traditional tiling WM layouts with configurable ratios
- **Focus Navigation**: Directional window navigation (up/down/left/right/next)
- **Simultaneous Resize**: xpytile-inspired resize with automatic adjacent window adjustment
- **Gap Management**: Configurable pixel gaps around windows with real-time adjustment
- **Preset System**: Save/load custom window arrangements
- **Workspace Management**: Workspace-aware operations and window movement

## Architecture

### Modular Architecture
The project follows a clean modular design with separated concerns:

#### Main Script (place-window, 382 lines)
- **Command Dispatcher**: Routes commands to appropriate library modules
- **Module Imports**: Sources all library modules at startup
- **Help System**: Comprehensive usage documentation and examples
- **Error Handling**: Validates arguments and provides helpful error messages

#### Configuration Module (lib/config.sh, 276 lines)
- **Config Files**: `~/.config/window-positioning/{settings.conf,presets.conf,workspace-*.conf}`
- **Settings Management**: Gap size, panel height, auto-hide, decoration dimensions
- **Workspace State**: Per-workspace and per-monitor layout preferences
- **Auto-initialization**: Creates default configs if missing
- **Settings Update**: Dynamic configuration changes with persistence

#### Monitor Detection Module (lib/monitors.sh, 158 lines)
- **Multi-Monitor Support**: Xrandr-based monitor detection and boundary calculation
- **Layout Areas**: Per-monitor usable area calculation with gap/panel handling
- **Primary Monitor**: Detection and panel space management
- **Window-Monitor Mapping**: Determines which monitor contains each window

#### Window Management Module (lib/windows.sh, 154 lines)
- **Core Operations**: Window selection, geometry manipulation, workspace movement
- **Position Management**: Save/load window positions to presets
- **Window Discovery**: Spatial window ordering and visibility detection
- **Geometry Utils**: Window sizing with minimum constraints

#### Layout System Module (lib/layouts.sh, 448 lines)
Meta-layout system with atomic layout functions:
- `apply_meta_maximize_single_monitor()`: Single window maximization
- `apply_meta_columns_single_monitor()`: Multi-column layouts
- `apply_meta_main_sidebar_single_monitor()`: Master window with sidebar
- `apply_meta_grid_single_monitor()`: Grid-based arrangements
- `apply_meta_topbar_main_single_monitor()`: Top bar with main content
- `apply_meta_center_corners_single_monitor()`: Center focus with corner windows
- `apply_meta_center_sidebar_single_monitor()`: Three-column center-focused layout
- **Auto-Layout Engine**: Per-monitor layout coordination with preference system

#### Daemon Module (lib/daemon.sh, 200 lines)
- **Watch Mode**: Background daemon for automatic window tiling
- **Event Monitoring**: X11 property change detection for efficiency
- **Process Management**: Daemon lifecycle control and status monitoring
- **Layout Application**: Automatic layout triggering on window events

#### Interactive Module (lib/interactive.sh, 164 lines)
- **Menu System**: User-friendly interactive mode with click-to-select
- **Preset Application**: Quick positioning presets (ul, ur, left, right, etc.)
- **Configuration UI**: Interactive gap and panel height adjustment
- **Custom Positioning**: Manual coordinate entry and workspace movement

#### Advanced Features Module (lib/advanced.sh, 508 lines)
- **Simultaneous Resize**: Adjacent window detection and coordinated resizing
- **Master-Stack Layouts**: Traditional tiling WM master/secondary arrangements
- **Focus Navigation**: Directional window focus with spatial awareness
- **Window Operations**: Minimize others, swap/rotate windows, position cycling
- **Center Master**: Three-column layouts with configurable center width

### Multi-Monitor Architecture
- **Per-Monitor Layouts**: Each monitor maintains independent window arrangements
- **Boundary Awareness**: Windows constrained to their monitor's usable area
- **Smart Panel Handling**: Panel height only applied to primary monitor
- **Coordinated Auto-Layout**: Global auto-layout respects per-monitor groupings

### Watch Mode Daemon
- **Event Monitoring**: Efficient X11 property monitoring (not polling) via `xprop -spy`
- **Resource Efficient**: Uses 3-4 background processes vs potentially 100s with per-window monitoring
- **Workspace Awareness**: Only processes windows on current workspace
- **Layout Persistence**: Applies saved per-workspace and per-monitor layout preferences
- **Background Operation**: Runs as daemon until explicitly stopped

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
```bash
place-window auto-config show                    # Show current preferences  
place-window auto-config 2 primary-secondary     # Set 2-window preference
place-window master vertical                     # Master-stack layout
place-window center-master                       # Center-focused layout
```

### Watch Mode (Systemd User Service)
```bash
# Service control via place-window wrapper
place-window watch start        # Start the daemon
place-window watch stop         # Stop the daemon
place-window watch status       # Check daemon status
place-window watch enable       # Auto-start on login
place-window watch disable      # Disable auto-start
place-window watch restart      # Restart the daemon
place-window watch logs         # View daemon logs

# Direct systemd control
systemctl --user start/stop/status window-positioning
systemctl --user enable window-positioning  # Auto-start on login
```

### Focus and Navigation
```bash
place-window focus right        # Focus window to the right
place-window focus next         # Focus next window in sequence
place-window swap clockwise     # Rotate window positions
```

### Window Operations
```bash
place-window minimize-others    # Minimize all except current
place-window resize expand-right 100    # Simultaneous resize
place-window ws 2              # Move to workspace 2
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

## Development History

Based on git history, the project has evolved significantly:

### Major Milestones
- **Initial Implementation**: Basic window positioning with presets
- **Gap Architecture**: Comprehensive gap management system
- **Meta-Layout System**: Flexible layouts for any window count  
- **Watch Mode**: Background daemon for automatic tiling
- **Multi-Monitor Support**: Per-monitor layout management
- **Master-Stack Layouts**: Traditional tiling WM functionality
- **Focus Navigation**: Directional window navigation
- **Simultaneous Resize**: xpytile-inspired coordinated resizing
- **Modular Refactoring**: Split 3,100-line monolith into focused modules

### Recent Improvements (Latest Commits)
- **efeec97**: Refactor monolithic script into modular architecture (87% size reduction)
- **bdc045e**: Fix swap functionality by implementing spatial window ordering
- **eb4947a**: Add minimize-others command and fix auto command layout reset behavior
- **ae8b377**: Implement comprehensive per-monitor layout system and auto command consistency
- **ed0319a**: Make master layouts monitor-aware with current monitor default
- **e5f00cc**: Apply DRY principle and consolidate master layout commands

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
- **DRY Principle**: Code follows Don't Repeat Yourself principles
- **Modular Architecture**: Clean separation of concerns across focused modules
- **Library Design**: Reusable functions with clear interfaces between modules
- **Configuration Driven**: Behavior customizable via config files
- **Error Handling**: Graceful degradation when tools unavailable
- **Maintainability**: 87% reduction in main script size for easier maintenance

### Security Notes
- **Local Only**: No network operations or external dependencies
- **File Permissions**: Proper ownership handling in installer
- **Config Safety**: Safe defaults with user override capability