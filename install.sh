#!/usr/bin/env bash
# Installation script for window positioning tool in Qubes OS dom0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_LIB_DIR="/usr/local/lib/place-window"

# Get the real user (not root when using sudo)
# If SUDO_USER is set, use that; otherwise try to detect the real user
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
elif [[ "$USER" == "root" ]]; then
    # If we're root but no SUDO_USER, try to find the real user from the environment
    REAL_USER=$(logname 2>/dev/null || who am i | awk '{print $1}' | head -1 || echo "user")
else
    REAL_USER="$USER"
fi

REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Safety check: never install to root's home
if [[ "$REAL_HOME" == "/root" ]]; then
    echo "ERROR: Detected root home directory. This should install to a regular user."
    echo "Please run as: sudo -E ./install.sh"
    echo "Or specify the target user manually."
    exit 1
fi

CONFIG_DIR="${REAL_HOME}/.config/window-positioning"

# Debug information
echo "Debug: USER=$USER, SUDO_USER=${SUDO_USER:-'not set'}, REAL_USER=$REAL_USER"
echo "Debug: HOME=$HOME, REAL_HOME=$REAL_HOME"
echo "Debug: CONFIG_DIR will be: $CONFIG_DIR"

echo "Window Positioning Tool Installer for Qubes OS dom0"
echo "=================================================="
echo "Installing for user: $REAL_USER (home: $REAL_HOME)"
echo "Config will be created at: $CONFIG_DIR"
echo "Libraries will be installed to: $INSTALL_LIB_DIR"
echo ""

# Clean up any existing temporary files to ensure fresh installation
echo "Cleaning up temporary files..."
rm -f /tmp/place-window-wrapper
rm -f /tmp/place-window*
echo "✓ Temporary files cleaned"

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

# Create configuration files using config.sh (single source of truth)
# Set our variables BEFORE sourcing config.sh to prevent override
export CONFIG_DIR="$CONFIG_DIR"  # Use the installer's CONFIG_DIR (set to REAL_USER's home)
export PRESETS_FILE="${CONFIG_DIR}/presets.conf"
export SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
export WORKSPACE_STATE_FILE="${CONFIG_DIR}/workspace-state.conf"

echo "Debug: Before sourcing config.sh - CONFIG_DIR=$CONFIG_DIR, PRESETS_FILE=$PRESETS_FILE"

# Now source the config functions (without letting it override our variables)
# We need to modify how we source it to avoid the variable assignments
source <(grep -v '^CONFIG_DIR=' "$INSTALL_LIB_DIR/config.sh" | grep -v '^PRESETS_FILE=' | grep -v '^SETTINGS_FILE=' | grep -v '^WORKSPACE_STATE_FILE=')

echo "Debug: After sourcing config.sh - CONFIG_DIR=$CONFIG_DIR, PRESETS_FILE=$PRESETS_FILE"

# Initialize configuration files
init_config

# Fix ownership after config creation
chown -R "$REAL_USER:$REAL_USER" "$CONFIG_DIR" 2>/dev/null || true
echo "✓ Configuration files created/verified"


# Create keyboard shortcut helper
echo "Debug: Creating keyboard shortcuts at: $CONFIG_DIR/keyboard-shortcuts.txt"
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
echo "Debug: Creating uninstaller at: $CONFIG_DIR/uninstall.sh"
echo "Debug: CONFIG_DIR permissions: $(ls -ld "$CONFIG_DIR" 2>/dev/null || echo 'directory not found')"

# Create uninstaller with explicit error checking
if ! cat > "$CONFIG_DIR/uninstall.sh" << EOF
#!/usr/bin/env bash
# Uninstaller for window positioning tool

echo "Removing window positioning tool..."

# Stop daemon if running
if pgrep -f "place-window.*watch.*daemon" > /dev/null; then
    echo "Stopping window-positioning daemon..."
    pkill -f "place-window.*watch.*daemon"
fi

# Remove XDG autostart file
rm -f "${REAL_HOME}/.config/autostart/window-positioning.desktop"
echo "✓ Removed XDG autostart service"

sudo rm -f "${INSTALL_BIN_DIR}/place-window"
echo "✓ Removed script from ${INSTALL_BIN_DIR}"

sudo rm -rf "${INSTALL_LIB_DIR}"
echo "✓ Removed library modules from ${INSTALL_LIB_DIR}"

read -p "Also remove configuration directory ${CONFIG_DIR}? [y/N]: " confirm
if [[ "\$confirm" == [yY] ]]; then
    rm -rf "${CONFIG_DIR}"
    echo "✓ Removed configuration directory"
else
    echo "✓ Configuration directory preserved"
fi

echo "Uninstallation complete."
EOF
then
    echo "ERROR: Failed to create uninstaller at $CONFIG_DIR/uninstall.sh"
    echo "Check directory permissions and try again"
    exit 1
fi

if ! chmod +x "$CONFIG_DIR/uninstall.sh"; then
    echo "ERROR: Failed to make uninstaller executable"
    exit 1
fi

chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/uninstall.sh" 2>/dev/null || true
echo "✓ Created uninstaller at $CONFIG_DIR/uninstall.sh"

# Verify the file was actually created
if [[ -f "$CONFIG_DIR/uninstall.sh" ]]; then
    echo "✓ Verified uninstaller exists: $(ls -la "$CONFIG_DIR/uninstall.sh")"
else
    echo "ERROR: Uninstaller file not found after creation!"
fi

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
echo "Daemon Control (via place-window wrapper):"
echo "  place-window watch start     # Start daemon"
echo "  place-window watch stop      # Stop daemon"
echo "  place-window watch status    # Check status"
echo "  place-window watch enable    # Enable auto-start on login"
echo "  place-window watch disable   # Disable auto-start"
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
echo "3. Enable auto-tiling daemon: place-window watch enable && place-window watch start"
echo "4. Customize settings in $CONFIG_DIR/settings.conf"