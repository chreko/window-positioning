#!/usr/bin/env bash
# Installation script for window positioning tool

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
REAL_UID=$(id -u "$REAL_USER")

# Run a command as REAL_USER with the environment needed to reach their
# systemd user manager and D-Bus session (both under /run/user/<uid>).
# Under sudo, root's environment points at root's runtime dir, so plain
# `systemctl --user` and `xfconf-query` fail — historically this left the
# unit installed but never enabled, and the daemon dead after reboot.
run_as_real_user() {
    if [[ $EUID -eq 0 ]]; then
        runuser -u "$REAL_USER" -- env \
            XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
            "$@"
    else
        "$@"
    fi
}

user_systemctl() { run_as_real_user systemctl --user "$@"; }

# Debug information
echo "Debug: USER=$USER, SUDO_USER=${SUDO_USER:-'not set'}, REAL_USER=$REAL_USER"
echo "Debug: HOME=$HOME, REAL_HOME=$REAL_HOME"
echo "Debug: CONFIG_DIR will be: $CONFIG_DIR"

echo "Window Positioning Tool Installer"
echo "=================================="
echo "Installing for user: $REAL_USER (home: $REAL_HOME)"
echo "Config will be created at: $CONFIG_DIR"
echo "Libraries will be installed to: $INSTALL_LIB_DIR"
echo ""

# Clean up any existing temporary files to ensure fresh installation
echo "Cleaning up temporary files..."
rm -f /tmp/place-window-wrapper
rm -f /tmp/place-window*
echo "✓ Temporary files cleaned"

# Optional: Check if running in Qubes dom0
if [[ -f /proc/xen/capabilities ]] && grep -q "control_d" /proc/xen/capabilities 2>/dev/null; then
    echo "Note: Detected Qubes OS dom0 environment."
fi

# Check for required tools
echo "Checking for required tools..."
missing_tools=()

for tool in xdotool wmctrl xwininfo; do
    if ! command -v "$tool" &> /dev/null; then
        missing_tools+=("$tool")
    fi
done

if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "Missing required tools: ${missing_tools[*]}"
    echo ""

    # Detect package manager and provide appropriate command
    if command -v apt-get &> /dev/null; then
        echo "To install on Debian/Ubuntu:"
        echo "  sudo apt-get install ${missing_tools[*]}"
    elif command -v dnf &> /dev/null; then
        echo "To install on Fedora/RHEL:"
        echo "  sudo dnf install ${missing_tools[*]}"
    elif command -v yum &> /dev/null; then
        echo "To install on older RHEL/CentOS:"
        echo "  sudo yum install ${missing_tools[*]}"
    elif command -v pacman &> /dev/null; then
        echo "To install on Arch Linux:"
        echo "  sudo pacman -S ${missing_tools[*]}"
    elif command -v zypper &> /dev/null; then
        echo "To install on openSUSE:"
        echo "  sudo zypper install ${missing_tools[*]}"
    elif command -v qubes-dom0-update &> /dev/null; then
        echo "To install in Qubes dom0:"
        echo "  sudo qubes-dom0-update ${missing_tools[*]}"
    else
        echo "Please install the missing tools using your package manager."
    fi

    echo ""
    read -p "Attempt automatic installation? [Y/n]: " confirm
    if [[ "$confirm" != [nN] ]]; then
        # Try to install based on available package manager
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y "${missing_tools[@]}"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "${missing_tools[@]}"
        elif command -v yum &> /dev/null; then
            sudo yum install -y "${missing_tools[@]}"
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm "${missing_tools[@]}"
        elif command -v zypper &> /dev/null; then
            sudo zypper install -y "${missing_tools[@]}"
        elif command -v qubes-dom0-update &> /dev/null; then
            sudo qubes-dom0-update "${missing_tools[@]}"
        else
            echo "Cannot automatically install. Please install manually and run installer again."
            exit 1
        fi

        # Verify installation
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" &> /dev/null; then
                echo "Failed to install $tool. Please install manually."
                exit 1
            fi
        done
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

