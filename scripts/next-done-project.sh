#!/usr/bin/env bash

# Find and switch to the next 'done' agent pane

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

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

get_agent_status() {
    local key="$1"
    local pane_cmd="$2"
    local session="$3"

    if [ -f "$PARKED_DIR/${key}.parked" ]; then
        echo "parked"
        return
    fi

    local remote_status="$STATUS_DIR/${key}-remote.status"
    if [ -f "$remote_status" ] && is_ssh_pane "$pane_cmd" "$session"; then
        cat "$remote_status" 2>/dev/null
        return
    elif [ -f "$remote_status" ] && ! is_ssh_pane "$pane_cmd" "$session"; then
        rm -f "$remote_status" 2>/dev/null
    fi

    local status_file="$STATUS_DIR/${key}.status"
    if [ -f "$status_file" ]; then
        normalize_local_wait_status "$key"
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get current pane target
current_target=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')

# Check if we're being called with a target to exclude (from wait-session-handler.sh or park-session.sh)
exclude_target="$1"

# Collect all done panes with their completion times
done_panes_with_times=()
while IFS=$'\t' read -r pane_id pane_pid session window pane_idx pane_cmd; do
    [ -z "$pane_id" ] && continue

    local_target="${session}:${window}.${pane_idx}"
    status_key="p${pane_id#%}"

    agent_status=$(get_agent_status "$status_key" "$pane_cmd" "$session")
    has_agent=false

    if pane_has_agent_process "$pane_pid"; then
        has_agent=true
    elif [ -n "$agent_status" ] && is_ssh_pane "$pane_cmd" "$session"; then
        has_agent=true
    elif [ -n "$agent_status" ]; then
        has_agent=true
    fi

    if [ "$has_agent" = true ]; then
        [ -z "$agent_status" ] && agent_status="done"

        if [ "$agent_status" = "done" ] && [ "$local_target" != "$exclude_target" ]; then
            status_file=""
            if is_ssh_pane "$pane_cmd" "$session"; then
                status_file="$STATUS_DIR/${status_key}-remote.status"
            else
                status_file="$STATUS_DIR/${status_key}.status"
            fi

            completion_time=0
            if [ -f "$status_file" ]; then
                completion_time=$(stat -c %Y "$status_file" 2>/dev/null || stat -f %m "$status_file" 2>/dev/null || echo 0)
            fi

            done_panes_with_times+=("$completion_time:$local_target")
        fi
    fi
done < <(tmux list-panes -a -F "#{pane_id}	#{pane_pid}	#{session_name}	#{window_index}	#{pane_index}	#{pane_current_command}" 2>/dev/null || echo "")

# Sort by completion time (most recent first) and extract targets
IFS=$'\n' sorted_targets=($(printf '%s\n' "${done_panes_with_times[@]}" | sort -t: -k1,1nr | cut -d: -f2-))
done_targets=("${sorted_targets[@]}")

# If no done panes, exit
if [ ${#done_targets[@]} -eq 0 ]; then
    tmux display-message "No done projects found"
    exit 1
fi

# Find current target index in done targets
current_index=-1
for i in "${!done_targets[@]}"; do
    if [ "${done_targets[$i]}" = "$current_target" ]; then
        current_index=$i
        break
    fi
done

# Calculate next index
if [ $current_index -eq -1 ]; then
    next_target="${done_targets[0]}"
else
    next_index=$(( (current_index + 1) % ${#done_targets[@]} ))
    next_target="${done_targets[$next_index]}"
fi

# Switch to the next done pane
tmux switch-client -t "$next_target"
tmux display-message "Switched to next done project: $next_target"
