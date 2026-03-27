#!/usr/bin/env bash

# Park the current window so it stays in the switcher but drops out of the toolbar.

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
mkdir -p "$PARKED_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

current_session=$(tmux display-message -p "#{session_name}")
current_window=$(tmux display-message -p "#{window_index}")
status_key="${current_session}_w${current_window}"
target="${current_session}:${current_window}"

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

if ! window_has_agent_process "$current_session" "$current_window" && ! is_ssh_session "$current_session"; then
    if [ ! -f "$STATUS_DIR/${status_key}.status" ] && [ ! -f "$STATUS_DIR/${status_key}-remote.status" ]; then
        tmux display-message "Window $target has no agent state to park"
        exit 1
    fi
fi

rm -f "$WAIT_DIR/${status_key}.wait"
: > "$PARKED_DIR/${status_key}.parked"

if is_ssh_session "$current_session"; then
    echo "parked" > "$STATUS_DIR/${status_key}-remote.status"
else
    echo "parked" > "$STATUS_DIR/${status_key}.status"
fi

NEXT_DONE_SCRIPT="$SCRIPT_DIR/next-done-project.sh"
if [ -f "$NEXT_DONE_SCRIPT" ]; then
    if ! bash "$NEXT_DONE_SCRIPT" "$target" 2>/dev/null; then
        tmux display-message "Window $target parked for later"
    fi
else
    tmux display-message "Window $target parked for later"
fi