# Remove modules deleted from the repo (advanced.sh merged into windows.sh)
for obsolete in advanced.sh; do
    if [[ -f "$INSTALL_LIB_DIR/$obsolete" ]]; then
        sudo rm -f "$INSTALL_LIB_DIR/$obsolete"
        echo "  ✓ Removed obsolete $obsolete"
    fi
done

# Create a wrapper script that knows where the libraries are
echo "Creating main executable..."
cat << 'EOF' > /tmp/place-window-wrapper
#!/usr/bin/env bash
# place-window: Position windows with mouse selection or window ID
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
Description: Master-stack layout (master on left)

Command: place-window master vertical-right 75
Key: Shift+Super+2
Description: Master-stack with master on right (75/25 split)

Command: place-window watch toggle
Key: Super+Shift+W
Description: Toggle watch mode daemon

Command: place-window minimize-others
Key: Super+Shift+O
Description: Minimize all except active window
EOF

chown "$REAL_USER:$REAL_USER" "$CONFIG_DIR/keyboard-shortcuts.txt" 2>/dev/null || true
echo "✓ Created keyboard shortcuts reference"

# Install systemd user unit. Replaces the old XDG autostart entry, which
# started the daemon with no output redirection (crashes left no log), no
# already-running guard (two instances could fight over the IPC pipes),
# and no supervision (any death was permanent until a manual restart).
echo "Installing systemd user unit..."
SYSTEMD_USER_DIR="${REAL_HOME}/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
chown "$REAL_USER:$REAL_USER" "$SYSTEMD_USER_DIR" 2>/dev/null || true
cp "$SCRIPT_DIR/window-positioning.service" "$SYSTEMD_USER_DIR/"
chown "$REAL_USER:$REAL_USER" "$SYSTEMD_USER_DIR/window-positioning.service" 2>/dev/null || true

# Migration: remove the legacy XDG autostart entry so it cannot race the
# unit at login, and stop any legacy nohup-started daemon.
if [[ -f "${REAL_HOME}/.config/autostart/window-positioning.desktop" ]]; then
    rm -f "${REAL_HOME}/.config/autostart/window-positioning.desktop"
    echo "✓ Removed legacy XDG autostart entry"
fi
if pgrep -f "place-window.*watch.*daemon" > /dev/null; then
    echo "Stopping legacy daemon instance..."
    pkill -f "place-window.*watch.*daemon" || true
    sleep 1
fi

# Enabling/starting needs the target user's manager, not root's;
# user_systemctl bridges the gap when the installer runs under sudo.
if user_systemctl show-environment >/dev/null 2>&1; then
    if user_systemctl daemon-reload && \
       user_systemctl enable --now window-positioning.service; then
        echo "✓ Installed, enabled, and started systemd user unit (auto-restarts on failure)"
    else
        echo "⚠ Unit installed but enabling it failed. Enable it as ${REAL_USER} with:"
        echo "    systemctl --user enable --now window-positioning.service"
    fi
else
    echo "⚠ ${REAL_USER}'s systemd user manager is not reachable; unit installed but not enabled."
    echo "  Enable it as ${REAL_USER} (while logged in) with:"
    echo "    systemctl --user enable --now window-positioning.service"
fi

# Create uninstaller
echo "Debug: Creating uninstaller at: $CONFIG_DIR/uninstall.sh"
echo "Debug: CONFIG_DIR permissions: $(ls -ld "$CONFIG_DIR" 2>/dev/null || echo 'directory not found')"

# Create uninstaller with explicit error checking
if ! cat > "$CONFIG_DIR/uninstall.sh" << EOF
#!/usr/bin/env bash
# Uninstaller for window positioning tool

echo "Removing window positioning tool..."

# Reach ${REAL_USER}'s systemd user manager even under sudo — root's own
# environment points at root's runtime dir, so a plain \`systemctl --user\`
# would silently no-op and leave the unit enabled after removal.
user_systemctl() {
    if [[ \$EUID -eq 0 ]]; then
        runuser -u "${REAL_USER}" -- env \\
            XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \\
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" \\
            systemctl --user "\$@"
    else
        systemctl --user "\$@"
    fi
}

