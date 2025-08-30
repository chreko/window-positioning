#!/usr/bin/env bash
# Installation script for window positioning tool in Qubes OS dom0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_LIB_DIR="/usr/local/lib/place-window"

# Get the real user (not root when using sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CONFIG_DIR="${REAL_HOME}/.config/window-positioning"

echo "Window Positioning Tool Installer for Qubes OS dom0"
echo "=================================================="
echo "Installing for user: $REAL_USER (home: $REAL_HOME)"
echo "Config will be created at: $CONFIG_DIR"
echo "Libraries will be installed to: $INSTALL_LIB_DIR"
echo ""

# Check if running in dom0
if [[ ! -f /proc/xen/capabilities ]] || ! grep -q "control_d" /proc/xen/capabilities 2>/dev/null; then
    echo "Warning: This doesn't appear to be dom0. This tool is designed for dom0 only."
    read -p "Continue anyway? [y/N]: " confirm
    [[ "$confirm" != [yY] ]] && exit 1
fi

# Check for required tools
echo "Checking for required tools..."
missing_tools=()

for tool in xdotool wmctrl; do
    if ! command -v "$tool" &> /dev/null; then
        missing_tools+=("$tool")
    fi
done

if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "Missing required tools: ${missing_tools[*]}"
    echo "Installing via qubes-dom0-update..."
    
    read -p "Install missing tools? [Y/n]: " confirm
    if [[ "$confirm" != [nN] ]]; then
        sudo qubes-dom0-update "${missing_tools[@]}"
    else
        echo "Cannot proceed without required tools."
        exit 1
    fi
fi

# Create library directory
echo "Creating library directory..."
sudo mkdir -p "$INSTALL_LIB_DIR"

