#!/usr/bin/env bash

# Put current window in wait mode with a timer

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

# Get current session and window
current_session=$(tmux display-message -p "#{session_name}")
current_window=$(tmux display-message -p "#{window_index}")
status_key="${current_session}_w${current_window}"

# Check if session is SSH
is_ssh_session() {
    local session="$1"
    if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
        return 0
    fi
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if window has an agent or is SSH session
if ! window_has_agent_process "$current_session" "$current_window" && ! is_ssh_session "$current_session"; then
    # Also check if window has a status file (might be from a finished agent)
    if [ ! -f "$STATUS_DIR/${status_key}.status" ] && [ ! -f "$STATUS_DIR/${status_key}-remote.status" ]; then
        tmux display-message "Window ${current_session}:${current_window} has no agent running"
        exit 1
    fi
fi

# Prompt for wait time using command-prompt
# This will call our handler script with the session, window, and wait time
tmux command-prompt -p "Wait time in minutes:" "run-shell '$SCRIPT_DIR/wait-session-handler.sh \"$current_session\" \"$current_window\" %1'"
