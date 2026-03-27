#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux pane status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
mkdir -p "$STATUS_DIR"

# Read JSON from stdin (required by Claude Code hooks)
JSON_INPUT=$(cat)

# Get tmux session if in tmux OR if we're in an SSH session
if [ -n "$TMUX" ] || [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    # Try to get session name via tmux command first
    TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)

    # If that fails (e.g., when called from Claude hooks or over SSH)
    if [ -z "$TMUX_SESSION" ]; then
        # For SSH sessions, try to auto-detect session name from the SSH connection
        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
            case $(hostname -s) in
                instance-*) TMUX_SESSION="reachgpu" ;;
                keen-schrodinger) TMUX_SESSION="sd1" ;;
                sam-l4-workstation-image) TMUX_SESSION="l4-workstation" ;;
                persistent-faraday) TMUX_SESSION="tig" ;;
                instance-20250620-122051) TMUX_SESSION="reachgpu" ;;
                *) TMUX_SESSION=$(hostname -s) ;;
            esac
        else
            SOCKET_PATH=$(echo "$TMUX" | cut -d',' -f1)
            TMUX_SESSION=$(basename "$SOCKET_PATH")
        fi
    fi

    if [ -n "$TMUX_SESSION" ]; then
        # Get pane ID for pane-level tracking
        if [ -n "$TMUX_PANE" ]; then
            STATUS_KEY="p${TMUX_PANE#%}"
        else
            PANE_ID=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
            if [ -n "$PANE_ID" ]; then
                STATUS_KEY="p${PANE_ID#%}"
            else
                # SSH fallback: use session name
                STATUS_KEY="${TMUX_SESSION}"
            fi
        fi

        HOOK_TYPE="$1"
        STATUS_FILE="$STATUS_DIR/${STATUS_KEY}.status"
        REMOTE_STATUS_FILE="$STATUS_DIR/${STATUS_KEY}-remote.status"
        WAIT_FILE="$STATUS_DIR/wait/${STATUS_KEY}.wait"
        PARKED_FILE="$STATUS_DIR/parked/${STATUS_KEY}.parked"

        set_status() {
            local status="$1"
            echo "$status" > "$STATUS_FILE"
            if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                echo "$status" > "$REMOTE_STATUS_FILE" 2>/dev/null
            fi
        }

        case "$HOOK_TYPE" in
            "UserPromptSubmit"|"PreToolUse")
                # User submitted a prompt or Claude is calling a tool - cancel wait mode if active
                if [ -f "$WAIT_FILE" ]; then
                    rm -f "$WAIT_FILE"
                fi
                if [ -f "$PARKED_FILE" ]; then
                    rm -f "$PARKED_FILE"
                fi
                set_status "working"
                ;;
            "PermissionRequest")
                # Claude is showing a permission dialog — needs user approval
                set_status "input"
                ;;
            "Stop")
                # Claude has finished responding
                set_status "done"
                ;;
            "Notification")
                # Claude is waiting for user input — don't overwrite "input"
                current=$(cat "$STATUS_FILE" 2>/dev/null)
                if [ "$current" != "input" ]; then
                    set_status "done"
                fi
                # Play notification sound when Claude finishes
                SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0
