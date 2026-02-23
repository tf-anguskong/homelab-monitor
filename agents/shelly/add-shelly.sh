#!/usr/bin/env bash
# add-shelly.sh — Add a Shelly smart plug to Telegraf monitoring
# Run on the Linux host where Telegraf is installed. Must be run as root.
#
# Usage:
#   sudo ./add-shelly.sh --name <device-name> --ip <ip-address> [--gen 1|2] [--interval 10s]
#
# Examples:
#   sudo ./add-shelly.sh --name living-room-tv --ip 192.168.1.50
#   sudo ./add-shelly.sh --name synology-nas   --ip 192.168.1.51 --gen 2

set -euo pipefail

CONF_DIR="/etc/telegraf/telegraf.d"
CONF_FILE="$CONF_DIR/shellys.conf"

DEVICE_NAME=""
DEVICE_IP=""
GEN=1
INTERVAL="10s"

# ── Strip carriage returns (safe copy-paste from Windows terminals) ────────────
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+${cleaned_args[@]}}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 --name <name> --ip <ip> [--gen 1|2] [--interval 10s]"
    echo ""
    echo "  --name      Device name used as the 'host' tag in InfluxDB (e.g. living-room-tv)"
    echo "  --ip        IP address of the Shelly device (e.g. 192.168.1.50)"
    echo "  --gen       Shelly generation: 1 (default) or 2"
    echo "  --interval  Poll interval (default: 10s)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)     DEVICE_NAME="$2"; shift 2 ;;
        --ip)       DEVICE_IP="$2";   shift 2 ;;
        --gen)      GEN="$2";         shift 2 ;;
        --interval) INTERVAL="$2";    shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$DEVICE_NAME" ]] && { echo "ERROR: --name is required"; usage; }
[[ -z "$DEVICE_IP"   ]] && { echo "ERROR: --ip is required";   usage; }
[[ "$GEN" != "1" && "$GEN" != "2" ]] && { echo "ERROR: --gen must be 1 or 2"; usage; }
[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: must be run as root (sudo)"; exit 1; }

# ── Check for duplicate ────────────────────────────────────────────────────────
if [[ -f "$CONF_FILE" ]] && grep -q "## BEGIN SHELLY: ${DEVICE_NAME}$" "$CONF_FILE"; then
    echo "ERROR: A Shelly device named '${DEVICE_NAME}' is already configured in ${CONF_FILE}"
    echo "       Run remove-shelly.sh --name ${DEVICE_NAME} first if you want to replace it."
    exit 1
fi

# ── Build config block ─────────────────────────────────────────────────────────
if [[ "$GEN" == "1" ]]; then
    URL="http://${DEVICE_IP}/meter/0"
    FIELD_PATH="power"
else
    URL="http://${DEVICE_IP}/rpc/Switch.GetStatus?id=0"
    FIELD_PATH="apower"
fi

mkdir -p "$CONF_DIR"

cat >> "$CONF_FILE" <<EOF

## BEGIN SHELLY: ${DEVICE_NAME}
[[inputs.http]]
  ## Shelly Gen ${GEN}: ${DEVICE_NAME} (${DEVICE_IP})
  urls     = ["${URL}"]
  method   = "GET"
  timeout  = "5s"
  interval = "${INTERVAL}"
  name_override = "power"
  [inputs.http.tags]
    host   = "${DEVICE_NAME}"
    source = "shelly"
    domain = "total"
  [[inputs.http.json_v2]]
    [[inputs.http.json_v2.field]]
      path   = "${FIELD_PATH}"
      rename = "watts"
      type   = "float"
## END SHELLY: ${DEVICE_NAME}
EOF

echo "==> Added Shelly device '${DEVICE_NAME}' (Gen ${GEN}, ${DEVICE_IP}) to ${CONF_FILE}"

# ── Restart Telegraf ───────────────────────────────────────────────────────────
if systemctl is-active --quiet telegraf; then
    echo "==> Restarting Telegraf to apply new config"
    systemctl restart telegraf
    sleep 2
    if systemctl is-active --quiet telegraf; then
        echo ""
        echo "✓ Telegraf restarted successfully"
        echo ""
        echo "Data from '${DEVICE_NAME}' should appear in InfluxDB within ${INTERVAL}."
        echo "It will show up automatically in all Grafana power panels."
        echo ""
        echo "To remove this device later:"
        echo "  sudo $(dirname "$0")/remove-shelly.sh --name ${DEVICE_NAME}"
    else
        echo "ERROR: Telegraf failed to restart. Check config:"
        echo "  journalctl -u telegraf -n 30"
        exit 1
    fi
else
    echo "WARN: Telegraf is not running — config written but service not restarted."
    echo "      Start it with: systemctl start telegraf"
fi
