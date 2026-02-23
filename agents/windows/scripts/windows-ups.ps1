#Requires -Version 5.1
<#
.SYNOPSIS
    Read CyberPower UPS status via pwrstat.exe and emit Telegraf line protocol.
.DESCRIPTION
    Requires CyberPower PowerPanel Personal to be installed.
    Download free from: https://www.cyberpower.com/global/en/software

    Emits two measurements:
      power  — UPS load in watts (domain=total); appears in Grafana power panels
               host tag is set to <COMPUTERNAME>-ups so it shows as a separate
               device alongside the CPU/DRAM estimate for the same machine
      ups    — Battery capacity %, runtime remaining, and on-battery status

    Exits silently (no output) if pwrstat.exe is not found so Telegraf
    does not log errors on machines without a UPS.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Locate pwrstat.exe ─────────────────────────────────────────────────────────
$PwrstatCandidates = @(
    'C:\Program Files\CyberPower\PowerPanel Personal\pwrstat.exe',
    'C:\Program Files (x86)\CyberPower\PowerPanel Personal\pwrstat.exe'
)

$PwrstatExe = $null
foreach ($candidate in $PwrstatCandidates) {
    if (Test-Path $candidate) { $PwrstatExe = $candidate; break }
}

if (-not $PwrstatExe) {
    $found = Get-Command pwrstat.exe -ErrorAction SilentlyContinue
    if ($found) { $PwrstatExe = $found.Source }
}

if (-not $PwrstatExe) {
    # PowerPanel Personal not installed — exit silently
    exit 0
}

# ── Query UPS status ───────────────────────────────────────────────────────────
try {
    $output = & $PwrstatExe -status 2>$null
} catch {
    exit 0
}

if (-not $output) { exit 0 }

$outputStr = $output -join "`n"

# ── Parse fields ───────────────────────────────────────────────────────────────
# Load: "Load......................... 90 Watt(88 VA)"
$loadWatts   = $null
if ($outputStr -match 'Load[.\s]+(\d+)\s+Watt') {
    $loadWatts = [double]$Matches[1]
}

# Battery capacity: "Battery Capacity............. 100 %"
$batteryPct  = $null
if ($outputStr -match 'Battery Capacity[.\s]+(\d+)\s+%') {
    $batteryPct = [int]$Matches[1]
}

# Remaining runtime: "Remaining Runtime............ 96 min."
$runtimeMin  = $null
if ($outputStr -match 'Remaining Runtime[.\s]+(\d+)\s+min') {
    $runtimeMin = [int]$Matches[1]
}

# Power source: "Power Supply by.............. AC Power" or "Battery Power"
$onBattery = 0
if ($outputStr -match 'Power Supply by[.\s]+Battery') {
    $onBattery = 1
}

if ($null -eq $loadWatts) {
    # Couldn't parse — UPS may be off or returning unexpected output
    exit 0
}

# ── Emit line protocol ─────────────────────────────────────────────────────────
# Use <COMPUTERNAME>-ups as the host tag so this device appears separately
# in Grafana alongside the CPU/DRAM estimate for the same machine.
# The host tag here overrides the global_tag set in telegraf.conf.
$upsHost = "$env:COMPUTERNAME-ups".ToLower()

# Power measurement — picked up by all existing Grafana power panels
Write-Output ("power,source=cyberpower,domain=total,host={0} watts={1}" -f $upsHost, $loadWatts)

# UPS-specific metrics — battery health and runtime
if ($null -ne $batteryPct) {
    Write-Output ("ups,source=cyberpower,host={0} battery_pct={1}i" -f $upsHost, $batteryPct)
}
if ($null -ne $runtimeMin) {
    Write-Output ("ups,source=cyberpower,host={0} runtime_min={1}i" -f $upsHost, $runtimeMin)
}
Write-Output ("ups,source=cyberpower,host={0} on_battery={1}i" -f $upsHost, $onBattery)
