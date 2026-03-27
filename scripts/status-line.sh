#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows agent status across all windows (not just sessions)

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
LAST_STATUS_FILE="$STATUS_DIR/.last-status-summary"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

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

# Check and expire wait timers
check_wait_timers() {
    local wait_dir="$STATUS_DIR/wait"
    [ ! -d "$wait_dir" ] && return
    local current_time=$(date +%s)
    for wait_file in "$wait_dir"/*.wait; do
        [ ! -f "$wait_file" ] && continue
        local key=$(basename "$wait_file" .wait)
        local expiry_time=$(cat "$wait_file" 2>/dev/null)
        if [ -n "$expiry_time" ] && [ "$current_time" -ge "$expiry_time" ]; then
            echo "done" > "$STATUS_DIR/${key}.status" 2>/dev/null
            [ -f "$STATUS_DIR/${key}-remote.status" ] && echo "done" > "$STATUS_DIR/${key}-remote.status" 2>/dev/null
            rm -f "$wait_file"
        fi
    done
}

normalize_local_wait_status() {
    local key="$1"
    local status_file="$STATUS_DIR/${key}.status"
    local wait_file="$STATUS_DIR/wait/${key}.wait"

    [ ! -f "$status_file" ] && return

    local status
    status=$(cat "$status_file" 2>/dev/null || echo "")
    if [ "$status" = "wait" ] && [ ! -f "$wait_file" ]; then
        echo "done" > "$status_file" 2>/dev/null
    fi
}

# Check for agent processes (Codex) via process polling
find_window_codex_pid() {
    find_window_agent_pid "$1" "$2" "codex"
}

get_deepest_codex_pid() {
    local codex_pid="$1"
    local child_codex_pid=""

    while :; do
        child_codex_pid=$(pgrep -P "$codex_pid" -f "codex" 2>/dev/null | head -1)
        [ -z "$child_codex_pid" ] && break
        codex_pid="$child_codex_pid"
    done

    echo "$codex_pid"
}

codex_session_is_working() {
    local codex_pid="$1"
    [ -z "$codex_pid" ] && return 1

    local worker_pid
    worker_pid=$(get_deepest_codex_pid "$codex_pid")
    [ -z "$worker_pid" ] && return 1

    pgrep -P "$worker_pid" >/dev/null 2>&1
}

check_agent_processes() {
    while IFS=: read -r session window; do
        [ -z "$session" ] && continue
        local status_key="${session}_w${window}"
        local status_file="$STATUS_DIR/${status_key}.status"
        local wait_file="$STATUS_DIR/wait/${status_key}.wait"
        local parked_file="$PARKED_DIR/${status_key}.parked"
        local codex_pid=""

        codex_pid=$(find_window_codex_pid "$session" "$window" 2>/dev/null)

        if [ -n "$codex_pid" ]; then
            local current_status
            if [ -f "$parked_file" ]; then
                current_status="parked"
            else
                current_status=$(cat "$status_file" 2>/dev/null)
            fi
            if [ -z "$current_status" ]; then
                echo "working" > "$status_file"
            elif codex_session_is_working "$codex_pid"; then
                case "$current_status" in
                    "done")
                        echo "working" > "$status_file"
                        ;;
                    "wait")
                        rm -f "$wait_file"
                        echo "working" > "$status_file"
                        ;;
                    "parked")
                        rm -f "$parked_file"
                        echo "working" > "$status_file"
                        ;;
                esac
            fi
        fi
    done < <(tmux list-windows -a -F "#{session_name}:#{window_index}" 2>/dev/null)
}

check_wait_timers
check_agent_processes

# Count agent windows by status
count_agent_status() {
    local working=0
    local waiting=0
    local done=0
    local total_agents=0

    while IFS=: read -r session window; do
        [ -z "$session" ] && continue

        local status_key="${session}_w${window}"
        local parked_file="$PARKED_DIR/${status_key}.parked"
        if [ -f "$parked_file" ]; then
            continue
        fi

        local remote_status_file="$STATUS_DIR/${status_key}-remote.status"
        local status_file="$STATUS_DIR/${status_key}.status"

        if [ -f "$remote_status_file" ] && is_ssh_session "$session"; then
            local status=$(cat "$remote_status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                case "$status" in
                    "working") ((working++)); ((total_agents++)) ;;
                    "done") ((done++)); ((total_agents++)) ;;
                    "wait") ((waiting++)); ((total_agents++)) ;;
                esac
            fi
        elif [ -f "$remote_status_file" ] && ! is_ssh_session "$session"; then
            rm -f "$remote_status_file" 2>/dev/null
            normalize_local_wait_status "$status_key"
            if [ -f "$status_file" ]; then
                local status=$(cat "$status_file" 2>/dev/null)
                if [ -n "$status" ]; then
                    case "$status" in
                        "working") ((working++)); ((total_agents++)) ;;
                        "done") ((done++)); ((total_agents++)) ;;
                        "wait") ((waiting++)); ((total_agents++)) ;;
                    esac
                fi
            fi
        elif [ -f "$status_file" ]; then
            normalize_local_wait_status "$status_key"
            local status=$(cat "$status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                case "$status" in
                    "working") ((working++)); ((total_agents++)) ;;
                    "done") ((done++)); ((total_agents++)) ;;
                    "wait") ((waiting++)); ((total_agents++)) ;;
                esac
            fi
        fi
    done < <(tmux list-windows -a -F "#{session_name}:#{window_index}" 2>/dev/null)

    echo "$working:$waiting:$done:$total_agents"
}

# Play notification sound
play_notification() {
    "$SCRIPT_DIR/play-sound.sh" &
}

# Get current status
IFS=':' read -r working waiting done total_agents <<< "$(count_agent_status)"

# Load previous status
prev_done=""
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_status=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "")
    if [[ "$prev_status" == *:* ]]; then
        IFS=':' read -r _ _ prev_done <<< "$prev_status"
    fi
fi

# Save current status counts
echo "$working:$waiting:$done" > "$LAST_STATUS_FILE"

# Check if any agent just finished (done count increased)
if [ -n "$prev_done" ] && [ "$done" -gt "$prev_done" ]; then
    play_notification
fi

format_working_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ agent working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $count working#[default]"
    fi
}

format_waiting_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=cyan,bold]⏸ 1 waiting#[default]"
    else
        echo "#[fg=cyan,bold]⏸ $count waiting#[default]"
    fi
}

format_done_segment() {
    local count="$1"
    echo "#[fg=green]✓ $count done#[default]"
}

# Generate status line output
if [ "$total_agents" -eq 0 ]; then
    echo ""
elif [ "$working" -eq 0 ] && [ "$waiting" -eq 0 ] && [ "$done" -gt 0 ]; then
    echo "#[fg=green,bold]✓ All agents ready#[default]"
else
    segments=()
    [ "$working" -gt 0 ] && segments+=("$(format_working_segment "$working")")
    [ "$waiting" -gt 0 ] && segments+=("$(format_waiting_segment "$waiting")")
    [ "$done" -gt 0 ] && segments+=("$(format_done_segment "$done")")
    printf '%s\n' "${segments[*]}"
fi
