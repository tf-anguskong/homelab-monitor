#!/usr/bin/env bash
# install-finance.sh — Finance agent setup
# Installs Python dependencies, copies .env.example, and adds an hourly cron job.
#
# Usage: ./install-finance.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECT_SCRIPT="$SCRIPT_DIR/collect.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Check Python >= 3.10
# ---------------------------------------------------------------------------
info "Checking Python version..."
PYTHON=$(command -v python3 || command -v python || true)
if [[ -z "$PYTHON" ]]; then
    error "Python 3 not found. Install Python 3.10 or later."
fi

PY_VER=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)

if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 10 ]]; }; then
    error "Python $PY_VER found, but >= 3.10 is required."
fi
info "Python $PY_VER — OK"

# ---------------------------------------------------------------------------
# Install pip dependencies
# ---------------------------------------------------------------------------
info "Installing Python dependencies..."
"$PYTHON" -m pip install --quiet --upgrade pip
"$PYTHON" -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
info "Dependencies installed."

# ---------------------------------------------------------------------------
# Copy .env.example → .env
# ---------------------------------------------------------------------------
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    info "Copied .env.example → .env"
    warn "Edit $SCRIPT_DIR/.env and fill in your credentials before running the collector."
else
    info ".env already exists — skipping copy."
fi

# ---------------------------------------------------------------------------
# Add hourly cron job (idempotent)
# ---------------------------------------------------------------------------
CRON_MARKER="# finance-agent"
CRON_JOB="0 * * * * $PYTHON $COLLECT_SCRIPT >> /var/log/finance-agent.log 2>&1  $CRON_MARKER"

if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    info "Cron job already present — skipping."
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    info "Added hourly cron job: $CRON_JOB"
fi

# ---------------------------------------------------------------------------
# Done — print next steps
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Finance agent installed successfully!"
echo "============================================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit .env with your InfluxDB connection details and"
echo "     credentials for each provider:"
echo "       $SCRIPT_DIR/.env"
echo ""
echo "  2. (Schwab) Run once to complete OAuth2 flow:"
echo "       $PYTHON $SCRIPT_DIR/schwab_setup.py"
echo "     Then set SCHWAB_ENABLED=true in .env."
echo ""
echo "  3. (Plaid — banks, Vanguard, etc.) Run once per institution:"
echo "       $PYTHON $SCRIPT_DIR/plaid_setup.py"
echo "     Open http://localhost:5000, link each account, then"
echo "     copy the printed PLAID_ACCESS_TOKEN_n values into .env."
echo ""
echo "  4. Test the collector manually:"
echo "       $PYTHON $COLLECT_SCRIPT"
echo ""
echo "  5. Verify data in InfluxDB Data Explorer under measurement"
echo "     'account_balance', then restart Grafana:"
echo "       docker compose -f /path/to/server/docker-compose.yml restart grafana"
echo ""
