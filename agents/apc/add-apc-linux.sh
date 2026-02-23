#!/usr/bin/env bash
# add-apc-linux.sh — Add APC UPS monitoring to Telegraf via apcupsd
# Run on the Linux host that has the APC UPS connected via USB. Must be run as root.
#
# How it works:
#   - Installs apcupsd if not present (communicates with APC UPS over USB)
#   - apcupsd exposes a Network Information Server (NIS) on port 3551
#   - Telegraf's native [[inputs.apcupsd]] plugin reads from that NIS
#   - A Starlark processor converts the data into:
#       measurement=power  field=watts  (picked up by all Grafana power panels)
#       measurement=ups    fields=battery_pct, runtime_min, on_battery
#
# Prerequisites:
#   - APC UPS connected via USB to this machine
#   - Telegraf agent installed (agents/linux/install-linux.sh)
#
# Usage:
#   sudo ./add-apc-linux.sh [--name <name>] [--rated-watts N]
#
# Options:
#   --name          Host tag used in InfluxDB/Grafana (default: <hostname>-ups)
#   --rated-watts   UPS rated watt capacity, e.g. 600.
#                   Only needed if your UPS does not report NOMPOWER to apcupsd.
#                   Run: apcaccess status | grep NOMPOWER  to check.
#
# Examples:
#   sudo ./add-apc-linux.sh
#   sudo ./add-apc-linux.sh --name rack-ups --rated-watts 600

set -euo pipefail

CONF_DIR="/etc/telegraf/telegraf.d"
CONF_FILE="$CONF_DIR/apc.conf"

UPS_NAME=""
RATED_WATTS=0

# ── Strip carriage returns (safe copy-paste from Windows terminals) ────────────
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+${cleaned_args[@]}}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 [--name <name>] [--rated-watts N]"
    echo ""
    echo "  --name          Host tag for the UPS in InfluxDB/Grafana (default: <hostname>-ups)"
    echo "  --rated-watts N UPS rated watt capacity (e.g. 600). Only needed if NOMPOWER"
    echo "                  is not reported by your UPS model."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)         UPS_NAME="$2";    shift 2 ;;
        --rated-watts)  RATED_WATTS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: must be run as root (sudo)"; exit 1; }

[[ -z "$UPS_NAME" ]] && UPS_NAME="$(hostname -s)-ups"

echo "==> APC UPS monitoring setup"
echo "    Host tag:    $UPS_NAME"
echo "    Rated watts: ${RATED_WATTS:-auto (from NOMPOWER)}"

# ── Install apcupsd if not present ────────────────────────────────────────────
if ! command -v apcupsd &>/dev/null; then
    echo "==> Installing apcupsd..."
    apt-get install -y apcupsd
else
    echo "==> apcupsd already installed: $(apcupsd --version 2>&1 | head -1)"
fi

# ── Configure apcupsd ─────────────────────────────────────────────────────────
APCUPSD_CONF="/etc/apcupsd/apcupsd.conf"
if [[ -f "$APCUPSD_CONF" ]]; then
    echo "==> Configuring apcupsd (USB device, NIS enabled on port 3551)"

    # USB UPS settings
    sed -i 's/^UPSCABLE.*/UPSCABLE usb/'    "$APCUPSD_CONF"
    sed -i 's/^UPSTYPE.*/UPSTYPE usb/'      "$APCUPSD_CONF"
    # DEVICE blank → apcupsd auto-detects the first USB UPS
    sed -i 's/^DEVICE .*/DEVICE/'           "$APCUPSD_CONF"

    # Enable NIS (Network Information Server) so Telegraf can query it
    sed -i 's/^#*NETSERVER.*/NETSERVER on/' "$APCUPSD_CONF"
    sed -i 's/^#*NISPORT.*/NISPORT 3551/'   "$APCUPSD_CONF"
    # Bind NIS to localhost only (no external exposure)
    sed -i 's/^#*NISIP.*/NISIP 127.0.0.1/' "$APCUPSD_CONF"
fi

