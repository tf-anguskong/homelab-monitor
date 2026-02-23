# Homelab Power Monitoring

Distributed power monitoring for homelabs using **Telegraf + InfluxDB v2 + Grafana (TIG stack)**.

Each machine runs a Telegraf agent that pushes power + system metrics every 10 seconds to a central InfluxDB instance. Grafana renders dashboards.

```
[Linux Agent]   ──push──▶ |
[Linux Agent 2] ──push──▶ | InfluxDB v2 ◀── Grafana
[Windows Agent] ──push──▶ |
```

Power data comes from software estimation only — no external hardware required:
- **Linux**: Intel RAPL energy counters (`/sys/class/powercap`)
- **Windows**: WMI battery discharge rate (laptops on battery) or CPU load × TDP estimate (desktops/AC)

---

## Quick Start — Central Server

### Prerequisites
- Docker and Docker Compose installed on the server machine
- Ports 8086 (InfluxDB) and 3000 (Grafana) accessible from agent machines

### 1. Configure secrets

```bash
cd server
cp .env.example .env
```

Edit `.env` and set strong values for all passwords and the InfluxDB token. The token must be at least 32 characters.

### 2. Start the stack

```bash
cd server
docker compose up -d
```

InfluxDB initializes automatically on first run (takes ~30 seconds). Grafana starts after InfluxDB is healthy.

- **InfluxDB UI**: `http://<server-ip>:8086`  — user/pass from `.env`
- **Grafana**: `http://<server-ip>:3000`  — user/pass from `.env`

### 3. Create a write token for agents

In the InfluxDB UI:
1. **Load Data → API Tokens → Generate API Token → Custom API Token**
2. Bucket: `powermon` → check **Write**
3. Click Generate and copy the token

This write-only token goes into the agent install commands below. Keep the admin token (from `.env`) private.

---

## Linux Agent

### Requirements
- Linux with Intel CPU (RAPL support)
- `bash`, `awk`, `sleep` (standard on all distros)
- `telegraf` will be installed by the script

### Install

```bash
sudo ./agents/linux/install-linux.sh \
  --server http://<SERVER_IP>:8086 \
  --token <WRITE_TOKEN> \
  [--role my-server-name]
```

**Proxmox or systems with restricted repos** — use `--deb` to skip repo setup and download the `.deb` directly instead:

```bash
sudo ./agents/linux/install-linux.sh \
  --server http://<SERVER_IP>:8086 \
  --token <WRITE_TOKEN> \
  --deb
```

The script:
- Installs Telegraf via apt/yum repo (default) or direct `.deb` download (`--deb`)
- Deploys config and the RAPL power script
- Fixes RAPL read permissions (adds `telegraf` to `power` group or creates a udev rule)
- Enables the Telegraf systemd service

### Test the RAPL script standalone

```bash
bash agents/linux/scripts/rapl-power.sh
# Expected output:
# power,source=rapl,domain=package-0 watts=12.345
# power,source=rapl,domain=core watts=8.901
# power,source=rapl,domain=dram watts=2.123
```

---

## macOS Agent

