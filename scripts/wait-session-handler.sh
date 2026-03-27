#!/usr/bin/env bash

# Handler for wait pane - called with status key, target, pane cmd, session, and wait time

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
mkdir -p "$WAIT_DIR"

status_key="$1"
target="$2"
pane_cmd="$3"
session="$4"
wait_minutes="$5"

# Validate input
if ! [[ "$wait_minutes" =~ ^[0-9]+$ ]] || [ "$wait_minutes" -eq 0 ]; then
    tmux display-message "Invalid wait time: $wait_minutes"
    exit 1
fi

is_ssh_pane() {
    local cmd="$1"
    local sess="$2"
    if [ "$cmd" = "ssh" ]; then
        return 0
    fi
    case "$sess" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}

# Calculate expiry time
expiry_time=$(($(date +%s) + (wait_minutes * 60)))

# Create wait file with expiry time FIRST (before changing status)
echo "$expiry_time" > "$WAIT_DIR/${status_key}.wait"

# Small delay to ensure wait file is written
sync

# Wait mode overrides any parked marker.
rm -f "$PARKED_DIR/${status_key}.parked"

# Set pane status to wait
if [ -f "$STATUS_DIR/${status_key}-remote.status" ] && is_ssh_pane "$pane_cmd" "$session"; then
    echo "wait" > "$STATUS_DIR/${status_key}-remote.status"
else
    echo "wait" > "$STATUS_DIR/${status_key}.status"
fi

tmux display-message "Pane $target will wait for $wait_minutes minutes"

# Switch to next done pane or show completion message
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"

if [ -f "$NEXT_DONE_SCRIPT" ]; then
    if ! bash "$NEXT_DONE_SCRIPT" "$target" 2>/dev/null; then
        tmux display-message "All done! No more panes to work on."
    fi
else
    tmux display-message "Wait mode activated"
fi
