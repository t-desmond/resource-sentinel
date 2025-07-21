#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/resource-sentinel/config.yaml"
SERVICE_FILE="/etc/systemd/system/resource-sentinel.service"

# Color codes
RED='\033[0;31m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

log_step() {
  echo -e "${BLUE}[STEP]${NC} $1"
}
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

apply_settings() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file not found at $CONFIG_FILE"
    exit 1
  fi
  
  if [[ "$(uname)" != "Linux" ]]; then
    log_error "This command is only supported on Linux."
    exit 1
  fi

  DAEMON_ENABLED=$(yq e '.daemon.enabled' "$CONFIG_FILE")

  if [[ "$DAEMON_ENABLED" == "true" ]]; then
    log_info "Daemon is enabled in the configuration. Ensuring service is active."
    if [[ ! -f "$SERVICE_FILE" ]]; then
      log_step "Service file not found. Recreating..."
      # This assumes sentinel is in the same directory
      INSTALL_DIR=$(dirname "$(readlink -f "$0")")
      cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Resource Sentinel System Monitor
After=network.target
[Service]
ExecStart=$INSTALL_DIR/sentinel
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
    fi
    systemctl enable resource-sentinel.service --now
    log_info "Service is active. Use 'systemctl status resource-sentinel.service' to check."
  else
    log_info "Daemon is disabled in the configuration. Ensuring service is stopped and disabled."
    if [[ -f "$SERVICE_FILE" ]];
        systemctl disable resource-sentinel.service --now
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        log_step "Service file removed and systemd reloaded."
    else
        log_info "Service was not active. No changes made."
    fi
  fi
}

usage() {
  echo "Usage: $0 <command>"
  echo "Commands:"
  echo "  apply   - Apply the daemon settings from the configuration file."
}

if [[ "$#" -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  apply)
    apply_settings
    ;;
  *)
    log_error "Unknown command: $1"
    usage
    exit 1
    ;;
esac 