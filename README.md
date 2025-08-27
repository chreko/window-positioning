# Window Positioning Tool for Qubes OS

A powerful window positioning tool designed specifically for Qubes OS dom0 that allows you to select windows with your mouse and position them using presets or custom coordinates, or automatically arrange all visible windows.

## Features

- **Watch Mode**: Automatic tiling daemon that monitors and tiles new windows as they appear
- **Multi-Monitor Support**: Automatically detects and works with multiple monitors
- **Auto-Layout**: Automatically arrange all visible windows based on their count (1-5 windows)
- **Simultaneous Resize**: Resize windows while automatically adjusting adjacent windows (xpytile-inspired)
- **Master-Stack Layouts**: Traditional tiling WM layouts with master window and stacked secondaries
- **Focus Navigation**: Navigate between windows using directional commands
- **Interactive Mode**: Click-to-select windows with a user-friendly menu
- **Configurable Gaps**: Set custom pixel gaps around all windows (default: 10px)
- **Quick Presets**: Position windows in common layouts with automatic gap handling
- **Custom Positions**: Set exact coordinates and dimensions
- **Save/Load Presets**: Create and reuse your own window arrangements
- **Workspace Management**: Move windows between workspaces
- **Real-time Configuration**: Adjust gaps and settings without restarting
- **XFCE Integration**: Designed for Qubes OS dom0's XFCE environment

## Installation

1. Clone or download this repository to your Qubes dom0
2. Run the installation script:
   ```bash
   cd window-positioning
   ./install.sh
   ```

