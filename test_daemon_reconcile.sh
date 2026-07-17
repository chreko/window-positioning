#!/bin/bash

# Tests for the daemon's change-detection logic (lib/daemon.sh).
#
# Regression under test: windows moved between virtual desktops were never
# re-positioned, because reconcile_ws_mon tracked membership as a bare window
# COUNT — any move sequence with a net-zero count change (swap two windows
# between desktops, move one in after another closed) was invisible, and the
# event watcher had no atom that fires on a pager-drag desktop move.
cd "$(dirname "$0")"

# Isolate config/runtime side effects from the real user environment
export XDG_CONFIG_HOME=$(mktemp -d)
export XDG_RUNTIME_DIR=$(mktemp -d)
trap 'rm -rf "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"' EXIT

# Mock external X tools (not available / not wanted in the dev qube).
# command -v resolves functions, so these also satisfy daemon.sh's need().
wmctrl() { :; }
xdotool() { echo "0"; }
xprop() { :; }
xrandr() { echo "eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 309mm x 173mm"; }
xwininfo() { echo -e "Absolute upper-left X:  0\nAbsolute upper-left Y:  0\nWidth: 100\nHeight: 100"; }
export -f wmctrl xdotool xprop xrandr xwininfo

source lib/daemon.sh

PASS=0
FAIL=0
check() {  # args: description condition-result
    if [[ "$2" == "0" ]]; then
        echo "✅ PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: $1"
        FAIL=$((FAIL + 1))
    fi
}

# Stub window discovery to canned data; reconcile_ws_mon must depend only on
# what this returns, so the tests control membership directly.
FAKE_WINDOWS=""
get_visible_windows() { [[ -n "$FAKE_WINDOWS" ]] && printf '%s\n' "$FAKE_WINDOWS"; }

K="workspace_0_monitor_eDP-1"

echo "=== reconcile_ws_mon change detection ==="

# Baseline: first sighting of {a, b} marks dirty (0 -> 2 windows)
FAKE_WINDOWS=$'0x0a\n0x0b'
reconcile_ws_mon 0 eDP-1 >/dev/null
check "initial window set marks dirty" \
      "$([[ "${WINDOW_DIRTY[$K]-0}" -eq 1 ]]; echo $?)"

# Same set again: must stay clean (no spurious re-applies)
WINDOW_DIRTY[$K]=0
reconcile_ws_mon 0 eDP-1 >/dev/null
check "unchanged window set stays clean" \
      "$([[ "${WINDOW_DIRTY[$K]-0}" -eq 0 ]]; echo $?)"

# THE BUG: same count, different member (window swapped in from another
# workspace while one left). Count 2 -> 2, membership {a,b} -> {a,c}.
WINDOW_DIRTY[$K]=0
FAKE_WINDOWS=$'0x0a\n0x0c'
reconcile_ws_mon 0 eDP-1 >/dev/null
check "membership change with equal count marks dirty" \
      "$([[ "${WINDOW_DIRTY[$K]-0}" -eq 1 ]]; echo $?)"

# Plain count change still detected (guard against regressing the old path)
WINDOW_DIRTY[$K]=0
FAKE_WINDOWS=$'0x0a\n0x0c\n0x0d'
reconcile_ws_mon 0 eDP-1 >/dev/null
check "count change still marks dirty" \
      "$([[ "${WINDOW_DIRTY[$K]-0}" -eq 1 ]]; echo $?)"

echo
echo "=== event watcher coverage ==="

# Desktop moves without a focus change (pager drag, script) must generate an
# event: the watcher has to spy _NET_CLIENT_LIST_STACKING, which xfwm4
# rewrites when a window is restacked into another workspace.
check "watcher spies _NET_CLIENT_LIST_STACKING" \
      "$([[ " ${WATCHED_ROOT_ATOMS-} " == *" _NET_CLIENT_LIST_STACKING "* ]]; echo $?)"

echo
echo "=== event rate-limit classification ==="

# Stacking fires on every click/raise like ACTIVE_WINDOW -> rate-limited
check "_NET_ACTIVE_WINDOW is rate-limited" \
      "$(event_is_rate_limited "__EVENT__ _NET_ACTIVE_WINDOW(WINDOW): window id # 0x123"; echo $?)"
check "_NET_CLIENT_LIST_STACKING is rate-limited" \
      "$(event_is_rate_limited "__EVENT__ _NET_CLIENT_LIST_STACKING(WINDOW): window id # 0x1, 0x2"; echo $?)"

# Rare, meaningful events must tick immediately. NB: _NET_CLIENT_LIST is a
# prefix of _NET_CLIENT_LIST_STACKING — the classifier must not confuse them.
check "_NET_CLIENT_LIST ticks immediately" \
      "$(! event_is_rate_limited "__EVENT__ _NET_CLIENT_LIST(WINDOW): window id # 0x1, 0x2"; echo $?)"
check "_NET_CURRENT_DESKTOP ticks immediately" \
      "$(! event_is_rate_limited "__EVENT__ _NET_CURRENT_DESKTOP(CARDINAL) = 1"; echo $?)"

echo
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
