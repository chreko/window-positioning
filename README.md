# Window Positioning Tool for Qubes OS

A powerful window positioning tool designed specifically for Qubes OS dom0 that allows you to select windows with your mouse and position them using presets or custom coordinates.

## Features

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
- Check for and install required dependencies (`xdotool`, `wmctrl`)
- Install the script to `/usr/local/bin/place-window`
- Create configuration directory with default presets
- Generate keyboard shortcuts reference

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
| `place-window ul` | `Super+Shift+1` | Upper left |
| `place-window ur` | `Super+Shift+2` | Upper right |
| `place-window left` | `Super+Shift+Left` | Left half |
| `place-window right` | `Super+Shift+Right` | Right half |

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
- Interactive mode shows current gap settings and allows real-time changes

## Examples

### Common Workflows

**Side-by-side browsing:**
```bash
# Open two browser windows, then:
place-window left    # First window
place-window right   # Second window
```

**Development layout:**
```bash
place-window load ide-main      # Main editor
place-window load browser-dev   # Browser for testing
place-window load terminal-dev  # Terminal
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