# Stop and remove systemd user unit
if user_systemctl list-unit-files window-positioning.service --no-legend 2>/dev/null | grep -q .; then
    user_systemctl disable --now window-positioning.service 2>/dev/null || true
fi
rm -f "${REAL_HOME}/.config/systemd/user/window-positioning.service"
user_systemctl daemon-reload 2>/dev/null || true
echo "✓ Removed systemd user unit"

# Stop any legacy nohup daemon if running
if pgrep -f "place-window.*watch.*daemon" > /dev/null; then
    echo "Stopping window-positioning daemon..."
    pkill -f "place-window.*watch.*daemon"
fi

# Remove legacy XDG autostart file if present
rm -f "${REAL_HOME}/.config/autostart/window-positioning.desktop"
echo "✓ Removed autostart entries"

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

# Install keyboard shortcuts (optional)
echo ""
echo "Would you like to install keyboard shortcuts for window positioning?"
echo "  Super+1-4    : Window layouts"
echo "  Super+Up/Down: Cycle windows"
echo "  Super+Left/Right: Adjust master size"
echo "  Super+w      : Toggle watch mode"
echo "  Super+s      : Swap windows"
echo "  Super+0      : Auto-arrange"
echo ""
read -p "Install keyboard shortcuts? [Y/n]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if ! command -v xfconf-query &> /dev/null; then
        echo "⚠ xfconf-query not found, skipping keyboard shortcuts"
        echo "  Add shortcuts manually - see $CONFIG_DIR/keyboard-shortcuts.txt"
    # xfconf-query needs the user's D-Bus session; run_as_real_user supplies
    # it under sudo. Probe once before writing 14 keys so a dead session
    # produces one warning instead of aborting mid-way under set -e.
    elif ! run_as_real_user xfconf-query -c xfce4-keyboard-shortcuts -l >/dev/null 2>&1; then
        echo "⚠ Cannot reach ${REAL_USER}'s D-Bus session for xfconf-query."
        echo "  Add shortcuts manually via Settings > Keyboard > Application Shortcuts"
    else
            set_shortcut() {
                local key="$1"
                local cmd="$2"
                run_as_real_user xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$key" --reset 2>/dev/null || true
                run_as_real_user xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$key" -n -t string -s "$cmd"
            }
            echo "Installing keyboard shortcuts..."
            set_shortcut "<Super>1" "place-window minimize-others"
            set_shortcut "<Super>2" "place-window master vertical 75"
            # Shift+Super+2: XFCE stores Shift+digit by the SHIFTED keysym name,
            # not the digit. On a US/QWERTY layout, Shift+2 -> "@" -> "at".
            # On other layouts the keysym differs; if the binding does not fire
            # after install, rebind via Settings > Keyboard > Application Shortcuts.
            set_shortcut "<Shift><Super>at" "place-window master vertical-right 75"
            set_shortcut "<Super>3" "place-window master center"
            set_shortcut "<Super>4" "place-window master horizontal 50"
            set_shortcut "<Super>Up" "place-window cycle"
            set_shortcut "<Super>Down" "place-window cycle counter-clockwise"
            set_shortcut "<Super>Left" "place-window master decrease"
            set_shortcut "<Super>Right" "place-window master increase"
            set_shortcut "<Super>w" "place-window watch toggle"
            set_shortcut "<Super>s" "place-window swap"
            set_shortcut "<Super>0" "place-window auto"
            set_shortcut "<Super>exclam" "place-window reapply"
            echo "✓ Keyboard shortcuts installed"
    fi
else
    echo "✓ Skipped keyboard shortcuts (see $CONFIG_DIR/keyboard-shortcuts.txt)"
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
echo "3. The auto-tiling daemon is enabled and supervised by systemd"
echo "   (auto-restarts on failure); check it with: place-window watch status"
echo "4. Customize settings in $CONFIG_DIR/settings.conf"