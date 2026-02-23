#!/usr/bin/env bash
# remove-unifi.sh — Remove a UniFi device from Telegraf SNMP monitoring
# Must be run as root.
#
# Usage:
#   sudo ./remove-unifi.sh --name <name>

set -euo pipefail

CONF_FILE="/etc/telegraf/telegraf.d/unifi.conf"
PROC_FILE="/etc/telegraf/telegraf.d/unifi-processors.conf"

DEVICE_NAME=""

# ── Strip carriage returns ─────────────────────────────────────────────────────
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+${cleaned_args[@]}}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 --name <name>"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) DEVICE_NAME="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$DEVICE_NAME" ]] && { echo "ERROR: --name is required"; usage; }
[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: must be run as root (sudo)"; exit 1; }

if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Config file not found: $CONF_FILE"
    exit 1
fi

if ! grep -q "## BEGIN UNIFI: ${DEVICE_NAME}$" "$CONF_FILE"; then
    echo "ERROR: No UniFi device named '${DEVICE_NAME}' found in ${CONF_FILE}"
    echo ""
    echo "Configured devices:"
    grep "## BEGIN UNIFI:" "$CONF_FILE" | sed 's/## BEGIN UNIFI: /  /' || echo "  (none)"
    exit 1
fi

# ── Remove the block ───────────────────────────────────────────────────────────
TMPFILE=$(mktemp)
awk -v name="${DEVICE_NAME}" '
    /^## BEGIN UNIFI: / && $0 == "## BEGIN UNIFI: " name { skip=1 }
    skip && /^## END UNIFI: /   && $0 == "## END UNIFI: "   name { skip=0; next }
    !skip
' "$CONF_FILE" > "$TMPFILE"
mv "$TMPFILE" "$CONF_FILE"
echo "==> Removed UniFi device '${DEVICE_NAME}' from ${CONF_FILE}"

# ── Remove PoE processor if no PoE devices remain ─────────────────────────────
if [[ -f "$PROC_FILE" ]] && ! grep -q "unifi_poe_raw" "$CONF_FILE" 2>/dev/null; then
    rm "$PROC_FILE"
    echo "==> Removed ${PROC_FILE} (no PoE devices remaining)"
fi

# ── Restart Telegraf ───────────────────────────────────────────────────────────
if systemctl is-active --quiet telegraf; then
    echo "==> Restarting Telegraf"
    systemctl restart telegraf
    sleep 2
    if systemctl is-active --quiet telegraf; then
        echo "✓ Telegraf restarted successfully"
    else
        echo "ERROR: Telegraf failed to restart. Check: journalctl -u telegraf -n 30"
        exit 1
    fi
else
    echo "WARN: Telegraf is not running — config updated but service not restarted."
fi
