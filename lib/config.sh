#!/bin/bash

# Configuration management for place-window

CONFIG_DIR="${HOME}/.config/window-positioning"
PRESETS_FILE="${CONFIG_DIR}/presets.conf"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
WORKSPACE_STATE_FILE="${CONFIG_DIR}/workspace-state.conf"

# Initialize configuration
init_config() {
    # Ensure config directory exists
    mkdir -p "$CONFIG_DIR"

    # Initialize settings file if not exists
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        cat > "$SETTINGS_FILE" << 'EOF'
# Window positioning settings
# Gap around windows (in pixels)
GAP=10

# Panel height (adjust for your XFCE theme)
# Set to 0 if panel auto-hides or doesn't reserve space
PANEL_HEIGHT=30

# Panel auto-hide mode
# Set to true if panel is set to auto-hide (intelligently or always)
# When true, panel height is ignored for layout calculations
PANEL_AUTOHIDE=false

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

# Window decoration dimensions (in pixels)
# Height: title bar height - set to 0 if windows don't have title bars
DECORATION_HEIGHT=24

# Bottom frame border height (the B in _NET_FRAME_EXTENTS "L, R, T, B").
# Check with: xprop -id $(xdotool getactivewindow) _NET_FRAME_EXTENTS
# Without it every window is B px too tall: bottom and inter-row gaps
# come out B px smaller than the top gap.
DECORATION_BOTTOM=5

# Width: side border width (left + right combined) - usually 0 for modern themes
DECORATION_WIDTH=0

# Window ordering strategy
# Available strategies:
#   position/spatial     - Order by position (left-to-right, top-to-bottom) - DEFAULT
#   creation/chronological - Order by window creation time
#   stacking/focus       - Order by stacking/focus history (most recent first)
WINDOW_ORDER_STRATEGY=position

# Ignored applications (comma-separated list)
# These applications will not be included in auto-layout positioning
# Matches against WM_CLASS and window title
# Supports wildcards (*,?) and case-sensitive prefix (cs:)
# Common patterns:
#   About - About dialogs
#   ulauncher* - Application launcher
#   cs:Warning*, cs:Error* - System warnings/errors
#   cs:Password Required* - Password prompts
#   cs:Settings - Settings windows (exact match)
#   cs:Select Power Mode - Power management dialogs
#   *Preferences - Preference dialogs
#   Application Finder - XFCE app finder
#   Save*, Open*, Save As* - File dialogs
IGNORED_APPS="About,ulauncher*,cs:Warning*,cs:Error*,cs:Password Required*,cs:Settings,cs:Select Power Mode,*Preferences,Application Finder,cs:Save As,cs:Save Changes,cs:Unlock Keyring,cs:xfce4-panel,xfce4-*-settings,xfce4-*-preferences,xfce4-settings-manager"

# Watch mode: auto-layout on daemon start
# When true, the daemon automatically applies layouts when windows change
# When false, the daemon starts in idle mode (toggle with: place-window watch on)
WATCH_AUTO_LAYOUT=true
EOF
    fi

    # Initialize presets file if not exists
    if [[ ! -f "$PRESETS_FILE" ]]; then
        cat > "$PRESETS_FILE" << 'EOF'
# Window positioning presets
# Format: NAME=X,Y,WIDTH,HEIGHT
# You can add custom presets here
browser-left=10,40,960,1040
browser-right=970,40,960,1040
terminal-top=10,40,1920,500
terminal-bottom=10,580,1920,500
editor-center=480,270,960,540
EOF
    fi
}

# Load configuration settings
load_config() {
    # Load settings
    source "$SETTINGS_FILE"
    
    # Set defaults if not in config
    GAP=${GAP:-10}
    PANEL_HEIGHT=${PANEL_HEIGHT:-30}
    PANEL_AUTOHIDE=${PANEL_AUTOHIDE:-false}
    MIN_WIDTH=${MIN_WIDTH:-400}
    MIN_HEIGHT=${MIN_HEIGHT:-300}
    
    # Window decoration dimensions - configurable via settings.
    # DECORATION_HEIGHT is the title bar (T in _NET_FRAME_EXTENTS);
    # DECORATION_BOTTOM is the bottom border (B). Positioning uses T alone
    # (the client sits T below the frame top); vertical size budgeting uses
    # T+B (what a window's frame consumes beyond its client height) — see
    # init_layout_vars in lib/layouts.sh. Defaults match the xfwm4 default
    # theme (extents 1,1,24,5).
    DECORATION_HEIGHT=${DECORATION_HEIGHT:-24}
    DECORATION_BOTTOM=${DECORATION_BOTTOM:-5}
    DECORATION_WIDTH=${DECORATION_WIDTH:-0}
    
    # Window ordering strategy
    WINDOW_ORDER_STRATEGY=${WINDOW_ORDER_STRATEGY:-position}
    export WINDOW_ORDER_STRATEGY
    
    # Ignored applications (comma-separated list) with fallback to defaults
    IGNORED_APPS=${IGNORED_APPS:-"About,ulauncher*,cs:Warning*,cs:Error*,cs:Password Required*,cs:Settings,cs:Select Power Mode,*Preferences,Application Finder,cs:Save As,cs:Save Changes,cs:Unlock Keyring,cs:xfce4-panel,xfce4-*-settings,xfce4-*-preferences,xfce4-settings-manager"}
    export IGNORED_APPS
    compile_ignored_patterns

    # Watch mode auto-layout default
    WATCH_AUTO_LAYOUT=${WATCH_AUTO_LAYOUT:-true}
    export WATCH_AUTO_LAYOUT
}

