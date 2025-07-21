
# Resource Sentinel

**Resource Sentinel** is a cross-platform system resource monitor that alerts logged-in users if any process exceeds defined CPU or memory usage thresholds. It supports Linux and macOS, provides notifications with actions to kill, ignore, or remind later, and can run as a daemon.

---

## Installation

Run the following command to install:

```bash
bash <(curl -s https://raw.githubusercontent.com/t-desmond/resource-sentinel/main/install.sh)
```

You will be prompted to configure monitoring parameters and whether to install as a background service.

---

## Usage

- To run manually:

```bash
sentinel
```

- If installed as a daemon on Linux:

```bash
sudo systemctl status resource-sentinel.service
sudo systemctl stop resource-sentinel.service
sudo systemctl start resource-sentinel.service
```

---

## Configuration

Configuration is located at `/etc/resource-sentinel/config.yaml`.

You can modify thresholds, ignored processes, notification settings, and monitoring intervals.

---

## Dependencies

- `yq` (for YAML parsing)
- `zenity` (Linux GUI notifications)
- `osascript` (macOS notifications)
- `curl` (used by installer)

---

## Logs

Logs are stored in `/var/log/resource-sentinel/`.