# Install library modules
echo "Installing library modules..."
for lib_file in "$SCRIPT_DIR"/lib/*.sh; do
    if [[ -f "$lib_file" ]]; then
        lib_name=$(basename "$lib_file")
        sudo cp "$lib_file" "$INSTALL_LIB_DIR/"
        sudo chmod 644 "$INSTALL_LIB_DIR/$lib_name"
        echo "  ✓ Installed $lib_name"
    fi
done

# Create a wrapper script that knows where the libraries are
echo "Creating main executable..."
cat << 'EOF' > /tmp/place-window-wrapper
#!/usr/bin/env bash
# place-window: Position windows in dom0 with mouse selection or window ID
# This is a wrapper that sets up the library path

set -euo pipefail

# Set the library directory location
INSTALL_LIB_DIR="/usr/local/lib/place-window"

# Source all library modules
source "$INSTALL_LIB_DIR/config.sh"
source "$INSTALL_LIB_DIR/monitors.sh" 
source "$INSTALL_LIB_DIR/windows.sh"
source "$INSTALL_LIB_DIR/layouts.sh"
source "$INSTALL_LIB_DIR/daemon.sh"
source "$INSTALL_LIB_DIR/interactive.sh"
source "$INSTALL_LIB_DIR/advanced.sh"

# Initialize configuration
init_config
load_config

# Check if running in daemon mode (prevent interactive prompts)
DAEMON_MODE=${DAEMON_MODE:-false}

EOF

# Append the main logic from place-window (skip the library sourcing part)
sed -n '/^# Main command processing/,$p' "$SCRIPT_DIR/place-window" >> /tmp/place-window-wrapper

# Install the wrapper script
sudo mv /tmp/place-window-wrapper "$INSTALL_BIN_DIR/place-window"
sudo chmod +x "$INSTALL_BIN_DIR/place-window"
echo "✓ Installed main script to $INSTALL_BIN_DIR/place-window"

# Create config directory and default configuration
echo "Setting up configuration for user: $REAL_USER"
echo "Config directory: $CONFIG_DIR"

# Create config directory with proper ownership
mkdir -p "$CONFIG_DIR"
chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR" 2>/dev/null || true

# Create settings configuration
if [[ ! -f "$CONFIG_DIR/settings.conf" ]]; then
    cat > "$CONFIG_DIR/settings.conf" << 'EOF'
# Window positioning settings
# Gap around windows (in pixels)
GAP=10

# Panel height (adjust for your XFCE theme)
# Set to 0 if panel auto-hides or doesn't reserve space
PANEL_HEIGHT=32

# Panel auto-hide mode
# Set to true if panel is set to auto-hide (intelligently or always)
# When true, panel height is ignored for layout calculations
PANEL_AUTOHIDE=false

# Window decoration dimensions (in pixels)
# Height: title bar height - set to 0 if windows don't have title bars
DECORATION_HEIGHT=30

# Width: side border width (left + right combined) - usually 0 for modern themes  
DECORATION_WIDTH=2

# Minimum window size
MIN_WIDTH=400
MIN_HEIGHT=300

# Auto-layout preferences
# Available layouts for each window count:
# 1 window: maximize
# 2 windows: equal, primary-secondary, secondary-primary
# 3 windows: main-two-side, three-columns, center-sidebars
# 4 windows: grid, main-three-side, three-top-bottom
# 5 windows: center-corners, two-three-columns, grid-wide-bottom

AUTO_LAYOUT_1="maximize"
AUTO_LAYOUT_2="equal"
AUTO_LAYOUT_3="main-two-side"
AUTO_LAYOUT_4="grid"
AUTO_LAYOUT_5="grid-wide-bottom"
EOF
    chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/settings.conf" 2>/dev/null || true
    echo "✓ Created settings configuration"
else
    echo "✓ Existing settings configuration preserved"
fi

if [[ ! -f "$CONFIG_DIR/presets.conf" ]]; then
    cat > "$CONFIG_DIR/presets.conf" << 'EOF'
# Window positioning presets
# Format: NAME=X,Y,WIDTH,HEIGHT
# You can add custom presets here

# Browser presets
browser-left=10,40,960,1040
browser-right=970,40,960,1040
browser-fullwidth=10,40,1900,1040

# Terminal presets  
terminal-top=10,40,1920,500
terminal-bottom=10,580,1920,500
terminal-small=1400,40,520,600

# Editor presets
editor-center=480,270,960,540
editor-left=10,40,950,1040
editor-right=970,40,950,1040

# Communication apps
chat-right=1400,40,520,1040
video-call=300,200,1320,800

# Development layout
ide-main=10,40,1200,1040
browser-dev=1220,40,700,520
terminal-dev=1220,570,700,510
EOF
    chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/presets.conf" 2>/dev/null || true
    echo "✓ Created default presets configuration"
else
    echo "✓ Existing presets configuration preserved"
fi

# Create keyboard shortcut helper
cat > "$CONFIG_DIR/keyboard-shortcuts.txt" << 'EOF'
Suggested XFCE Keyboard Shortcuts
================================

To add keyboard shortcuts in XFCE:
1. Go to Settings → Keyboard → Application Shortcuts
2. Click "Add" and enter the command and key combination

Recommended shortcuts:

Command: place-window
Key: Super+Shift+P
Description: Interactive window positioning

Command: place-window ul
Key: Super+Shift+1
Description: Position window in upper left

Command: place-window ur  
Key: Super+Shift+2
Description: Position window in upper right

Command: place-window ll
Key: Super+Shift+3
Description: Position window in lower left

Command: place-window lr
Key: Super+Shift+4
Description: Position window in lower right

Command: place-window c
Key: Super+Shift+5
Description: Center window

Command: place-window left
Key: Super+Shift+Left
Description: Left half of screen

Command: place-window right
Key: Super+Shift+Right
Description: Right half of screen

Command: place-window top
Key: Super+Shift+Up
Description: Top half of screen

Command: place-window bottom
Key: Super+Shift+Down
Description: Bottom half of screen

Command: place-window auto
Key: Super+Shift+A
Description: Auto-arrange all windows

Command: place-window master vertical
Key: Super+Shift+M
Description: Master-stack layout

Command: place-window watch toggle
Key: Super+Shift+W
Description: Toggle watch mode daemon

Command: place-window minimize-others
Key: Super+Shift+O
Description: Minimize all except active window
EOF

chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/keyboard-shortcuts.txt" 2>/dev/null || true
echo "✓ Created keyboard shortcuts reference"

# Install XDG autostart service (more reliable for X11 applications)
echo "Installing XDG autostart service..."
AUTOSTART_DIR="${REAL_HOME}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
chown "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR" 2>/dev/null || true

# Create XDG autostart desktop file
cat > "$AUTOSTART_DIR/window-positioning.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Window Positioning Daemon
Comment=Automatic window tiling daemon for QubesOS dom0
Exec=/usr/local/bin/place-window watch daemon
Icon=preferences-system-windows
Categories=System;
X-GNOME-Autostart-enabled=true
X-XFCE-Autostart-enabled=true
X-XFCE-Autostart-Delay=5
Hidden=false
StartupNotify=false
EOF

chown "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR/window-positioning.desktop" 2>/dev/null || true
echo "✓ Installed XDG autostart service"

# Create uninstaller
cat > "$CONFIG_DIR/uninstall.sh" << EOF
#!/usr/bin/env bash
# Uninstaller for window positioning tool

echo "Removing window positioning tool..."

# Stop daemon if running
if pgrep -f "place-window.*watch.*daemon" > /dev/null; then
    echo "Stopping window-positioning daemon..."
    pkill -f "place-window.*watch.*daemon"
fi

# Remove XDG autostart file
rm -f "$AUTOSTART_DIR/window-positioning.desktop"
echo "✓ Removed XDG autostart service"

sudo rm -f "$INSTALL_BIN_DIR/place-window"
echo "✓ Removed script from $INSTALL_BIN_DIR"

sudo rm -rf "$INSTALL_LIB_DIR"
echo "✓ Removed library modules from $INSTALL_LIB_DIR"

read -p "Also remove configuration directory $CONFIG_DIR? [y/N]: " confirm
if [[ "\$confirm" == [yY] ]]; then
    rm -rf "$CONFIG_DIR"
    echo "✓ Removed configuration directory"
else
    echo "✓ Configuration directory preserved"
fi

echo "Uninstallation complete."
EOF

chmod +x "$CONFIG_DIR/uninstall.sh"
chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/uninstall.sh" 2>/dev/null || true

echo ""
echo "Installation Complete!"
echo "====================="
echo ""
echo "Installed components:"
echo "  Main script: $INSTALL_BIN_DIR/place-window"
echo "  Libraries:   $INSTALL_LIB_DIR/"
echo "  Config:      $CONFIG_DIR/"
echo ""
echo "Usage:"
echo "  place-window              # Interactive mode"
echo "  place-window ul           # Quick upper-left positioning"
echo "  place-window auto         # Auto-arrange windows"
echo "  place-window help         # Full help"
echo ""
echo "Systemd Service Control:"
echo "  systemctl --user start window-positioning    # Start daemon"
echo "  systemctl --user stop window-positioning     # Stop daemon"
echo "  systemctl --user status window-positioning   # Check status"
echo "  systemctl --user enable window-positioning   # Auto-start on login"
echo "  systemctl --user disable window-positioning  # Disable auto-start"
echo ""
echo "Configuration:"
echo "• Edit $CONFIG_DIR/settings.conf to customize gaps, panel height, etc."
echo "• Edit $CONFIG_DIR/presets.conf to customize window positions"
echo "• See $CONFIG_DIR/keyboard-shortcuts.txt for XFCE shortcut setup"
echo "• Run $CONFIG_DIR/uninstall.sh to remove the tool"
echo ""
echo "Key features:"
echo "• Modular architecture with focused library components"
echo "• Watch mode daemon for automatic window tiling"
echo "• Multi-monitor support with per-monitor layouts"
echo "• Master-stack layouts (vertical/horizontal/center)"
echo "• Focus navigation and window swapping"
echo "• Configurable gaps and panel handling"
echo ""
echo "To test: Run 'place-window' and click on any window"
echo ""
echo "Next steps:"
echo "1. Test the tool: place-window"
echo "2. Set up keyboard shortcuts (see $CONFIG_DIR/keyboard-shortcuts.txt)"
echo "3. Enable auto-tiling daemon: systemctl --user enable --now window-positioning"
echo "4. Customize settings in $CONFIG_DIR/settings.conf"