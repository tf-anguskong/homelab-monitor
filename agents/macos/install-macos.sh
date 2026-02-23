#!/usr/bin/env bash
# install-macos.sh — Install and configure Telegraf power monitoring agent on macOS
# Usage: sudo ./install-macos.sh --server http://INFLUXDB_HOST:8086 --token TOKEN [--role NAME]
# Must be run as root (sudo).
#
# Requires Homebrew to be installed under the current user account.
# Supports Apple Silicon (/opt/homebrew) and Intel (/usr/local) Macs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TELEGRAF_CONF_DIR="/usr/local/etc/telegraf"
TELEGRAF_SCRIPTS_DIR="$TELEGRAF_CONF_DIR/scripts"
TELEGRAF_CONF="$TELEGRAF_CONF_DIR/telegraf.conf"
LAUNCHDAEMON_PLIST="/Library/LaunchDaemons/com.influxdata.telegraf.plist"
LOG_DIR="/var/log/telegraf"

SERVER_URL=""
WRITE_TOKEN=""
ROLE="agent"

# ── Strip carriage returns (safe copy-paste from Windows terminals) ────────────
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+"${cleaned_args[@]}"}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 --server http://HOST:8086 --token TOKEN [--role ROLE]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server) SERVER_URL="$2"; shift 2 ;;
        --token)  WRITE_TOKEN="$2"; shift 2 ;;
        --role)   ROLE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$SERVER_URL" ]]  && { echo "ERROR: --server is required"; usage; }
[[ -z "$WRITE_TOKEN" ]] && { echo "ERROR: --token is required"; usage; }
[[ "$(id -u)" -ne 0 ]]  && { echo "ERROR: must be run as root (sudo)"; exit 1; }

echo "==> Installing Telegraf power monitoring agent (macOS)"
echo "    Server: $SERVER_URL"
echo "    Role:   $ROLE"

# ── Detect Homebrew and Telegraf binary ───────────────────────────────────────
TELEGRAF_BIN=""
BREW_USER="${SUDO_USER:-}"

if [[ -x /opt/homebrew/bin/telegraf ]]; then
    TELEGRAF_BIN="/opt/homebrew/bin/telegraf"
    echo "==> Found Telegraf (Apple Silicon Homebrew): $TELEGRAF_BIN"
elif [[ -x /usr/local/bin/telegraf ]]; then
    TELEGRAF_BIN="/usr/local/bin/telegraf"
    echo "==> Found Telegraf (Intel Homebrew): $TELEGRAF_BIN"
else
    echo "==> Telegraf not found — installing via Homebrew"
    if [[ -z "$BREW_USER" ]]; then
        echo "ERROR: Could not determine the user who invoked sudo. Run with: sudo -E $0 ..."
        exit 1
    fi

    # Brew must be run as the non-root user
    if [[ -x /opt/homebrew/bin/brew ]]; then
        sudo -u "$BREW_USER" /opt/homebrew/bin/brew install telegraf
        TELEGRAF_BIN="/opt/homebrew/bin/telegraf"
    elif [[ -x /usr/local/bin/brew ]]; then
        sudo -u "$BREW_USER" /usr/local/bin/brew install telegraf
        TELEGRAF_BIN="/usr/local/bin/telegraf"
    else
        echo "ERROR: Homebrew not found. Install it from https://brew.sh then re-run this script."
        exit 1
    fi
fi

echo "    Telegraf: $($TELEGRAF_BIN version | head -1)"

# ── Unload existing LaunchDaemon ──────────────────────────────────────────────
if [[ -f "$LAUNCHDAEMON_PLIST" ]]; then
    echo "==> Unloading existing Telegraf LaunchDaemon"
    launchctl unload "$LAUNCHDAEMON_PLIST" 2>/dev/null || true
fi

# ── Deploy config and scripts ──────────────────────────────────────────────────
echo "==> Deploying configuration and scripts"
mkdir -p "$TELEGRAF_SCRIPTS_DIR"
mkdir -p "$LOG_DIR"

cp "$SCRIPT_DIR/telegraf-macos.conf" "$TELEGRAF_CONF"
cp "$SCRIPT_DIR/scripts/macos-power.sh" "$TELEGRAF_SCRIPTS_DIR/macos-power.sh"
chmod +x "$TELEGRAF_SCRIPTS_DIR/macos-power.sh"

# ── Substitute placeholders ────────────────────────────────────────────────────
echo "==> Writing server URL and token into config"
# macOS sed requires -i '' (BSD sed, not GNU sed)
sed -i '' "s|INFLUXDB_SERVER_URL|${SERVER_URL}|g" "$TELEGRAF_CONF"
sed -i '' "s|WRITE_TOKEN_HERE|${WRITE_TOKEN}|g"    "$TELEGRAF_CONF"
sed -i '' "s|role = \"agent\"|role = \"${ROLE}\"|g" "$TELEGRAF_CONF"

# ── Create LaunchDaemon plist ──────────────────────────────────────────────────
# Runs telegraf as root so powermetrics can access hardware power counters
echo "==> Creating LaunchDaemon (runs as root for powermetrics access)"
cat > "$LAUNCHDAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.influxdata.telegraf</string>
    <key>ProgramArguments</key>
    <array>
        <string>${TELEGRAF_BIN}</string>
        <string>--config</string>
        <string>${TELEGRAF_CONF}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/telegraf.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/telegraf.log</string>
</dict>
</plist>
EOF

chmod 644 "$LAUNCHDAEMON_PLIST"

# ── Load the LaunchDaemon ──────────────────────────────────────────────────────
echo "==> Starting Telegraf LaunchDaemon"
launchctl load "$LAUNCHDAEMON_PLIST"

# ── Verify ────────────────────────────────────────────────────────────────────
sleep 3
if launchctl list | grep -q "com.influxdata.telegraf"; then
    echo ""
    echo "✓ Telegraf is running"
    echo ""
    echo "Useful commands:"
    echo "  sudo launchctl list | grep telegraf"
    echo "  tail -f $LOG_DIR/telegraf.log"
    echo "  sudo $TELEGRAF_BIN --config $TELEGRAF_CONF --test"
    echo ""
    echo "Test power script standalone:"
    echo "  sudo $TELEGRAF_SCRIPTS_DIR/macos-power.sh"
    echo ""
    echo "Data should appear in InfluxDB within 30 seconds."
else
    echo ""
    echo "ERROR: Telegraf LaunchDaemon did not start. Check logs:"
    tail -20 "$LOG_DIR/telegraf.log" 2>/dev/null || echo "(no log file yet)"
    exit 1
fi
