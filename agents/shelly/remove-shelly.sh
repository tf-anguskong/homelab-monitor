#!/usr/bin/env bash
# remove-shelly.sh — Remove a Shelly smart plug from Telegraf monitoring
# Must be run as root.
#
# Usage:
#   sudo ./remove-shelly.sh --name <device-name>

set -euo pipefail

CONF_FILE="/etc/telegraf/telegraf.d/shellys.conf"

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

# ── Check file exists ──────────────────────────────────────────────────────────
if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Config file not found: $CONF_FILE"
    exit 1
fi

if ! grep -q "## BEGIN SHELLY: ${DEVICE_NAME}$" "$CONF_FILE"; then
    echo "ERROR: No Shelly device named '${DEVICE_NAME}' found in ${CONF_FILE}"
    echo ""
    echo "Configured devices:"
    grep "## BEGIN SHELLY:" "$CONF_FILE" | sed 's/## BEGIN SHELLY: /  /' || echo "  (none)"
    exit 1
fi

# ── Remove the block ───────────────────────────────────────────────────────────
# Deletes from the blank line before BEGIN SHELLY: <name> through END SHELLY: <name>
TMPFILE=$(mktemp)
awk -v name="${DEVICE_NAME}" '
    /^## BEGIN SHELLY: / && $0 == "## BEGIN SHELLY: " name { skip=1 }
    skip && /^## END SHELLY: / && $0 == "## END SHELLY: " name { skip=0; next }
    !skip
' "$CONF_FILE" > "$TMPFILE"

# Strip trailing blank lines left by the removed block
sed -i '/^[[:space:]]*$/{ /\S/!{ N; /^\n$/d } }' "$TMPFILE" 2>/dev/null || true

mv "$TMPFILE" "$CONF_FILE"
echo "==> Removed Shelly device '${DEVICE_NAME}' from ${CONF_FILE}"

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
