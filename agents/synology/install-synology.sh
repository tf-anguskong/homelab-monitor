#!/usr/bin/env bash
# install-synology.sh — Deploy Telegraf monitoring agent on Synology NAS
# Run via SSH on the Synology, from the directory containing this script.
# Requires Docker (Container Manager on DSM 7, Docker package on DSM 6).
#
# Usage:
#   bash install-synology.sh \
#     --server http://<SERVER_IP>:8086 \
#     --token  <WRITE_TOKEN> \
#     --role   synology            # name shown in Grafana (default: synology)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER_URL=""
WRITE_TOKEN=""
ROLE="synology"

# ── Strip carriage returns (safe copy-paste from Windows terminals) ────────────
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+${cleaned_args[@]}}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: bash $0 --server http://HOST:8086 --token TOKEN [--role NAME]"
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

echo "==> Installing Synology Telegraf agent"
echo "    Server:   $SERVER_URL"
echo "    Hostname: $ROLE"

# ── Check Docker is available ──────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found."
    echo "       Install 'Container Manager' (DSM 7) or 'Docker' (DSM 6) from Package Center."
    exit 1
fi

COMPOSE_CMD=""
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "ERROR: docker compose not found."
    echo "       Update Docker/Container Manager or install docker-compose manually."
    exit 1
fi

# ── Substitute placeholders in config files ────────────────────────────────────
echo "==> Writing credentials into config"

# Work on copies so the originals remain as templates
cp "$SCRIPT_DIR/telegraf-synology.conf" "$SCRIPT_DIR/telegraf-synology.conf.tmp"
cp "$SCRIPT_DIR/docker-compose.yml"     "$SCRIPT_DIR/docker-compose.yml.tmp"

sed -i "s|INFLUXDB_SERVER_URL|${SERVER_URL}|g"  "$SCRIPT_DIR/telegraf-synology.conf.tmp"
sed -i "s|WRITE_TOKEN_HERE|${WRITE_TOKEN}|g"     "$SCRIPT_DIR/telegraf-synology.conf.tmp"
sed -i "s|SYNOLOGY_HOSTNAME_HERE|${ROLE}|g"      "$SCRIPT_DIR/docker-compose.yml.tmp"

# Move configured files into place
mv "$SCRIPT_DIR/telegraf-synology.conf.tmp" "$SCRIPT_DIR/telegraf-synology.conf.live"
mv "$SCRIPT_DIR/docker-compose.yml.tmp"     "$SCRIPT_DIR/docker-compose.live.yml"

# ── Stop any existing container ────────────────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q '^telegraf-powermon$'; then
    echo "==> Stopping existing telegraf-powermon container"
    $COMPOSE_CMD -f "$SCRIPT_DIR/docker-compose.live.yml" down 2>/dev/null || true
fi

# ── Start the container ────────────────────────────────────────────────────────
echo "==> Starting Telegraf container"
$COMPOSE_CMD -f "$SCRIPT_DIR/docker-compose.live.yml" up -d

# ── Verify ────────────────────────────────────────────────────────────────────
sleep 5
if docker ps --filter "name=telegraf-powermon" --filter "status=running" --format '{{.Names}}' | grep -q telegraf-powermon; then
    echo ""
    echo "✓ Telegraf is running"
    echo ""
    echo "Useful commands:"
    echo "  docker logs telegraf-powermon -f"
    echo "  docker ps --filter name=telegraf-powermon"
    echo "  $COMPOSE_CMD -f $SCRIPT_DIR/docker-compose.live.yml down"
    echo ""
    echo "Data for '$ROLE' should appear in InfluxDB within 30 seconds."
    echo "CPU, memory, disk, and network metrics will show in all Grafana panels."
    echo ""
    echo "For power monitoring, plug the NAS into a Shelly smart plug and run:"
    echo "  sudo ./agents/shelly/add-shelly.sh --name ${ROLE}-power --ip <SHELLY_IP>"
    echo "(run that command on your Linux agent host, not the Synology)"
else
    echo ""
    echo "ERROR: Container failed to stay running. Check logs:"
    docker logs telegraf-powermon 2>/dev/null | tail -20
    exit 1
fi