### Requirements
- macOS 12 (Monterey) or later
- Apple Silicon (M1/M2/M3) or Intel Mac
- [Homebrew](https://brew.sh) installed
- Run install script as root

### Install

```bash
sudo ./agents/macos/install-macos.sh \
  --server http://<SERVER_IP>:8086 \
  --token <WRITE_TOKEN> \
  --role my-macbook
```

The script:
- Installs Telegraf via Homebrew if not already present
- Deploys config and the `powermetrics` power script to `/usr/local/etc/telegraf/`
- Creates a root LaunchDaemon at `/Library/LaunchDaemons/com.influxdata.telegraf.plist` so `powermetrics` can access hardware power counters
- Starts the service automatically on boot

### Test the power script standalone

```bash
sudo ./agents/macos/scripts/macos-power.sh
# Apple Silicon output:
# power,source=powermetrics,domain=cpu   watts=1.234
# power,source=powermetrics,domain=gpu   watts=0.567
# power,source=powermetrics,domain=total watts=1.801
#
# Intel Mac output:
# power,source=powermetrics,domain=package watts=12.345
# power,source=powermetrics,domain=total   watts=12.345
```

### Manage the service

```bash
# Stop
sudo launchctl unload /Library/LaunchDaemons/com.influxdata.telegraf.plist

# Start
sudo launchctl load /Library/LaunchDaemons/com.influxdata.telegraf.plist

# Logs
tail -f /var/log/telegraf/telegraf.log
```

---

## Windows Agent

### Requirements
- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1+
- Run as Administrator

### Install

Run as a single line (backtick line continuations can break on copy-paste):

```powershell
.\agents\windows\install-windows.ps1 -ServerUrl "http://<SERVER_IP>:8086" -WriteToken "YOUR_TOKEN_HERE" -TdpWatts 65
```

**TdpWatts** — set this to your CPU's rated TDP (check the CPU spec sheet or manufacturer website). This value is only used when on AC power; laptop battery readings are always real.

The script:
- Downloads Telegraf 1.29.5 from influxdata.com
- Deploys config and the WMI power script
- Sets `CPU_TDP_WATTS` as a machine-level environment variable
- Installs Telegraf as a Windows service with auto-restart

### Test the power script standalone

```powershell
.\agents\windows\scripts\windows-power.ps1
# Expected output:
# power,source=wmi,domain=cpu watts=32.5
# power,source=wmi,domain=dram watts=3.0
# power,source=wmi,domain=total watts=35.5
```

---

## Grafana Dashboard

The "Homelab Power Monitoring" dashboard is pre-provisioned and loads automatically. Navigate to **Dashboards** in the sidebar.

Panels:
- **Row 1**: Total power now, active host count, peak power (1h), average power (1h)
- **Row 2**: Per-host power over time (one line per host)
- **Row 3**: CPU vs DRAM power breakdown by host, current power table
- **Row 4**: CPU%, memory%, and network I/O per host

---

## Troubleshooting

### RAPL: "Permission denied" reading `/sys/class/powercap`

The install script handles this automatically. If running the script manually:

```bash
# Option A — add telegraf user to power group
sudo usermod -aG power telegraf

# Option B — temporary fix (resets on reboot without udev rule)
sudo chmod -R o+r /sys/class/powercap
```

### 401 Unauthorized from InfluxDB

The write token in the agent config doesn't match InfluxDB. Verify:

```bash
# Test token directly
curl -H "Authorization: Token YOUR_TOKEN" http://SERVER:8086/api/v2/buckets
```

Re-run the install script with the correct token, or edit the config directly:

```bash
# Linux
sudo sed -i 's/token = ".*"/token = "CORRECT_TOKEN"/' /etc/telegraf/telegraf.conf
sudo systemctl restart telegraf
```

### Grafana shows "No data"

1. Confirm agents are running and sending data — check InfluxDB Data Explorer
2. Confirm the datasource URL is `http://influxdb:8086` (Docker service name, not localhost)
3. Check that `INFLUXDB_TOKEN` env var is set in the Grafana container:
   ```bash
   docker exec grafana env | grep INFLUX
   ```
4. Try a manual Flux query in Grafana Explore:
   ```flux
   from(bucket: "powermon") |> range(start: -5m) |> limit(n: 10)
   ```

### Windows: "Execution policy" error running the install script

```powershell
Set-ExecutionPolicy RemoteSigned -Scope Process
.\install-windows.ps1 ...
```

### Windows: Telegraf service fails to start

```powershell
# Check event log
Get-EventLog -LogName Application -Source telegraf -Newest 20

# Test config directly
& "C:\Program Files\Telegraf\telegraf.exe" --config "C:\Program Files\Telegraf\telegraf.conf" --test
```

### Linux: Check Telegraf logs

```bash
journalctl -u telegraf -f
# or
systemctl status telegraf
```

---

## Directory Structure

```
powermon/
├── README.md
├── server/
│   ├── docker-compose.yml
│   ├── .env.example          # Copy to .env and fill in secrets
│   ├── .gitignore            # .env is gitignored
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── influxdb.yml
│           └── dashboards/
│               ├── dashboard.yml
│               └── power-monitoring.json
└── agents/
    ├── linux/
    │   ├── telegraf-linux.conf
    │   ├── install-linux.sh
    │   └── scripts/
    │       └── rapl-power.sh
    └── windows/
        ├── telegraf-windows.conf
        ├── install-windows.ps1
        └── scripts/
            └── windows-power.ps1
```
