#!/usr/bin/env bash

# Park the current pane so it stays in the switcher but drops out of the toolbar.

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
mkdir -p "$PARKED_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

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

if ! pane_has_agent_process "$current_pane_pid" && ! is_ssh_pane "$current_pane_cmd" "$current_session"; then
    if [ ! -f "$STATUS_DIR/${status_key}.status" ] && [ ! -f "$STATUS_DIR/${status_key}-remote.status" ]; then
        tmux display-message "Pane $target has no agent state to park"
        exit 1
    fi
fi

rm -f "$WAIT_DIR/${status_key}.wait"
: > "$PARKED_DIR/${status_key}.parked"

if is_ssh_pane "$current_pane_cmd" "$current_session"; then
    echo "parked" > "$STATUS_DIR/${status_key}-remote.status"
else
    echo "parked" > "$STATUS_DIR/${status_key}.status"
fi

NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"
if [ -f "$NEXT_DONE_SCRIPT" ]; then
    if ! bash "$NEXT_DONE_SCRIPT" "$target" 2>/dev/null; then
        tmux display-message "Pane $target parked for later"
    fi
else
    tmux display-message "Pane $target parked for later"
fi
