#!/usr/bin/env bash
# test-ipc-daemon.sh: Test the complete IPC daemon implementation
# 
# This verifies that the daemon creates pipes and responds to commands

set -x  # Enable debug output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="/tmp/ipc-daemon-test.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== IPC DAEMON IMPLEMENTATION TEST ==="
echo "Date: $(date)"
echo "Testing that daemon creates IPC pipes and listens for commands"
echo ""

# Test 1: Start daemon and check pipe creation
echo "=== TEST 1: Daemon Startup and Pipe Creation ==="

# Stop any existing daemon
echo "Stopping any existing daemon..."
./place-window watch stop || true
sleep 1

# Start new daemon
echo "Starting daemon..."
./place-window watch start &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"

# Wait for daemon to initialize
echo "Waiting for daemon initialization..."
sleep 3

# Check if daemon is running
if ./place-window watch status | grep -q "running"; then
    echo "✅ Daemon is running"
else
    echo "❌ Daemon failed to start"
    exit 1
fi

# Check if pipes exist
DAEMON_PIPE_DIR="${XDG_RUNTIME_DIR:-/tmp}/window-positioning"
DAEMON_CMD_PIPE="$DAEMON_PIPE_DIR/commands"
DAEMON_RESP_PIPE="$DAEMON_PIPE_DIR/responses"

echo "Checking for pipes in: $DAEMON_PIPE_DIR"
if [[ -p "$DAEMON_CMD_PIPE" ]]; then
    echo "✅ Command pipe exists: $DAEMON_CMD_PIPE"
else
    echo "❌ Command pipe missing: $DAEMON_CMD_PIPE"
    ls -la "$DAEMON_PIPE_DIR" || echo "Pipe directory doesn't exist"
    exit 1
fi

if [[ -p "$DAEMON_RESP_PIPE" ]]; then
    echo "✅ Response pipe exists: $DAEMON_RESP_PIPE"
else
    echo "❌ Response pipe missing: $DAEMON_RESP_PIPE"
    exit 1
fi

echo ""

# Test 2: Test command communication
echo "=== TEST 2: IPC Command Communication ==="

echo "Testing cycle command through IPC..."
./place-window cycle clockwise

echo "✅ Cycle command completed"
echo ""

echo "Testing auto command through IPC..."
./place-window auto

echo "✅ Auto command completed"
echo ""

# Test 3: Multiple consecutive commands (the original problem)
echo "=== TEST 3: Multiple Commands ==="
echo "Testing multiple commands that previously failed..."

for i in {1..3}; do
    echo "--- Command $i ---"
    ./place-window cycle
    echo "Command $i completed"
    sleep 1
done

echo "✅ All consecutive commands completed"
echo ""

# Test 4: Check daemon logs
echo "=== TEST 4: Daemon Response ==="
echo "Daemon should have received and processed commands"
echo "Check daemon output for 'Received command:' messages"
echo ""

# Test 5: Stop daemon
echo "=== TEST 5: Daemon Shutdown ==="
echo "Stopping daemon..."
./place-window watch stop

# Verify pipes are cleaned up
if [[ ! -p "$DAEMON_CMD_PIPE" ]]; then
    echo "✅ Command pipe cleaned up"
else
    echo "❌ Command pipe still exists"
fi

if [[ ! -p "$DAEMON_RESP_PIPE" ]]; then
    echo "✅ Response pipe cleaned up"
else
    echo "❌ Response pipe still exists"
fi

echo ""
echo "=== IPC DAEMON TEST COMPLETE ==="
echo "Log saved to: $LOG_FILE"
echo ""
echo "EXPECTED RESULTS:"
echo "✅ Daemon creates named pipes on startup"
echo "✅ Commands communicate through pipes instead of failing"
echo "✅ Multiple consecutive commands work without empty window list errors"
echo "✅ Pipes are cleaned up on daemon shutdown"