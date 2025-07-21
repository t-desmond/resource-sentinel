#!/bin/bash
set -euo pipefail

# Color codes
RED='\033[0;31m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging helpers
log_step() {
  echo -e "${BLUE}[STEP]${NC} $1"
  echo "[STEP] $1" >> "$INSTALL_LOG"
}
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  echo "[ERROR] $1" >> "$INSTALL_LOG"
}
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
  echo "[INFO] $1" >> "$INSTALL_LOG"
}
log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
  echo "[WARN] $1" >> "$INSTALL_LOG"
}

cleanup() {
    log_error "Installation failed."
    log_info "Cleaning up temporary files..."
    if [[ -n "${TEMP_DIR-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR" &>/dev/null || true
        log_info "Removed temporary directory: $TEMP_DIR"
    fi
    if [[ -n "${CONFIG_DIR-}" && -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR" &>/dev/null || true
        log_info "Removed config directory: $CONFIG_DIR"
    fi
    for script in sentinel notifier.sh; do
        if [[ -f "/usr/local/bin/$script" ]]; then
            rm -f "/usr/local/bin/$script" &>/dev/null || true
            log_info "Removed installed script: /usr/local/bin/$script"
        fi
    done
    exit 1
}
trap cleanup ERR

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/resource-sentinel"
LOG_DIR="/var/log/resource-sentinel"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/resource-sentinel.service"
LOG_FILE="$LOG_DIR/monitor.log"
TEMP_DIR="$(mktemp -d -t resource-sentinel-setup-XXXX)"
INSTALL_LOG="/tmp/resource-sentinel-install-$$.log"
REPO_URL="https://raw.githubusercontent.com/t-desmond/resource-sentinel/main"

# Create log file with proper permissions
touch "$INSTALL_LOG" || {
    echo "[ERROR] Cannot create log file: $INSTALL_LOG"
    exit 1
}
chmod 600 "$INSTALL_LOG"

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "Please run as root or with sudo."
    exit 1
fi

log_step "Starting Resource Sentinel installation..."

# Dependency check and optional install
require_tools=( "yq" "curl" )
if [[ "$(uname)" == "Linux" ]]; then
  require_tools+=( "zenity" )
elif [[ "$(uname)" == "Darwin" ]]; then
  require_tools+=( "osascript" )
else
  log_error "Unsupported OS: $(uname)"
  exit 1
fi

for tool in "${require_tools[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    read -rp "$tool is not installed. Attempt to install it? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      log_step "Installing $tool..."
      if [[ "$tool" == "yq" ]]; then
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
            curl -sSL "$REPO_URL/utils/$YQ_BINARY" -o "/usr/local/bin/yq" &>/dev/null
            chmod +x "/usr/local/bin/yq" &>/dev/null
            log_step "yq installed successfully to /usr/local/bin/yq"
        else
            log_error "Unsupported OS/architecture for yq auto-installation: $OS/$ARCH"
            log_error "Please install yq manually and re-run this script."
            exit 1
        fi
      else
        if [[ "$(uname)" == "Linux" ]]; then
          apt update &>/dev/null && apt install -y "$tool" &>/dev/null
        elif [[ "$(uname)" == "Darwin" ]]; then
          if ! command -v brew &>/dev/null; then
            log_error "Homebrew not found. Please install Homebrew first."
            exit 1
          fi
          brew install "$tool" &>/dev/null
        fi
      fi
    else
      log_error "User declined to install $tool"
      exit 1
    fi
  fi
  log_step "$tool is installed."
done

log_step "Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" &>/dev/null
chmod 755 "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" &>/dev/null

# User config dir
if [[ -n "${SUDO_USER-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
        USER_CONFIG_DIR="$USER_HOME/.config/resource-sentinel"
        mkdir -p "$(dirname "$USER_CONFIG_DIR")" &>/dev/null
        chown "$SUDO_USER:$(id -g -n "$SUDO_USER")" "$(dirname "$USER_CONFIG_DIR")" &>/dev/null
        mkdir -p "$USER_CONFIG_DIR" &>/dev/null
        chown "$SUDO_USER:$(id -g -n "$SUDO_USER")" "$USER_CONFIG_DIR" &>/dev/null
        log_step "Created user-specific config directory at $USER_CONFIG_DIR"
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

log_step "Fetching scripts from remote repository..."
curl -sSL "$REPO_URL/sentinel.sh" -o "$INSTALL_DIR/sentinel" &>/dev/null
chmod +x "$INSTALL_DIR/sentinel" &>/dev/null
curl -sSL "$REPO_URL/utils/notifier.sh" -o "$INSTALL_DIR/notifier.sh" &>/dev/null
chmod +x "$INSTALL_DIR/notifier.sh" &>/dev/null
cp "$TEMP_DIR/config.yaml" "$CONFIG_DIR/config.yaml" &>/dev/null

log_step "Files copied and permissions set."

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
    systemctl daemon-reload &>/dev/null
    systemctl enable resource-sentinel.service &>/dev/null
    systemctl start resource-sentinel.service &>/dev/null
    log_step "Daemon installed and started."
    log_info "Use 'sudo systemctl status resource-sentinel.service' to check status."
  else
    log_info "Daemon install not supported automatically on this OS."
    log_info "Run sentinel manually with: $INSTALL_DIR/sentinel"
  fi
else
  log_info "You chose to run sentinel manually."
  log_info "Run it with: $INSTALL_DIR/sentinel"
fi

read -rp "Enable Discord notifications? [y/N]: " DISCORD_CHOICE
if [[ "$DISCORD_CHOICE" =~ ^[Yy]$ ]]; then
    yq e '.notifications.discord.enabled = true' -i "$CONFIG_FILE" &>/dev/null
    log_info "Discord notifications enabled. Please edit $CONFIG_FILE to add your webhook URL."
    log_info "Join our Discord server: https://discord.gg/your-server-link"
fi

log_step "Installation complete."
log_info "You can override system-wide settings by creating a config file at: ~/.config/resource-sentinel/config.yaml"
log_info "Installation log file: $INSTALL_LOG"
