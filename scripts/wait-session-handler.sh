#!/usr/bin/env bash

# Handler for wait session - called with session, window, and wait time as arguments

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
mkdir -p "$WAIT_DIR"

current_session="$1"
current_window="$2"
wait_minutes="$3"
status_key="${current_session}_w${current_window}"
target="${current_session}:${current_window}"

# Validate input
if ! [[ "$wait_minutes" =~ ^[0-9]+$ ]] || [ "$wait_minutes" -eq 0 ]; then
    tmux display-message "Invalid wait time: $wait_minutes"
    exit 1
fi

# Calculate expiry time
expiry_time=$(($(date +%s) + (wait_minutes * 60)))

# Create wait file with expiry time FIRST (before changing status)
echo "$expiry_time" > "$WAIT_DIR/${status_key}.wait"

# Small delay to ensure wait file is written
sync

# Wait mode overrides any parked marker.
rm -f "$PARKED_DIR/${status_key}.parked"

# Set window status to wait
# Check if it's an SSH session by looking for remote status file
if [ -f "$STATUS_DIR/${status_key}-remote.status" ]; then
    echo "wait" > "$STATUS_DIR/${status_key}-remote.status"
else
    echo "wait" > "$STATUS_DIR/${status_key}.status"
fi

tmux display-message "Window $target will wait for $wait_minutes minutes"

# Switch to next done window or show completion message
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"

if [ -f "$NEXT_DONE_SCRIPT" ]; then
    # Try to switch to next done window (excluding current target)
    if ! bash "$NEXT_DONE_SCRIPT" "$target" 2>/dev/null; then
        # No done windows available
        tmux display-message "All done! No more windows to work on."
    fi
else
    tmux display-message "Wait mode activated"
fi
