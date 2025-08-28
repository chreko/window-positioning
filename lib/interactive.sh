#!/bin/bash

# Interactive mode functionality for place-window

# Apply quick presets to windows
apply_preset() {
    local preset="$1" id="$2"
    get_screen_info
    
    # Determine which monitor the window is primarily on
    local monitor=$(get_window_monitor "$id")
    local layout_area=$(get_monitor_layout_area "$monitor")
    IFS=':' read -r usable_x usable_y usable_w usable_h <<< "$layout_area"
    
    local half_w=$((usable_w / 2))
    local half_h=$((usable_h / 2))
    
    local gap=$GAP
    local decoration_h=$DECORATION_HEIGHT
    local decoration_w=$DECORATION_WIDTH
    
    case "$preset" in
        ul) # Upper left
            read -r w h <<< "$(ensure_minimum_size $((half_w - gap)) $((half_h - gap - decoration_h)))"
            apply_geometry "$id" $((usable_x + gap)) $((usable_y + gap)) $w $h
            ;;
        ur) # Upper right
            read -r w h <<< "$(ensure_minimum_size $((half_w - gap)) $((half_h - gap - decoration_h)))"
            apply_geometry "$id" $((usable_x + half_w + gap)) $((usable_y + gap)) $w $h
            ;;
        ll) # Lower left
            read -r w h <<< "$(ensure_minimum_size $((half_w - gap)) $((half_h - gap - decoration_h)))"
            apply_geometry "$id" $((usable_x + gap)) $((usable_y + half_h + gap)) $w $h
            ;;
        lr) # Lower right
            read -r w h <<< "$(ensure_minimum_size $((half_w - gap)) $((half_h - gap - decoration_h)))"
            apply_geometry "$id" $((usable_x + half_w + gap)) $((usable_y + half_h + gap)) $w $h
            ;;
        c) # Center
            local center_w=$((usable_w * 2 / 3 - gap * 2))
            local center_h=$((usable_h * 2 / 3 - gap * 2 - decoration_h))
            read -r center_w center_h <<< "$(ensure_minimum_size $center_w $center_h)"
            local center_x=$((usable_x + gap + (usable_w - center_w - gap * 2) / 2))
            local center_y=$((usable_y + gap + (usable_h - center_h - gap * 2 - decoration) / 2))
            apply_geometry "$id" $center_x $center_y $center_w $center_h
            ;;
        left) # Left half
            read -r w h <<< "$(ensure_minimum_size $((half_w - gap)) $((usable_h - gap * 2 - decoration_h)))"
            apply_geometry "$id" $((usable_x + gap)) $((usable_y + gap)) $w $h
            ;;
        right) # Right half
            read -r w h <<< "$(ensure_minimum_size $((half_w - gap)) $((usable_h - gap * 2 - decoration_h)))"
            apply_geometry "$id" $((usable_x + half_w + gap)) $((usable_y + gap)) $w $h
            ;;
        top) # Top half
            read -r w h <<< "$(ensure_minimum_size $((usable_w - gap * 2)) $((half_h - gap - decoration_h)))"
            apply_geometry "$id" $((usable_x + gap)) $((usable_y + gap)) $w $h
            ;;
        bottom) # Bottom half
            read -r w h <<< "$(ensure_minimum_size $((usable_w - gap * 2)) $((half_h - gap - decoration_h)))"
            apply_geometry "$id" $((usable_x + gap)) $((usable_y + half_h + gap)) $w $h
            ;;
        maximize) # Maximize (with gaps)
            local final_x=$((usable_x + gap))
            local final_y=$((usable_y + gap))
            local final_w=$((usable_w - gap * 2 - decoration_w))
            local final_h=$((usable_h - gap * 2 - decoration_h))
            read -r w h <<< "$(ensure_minimum_size $final_w $final_h)"
            apply_geometry "$id" $final_x $final_y $w $h
            ;;
        *)
            # Check if it's a saved preset
            load_position "$preset" "$id"
            ;;
    esac
}

# Interactive mode menu
interactive_mode() {
    local id=$(pick_window)
    
    echo ""
    echo "Window Positioning - Interactive Mode"
    echo "====================================="
    echo "Current settings: Gap=${GAP}px, Panel=${PANEL_HEIGHT}px"
    echo ""
    echo "Quick presets:"
    echo "  1) Upper left (ul)      6) Left half"
    echo "  2) Upper right (ur)     7) Right half"
    echo "  3) Lower left (ll)      8) Top half"
    echo "  4) Lower right (lr)     9) Bottom half"
    echo "  5) Center (c)          10) Maximize"
    echo ""
    echo "Other options:"
    echo "  s) Save current position    g) Set gap size"
    echo "  l) Load saved position      p) Set panel height"
    echo "  c) Custom coordinates       r) Reload settings"
    echo "  w) Move to workspace        q) Quit"
    echo ""
    
    read -p "Choose option: " choice
    
    case "$choice" in
        1|ul) apply_preset "ul" "$id" ;;
        2|ur) apply_preset "ur" "$id" ;;
        3|ll) apply_preset "ll" "$id" ;;
        4|lr) apply_preset "lr" "$id" ;;
        5|c) apply_preset "c" "$id" ;;
        6) apply_preset "left" "$id" ;;
        7) apply_preset "right" "$id" ;;
        8) apply_preset "top" "$id" ;;
        9) apply_preset "bottom" "$id" ;;
        10) apply_preset "maximize" "$id" ;;
        s)
            read -p "Enter name for this position: " name
            save_position "$name" "$id"
            ;;
        l)
            echo "Available presets:"
            grep -v '^#' "$PRESETS_FILE" | cut -d= -f1 | sed 's/^/  - /'
            read -p "Enter preset name: " name
            load_position "$name" "$id"
            ;;
        c)
            read -p "Enter X Y Width Height (space-separated): " x y w h
            apply_geometry "$id" "$x" "$y" "$w" "$h"
            ;;
        w)
            read -p "Enter workspace number (1-based): " ws
            move_to_workspace "$id" $((ws - 1))
            ;;
        g)
            read -p "Enter new gap size (current: ${GAP}px): " new_gap
            if [[ "$new_gap" =~ ^[0-9]+$ ]]; then
                update_setting "GAP" "$new_gap"
                GAP=$new_gap
                echo "Gap size set to ${new_gap}px"
            else
                echo "Invalid gap size. Must be a number."
            fi
            ;;
        p)
            read -p "Enter new panel height (current: ${PANEL_HEIGHT}px): " new_panel
            if [[ "$new_panel" =~ ^[0-9]+$ ]]; then
                update_setting "PANEL_HEIGHT" "$new_panel"
                PANEL_HEIGHT=$new_panel
                echo "Panel height set to ${new_panel}px"
            else
                echo "Invalid panel height. Must be a number."
            fi
            ;;
        r)
            load_config
            echo "Settings reloaded: Gap=${GAP}px, Panel=${PANEL_HEIGHT}px"
            ;;
        q)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option"
            exit 1
            ;;
    esac
}