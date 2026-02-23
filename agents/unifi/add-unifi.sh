#!/usr/bin/env bash
# add-unifi.sh — Add a UniFi device to Telegraf SNMP monitoring
# Run on the Linux host where Telegraf is installed. Must be run as root.
#
# Collects interface traffic (all devices) and PoE consumed power (--poe flag).
# PoE power appears automatically in all Grafana power dashboard panels.
#
# Prerequisites:
#   - SNMP enabled on the UniFi device:
#     UniFi Network → Settings → Services → SNMP → Enable
#   - Telegraf agent installed (agents/linux/install-linux.sh)
#
# Usage:
#   sudo ./add-unifi.sh --name <name> --ip <ip> [--community public] [--poe]
#
# Examples:
#   sudo ./add-unifi.sh --name unifi-switch --ip 192.168.1.2 --poe
#   sudo ./add-unifi.sh --name unifi-ap     --ip 192.168.1.3

set -euo pipefail

CONF_DIR="/etc/telegraf/telegraf.d"
CONF_FILE="$CONF_DIR/unifi.conf"
PROC_FILE="$CONF_DIR/unifi-processors.conf"

DEVICE_NAME=""
DEVICE_IP=""
COMMUNITY="${SNMP_COMMUNITY:-public}"
POE=false

# ── Strip carriage returns (safe copy-paste from Windows terminals) ────────────
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+${cleaned_args[@]}}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 --name <name> --ip <ip> [--community STRING] [--poe]"
    echo ""
    echo "  --name       Device name used as the 'host' tag in InfluxDB"
    echo "  --ip         IP address of the UniFi device"
    echo "  --community  SNMP community string (default: public)"
    echo "  --poe        Device is a PoE switch — collect total PoE power draw"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)      DEVICE_NAME="$2"; shift 2 ;;
        --ip)        DEVICE_IP="$2";   shift 2 ;;
        --community) COMMUNITY="$2";   shift 2 ;;
        --poe)       POE=true;         shift 1 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$DEVICE_NAME" ]] && { echo "ERROR: --name is required"; usage; }
[[ -z "$DEVICE_IP"   ]] && { echo "ERROR: --ip is required";   usage; }
[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: must be run as root (sudo)"; exit 1; }

# ── Check for duplicate ────────────────────────────────────────────────────────
if [[ -f "$CONF_FILE" ]] && grep -q "## BEGIN UNIFI: ${DEVICE_NAME}$" "$CONF_FILE"; then
    echo "ERROR: A UniFi device named '${DEVICE_NAME}' is already configured in ${CONF_FILE}"
    echo "       Run remove-unifi.sh --name ${DEVICE_NAME} first to replace it."
    exit 1
fi

mkdir -p "$CONF_DIR"

# ── Write PoE processor (idempotent — always up to date) ──────────────────────
# One shared processor converts all unifi_poe_raw metrics (mW → W, measurement=power)
cat > "$PROC_FILE" <<'PROCEOF'
# UniFi PoE power processor — converts unifi_poe_raw (milliwatts) to
# measurement=power field=watts so PoE switches appear in the power dashboard.
# Managed by add-unifi.sh — do not edit manually.
[[processors.starlark]]
  namepass = ["unifi_poe_raw"]
  source = '''
def apply(metric):
    if "power_mw" in metric.fields:
        metric.name = "power"
        watts = float(metric.fields["power_mw"]) / 1000.0
        metric.fields.clear()
        metric.fields["watts"] = watts
    return metric
'''
PROCEOF

# ── Append SNMP config block ───────────────────────────────────────────────────
cat >> "$CONF_FILE" <<EOF

## BEGIN UNIFI: ${DEVICE_NAME}
[[inputs.snmp]]
  ## UniFi general metrics: ${DEVICE_NAME} (${DEVICE_IP})
  agents    = ["udp://${DEVICE_IP}:161"]
  version   = 2
  community = "${COMMUNITY}"
  interval  = "60s"
  timeout   = "10s"
  retries   = 2
  name      = "unifi"
  [inputs.snmp.tags]
    host = "${DEVICE_NAME}"
    role = "agent"

  # System uptime
  [[inputs.snmp.field]]
    name = "uptime"
    oid  = "1.3.6.1.2.1.1.3.0"

  # Interface traffic table (bytes in/out per interface)
  [[inputs.snmp.table]]
    name = "interface"
    [[inputs.snmp.table.field]]
      name   = "name"
      oid    = "1.3.6.1.2.1.31.1.1.1.1"   # ifName
      is_tag = true
    [[inputs.snmp.table.field]]
      name = "bytes_recv"
      oid  = "1.3.6.1.2.1.31.1.1.1.6"    # ifHCInOctets
    [[inputs.snmp.table.field]]
      name = "bytes_sent"
      oid  = "1.3.6.1.2.1.31.1.1.1.10"   # ifHCOutOctets
EOF

if $POE; then
    cat >> "$CONF_FILE" <<EOF

[[inputs.snmp]]
  ## UniFi PoE consumed power: ${DEVICE_NAME} (${DEVICE_IP})
  ## pethMainPseConsumptionPower — total PoE watts drawn, in milliwatts
  ## Converted to measurement=power by the processor in unifi-processors.conf
  agents    = ["udp://${DEVICE_IP}:161"]
  version   = 2
  community = "${COMMUNITY}"
  interval  = "10s"
  timeout   = "10s"
  retries   = 2
  name      = "unifi_poe_raw"
  [inputs.snmp.tags]
    host   = "${DEVICE_NAME}"
    domain = "total"
    source = "snmp-poe"
    role   = "agent"
  [[inputs.snmp.field]]
    name = "power_mw"
    oid  = "1.3.6.1.2.1.105.1.3.1.4.1"
EOF
fi

cat >> "$CONF_FILE" <<EOF
## END UNIFI: ${DEVICE_NAME}
EOF

POE_MSG=""
$POE && POE_MSG=" + PoE power"
echo "==> Added UniFi device '${DEVICE_NAME}' (${DEVICE_IP}) — interface traffic${POE_MSG}"

# ── Restart Telegraf ───────────────────────────────────────────────────────────
if systemctl is-active --quiet telegraf; then
    echo "==> Restarting Telegraf"
    systemctl restart telegraf
    sleep 2
    if systemctl is-active --quiet telegraf; then
        echo ""
        echo "✓ Telegraf restarted successfully"
        echo ""
        if $POE; then
            echo "PoE power for '${DEVICE_NAME}' will appear in all Grafana power panels."
        fi
        echo "Interface traffic is in the 'interface' measurement in InfluxDB."
        echo ""
        echo "To remove this device:"
        echo "  sudo $(dirname "$0")/remove-unifi.sh --name ${DEVICE_NAME}"
    else
        echo "ERROR: Telegraf failed to restart. Check: journalctl -u telegraf -n 30"
        exit 1
    fi
else
    echo "WARN: Telegraf is not running — config written but service not restarted."
fi
