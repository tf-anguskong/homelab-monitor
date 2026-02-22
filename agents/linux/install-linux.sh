#!/usr/bin/env bash
# install-linux.sh — Install and configure Telegraf power monitoring agent
# Usage: sudo ./install-linux.sh --server http://INFLUXDB_HOST:8086 --token YOUR_WRITE_TOKEN [--role NAME] [--deb]
# Must be run as root.
#
# Flags:
#   --server URL   InfluxDB server URL (required)
#   --token TOKEN  InfluxDB write token (required)
#   --role NAME    Role tag written to InfluxDB (default: agent)
#   --deb          Install via direct .deb download instead of adding apt/yum repo.
#                  Use this on Proxmox or any system with restricted/custom repos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELEGRAF_CONF_SRC="$SCRIPT_DIR/telegraf-linux.conf"
SCRIPTS_SRC="$SCRIPT_DIR/scripts"
TELEGRAF_CONF_DEST="/etc/telegraf/telegraf.conf"
SCRIPTS_DEST="/etc/telegraf/scripts"

TELEGRAF_DEB_VERSION="1.29.5"
TELEGRAF_DEB_URL="https://dl.influxdata.com/telegraf/releases/telegraf_${TELEGRAF_DEB_VERSION}-1_amd64.deb"

SERVER_URL=""
WRITE_TOKEN=""
ROLE="agent"
USE_DEB=false

# ── Strip carriage returns from all arguments ─────────────────────────────────
# Protects against \r injected by copy-paste from Windows terminals or CRLF scripts
cleaned_args=()
for arg in "$@"; do
    cleaned_args+=("${arg//$'\r'/}")
done
set -- "${cleaned_args[@]+"${cleaned_args[@]}"}"

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 --server http://HOST:8086 --token TOKEN [--role ROLE] [--deb]"
    echo ""
    echo "  --deb   Install Telegraf via direct .deb download (use on Proxmox / restricted repos)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server) SERVER_URL="$2"; shift 2 ;;
        --token)  WRITE_TOKEN="$2"; shift 2 ;;
        --role)   ROLE="$2"; shift 2 ;;
        --deb)    USE_DEB=true; shift ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$SERVER_URL" ]] && { echo "ERROR: --server is required"; usage; }
[[ -z "$WRITE_TOKEN" ]] && { echo "ERROR: --token is required"; usage; }
[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: must be run as root (sudo)"; exit 1; }

echo "==> Installing Telegraf power monitoring agent"
echo "    Server: $SERVER_URL"
echo "    Role:   $ROLE"
echo "    Method: $([ "$USE_DEB" = true ] && echo 'direct .deb download' || echo 'package repo')"

# ── Install via direct .deb (Proxmox / restricted repo systems) ───────────────
install_telegraf_deb() {
    local tmp_deb
    tmp_deb="$(mktemp /tmp/telegraf_XXXXXX.deb)"

    echo "==> Downloading Telegraf ${TELEGRAF_DEB_VERSION} .deb..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$TELEGRAF_DEB_URL" -o "$tmp_deb"
    elif command -v wget &>/dev/null; then
        wget -q "$TELEGRAF_DEB_URL" -O "$tmp_deb"
    else
        echo "ERROR: curl or wget is required to download Telegraf"
        exit 1
    fi

    echo "==> Installing .deb package..."
    dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    echo "==> Telegraf installed: $(telegraf --version | head -1)"
}

# ── Install via package repo (standard distros) ───────────────────────────────
install_telegraf_repo() {
    if [[ -f /etc/debian_version ]]; then
        echo "==> Installing Telegraf via InfluxData apt repo (Debian/Ubuntu)"
        curl -fsSL https://repos.influxdata.com/influxdata-archive_compat.key \
            | gpg --dearmor -o /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] \
https://repos.influxdata.com/debian stable main" \
            > /etc/apt/sources.list.d/influxdata.list
        apt-get update -q
        apt-get install -y telegraf

    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/fedora-release ]]; then
        echo "==> Installing Telegraf via InfluxData yum repo (RHEL/CentOS/Fedora)"
        cat > /etc/yum.repos.d/influxdata.repo <<'EOF'
[influxdata]
name = InfluxData Repository
baseurl = https://repos.influxdata.com/rhel/$releasever/$basearch/stable/
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive_compat.key
EOF
        yum install -y telegraf

    elif [[ -f /etc/arch-release ]]; then
        echo "==> Installing Telegraf via AUR (Arch Linux)"
        if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
            echo "ERROR: AUR helper (yay/paru) required for Arch. Install telegraf from AUR manually."
            exit 1
        fi
        local aur_cmd
        aur_cmd=$(command -v yay || command -v paru)
        sudo -u "${SUDO_USER:-nobody}" "$aur_cmd" -S --noconfirm telegraf-bin

    else
        echo "ERROR: Unsupported distro. Use --deb for direct download, or install Telegraf manually:"
        echo "       https://docs.influxdata.com/telegraf/v1/install/"
        exit 1
    fi
    echo "==> Telegraf installed: $(telegraf --version | head -1)"
}

