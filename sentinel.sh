#!/bin/bash
set -euo pipefail

SYSTEM_CONFIG_FILE="/etc/resource-sentinel/config.yaml"
USER_CONFIG_DIR="$HOME/.config/resource-sentinel"
USER_CONFIG_FILE="$USER_CONFIG_DIR/config.yaml"
LOG_FILE="/var/log/resource-sentinel/monitor.log"
HOST_OS="$(uname -s)"

if [[ -f "$USER_CONFIG_FILE" ]]; then
    CONFIG_FILE="$USER_CONFIG_FILE"
elif [[ -f "$SYSTEM_CONFIG_FILE" ]]; then
    CONFIG_FILE="$SYSTEM_CONFIG_FILE"
else
    echo "Configuration file not found." >&2
    exit 1
fi

DURATION=$(yq e '.monitoring.duration' "$CONFIG_FILE")
INTERVAL=$(yq e '.monitoring.interval' "$CONFIG_FILE")
CPU_THRESHOLD=$(yq e '.monitoring.cpu_threshold' "$CONFIG_FILE")
RAM_THRESHOLD=$(yq e '.monitoring.ram_threshold' "$CONFIG_FILE")
MAX_ALERTS=$(yq e '.monitoring.max_alerts_per_process' "$CONFIG_FILE")
IGNORE_LIST=($(yq e '.ignore.processes[]' "$CONFIG_FILE"))
RESP_TIMEOUT=$(yq e '.notifications.response_timeout' "$CONFIG_FILE")
REMINDER_DELAY=$(yq e '.notifications.reminder_delay' "$CONFIG_FILE")
DISCORD_ENABLED=$(yq e '.notifications.discord.enabled' "$CONFIG_FILE")
DISCORD_WEBHOOK_URL=$(yq e '.notifications.discord.webhook_url' "$CONFIG_FILE")

declare -A ALERT_COUNT
declare -A IGNORE_PIDS

log() {
    echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

should_ignore() {
    local name="$1"
    for pattern in "${IGNORE_LIST[@]}"; do
        if [[ "$name" == "$pattern" ]]; then
            return 0
        fi
    done
    return 1
}

while [ "$(date +%s)" -lt "$(( $(date +%s) + DURATION ))" ]; do
    while read -r pid comm cpu mem; do
        [[ "$pid" == "PID" ]] && continue

        if should_ignore "$comm"; then
            continue
        fi
        [[ ${IGNORE_PIDS[$pid]+_} ]] && continue

        cpu_int=${cpu%.*}
        mem_int=${mem%.*}

        if (( cpu_int > CPU_THRESHOLD || mem_int > RAM_THRESHOLD )); then
            count=${ALERT_COUNT[$pid]:-0}
            if (( count >= MAX_ALERTS )); then
                continue
            fi

            ALERT_COUNT[$pid]=$((count+1))
            log "High usage detected: $comm (PID $pid) CPU: $cpu% MEM: $mem%"

            if [[ "$DISCORD_ENABLED" == "true" && -n "$DISCORD_WEBHOOK_URL" ]]; then
                /usr/local/bin/notifier.sh "discord" "$pid" "$comm" "$cpu" "$mem" "$DISCORD_WEBHOOK_URL" &
            fi

            response=$(/usr/local/bin/notifier.sh "native" "$pid" "$comm" "$cpu" "$mem")
            log "User responded: $response for PID $pid ($comm)"

            case "$response" in
                kill)
                    if kill -9 "$pid" 2>/dev/null; then
                        log "Killed $comm (PID $pid)"
                    else
                        log "Failed to kill $comm (PID $pid)"
                    fi
                    ;;
                ignore)
                    IGNORE_PIDS[$pid]=1
                    ;;
                remind)
                    sleep "$REMINDER_DELAY"
                    ;;
            esac
        fi
    done < <(ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 20)
    sleep "$INTERVAL"
done
log "Monitoring session ended."
