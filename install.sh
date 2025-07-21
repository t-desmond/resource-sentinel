#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/resource-sentinel"
LOG_DIR="/var/log/resource-sentinel"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/resource-sentinel.service"
LOG_FILE="$LOG_DIR/monitor.log"
TEMP_DIR="$(mktemp -d -t resource-sentinel-setup-XXXX)"
INSTALL_LOG="/tmp/resource-sentinel-install.log"

trap 'cleanup' ERR

cleanup() {
  echo "[ERROR] Installation failed. See $INSTALL_LOG"
  echo "[INFO] Cleaning up temp files..."
  rm -rf "$TEMP_DIR"
  exit 1
}

log() {
  echo "[$(date '+%F %T')] $1" | tee -a "$INSTALL_LOG"
}

log "Starting Resource Sentinel installation..."

# Check root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root or with sudo."
  exit 1
fi

# Dependency check and optional install
require_tools=( "yq" "curl" )
if [[ "$(uname)" == "Linux" ]]; then
  require_tools+=( "zenity" )
elif [[ "$(uname)" == "Darwin" ]]; then
  require_tools+=( "osascript" )
else
  log "Unsupported OS: $(uname)"
  exit 1
fi

for tool in "${require_tools[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    read -rp "$tool is not installed. Attempt to install it? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      log "Installing $tool..."
      if [[ "$(uname)" == "Linux" ]]; then
        apt update && apt install -y "$tool"
      elif [[ "$(uname)" == "Darwin" ]]; then
        if ! command -v brew &>/dev/null; then
          log "Homebrew not found. Please install Homebrew first."
          exit 1
        fi
        brew install "$tool"
      fi
    else
      log "User declined to install $tool"
      exit 1
    fi
  fi
  log "$tool is installed."
done

# Create directories
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
chmod 755 "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"

# Prompt config values with defaults
read -rp "Monitoring duration in minutes [30]: " DURATION
DURATION=${DURATION:-30}

read -rp "Processes to ignore (comma separated) [chrome,firefox]: " IGNORE
IGNORE=${IGNORE:-chrome,firefox}

# Create config.yaml content
cat > "$TEMP_DIR/config.yaml" <<EOF
monitoring:
  duration: $(( DURATION * 60 ))
  interval: 10
  cpu_threshold: 70
  ram_threshold: 500
  disk_threshold: 80
  max_alerts_per_process: 2

ignore:
  processes: [${IGNORE//,/\, }]

notifications:
  method: native
  response_timeout: 30
  reminder_delay: 60
EOF

# Copy scripts to install dir
cp sentinel.sh "$INSTALL_DIR/sentinel"
chmod +x "$INSTALL_DIR/sentinel"

cp utils/notifier.sh "$INSTALL_DIR/notifier.sh"
chmod +x "$INSTALL_DIR/notifier.sh"

# Copy config
cp "$TEMP_DIR/config.yaml" "$CONFIG_DIR/config.yaml"

log "Files copied and permissions set."

# Prompt for daemon install
read -rp "Install Resource Sentinel as a background service (daemon)? [Y/n]: " DAEMON_CHOICE
DAEMON_CHOICE=${DAEMON_CHOICE:-Y}

if [[ "$DAEMON_CHOICE" =~ ^[Yy]$ ]]; then
  if [[ "$(uname)" == "Linux" ]]; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Resource Sentinel System Monitor
After=network.target

[Service]
ExecStart=$INSTALL_DIR/sentinel
Restart=on-failure
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable resource-sentinel.service
    systemctl start resource-sentinel.service

    log "Daemon installed and started."
    echo "Use 'sudo systemctl status resource-sentinel.service' to check status."
  else
    echo "Daemon install not supported automatically on this OS."
    echo "Run sentinel manually with: $INSTALL_DIR/sentinel"
  fi
else
  echo "You chose to run sentinel manually."
  echo "Run it with: $INSTALL_DIR/sentinel"
fi

log "Installation complete."
echo "Temporary installation directory: $TEMP_DIR"
echo "Installation log file: $INSTALL_LOG"