# ── Main install dispatch ──────────────────────────────────────────────────────
if command -v telegraf &>/dev/null; then
    echo "==> Telegraf already installed: $(telegraf --version | head -1)"
elif [[ "$USE_DEB" == true ]]; then
    install_telegraf_deb
else
    install_telegraf_repo
fi

# ── Copy config and scripts ────────────────────────────────────────────────────
echo "==> Deploying configuration"
systemctl stop telegraf 2>/dev/null || true

cp "$TELEGRAF_CONF_SRC" "$TELEGRAF_CONF_DEST"
mkdir -p "$SCRIPTS_DEST"
cp "$SCRIPTS_SRC/rapl-power.sh" "$SCRIPTS_DEST/rapl-power.sh"
chmod +x "$SCRIPTS_DEST/rapl-power.sh"

# ── Substitute placeholders ────────────────────────────────────────────────────
echo "==> Writing server URL and token into config"
sed -i "s|INFLUXDB_SERVER_URL|${SERVER_URL}|g" "$TELEGRAF_CONF_DEST"
sed -i "s|WRITE_TOKEN_HERE|${WRITE_TOKEN}|g"    "$TELEGRAF_CONF_DEST"

# Set role tag
sed -i "s|role = \"agent\"|role = \"${ROLE}\"|g" "$TELEGRAF_CONF_DEST"

# ── NVIDIA GPU detection ───────────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    echo "==> NVIDIA GPU detected — enabling GPU metrics block"
    sed -i 's/^## \(\[\[inputs.exec\]\]\)/\1/' "$TELEGRAF_CONF_DEST"
    sed -i 's/^##   commands = \(\[$/  commands = \[/' "$TELEGRAF_CONF_DEST"
    sed -i '/nvidia-smi/{ s/^## //; }' "$TELEGRAF_CONF_DEST"
    sed -i '/--query-gpu/{ s/^## //; }' "$TELEGRAF_CONF_DEST"
else
    echo "==> No NVIDIA GPU found — GPU block remains commented out"
fi

# ── RAPL kernel modules ───────────────────────────────────────────────────────
# Proxmox and some minimal kernels don't auto-load RAPL modules.
# Load them now and make them persistent across reboots.
echo "==> Checking Intel RAPL kernel modules"
if [[ ! -d /sys/class/powercap/intel-rapl ]]; then
    echo "    RAPL not yet exposed — loading kernel modules..."
    modprobe intel_rapl_common 2>/dev/null || true
    modprobe intel_rapl_msr    2>/dev/null || true
    sleep 1
    if [[ -d /sys/class/powercap/intel-rapl ]]; then
        echo "    Modules loaded successfully"
    else
        echo "    WARNING: RAPL still not available after loading modules."
        echo "    Your CPU or kernel may not support Intel RAPL."
        echo "    Power metrics will be skipped — all other metrics will still be collected."
    fi
else
    echo "    RAPL already available"
fi

# Persist modules across reboots
MODULES_LOAD_FILE="/etc/modules-load.d/rapl.conf"
if [[ ! -f "$MODULES_LOAD_FILE" ]]; then
    echo "==> Making RAPL modules persistent across reboots"
    cat > "$MODULES_LOAD_FILE" <<'EOF'
# Intel RAPL power reporting — loaded for Telegraf power monitoring
intel_rapl_common
intel_rapl_msr
EOF
    echo "    Written to $MODULES_LOAD_FILE"
fi

# ── RAPL permissions — run telegraf as root via systemd override ───────────────
# sysfs RAPL files are root-only and permissions reset on module reload.
# The most reliable fix is a systemd drop-in that runs telegraf as root.
# For a local monitoring agent this is acceptable; it avoids a sudo dependency.
echo "==> Configuring telegraf service to run as root (required for RAPL access)"
OVERRIDE_DIR="/etc/systemd/system/telegraf.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE_DIR/rapl-root.conf" <<'EOF'
[Service]
User=root
Group=root
EOF
echo "    Systemd override written to $OVERRIDE_DIR/rapl-root.conf"

# ── Enable and start Telegraf ──────────────────────────────────────────────────
echo "==> Enabling and starting Telegraf service"
systemctl daemon-reload
systemctl enable telegraf
systemctl restart telegraf

# ── Verify ────────────────────────────────────────────────────────────────────
sleep 3
if systemctl is-active --quiet telegraf; then
    echo ""
    echo "✓ Telegraf is running successfully"
    echo ""
    echo "Useful commands:"
    echo "  systemctl status telegraf"
    echo "  journalctl -u telegraf -f"
    echo "  telegraf --config $TELEGRAF_CONF_DEST --test"
    echo ""
    echo "Data should appear in InfluxDB within 30 seconds."
else
    echo ""
    echo "ERROR: Telegraf failed to start. Check logs:"
    journalctl -u telegraf --no-pager -n 30
    exit 1
fi
