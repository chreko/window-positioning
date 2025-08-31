#!/usr/bin/env bash
# debug-daemon-startup.sh: Debug what happens during daemon startup
# 
# This will trace exactly what functions are being called and where it fails

set -x  # Enable debug output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="/tmp/debug-daemon-startup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== DAEMON STARTUP DEBUG ==="
echo "Date: $(date)"
echo "Debugging why IPC pipes are not being created"
echo ""

# Test 1: Check what function is actually called
echo "=== TEST 1: Function Routing Check ==="

# Source all libraries to check function definitions
source lib/config.sh
source lib/monitors.sh
source lib/windows.sh
source lib/layouts.sh
source lib/daemon.sh
source lib/interactive.sh
source lib/advanced.sh

echo "Checking which daemon functions exist:"
if declare -f watch_daemon >/dev/null; then
    echo "✅ watch_daemon function exists"
else
    echo "❌ watch_daemon function missing"
fi

if declare -f watch_daemon_internal >/dev/null; then
    echo "✅ watch_daemon_internal function exists" 
else
    echo "❌ watch_daemon_internal function missing"
fi

if declare -f setup_daemon_ipc >/dev/null; then
    echo "✅ setup_daemon_ipc function exists"
else
    echo "❌ setup_daemon_ipc function missing"
fi

echo ""

# Test 2: Test setup_daemon_ipc directly
echo "=== TEST 2: Direct IPC Setup Test ==="

echo "Testing setup_daemon_ipc function directly..."
init_config
load_config

echo "Calling setup_daemon_ipc..."
if setup_daemon_ipc; then
    echo "✅ setup_daemon_ipc completed successfully"
    
    # Check if pipes were created
    DAEMON_PIPE_DIR="${XDG_RUNTIME_DIR:-/tmp}/window-positioning"
    DAEMON_CMD_PIPE="$DAEMON_PIPE_DIR/commands"
    DAEMON_RESP_PIPE="$DAEMON_PIPE_DIR/responses"
    
    if [[ -p "$DAEMON_CMD_PIPE" ]]; then
        echo "✅ Command pipe created: $DAEMON_CMD_PIPE"
    else
        echo "❌ Command pipe missing after setup"
    fi
    
    if [[ -p "$DAEMON_RESP_PIPE" ]]; then
        echo "✅ Response pipe created: $DAEMON_RESP_PIPE"
    else
        echo "❌ Response pipe missing after setup"
    fi
    
    # Clean up test pipes
    cleanup_daemon_ipc
    
else
    echo "❌ setup_daemon_ipc failed"
fi

echo ""

# Test 3: Test watch_daemon function step by step
echo "=== TEST 3: watch_daemon Function Test ==="

# Create a simple test version
echo "Testing watch_daemon components..."

echo "Step 1: Calling setup_daemon_ipc again..."
setup_daemon_ipc

echo "Step 2: Check if pipes exist before daemon loop..."
if [[ -p "$DAEMON_CMD_PIPE" && -p "$DAEMON_RESP_PIPE" ]]; then
    echo "✅ Pipes created successfully"
    echo "Command pipe: $DAEMON_CMD_PIPE"
    echo "Response pipe: $DAEMON_RESP_PIPE"
else
    echo "❌ Pipes not created properly"
    ls -la "$DAEMON_PIPE_DIR" 2>/dev/null || echo "Directory doesn't exist"
fi

echo "Step 3: Clean up..."
cleanup_daemon_ipc

echo ""
echo "=== DAEMON STARTUP DEBUG COMPLETE ==="
echo "Log saved to: $LOG_FILE"
echo ""
echo "This debug shows:"
echo "1. Which daemon functions exist"
echo "2. Whether setup_daemon_ipc works in isolation"
echo "3. Step-by-step daemon startup process"