The installer will:
- **Auto-detect the real user** (works correctly even when run with sudo)
- Check for and install required dependencies (`xdotool`, `wmctrl`)
- Install the script to `/usr/local/bin/place-window` 
- Create configuration directory: `~/.config/window-positioning/` (in actual user's home)
- Generate default configuration files with proper ownership
- Create keyboard shortcuts reference and uninstaller

**Important**: The installer correctly handles user vs root permissions - config files are created in the actual user's home directory, not root's.

## Usage

### Interactive Mode
```bash
place-window
```
Click on any window, then choose from the interactive menu with options like:
- Quick corner positioning (upper-left, upper-right, etc.)
- Half-screen layouts (left half, right half, top, bottom)
- Center and maximize options
- Save/load custom positions

### Quick Presets
```bash
place-window ul         # Upper left quarter
place-window ur         # Upper right quarter  
place-window ll         # Lower left quarter
place-window lr         # Lower right quarter
place-window c          # Center window
place-window left       # Left half of screen
place-window right      # Right half of screen
place-window top        # Top half of screen
place-window bottom     # Bottom half of screen
place-window maximize   # Maximize with gaps
```

### Custom Positioning
```bash
place-window 100 50 800 600    # X Y Width Height
```

### Workspace Management
```bash
place-window ws 2              # Move to workspace 2 (0-based)
```

### Save/Load Presets
```bash
place-window save mypreset     # Save current window position
place-window load mypreset     # Load saved position
place-window list              # List all saved presets
```

### Auto-Layout
```bash
place-window auto              # Auto-arrange all visible windows
```
Automatically arranges all non-minimized, non-maximized windows on the current workspace.
Layouts adapt based on window count (1-5 windows supported).

### Auto-Layout Configuration
```bash
place-window auto-config show              # Show current preferences
place-window auto-config 2 equal           # Set 2-window layout to equal split
place-window auto-config 2 primary-secondary  # Set to 70/30 split
place-window auto-config 3 three-columns   # Set 3-window layout to columns
```

**Available Auto-Layouts:**
- **1 window:** maximize
- **2 windows:** equal (50/50), primary-secondary (70/30), secondary-primary (30/70)
- **3 windows:** main-two-side, three-columns, center-sidebars (20/60/20)
- **4 windows:** grid (2x2), main-three-side, three-top-bottom
- **5 windows:** center-corners, two-three-columns, grid-wide-bottom

### Watch Mode (Automatic Tiling)
```bash
place-window watch start        # Start automatic tiling daemon
place-window watch stop         # Stop the daemon  
place-window watch status       # Check daemon status
```
Watch mode runs in the background and automatically applies auto-layout whenever new windows appear or existing windows close. Perfect for maintaining optimal layouts without manual intervention.

**Features:**
- Monitors window creation/destruction events
- Automatically applies configured auto-layout preferences
- Runs as background daemon until stopped
- Works with multi-monitor setups
- Respects all gap and panel settings

**Usage:**
```bash
# Start watch mode and let it run
place-window watch start

# In another terminal, open applications - they'll be auto-tiled
# Stop when done
place-window watch stop
```

### Master-Stack Layouts
```bash
place-window master vertical    # Master left (60%), stack right (40%)
place-window master horizontal  # Master top (60%), stack bottom (40%)
```
Traditional tiling window manager layouts where the first window becomes the "master" and takes up the majority of space, while remaining windows are stacked in the remaining area.

### Simultaneous Resize
```bash
place-window resize expand-right 100   # Expand window right by 100px
place-window resize shrink-down 50     # Shrink window down by 50px
```
Resize windows while automatically adjusting adjacent windows to maintain the tiled layout. Inspired by xpytile's simultaneous resize feature.

### Focus Navigation
```bash
place-window focus right        # Focus window to the right
place-window focus next         # Focus next window in sequence
```
Navigate between windows using directional or sequential focus commands.

### Multi-Monitor Support
```bash
place-window monitors           # Show detected monitors and usable areas
```
**Monitor-Aware Features:**
- **Preset positioning**: `ul`, `ur`, `left`, etc. work within the window's current monitor
- **Auto-layout**: Groups windows by monitor and applies layouts independently
- **Smart panel handling**: Panel height only applied to primary monitor
- **Boundary detection**: Windows stay within monitor boundaries

**Example Multi-Monitor Usage:**
```bash
# Check your monitor setup
place-window monitors

# Windows on each monitor get arranged independently
place-window auto

# Position window within its current monitor
place-window ul     # Upper-left of current monitor, not screen
```

### Gap Configuration
```bash
place-window config gap 15     # Set 15px gaps around windows
place-window config gap        # Show current gap size
place-window config panel 40   # Set panel height to 40px
place-window config show       # Show all settings
```

## Keyboard Shortcuts

Set up keyboard shortcuts in XFCE (Settings → Keyboard → Application Shortcuts):

| Command | Suggested Key | Description |
|---------|---------------|-------------|
| `place-window` | `Super+Shift+P` | Interactive mode |
| `place-window auto` | `Super+Shift+A` | Auto-layout all windows |
| `place-window watch start` | `Super+Shift+W` | Start watch mode daemon |
| `place-window master vertical` | `Super+Shift+M` | Master-stack vertical |
| `place-window focus right` | `Super+Shift+Right` | Focus right window |
| `place-window focus left` | `Super+Shift+Left` | Focus left window |
| `place-window focus up` | `Super+Shift+Up` | Focus up window |
| `place-window focus down` | `Super+Shift+Down` | Focus down window |
| `place-window resize expand-right` | `Super+Shift+Ctrl+Right` | Expand right |
| `place-window resize shrink-right` | `Super+Shift+Alt+Right` | Shrink right |

See `~/.config/window-positioning/keyboard-shortcuts.txt` for complete list.

## Configuration

### Gap Settings
Edit `~/.config/window-positioning/settings.conf`:

```bash
# Gap around windows (in pixels)
GAP=10

# Panel height (adjust for your XFCE theme)
PANEL_HEIGHT=32

# Minimum window size
MIN_WIDTH=400
MIN_HEIGHT=300

# Auto-layout preferences
AUTO_LAYOUT_1="maximize"
AUTO_LAYOUT_2="equal"
AUTO_LAYOUT_3="main-two-side"
AUTO_LAYOUT_4="grid"
AUTO_LAYOUT_5="grid-wide-bottom"
```

### Window Presets
Edit `~/.config/window-positioning/presets.conf`:

```
# Format: NAME=X,Y,WIDTH,HEIGHT
browser-left=10,40,960,1040
browser-right=970,40,960,1040
terminal-dev=1220,570,700,510
```

**Gap Behavior:**
- All preset layouts automatically apply the configured gap
- Gaps are maintained around window edges and between windows
- Custom coordinate positioning ignores gaps for precise control
- Auto-layout respects gap settings for all window arrangements
- Interactive mode shows current gap settings and allows real-time changes

## Examples

### Common Workflows

**Quick auto-arrangement:**
```bash
# Have multiple windows open, then:
place-window auto    # Automatically arranges all visible windows
```

**Master-stack workflow:**
```bash
# Open primary application and supporting tools:
place-window master vertical    # Main app left, others stacked right
# Or horizontal master:
place-window master horizontal  # Main app top, others on bottom
```

**Interactive tiling with resize:**
```bash
# Position windows, then fine-tune:
place-window auto               # Initial arrangement
place-window resize expand-right 100  # Adjust primary window
place-window focus right        # Navigate to next window
```

**Development layout:**
```bash
# Three-window development setup:
place-window auto               # Auto-arrange editor, browser, terminal
# Or specific layout:
place-window master vertical    # Editor master, browser+terminal stacked
```

**Customize auto-layout for your workflow:**
```bash
# Prefer 70/30 split for 2 windows:
place-window auto-config 2 primary-secondary
# Prefer 3 columns for 3 windows:
place-window auto-config 3 three-columns
# Now auto-layout uses your preferences:
place-window auto
```

**Save your current layout:**
```bash
# Position your windows as desired, then:
place-window save work-layout   # For each window
```

## Requirements

- Qubes OS 4.1+ with XFCE (dom0)
- `xdotool` and `wmctrl` (auto-installed)

## Uninstalling

Run the uninstaller:
```bash
~/.config/window-positioning/uninstall.sh
```

## Troubleshooting

**Windows not positioning correctly?**
- Adjust `panel_height` and `gap` values in the script for your theme
- Check screen resolution with `xdotool getdisplaygeometry`

**Mouse selection not working?**
- Ensure `xdotool` is installed: `sudo qubes-dom0-update xdotool`
- Try clicking on the window's title bar

**Presets not saving?**
- Check permissions on `~/.config/window-positioning/`
- Verify the presets.conf file format

## Why This Tool?

Qubes OS's approach to window management (seamlessly integrated AppVM windows) makes traditional window positioning methods ineffective. This tool bridges that gap by:

1. Working directly with dom0's window manager
2. Using mouse selection to identify any window regardless of source VM
3. Providing both quick presets and precise control
4. Integrating with XFCE's keyboard shortcut system
5. Saving/loading arrangements that persist across sessions

Perfect for users who want consistent, efficient window layouts in their Qubes workflow.