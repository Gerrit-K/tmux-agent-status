#!/usr/bin/env bash

# Hook-based pane switcher that reads status from files
# Tracks agent status per-pane. Only shows panes with an agent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
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
    local status_key="$1"
    local pane_cmd="$2"
    local session="$3"

    if [ -f "$PARKED_DIR/${status_key}.parked" ]; then
        echo "parked"
        return
    fi

    local remote_status="$STATUS_DIR/${status_key}-remote.status"
    if [ -f "$remote_status" ] && is_ssh_pane "$pane_cmd" "$session"; then
        cat "$remote_status" 2>/dev/null
        return
    elif [ -f "$remote_status" ] && ! is_ssh_pane "$pane_cmd" "$session"; then
        rm -f "$remote_status" 2>/dev/null
    fi

    local status_file="$STATUS_DIR/${status_key}.status"
    if [ -f "$status_file" ]; then
        normalize_local_wait_status "$status_key"
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get all agent panes with formatted output
get_panes_with_status() {
    local working_entries=()
    local done_entries=()
    local wait_entries=()
    local parked_entries=()

    # Get current active pane for marking
    local current_pane_id
    current_pane_id=$(tmux display-message -p '#{pane_id}' 2>/dev/null)

    while IFS=$'\t' read -r pane_id pane_pid session window pane_idx pane_path pane_cmd; do
        [ -z "$pane_id" ] && continue

        local status_key="p${pane_id#%}"
        local target="${session}:${window}.${pane_idx}"
        local dir_name
        dir_name=$(basename "$pane_path" 2>/dev/null)

        local agent_status
        agent_status=$(get_agent_status "$status_key" "$pane_cmd" "$session")
        local has_agent=false

        if pane_has_agent_process "$pane_pid"; then
            has_agent=true
        elif [ "$agent_status" = "parked" ]; then
            has_agent=true
        elif [ -n "$agent_status" ] && is_ssh_pane "$pane_cmd" "$session"; then
            has_agent=true
        elif [ -n "$agent_status" ]; then
            # Has a status file but no running process — check if it's a finished agent
            has_agent=true
        fi

        # Only show panes with agents
        [ "$has_agent" = false ] && continue

        local active_indicator=""
        if [ "$pane_id" = "$current_pane_id" ]; then
            active_indicator="(active)"
        fi

        local ssh_indicator=""
        if is_ssh_pane "$pane_cmd" "$session"; then
            ssh_indicator="[ssh]"
        fi

        [ -z "$agent_status" ] && agent_status="done"

        local formatted_line=""

        if [ "$agent_status" = "working" ]; then
            formatted_line=$(printf "%-8s %-22s %-10s %s [working]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
            working_entries+=("$formatted_line")
        elif [ "$agent_status" = "wait" ]; then
            local wait_file="$STATUS_DIR/wait/${status_key}.wait"
            local wait_info=""
            if [ -f "$wait_file" ]; then
                local expiry_time=$(cat "$wait_file" 2>/dev/null)
                local current_time=$(date +%s)
                local remaining=$(( expiry_time - current_time ))
                if [ "$remaining" -gt 0 ]; then
                    local remaining_minutes=$(( remaining / 60 ))
                    wait_info="(${remaining_minutes}m)"
                fi
            fi
            formatted_line=$(printf "%-8s %-22s %-10s %s [wait] %s" "$target" "$dir_name" "$active_indicator" "$ssh_indicator" "$wait_info")
            wait_entries+=("$formatted_line")
        elif [ "$agent_status" = "parked" ]; then
            formatted_line=$(printf "%-8s %-22s %-10s %s [parked]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
            parked_entries+=("$formatted_line")
        else
            formatted_line=$(printf "%-8s %-22s %-10s %s [done]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
            done_entries+=("$formatted_line")
        fi
    done < <(tmux list-panes -a -F "#{pane_id}	#{pane_pid}	#{session_name}	#{window_index}	#{pane_index}	#{pane_current_path}	#{pane_current_command}" 2>/dev/null || echo "")

    # Output grouped entries with separators

    if [ ${#working_entries[@]} -gt 0 ]; then
        echo -e "\033[1;33m WORKING \033[0m"
        printf '%s\n' "${working_entries[@]}"
    fi

    if [ ${#done_entries[@]} -gt 0 ]; then
        [ ${#working_entries[@]} -gt 0 ] && echo
        echo -e "\033[1;32m DONE \033[0m"
        printf '%s\n' "${done_entries[@]}"
    fi

    if [ ${#wait_entries[@]} -gt 0 ]; then
        [ ${#working_entries[@]} -gt 0 ] || [ ${#done_entries[@]} -gt 0 ] && echo
        echo -e "\033[1;36m WAIT \033[0m"
        printf '%s\n' "${wait_entries[@]}"
    fi

    if [ ${#parked_entries[@]} -gt 0 ]; then
        [ ${#working_entries[@]} -gt 0 ] || [ ${#done_entries[@]} -gt 0 ] || [ ${#wait_entries[@]} -gt 0 ] && echo
        echo -e "\033[1;35m PARKED \033[0m"
        printf '%s\n' "${parked_entries[@]}"
    fi
}

# Handle --no-fzf flag for daemon refresh
if [ "$1" = "--no-fzf" ]; then
    get_panes_with_status
    exit 0
fi

# Function to perform full reset
perform_full_reset() {
    pkill -f "daemon-monitor.sh" 2>/dev/null
    pkill -f "smart-monitor.sh" 2>/dev/null

    find "$STATUS_DIR" -type f -name "*.pid" -delete 2>/dev/null

    for wait_file in "$STATUS_DIR/wait"/*.wait; do
        [ ! -f "$wait_file" ] && continue
        key=$(basename "$wait_file" .wait)
        [ -f "$STATUS_DIR/${key}.status" ] && echo "done" > "$STATUS_DIR/${key}.status" 2>/dev/null
        [ -f "$STATUS_DIR/${key}-remote.status" ] && echo "done" > "$STATUS_DIR/${key}-remote.status" 2>/dev/null
        rm -f "$wait_file" 2>/dev/null
    done

    rm -f "$STATUS_DIR"/.*.status.tmp 2>/dev/null

    # Collect all live pane IDs
    local -A live_panes
    while IFS=$'\t' read -r pane_id pane_pid; do
        [ -z "$pane_id" ] && continue
        live_panes["p${pane_id#%}"]="$pane_pid"
    done < <(tmux list-panes -a -F "#{pane_id}	#{pane_pid}" 2>/dev/null)

    for status_file in "$STATUS_DIR"/*.status; do
        [ ! -f "$status_file" ] && continue

        local key
        key=$(basename "$status_file" .status)

        # Skip remote status files
        if [[ "$key" == *"-remote" ]]; then
            continue
        fi

        if [ -f "$STATUS_DIR/wait/${key}.wait" ]; then
            continue
        fi

        if [ -f "$PARKED_DIR/${key}.parked" ]; then
            continue
        fi

        local status_value
        status_value=$(cat "$status_file" 2>/dev/null)
        if [ "$status_value" = "wait" ]; then
            echo "done" > "$status_file" 2>/dev/null
        fi

        # Check if the pane still exists and has an agent
        local has_agent=false
        if [[ "$key" =~ ^p[0-9]+$ ]] && [ -n "${live_panes[$key]+x}" ]; then
            pane_has_agent_process "${live_panes[$key]}" && has_agent=true
        elif [[ "$key" =~ ^p[0-9]+$ ]]; then
            # Pane no longer exists
            has_agent=false
        else
            # Legacy session-level key
            session_has_agent_process "$key" && has_agent=true
        fi

        if [ "$has_agent" = false ]; then
            rm -f "$status_file"
        fi
    done

    "$SCRIPT_DIR/../smart-monitor.sh" stop >/dev/null 2>&1
    "$SCRIPT_DIR/../smart-monitor.sh" start >/dev/null 2>&1
    "$SCRIPT_DIR/daemon-monitor.sh" >/dev/null 2>&1 &
}

# Handle --reset flag for full reset
if [ "$1" = "--reset" ]; then
    perform_full_reset
    get_panes_with_status
    exit 0
fi

# Main
sessions_with_reminder=$(echo -e "$(get_panes_with_status)\n\n\033[1;36m Hit Ctrl-R to clear stale caches and refresh! \033[0m")

selected=$(echo "$sessions_with_reminder" | fzf \
    --ansi \
    --no-sort \
    --header="Agent panes grouped by status | j/k: navigate | Enter: select | Esc: cancel | Ctrl-R: clear stale caches" \
    --preview 'if echo {} | grep -q "━━━\|───"; then echo "Category separator"; else target=$(echo {} | awk "{print \$1}"); tmux capture-pane -epJ -t "$target" 2>/dev/null | cat -s || echo "No preview available"; fi' \
    --preview-window=right:40% \
    --prompt="Pane> " \
    --bind="j:down,k:up,ctrl-j:preview-down,ctrl-k:preview-up" \
    --bind="ctrl-r:reload(bash '$0' --reset)" \
    --layout=reverse \
    --info=inline)

# Switch to selected pane
if [ -n "$selected" ] && ! echo "$selected" | grep -q "━━━\|───"; then
    target=$(echo "$selected" | awk '{print $1}')
    tmux switch-client -t "$target"
fi
