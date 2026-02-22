#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Install and configure Telegraf power monitoring agent on Windows.
.DESCRIPTION
    Downloads Telegraf, copies config and scripts, substitutes server URL and token,
    configures TDP env var, installs as a Windows service with auto-restart.
.PARAMETER ServerUrl
    URL of the central InfluxDB server, e.g. http://192.168.1.100:8086
.PARAMETER WriteToken
    InfluxDB write API token created in the InfluxDB UI.
.PARAMETER TdpWatts
    CPU TDP in watts for power estimation (default: 65). Check your CPU spec sheet.
.PARAMETER Role
    Role label tag written to InfluxDB (default: agent).
.EXAMPLE
    .\install-windows.ps1 -ServerUrl http://192.168.1.10:8086 -WriteToken mytoken123 -TdpWatts 65
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ServerUrl,

    [Parameter(Mandatory=$true)]
    [string]$WriteToken,

    [int]$TdpWatts = 65,

    [string]$Role = 'agent'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TelegrafVersion = '1.29.5'
$TelegrafInstallDir = 'C:\Program Files\Telegraf'
$TelegrafScriptsDir = "$TelegrafInstallDir\scripts"
$TelegrafConf = "$TelegrafInstallDir\telegraf.conf"
$TelegrafExe = "$TelegrafInstallDir\telegraf.exe"
$DownloadUrl = "https://dl.influxdata.com/telegraf/releases/telegraf-${TelegrafVersion}_windows_amd64.zip"
$TempZip = "$env:TEMP\telegraf.zip"
$TempExtract = "$env:TEMP\telegraf_extract"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "==> Installing Telegraf power monitoring agent (Windows)" -ForegroundColor Cyan
Write-Host "    Server: $ServerUrl"
Write-Host "    TDP:    ${TdpWatts}W"
Write-Host "    Role:   $Role"

# ── Set PowerShell execution policy ───────────────────────────────────────────
Write-Host "==> Setting execution policy to RemoteSigned"
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

# ── Download Telegraf if not present ──────────────────────────────────────────
if (Test-Path $TelegrafExe) {
    $existing = & $TelegrafExe version 2>&1 | Select-Object -First 1
    Write-Host "==> Telegraf already installed: $existing"
}
else {
    Write-Host "==> Downloading Telegraf $TelegrafVersion..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempZip -UseBasicParsing

    Write-Host "==> Extracting..."
    if (Test-Path $TempExtract) { Remove-Item $TempExtract -Recurse -Force }
    Expand-Archive -Path $TempZip -DestinationPath $TempExtract -Force

    $extracted = Get-ChildItem $TempExtract -Recurse -Filter 'telegraf.exe' | Select-Object -First 1
    if (-not $extracted) { throw "telegraf.exe not found in downloaded archive" }

    New-Item -ItemType Directory -Path $TelegrafInstallDir -Force | Out-Null
    Copy-Item -Path $extracted.DirectoryName\* -Destination $TelegrafInstallDir -Recurse -Force

    Remove-Item $TempZip -Force
    Remove-Item $TempExtract -Recurse -Force
    Write-Host "==> Telegraf installed to $TelegrafInstallDir"
}

# ── Stop existing service if running ──────────────────────────────────────────
$svc = Get-Service -Name telegraf -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "==> Stopping existing Telegraf service..."
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name telegraf -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Write-Host "==> Uninstalling existing Telegraf service..."
    & $TelegrafExe --service uninstall 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

# ── Deploy config and scripts ──────────────────────────────────────────────────
Write-Host "==> Deploying configuration and scripts"
New-Item -ItemType Directory -Path $TelegrafScriptsDir -Force | Out-Null

# Config
$confSrc = Join-Path $ScriptDir 'telegraf-windows.conf'
if (-not (Test-Path $confSrc)) { throw "telegraf-windows.conf not found at: $confSrc" }
Copy-Item -Path $confSrc -Destination $TelegrafConf -Force

# Power script
$scriptSrc = Join-Path $ScriptDir 'scripts\windows-power.ps1'
if (-not (Test-Path $scriptSrc)) { throw "windows-power.ps1 not found at: $scriptSrc" }
Copy-Item -Path $scriptSrc -Destination "$TelegrafScriptsDir\windows-power.ps1" -Force

# ── Substitute placeholders ────────────────────────────────────────────────────
Write-Host "==> Substituting server URL and token in config"
$confContent = Get-Content -Path $TelegrafConf -Raw
$confContent = $confContent -replace 'INFLUXDB_SERVER_URL', $ServerUrl
$confContent = $confContent -replace 'WRITE_TOKEN_HERE', $WriteToken
$confContent = $confContent -replace 'role = "agent"', "role = `"$Role`""
Set-Content -Path $TelegrafConf -Value $confContent -Encoding UTF8

# ── Set CPU TDP environment variable (persists machine-wide) ──────────────────
Write-Host "==> Setting CPU_TDP_WATTS=$TdpWatts (machine-level environment variable)"
[Environment]::SetEnvironmentVariable('CPU_TDP_WATTS', "$TdpWatts", 'Machine')

# ── Install Telegraf as Windows service ───────────────────────────────────────
Write-Host "==> Installing Telegraf Windows service"
& $TelegrafExe --config $TelegrafConf --service install
if ($LASTEXITCODE -ne 0) { throw "Failed to install Telegraf service (exit code $LASTEXITCODE)" }

# ── Configure service auto-restart with backoff ───────────────────────────────
Write-Host "==> Configuring service auto-restart"
# Reset failure count after 60s, restart: 5s -> 10s -> 30s
sc.exe failure telegraf reset= 60 actions= restart/5000/restart/10000/restart/30000 | Out-Null

# ── Start the service ─────────────────────────────────────────────────────────
Write-Host "==> Starting Telegraf service"
Start-Service -Name telegraf
Start-Sleep -Seconds 3

# ── Verify ────────────────────────────────────────────────────────────────────
$svc = Get-Service -Name telegraf
if ($svc.Status -eq 'Running') {
    Write-Host ""
    Write-Host "Telegraf is running successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Useful commands:"
    Write-Host "  Get-Service telegraf"
    Write-Host "  Get-EventLog -LogName Application -Source telegraf -Newest 20"
    Write-Host "  & '$TelegrafExe' --config '$TelegrafConf' --test"
    Write-Host ""
    Write-Host "Data should appear in InfluxDB within 30 seconds."
}
else {
    Write-Host ""
    Write-Error "Telegraf service is not running (status: $($svc.Status)). Check Event Viewer > Application log."
}
