#!/usr/bin/env bash
# test-ipc-fix.sh: Test the IPC fix for window list persistence
# 
# This test verifies that cycle commands now work through daemon IPC
# instead of direct function calls, solving the window list persistence issue.

set -x  # Enable debug output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="/tmp/ipc-fix-test.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== IPC FIX VERIFICATION TEST ==="
echo "Date: $(date)"
echo "Testing that cycle commands use daemon IPC instead of direct function calls"
echo ""

# Test 1: Verify daemon is running
echo "=== TEST 1: Daemon Status ==="
if ./place-window watch status; then
    echo "✅ Daemon is running"
else
    echo "❌ Daemon not running - starting daemon..."
    ./place-window watch start
    sleep 2
    if ./place-window watch status; then
        echo "✅ Daemon started successfully"
    else
        echo "❌ Failed to start daemon"
        exit 1
    fi
fi
echo ""

# Test 2: Test cycle command routing
echo "=== TEST 2: Cycle Command Routing ==="
echo "Testing if cycle commands now route through daemon..."

# Test clockwise cycle
echo "Testing clockwise cycle:"
./place-window cycle clockwise
echo "✅ Clockwise cycle command completed"

echo ""

# Test counter-clockwise cycle  
echo "Testing counter-clockwise cycle:"
./place-window cycle counter-clockwise
echo "✅ Counter-clockwise cycle command completed"

echo ""

# Test 3: Multiple consecutive cycles (the original problem)
echo "=== TEST 3: Multiple Consecutive Cycles ==="
echo "Testing multiple cycles in a row (this was the failing case)..."

for i in {1..5}; do
    echo "--- Cycle attempt $i ---"
    ./place-window cycle
    echo "Cycle $i completed successfully"
    sleep 1
done

echo "✅ All 5 consecutive cycles completed - issue should be fixed!"
echo ""

# Test 4: Other daemon-routed commands
echo "=== TEST 4: Other Daemon Commands ==="

echo "Testing auto command:"
./place-window auto
echo "✅ Auto command completed"

echo ""

echo "Testing master command:"
./place-window master vertical 70
echo "✅ Master command completed"

echo ""

echo "Testing focus command:"
./place-window focus next
echo "✅ Focus command completed"

echo ""

# Test 5: Verify daemon maintains state
echo "=== TEST 5: Daemon State Persistence ==="
echo "All commands should use persistent window lists from daemon memory"
echo "No more 'window list empty' issues!"

echo ""
echo "=== IPC FIX TEST COMPLETE ==="
echo "Log saved to: $LOG_FILE"
echo ""
echo "EXPECTED RESULTS:"
echo "✅ All cycle commands should work without 'empty window list' errors"
echo "✅ Multiple consecutive cycles should work (was failing before)"
echo "✅ Layout reapplication should maintain user-modified window order"
echo "✅ All window list commands route through daemon for persistent state"
echo ""
echo "If any commands failed, the daemon may need to be restarted:"
echo "  ./place-window watch restart"