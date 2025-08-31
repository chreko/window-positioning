#!/usr/bin/env bash
# debug-cycle-daemon.sh: Debug cycle commands in daemon context
# 
# This traces what happens inside the daemon when cycle commands are executed

set -x  # Enable debug output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="/tmp/debug-cycle-daemon.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== DAEMON CYCLE DEBUGGING ==="
echo "Date: $(date)"
echo "Testing cycle commands through daemon IPC to debug persistence issues"
echo ""

# Test 1: Verify daemon is running and has IPC pipes
echo "=== TEST 1: Daemon and IPC Status ==="

if ./place-window watch status | grep -q "running"; then
    echo "✅ Daemon is running"
else
    echo "❌ Daemon not running - starting..."
    ./place-window watch start
    sleep 2
fi

# Check pipes exist
DAEMON_PIPE_DIR="${XDG_RUNTIME_DIR:-/tmp}/window-positioning"
DAEMON_CMD_PIPE="$DAEMON_PIPE_DIR/commands"
DAEMON_RESP_PIPE="$DAEMON_PIPE_DIR/responses"

if [[ -p "$DAEMON_CMD_PIPE" && -p "$DAEMON_RESP_PIPE" ]]; then
    echo "✅ IPC pipes exist"
    echo "  Command pipe: $DAEMON_CMD_PIPE"
    echo "  Response pipe: $DAEMON_RESP_PIPE"
else
    echo "❌ IPC pipes missing"
    ls -la "$DAEMON_PIPE_DIR" 2>/dev/null || echo "Pipe directory not found"
    exit 1
fi

echo ""

# Test 2: First cycle command
echo "=== TEST 2: First Cycle Command ==="
echo "Running first cycle command..."
echo "BEFORE: First cycle"

# Run cycle and capture response
cycle1_result=$(./place-window cycle 2>&1)
echo "RESULT 1: $cycle1_result"

if echo "$cycle1_result" | grep -q "Error"; then
    echo "❌ First cycle failed: $cycle1_result"
else
    echo "✅ First cycle completed"
fi

sleep 2
echo ""

# Test 3: Second cycle command (this should fail based on original issue)
echo "=== TEST 3: Second Cycle Command ==="
echo "Running second cycle command (this was the failing case)..."
echo "BEFORE: Second cycle"

# Run cycle and capture response
cycle2_result=$(./place-window cycle 2>&1)
echo "RESULT 2: $cycle2_result"

if echo "$cycle2_result" | grep -q "Error"; then
    echo "❌ Second cycle failed: $cycle2_result"
    echo "ISSUE CONFIRMED: Second cycle fails as reported"
else
    echo "✅ Second cycle completed successfully"
    echo "ISSUE RESOLVED: Second cycle now works!"
fi

sleep 2
echo ""

# Test 4: Multiple consecutive cycles
echo "=== TEST 4: Multiple Consecutive Cycles ==="
echo "Testing multiple cycles to see the pattern..."

for i in {3..5}; do
    echo "--- Cycle attempt $i ---"
    cycle_result=$(./place-window cycle 2>&1)
    
    if echo "$cycle_result" | grep -q "Error"; then
        echo "❌ Cycle $i failed: $cycle_result"
    else
        echo "✅ Cycle $i completed: $cycle_result"
    fi
    
    sleep 1
done

echo ""

# Test 5: Test master layout reset issue
echo "=== TEST 5: Master Layout Reset Issue ==="
echo "Testing if master layout resets after reapplication..."

echo "Step 1: Apply master layout..."
master_result=$(./place-window master vertical 70 2>&1)
echo "Master result: $master_result"

sleep 2

echo "Step 2: Run cycle to change window order..."
cycle_after_master=$(./place-window cycle 2>&1)
echo "Cycle after master: $cycle_after_master"

sleep 2

echo "Step 3: Check if master layout maintained window order..."
# The issue is that layout reapplication reverts to starting configuration
echo "If master layout resets, this confirms issue #2"

echo ""

# Test 6: Check daemon logs for errors
echo "=== TEST 6: Daemon Log Analysis ==="
echo "Checking daemon logs for any errors or debug info..."

if [[ -f ~/.config/window-positioning/daemon.log ]]; then
    echo "Recent daemon log entries:"
    tail -20 ~/.config/window-positioning/daemon.log
else
    echo "No daemon log found"
fi

echo ""
echo "=== DAEMON CYCLE DEBUG COMPLETE ==="
echo "Log saved to: $LOG_FILE"
echo ""
echo "KEY FINDINGS:"
echo "1. First cycle: Should work (IPC functioning)"  
echo "2. Second cycle: Check if still fails"
echo "3. Master reset: Check if layout reapplication loses window order"
echo "4. Daemon logs: Any errors in daemon process"
echo ""
echo "This will identify exactly where the window list persistence breaks down"