# Compile IGNORED_APPS into ready-to-use regex arrays, ONCE per config load.
# get_visible_windows previously recompiled every pattern with ~5 forked
# sed/echo/grep processes per pattern, per window, per call — on the daemon's
# hot path that was the single largest CPU cost per tick (dom0 has 4 vcores;
# fork rate is the budget). Matching now uses bash [[ =~ ]] with these
# precompiled patterns and forks nothing.
#
# Semantics preserved from the original per-call compiler (commits 65ea404,
# c1fda77): `cs:` prefix = case-sensitive; `*`/`?` wildcards; no wildcard =
# exact match; trailing-only wildcard = anchored start; leading-only wildcard
# = anchored end; wildcards on both ends or mid-pattern = match anywhere.
# Case-insensitive matching is done by lowercasing both the pattern (stored
# pre-lowercased in IGNORED_RE) and the tested string — bash regex has no
# inline case flag, and toggling nocasematch in daemon scope is a footgun.
declare -a IGNORED_RE=()   # compiled ERE, pre-lowercased unless case-sensitive
declare -a IGNORED_RE_CS=() # "1" if case-sensitive, "0" otherwise
compile_ignored_patterns() {
    IGNORED_RE=()
    IGNORED_RE_CS=()
    [[ -z "$IGNORED_APPS" ]] && return 0

    local -a apps=()
    IFS=',' read -ra apps <<< "$IGNORED_APPS"
    local app pattern cs
    for app in "${apps[@]}"; do
        # Trim whitespace (pure bash)
        app="${app#"${app%%[![:space:]]*}"}"
        app="${app%"${app##*[![:space:]]}"}"
        [[ -z "$app" ]] && continue

        cs=0
        if [[ "$app" == cs:* ]]; then
            cs=1
            app="${app#cs:}"
        fi

        # Escape regex specials except * and ?, then convert wildcards
        pattern=$(printf '%s' "$app" | sed 's/\([[\\.^$()+{}|]\)/\\\1/g; s/\*/\.\*/g; s/\?/\./g')

        # Anchor based on wildcard position (same rules as before)
        if [[ "$app" != *"*"* && "$app" != *"?"* ]]; then
            pattern="^${pattern}$"
        elif [[ "$app" == *"*" && "$app" != "*"* ]]; then
            pattern="^${pattern}"
        elif [[ "$app" == "*"* && "$app" != *"*" ]]; then
            pattern="${pattern}$"
        fi

        if [[ "$cs" == 1 ]]; then
            IGNORED_RE+=("$pattern")
        else
            IGNORED_RE+=("${pattern,,}")
        fi
        IGNORED_RE_CS+=("$cs")
    done
}

# Test whether a window's class/title matches any ignored pattern.
# Args: class title. Returns 0 (match/skip) or 1. Forks nothing.
matches_ignored_app() {
    local class="$1" title="$2"
    local class_lc="${class,,}" title_lc="${title,,}"
    local i
    for ((i=0; i<${#IGNORED_RE[@]}; i++)); do
        if [[ "${IGNORED_RE_CS[i]}" == 1 ]]; then
            [[ "$class" =~ ${IGNORED_RE[i]} || "$title" =~ ${IGNORED_RE[i]} ]] && return 0
        else
            [[ "$class_lc" =~ ${IGNORED_RE[i]} || "$title_lc" =~ ${IGNORED_RE[i]} ]] && return 0
        fi
    done
    return 1
}

# Update a setting in the config file
update_setting() {
    local setting_name="$1"
    local new_value="$2"
    sed -i "s|^${setting_name}=.*|${setting_name}=${new_value}|" "$SETTINGS_FILE"
}

# Auto-detect decoration dimensions from a sample window
auto_detect_decorations() {
    echo "Auto-detecting window decoration dimensions..."
    echo "Please click on any window to sample decoration sizes..."
    
    # Get window ID
    local window_id=$(xdotool selectwindow 2>/dev/null)
    if [[ -z "$window_id" ]]; then
        echo "No window selected"
        return 1
    fi

    # Get window geometry with decorations (using xwininfo)
    local decoration_info=$(xwininfo -id "$window_id" 2>/dev/null)
    if [[ -z "$decoration_info" ]]; then
        echo "Could not get window information"
        return 1
    fi

    # Extract border width
    local border_width=$(echo "$decoration_info" | grep "Border width:" | awk '{print $3}')
    
    # Get window geometry without decorations (using xdotool)
    local client_info=$(xdotool getwindowgeometry "$window_id" 2>/dev/null)
    if [[ -z "$client_info" ]]; then
        echo "Could not get client geometry"
        return 1
    fi

    # Get actual window frame geometry (with decorations)
    local frame_geometry=$(wmctrl -lG | awk -v id="$(printf "0x%08x" "$window_id")" '$1 == id {print $3,$4,$5,$6}')
    if [[ -z "$frame_geometry" ]]; then
        echo "Could not get frame geometry"
        return 1
    fi

    read -r frame_x frame_y frame_w frame_h <<< "$frame_geometry"
    
    # Parse client geometry  
    local client_w=$(echo "$client_info" | grep "Geometry:" | sed 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\1/')
    local client_h=$(echo "$client_info" | grep "Geometry:" | sed 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\2/')

    # Calculate decoration dimensions
    local detected_decoration_width=$((frame_w - client_w))
    local detected_decoration_height=$((frame_h - client_h))
    
    # Ensure non-negative values
    detected_decoration_width=$((detected_decoration_width > 0 ? detected_decoration_width : 0))
    detected_decoration_height=$((detected_decoration_height > 0 ? detected_decoration_height : 0))

    echo "Detected decoration dimensions:"
    echo "  Width (borders): ${detected_decoration_width}px"
    echo "  Height (title bar): ${detected_decoration_height}px"
    echo ""
    echo "Current settings:"
    echo "  DECORATION_WIDTH=${DECORATION_WIDTH}"
    echo "  DECORATION_HEIGHT=${DECORATION_HEIGHT}"
    echo ""
    
    read -p "Update settings with detected values? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        update_setting "DECORATION_WIDTH" "$detected_decoration_width"
        update_setting "DECORATION_HEIGHT" "$detected_decoration_height"
        echo "Settings updated successfully"
        
        # Reload settings
        load_config
    else
        echo "Settings unchanged"
    fi
}

# Save workspace monitor layout
save_workspace_monitor_layout() {
    local workspace="$1" 
    local monitor_name="$2"
    local layout="$3"
    local window_count="$4"
    
    # Use workspace-specific config file
    local workspace_file="${CONFIG_DIR}/workspace-${workspace}-monitor.conf"
    
    # Ensure it's a hash-style config
    if [[ ! -f "$workspace_file" ]]; then
        echo "# Workspace $workspace per-monitor layout configuration" > "$workspace_file"
    fi
    
    # Update or add the layout entry  
    local key="MONITOR_${monitor_name}_LAYOUT_${window_count}"
    if grep -q "^${key}=" "$workspace_file"; then
        sed -i "s|^${key}=.*|${key}=${layout}|" "$workspace_file"
    else
        echo "${key}=${layout}" >> "$workspace_file"
    fi
}

# Get workspace monitor layout
get_workspace_monitor_layout() {
    local workspace="$1"
    local monitor_name="$2" 
    local window_count="$3"
    local default_layout="$4"
    
    local workspace_file="${CONFIG_DIR}/workspace-${workspace}-monitor.conf"
    local key="MONITOR_${monitor_name}_LAYOUT_${window_count}"
    
    if [[ -f "$workspace_file" ]]; then
        local saved_layout=$(grep "^${key}=" "$workspace_file" 2>/dev/null | cut -d'=' -f2-)
        if [[ -n "$saved_layout" ]]; then
            echo "$saved_layout"
            return
        fi
    fi
    
    # Fall back to default
    echo "$default_layout"
}

# Clear workspace monitor layout
clear_workspace_monitor_layout() {
    local workspace="$1"
    local monitor_name="$2"
    
    local workspace_file="${CONFIG_DIR}/workspace-${workspace}-monitor.conf"
    
    if [[ -f "$workspace_file" ]]; then
        sed -i "/^MONITOR_${monitor_name}_LAYOUT_/d" "$workspace_file"
        { echo "$(date): clear_workspace_monitor_layout ws=$workspace monitor=$monitor_name caller=${FUNCNAME[1]:-?}"; } >&6 2>/dev/null
    else
        { echo "$(date): clear_workspace_monitor_layout ws=$workspace monitor=$monitor_name caller=${FUNCNAME[1]:-?} (no file to clear)"; } >&6 2>/dev/null
    fi
}
