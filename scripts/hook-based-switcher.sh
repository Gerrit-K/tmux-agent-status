#!/usr/bin/env bash

# Hook-based window switcher that reads status from files
# Tracks agent status per-window (not per-session) to support
# multiple Claude instances within a single tmux session.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
# shellcheck source=lib/agent-processes.sh
source "$SCRIPT_DIR/lib/agent-processes.sh"

# Function to check if session is SSH by examining panes
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
    local session="$2"

    if [ -f "$PARKED_DIR/${status_key}.parked" ]; then
        echo "parked"
        return
    fi

    local remote_status="$STATUS_DIR/${status_key}-remote.status"
    if [ -f "$remote_status" ] && is_ssh_session "$session"; then
        cat "$remote_status" 2>/dev/null
        return
    elif [ -f "$remote_status" ] && ! is_ssh_session "$session"; then
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

# Get all windows with formatted output
get_windows_with_status() {
    local working_entries=()
    local done_entries=()
    local wait_entries=()
    local parked_entries=()
    local no_agent_entries=()

    # Get current active window for marking
    local current_target
    current_target=$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null)

    while IFS=$'\t' read -r session window pane_path; do
        [ -z "$session" ] && continue

        local status_key="${session}_w${window}"
        local target="${session}:${window}"
        local dir_name
        dir_name=$(basename "$pane_path" 2>/dev/null)

        local active_indicator=""
        if [ "$target" = "$current_target" ]; then
            active_indicator="(active)"
        fi

        local ssh_indicator=""
        if is_ssh_session "$session"; then
            ssh_indicator="[ssh]"
        fi

        local agent_status
        agent_status=$(get_agent_status "$status_key" "$session")
        local has_agent=false

        if window_has_agent_process "$session" "$window"; then
            has_agent=true
        elif [ "$agent_status" = "parked" ]; then
            has_agent=true
        elif [ -n "$agent_status" ] && is_ssh_session "$session"; then
            has_agent=true
        else
            if [ -n "$agent_status" ] && ! is_ssh_session "$session"; then
                rm -f "$STATUS_DIR/${status_key}.status" 2>/dev/null
            fi
        fi

        local formatted_line=""

        if [ "$has_agent" = true ]; then
            [ -z "$agent_status" ] && agent_status="done"

            if [ "$agent_status" = "working" ]; then
                formatted_line=$(printf "%-6s %-22s %-10s %s [working]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
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
                formatted_line=$(printf "%-6s %-22s %-10s %s [wait] %s" "$target" "$dir_name" "$active_indicator" "$ssh_indicator" "$wait_info")
                wait_entries+=("$formatted_line")
            elif [ "$agent_status" = "parked" ]; then
                formatted_line=$(printf "%-6s %-22s %-10s %s [parked]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
                parked_entries+=("$formatted_line")
            else
                formatted_line=$(printf "%-6s %-22s %-10s %s [done]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
                done_entries+=("$formatted_line")
            fi
        else
            formatted_line=$(printf "%-6s %-22s %-10s %s [no agent]" "$target" "$dir_name" "$active_indicator" "$ssh_indicator")
            no_agent_entries+=("$formatted_line")
        fi
    done < <(tmux list-windows -a -F "#{session_name}	#{window_index}	#{pane_current_path}" 2>/dev/null || echo "")

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

    if [ ${#no_agent_entries[@]} -gt 0 ]; then
        [ ${#working_entries[@]} -gt 0 ] || [ ${#done_entries[@]} -gt 0 ] || [ ${#wait_entries[@]} -gt 0 ] || [ ${#parked_entries[@]} -gt 0 ] && echo
        echo -e "\033[1;90m NO AGENT \033[0m"
        printf '%s\n' "${no_agent_entries[@]}"
    fi
}

# Handle --no-fzf flag for daemon refresh
if [ "$1" = "--no-fzf" ]; then
    get_windows_with_status
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

        # Check if agent is running: parse window key or fall back to session
        local has_agent=false
        if [[ "$key" =~ ^(.+)_w([0-9]+)$ ]]; then
            local session="${BASH_REMATCH[1]}"
            local window="${BASH_REMATCH[2]}"
            window_has_agent_process "$session" "$window" && has_agent=true
        else
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
    get_windows_with_status
    exit 0
fi

# Main
sessions_with_reminder=$(echo -e "$(get_windows_with_status)\n\n\033[1;36m Hit Ctrl-R to clear stale caches and refresh! \033[0m")

selected=$(echo "$sessions_with_reminder" | fzf \
    --ansi \
    --no-sort \
    --header="Windows grouped by agent status | j/k: navigate | Enter: select | Esc: cancel | Ctrl-R: clear stale caches" \
    --preview 'if echo {} | grep -q "━━━\|───"; then echo "Category separator"; else target=$(echo {} | awk "{print \$1}"); tmux capture-pane -pJ -t "$target" 2>/dev/null | cat -s || echo "No preview available"; fi' \
    --preview-window=right:40% \
    --prompt="Window> " \
    --bind="j:down,k:up,ctrl-j:preview-down,ctrl-k:preview-up" \
    --bind="ctrl-r:reload(bash '$0' --reset)" \
    --layout=reverse \
    --info=inline)

# Switch to selected window
if [ -n "$selected" ] && ! echo "$selected" | grep -q "━━━\|───"; then
    target=$(echo "$selected" | awk '{print $1}')
    tmux switch-client -t "$target"
fi