# On Debian/Ubuntu apcupsd won't start until this flag is set
APCUPSD_DEFAULT="/etc/default/apcupsd"
if [[ -f "$APCUPSD_DEFAULT" ]]; then
    sed -i 's/^ISCONFIGURED=.*/ISCONFIGURED=yes/' "$APCUPSD_DEFAULT"
fi

# ── Start apcupsd ─────────────────────────────────────────────────────────────
echo "==> Starting apcupsd service..."
systemctl enable apcupsd --quiet 2>/dev/null || true
systemctl restart apcupsd
sleep 3

if systemctl is-active --quiet apcupsd; then
    echo "==> apcupsd is running"
    echo ""
    apcaccess status 2>/dev/null | grep -E "STATUS|LOADPCT|BCHARGE|TIMELEFT|NOMPOWER|MODEL" || true
    echo ""
else
    echo ""
    echo "WARN: apcupsd failed to start. Possible causes:"
    echo "  - APC UPS not connected via USB (check: lsusb | grep -i apc)"
    echo "  - Wrong cable/driver setting in $APCUPSD_CONF"
    echo "  Check logs: journalctl -u apcupsd -n 30"
    echo ""
    echo "Telegraf config will still be written; fix apcupsd and restart:"
    echo "  sudo systemctl restart apcupsd telegraf"
fi

# ── Write Telegraf config ──────────────────────────────────────────────────────
echo "==> Writing Telegraf config to $CONF_FILE"
mkdir -p "$CONF_DIR"

cat > "$CONF_FILE" <<CONFEOF
# APC UPS monitoring via apcupsd NIS
# Managed by add-apc-linux.sh — re-run the script to regenerate.

[[inputs.apcupsd]]
  ## apcupsd Network Information Server — runs on the host with the UPS connected
  servers  = ["tcp://localhost:3551"]
  timeout  = "5s"
  interval = "10s"
  [inputs.apcupsd.tags]
    host   = "${UPS_NAME}"
    source = "apcupsd"

# Convert apcupsd metrics into the two measurements our Grafana dashboard expects:
#   measurement=power  field=watts         — appears in all power panels
#   measurement=ups    fields=battery_pct, runtime_min, on_battery  — UPS Status panel
[[processors.starlark]]
  namepass = ["apcupsd"]
  source = '''
def apply(metric):
    load_pct  = metric.fields.get("load_percent",          None)
    nom_w     = metric.fields.get("nominal_power_watts",   ${RATED_WATTS})
    batt_pct  = metric.fields.get("battery_charge_percent",None)
    time_left = metric.fields.get("time_left",             None)  # minutes
    status    = str(metric.fields.get("status",            ""))

    results = []

    # power measurement — picked up automatically by all Grafana power panels
    rated = float(nom_w) if nom_w else 0.0
    if load_pct is not None and rated > 0.0:
        pwr = deepcopy(metric)
        pwr.name = "power"
        pwr.tags["domain"] = "total"
        pwr.fields.clear()
        pwr.fields["watts"] = float(load_pct) / 100.0 * rated
        results.append(pwr)

    # ups measurement — Grafana UPS Status panel
    ups = deepcopy(metric)
    ups.name = "ups"
    ups.fields.clear()
    if batt_pct  is not None: ups.fields["battery_pct"] = int(batt_pct)
    if time_left is not None: ups.fields["runtime_min"] = int(time_left)
    ups.fields["on_battery"] = 1 if "ONBATT" in status else 0
    results.append(ups)

    return results
'''
CONFEOF

# ── Restart Telegraf ───────────────────────────────────────────────────────────
if systemctl is-active --quiet telegraf; then
    echo "==> Restarting Telegraf..."
    systemctl restart telegraf
    sleep 2
    if systemctl is-active --quiet telegraf; then
        echo ""
        echo "✓ Done. APC UPS data will appear in Grafana within 30 seconds."
        echo ""
        echo "Verify apcupsd is reading your UPS:"
        echo "  apcaccess status"
        echo ""
        echo "Check Telegraf is collecting:"
        echo "  journalctl -u telegraf -n 20"
    else
        echo "ERROR: Telegraf failed to restart. Check: journalctl -u telegraf -n 30"
        exit 1
    fi
else
    echo "WARN: Telegraf is not running — config written but service not restarted."
fi
