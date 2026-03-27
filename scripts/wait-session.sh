#!/usr/bin/env bash

# Put current pane in wait mode with a timer

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

# Get current pane info
current_pane_id=$(tmux display-message -p "#{pane_id}")
current_pane_pid=$(tmux display-message -p "#{pane_pid}")
current_session=$(tmux display-message -p "#{session_name}")
current_pane_cmd=$(tmux display-message -p "#{pane_current_command}")
status_key="p${current_pane_id#%}"
target=$(tmux display-message -p "#{session_name}:#{window_index}.#{pane_index}")

is_ssh_pane() {
    local pane_cmd="$1"
    local session="$2"
    if [ "$pane_cmd" = "ssh" ]; then
        return 0
    fi
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if pane has an agent or is SSH
if ! pane_has_agent_process "$current_pane_pid" && ! is_ssh_pane "$current_pane_cmd" "$current_session"; then
    if [ ! -f "$STATUS_DIR/${status_key}.status" ] && [ ! -f "$STATUS_DIR/${status_key}-remote.status" ]; then
        tmux display-message "Pane $target has no agent running"
        exit 1
    fi
fi

# Prompt for wait time using command-prompt
tmux command-prompt -p "Wait time in minutes:" "run-shell '$SCRIPT_DIR/wait-session-handler.sh \"$status_key\" \"$target\" \"$current_pane_cmd\" \"$current_session\" %1'"
