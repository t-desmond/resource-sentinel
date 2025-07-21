#!/bin/bash
set -euo pipefail

# Define cleanup function first, before any potential errors can occur
cleanup() {
    echo "[ERROR] Installation failed."
    echo "[INFO] Cleaning up temporary files..."
    
    # Clean up temp directory if it exists
    if [[ -n "${TEMP_DIR-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        echo "[INFO] Removed temporary directory: $TEMP_DIR"
    fi
    
    # Clean up log file if it exists
    if [[ -n "${INSTALL_LOG-}" && -f "$INSTALL_LOG" ]]; then
        rm -f "$INSTALL_LOG"
        echo "[INFO] Removed log file: $INSTALL_LOG"
    fi
    
    # Clean up any partially installed files
    if [[ -n "${CONFIG_DIR-}" && -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        echo "[INFO] Removed config directory: $CONFIG_DIR"
    fi
    
    # Remove any partially installed scripts
    for script in sentinel notifier.sh; do
        if [[ -f "/usr/local/bin/$script" ]]; then
            rm -f "/usr/local/bin/$script"
            echo "[INFO] Removed installed script: /usr/local/bin/$script"
        fi
    done
    
    exit 1
}

# Set up error trap immediately after defining cleanup
trap cleanup ERR

# Now define installation paths and create temp directory
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/resource-sentinel"
LOG_DIR="/var/log/resource-sentinel"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/resource-sentinel.service"
LOG_FILE="$LOG_DIR/monitor.log"
TEMP_DIR="$(mktemp -d -t resource-sentinel-setup-XXXX)"
INSTALL_LOG="/tmp/resource-sentinel-install-$$.log"

# Create log file with proper permissions
touch "$INSTALL_LOG" || {
    echo "[ERROR] Cannot create log file: $INSTALL_LOG"
    cleanup
}
chmod 600 "$INSTALL_LOG"

log() {
    local message
    message="[$(date '+%F %T')] $1"
    echo "$message"
    echo "$message" >> "$INSTALL_LOG"
}

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root or with sudo."
    cleanup
fi

log "Starting Resource Sentinel installation..."

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
      if [[ "$tool" == "yq" ]]; then
        log "Attempting to install yq from GitHub..."
        YQ_BINARY=""
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)

        if [[ "$OS" == "linux" ]]; then
            if [[ "$ARCH" == "x86_64" ]]; then
                YQ_BINARY="yq_linux_amd64"
            elif [[ "$ARCH" == "aarch64" ]]; then
                YQ_BINARY="yq_linux_arm64"
            fi
        elif [[ "$OS" == "darwin" ]]; then
            if [[ "$ARCH" == "x86_64" ]]; then
                YQ_BINARY="yq_darwin_amd64"
            elif [[ "$ARCH" == "arm64" ]]; then
                YQ_BINARY="yq_darwin_arm64"
            fi
        fi

        if [[ -n "$YQ_BINARY" ]]; then
            curl -SL "https://github.com/mikefarah/yq/releases/latest/download/${YQ_BINARY}" -o "/usr/local/bin/yq"
            chmod +x "/usr/local/bin/yq"
            log "yq installed successfully to /usr/local/bin/yq"
        else
            log "Unsupported OS/architecture for yq auto-installation: $OS/$ARCH"
            log "Please install yq manually and re-run this script."
            cleanup
        fi
      else
        # Existing installation logic for other tools
        if [[ "$(uname)" == "Linux" ]]; then
          apt update && apt install -y "$tool"
        elif [[ "$(uname)" == "Darwin" ]]; then
          if ! command -v brew &>/dev/null; then
            log "Homebrew not found. Please install Homebrew first."
            cleanup
          fi
          brew install "$tool"
        fi
      fi
    else
      log "User declined to install $tool"
      cleanup
    fi
  fi
  log "$tool is installed."
done

# Create directories
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
chmod 755 "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"

# Create user-specific config directory if run with sudo
if [[ -n "${SUDO_USER-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
        USER_CONFIG_DIR="$USER_HOME/.config/resource-sentinel"
        # Ensure parent .config directory exists and has correct ownership
        mkdir -p "$(dirname "$USER_CONFIG_DIR")"
        chown "$SUDO_USER:$(id -g -n "$SUDO_USER")" "$(dirname "$USER_CONFIG_DIR")"
        # Create user config dir and set ownership
        mkdir -p "$USER_CONFIG_DIR"
        chown "$SUDO_USER:$(id -g -n "$SUDO_USER")" "$USER_CONFIG_DIR"
        log "Created user-specific config directory at $USER_CONFIG_DIR"
    fi
fi

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
  discord:
    enabled: false
    webhook_url: ""
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

read -rp "Enable Discord notifications? [y/N]: " DISCORD_CHOICE
if [[ "$DISCORD_CHOICE" =~ ^[Yy]$ ]]; then
    yq e '.notifications.discord.enabled = true' -i "$CONFIG_FILE"
    echo "Discord notifications enabled. Please edit $CONFIG_FILE to add your webhook URL."
fi

log "Installation complete."
echo "You can override system-wide settings by creating a config file at: ~/.config/resource-sentinel/config.yaml"
echo "Temporary installation directory: $TEMP_DIR"
echo "Installation log file: $INSTALL_LOG"
