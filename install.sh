#!/usr/bin/env bash
# Installation script for window positioning tool in Qubes OS dom0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"

# Get the real user (not root when using sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CONFIG_DIR="${REAL_HOME}/.config/window-positioning"

echo "Window Positioning Tool Installer for Qubes OS dom0"
echo "=================================================="
echo "Installing for user: $REAL_USER (home: $REAL_HOME)"
echo "Config will be created at: $CONFIG_DIR"
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

# Install the script
echo "Installing place-window script..."
sudo cp "$SCRIPT_DIR/place-window" "$INSTALL_DIR/"
sudo chmod +x "$INSTALL_DIR/place-window"
echo "✓ Installed to $INSTALL_DIR/place-window"

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
PANEL_HEIGHT=32

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
EOF

chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/keyboard-shortcuts.txt" 2>/dev/null || true
echo "✓ Created keyboard shortcuts reference"

# Create uninstaller
cat > "$CONFIG_DIR/uninstall.sh" << EOF
#!/usr/bin/env bash
# Uninstaller for window positioning tool

echo "Removing window positioning tool..."
sudo rm -f "/usr/local/bin/place-window"
echo "✓ Removed script from /usr/local/bin/"

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
echo "Usage:"
echo "  place-window              # Interactive mode"
echo "  place-window ul           # Quick upper-left positioning with gaps"
echo "  place-window config gap 15 # Set 15px gaps around windows"
echo "  place-window help         # Full help"
echo ""
echo "Configuration directory: $CONFIG_DIR"
echo "• Edit settings.conf to customize gaps, panel height, etc."
echo "• Edit presets.conf to customize window positions"
echo "• See keyboard-shortcuts.txt for XFCE shortcut setup"
echo "• Run uninstall.sh to remove the tool"
echo ""
echo "Gap feature:"
echo "• Default gap: 10px around all windows"
echo "• Configurable via: place-window config gap <SIZE>"
echo "• Interactive mode allows real-time gap adjustment"
echo ""
echo "To test: Run 'place-window' and click on any window"
echo ""
echo "Next steps:"
echo "1. Test the tool: place-window"
echo "2. Adjust gap size: place-window config gap <SIZE>"
echo "3. Set up keyboard shortcuts (see $CONFIG_DIR/keyboard-shortcuts.txt)"
echo "4. Customize settings in $CONFIG_DIR/settings.conf"
echo "5. Add custom presets in $CONFIG_DIR/presets.conf"