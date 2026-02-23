#Requires -Version 5.1
<#
.SYNOPSIS
    Read UPS status (CyberPower or APC) and emit Telegraf line protocol.
.DESCRIPTION
    Tries each method in order, using the first one that returns data:

    CyberPower (PowerPanel Personal):
      1. pwrstat.exe       — PowerPanel Personal v3.x and older
      2. SQLite DB         — PPPE_Db.db in app assets (v4+, requires sqlite3.exe)
                             Install sqlite3: winget install SQLite.sqlite
                             Fastest method — tried before REST API to avoid timeouts
      3. REST API port 3052— PowerPanel Personal v4+ fallback (pppd.exe daemon)
      4. ProgramData files — XML/JSON status written by pppd (last resort)

    APC:
      5. apcaccess.exe     — apcupsd for Windows (https://www.apcupsd.com/)
                             Gives full data: load watts, battery %, runtime
      6. Win32_Battery WMI — Generic Windows HID UPS driver (most APC USB models)
                             Battery % and runtime only — no load watts

    Emits two measurements:
      power  — UPS load in watts (domain=total); appears in all Grafana power panels
               host tag is set to <COMPUTERNAME>-ups so it shows as a separate
               device alongside the CPU/DRAM estimate for the same machine
      ups    — Battery capacity %, runtime remaining, and on-battery status

    Exits silently (no output) if no UPS is detected, so Telegraf logs no errors
    on machines without a UPS attached.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Locate PowerPanel Personal install directory ───────────────────────────────
# Newer versions install to "CyberPower PowerPanel Personal" (flat name)
# Older versions install to "CyberPower\PowerPanel Personal" (nested)
$PPPDirCandidates = @(
    'C:\Program Files\CyberPower PowerPanel Personal',
    'C:\Program Files (x86)\CyberPower PowerPanel Personal',
    'C:\Program Files\CyberPower\PowerPanel Personal',
    'C:\Program Files (x86)\CyberPower\PowerPanel Personal'
)

$PPPDir = $null
foreach ($d in $PPPDirCandidates) {
    if (Test-Path $d) { $PPPDir = $d; break }
}

$loadWatts  = $null
$batteryPct = $null
$runtimeMin = $null
$onBattery  = 0
$gotData    = $false
$upsSource  = 'ups'    # overwritten by whichever method succeeds

# Helper: find first non-null value from a PSObject by trying multiple property names
function Get-Prop([object]$obj, [string[]]$names) {
    foreach ($n in $names) {
        try {
            if ($obj.PSObject.Properties[$n] -and ($null -ne $obj.$n)) { return $obj.$n }
        } catch {}
    }
    return $null
}

# ── Methods 1–3: CyberPower PowerPanel Personal ───────────────────────────────
# ── Method 1: pwrstat.exe (PowerPanel Personal v3.x and older) ────────────────
$PwrstatExe = if ($PPPDir) { Join-Path $PPPDir 'pwrstat.exe' } else { $null }
if (-not (Test-Path $PwrstatExe)) {
    $found = Get-Command pwrstat.exe -ErrorAction SilentlyContinue
    $PwrstatExe = if ($found) { $found.Source } else { $null }
}

if ($PwrstatExe) {
    try {
        $out = & $PwrstatExe -status 2>$null
        $s   = $out -join "`n"
        if ($s -match 'Load[.\s]+(\d+)\s+Watt') {
            $loadWatts = [double]$Matches[1]
            $gotData   = $true
            $upsSource = 'cyberpower'
        }
        if ($s -match 'Battery Capacity[.\s]+(\d+)\s+%')    { $batteryPct = [int]$Matches[1] }
        if ($s -match 'Remaining Runtime[.\s]+(\d+)\s+min') { $runtimeMin = [int]$Matches[1] }
        if ($s -match 'Power Supply by[.\s]+Battery')        { $onBattery  = 1 }
    } catch {}
}

# ── Method 2: SQLite database (PowerPanel Personal v4+) ───────────────────────
# Fastest method — queries PPPE_Db.db directly. Tried before REST API to avoid
# slow port-scan timeouts when pppd is running but endpoints are unknown.
# DeviceLog table columns (confirmed schema):
#   LP       — Load in watts (e.g. 1000 on a 1500W UPS)
#   BatCap   — Battery capacity % (e.g. 100.0)
#   BatRun   — Runtime remaining in minutes (e.g. 55.0)
#   PowSour  — Power source: 0 = AC mains, non-zero = on battery
# Requires sqlite3.exe — install via: winget install SQLite.sqlite
#   or it may already be present via Git for Windows / Chocolatey.
if ($PPPDir -and -not $gotData) {
    $dbPath = Join-Path $PPPDir 'assets\PPPE_Db.db'
    if (Test-Path $dbPath) {
        # Locate sqlite3.exe — check PATH then common install locations
        $sqlite3 = $null
        $s3found = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
        if ($s3found) { $sqlite3 = $s3found.Source }
        if (-not $sqlite3) {
            $s3Candidates = @(
                # Telegraf install dir — recommended location (accessible to SYSTEM service)
                'C:\Program Files\Telegraf\sqlite3.exe',
                # Git for Windows
                'C:\Program Files\Git\usr\bin\sqlite3.exe',
                'C:\Program Files (x86)\Git\usr\bin\sqlite3.exe',
                # Chocolatey
                'C:\ProgramData\chocolatey\bin\sqlite3.exe',
                # winget (user-level — only works when Telegraf runs as a user account)
                "$env:LOCALAPPDATA\Microsoft\WinGet\Links\sqlite3.exe"
            )
            foreach ($c in $s3Candidates) {
                if (Test-Path $c) { $sqlite3 = $c; break }
            }
        }

        if ($sqlite3) {
            try {
                # Copy DB to a temp file to avoid waiting on pppd.exe's write lock.
                # Windows allows file copies even when another process has the file open.
                $tempDb = "$env:TEMP\pppe_snapshot.db"
                Copy-Item -Path $dbPath -Destination $tempDb -Force -ErrorAction Stop

                $sql = "SELECT LP, BatCap, BatRun, PowSour FROM DeviceLog ORDER BY id DESC LIMIT 1;"
                $row = & $sqlite3 -separator '|' $tempDb $sql 2>$null
                Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
                if ($row) {
                    $parts = @($row -split '\|')
                    $lp = 0.0
                    if ([double]::TryParse($parts[0],
                            [System.Globalization.NumberStyles]::Any,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [ref]$lp) -and $lp -gt 0) {
                        $loadWatts = $lp
                        $upsSource = 'cyberpower'
                        $gotData   = $true

                        $bv = 0.0
                        if ($parts.Count -gt 1 -and [double]::TryParse($parts[1],
                                [System.Globalization.NumberStyles]::Any,
                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$bv)) {
                            $batteryPct = [int]$bv
                        }
                        $rv = 0.0
                        if ($parts.Count -gt 2 -and [double]::TryParse($parts[2],
                                [System.Globalization.NumberStyles]::Any,
                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$rv)) {
                            $runtimeMin = [int]$rv
                        }
                        if ($parts.Count -gt 3) {
                            $onBattery = if ($parts[3] -ne '0') { 1 } else { 0 }
                        }
                    }
                }
            } catch {}
        }
    }
}

# ── Method 3: REST API (PowerPanel Personal v4+) ──────────────────────────────
# Only reached if SQLite DB is unavailable. pppd.exe serves a local REST API —
# default port 3052. Kept as fallback in case the DB path changes in future versions.
if ($PPPDir -and -not $gotData) {
    $apiPorts    = @(3052, 3000, 2266, 8080)
    $apiPaths    = @('/local/v1/ups', '/api/v1/ups', '/api/ups', '/api/status')

    :portLoop foreach ($port in $apiPorts) {
        foreach ($path in $apiPaths) {
            try {
                $r = Invoke-WebRequest -Uri "http://localhost:$port$path" `
                         -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
                if ($r.StatusCode -ne 200 -or -not $r.Content) { continue }

                $j = $r.Content | ConvertFrom-Json -ErrorAction Stop

                # API may return an array of UPS devices; take the first
                if ($j -is [array]) {
                    if ($j.Count -eq 0) { continue }
                    $j = $j[0]
                }

                # Try common field name conventions for load in watts
                $wf = Get-Prop $j @('load_w','load_watts','loadWatts','watts','outputWatts','output_watts')
                if ($null -eq $wf) {
                    $pwr = Get-Prop $j @('power','output','load')
                    if ($pwr -is [System.Management.Automation.PSCustomObject]) {
                        $wf = Get-Prop $pwr @('watts','load_w','load_watts','w')
                    }
                }
                if ($null -eq $wf) { continue }

                $loadWatts = [double]$wf

                $batt = Get-Prop $j @('battery_charge','batteryCharge','battery_capacity',
                                       'batteryCapacity','battery_pct','battery_level','battery')
                if ($batt -is [System.Management.Automation.PSCustomObject]) {
                    $batt = Get-Prop $batt @('charge','capacity','percent','level')
                }
                if ($null -ne $batt) { $batteryPct = [int][double]$batt }

                $rt = Get-Prop $j @('runtime_remaining','runtimeRemaining','runtime_sec',
                                     'runtime_min','runtime','remaining_runtime')
                if ($null -ne $rt) {
                    $rtInt = [int][double]$rt
                    $runtimeMin = if ($rtInt -gt 600) { [int]($rtInt / 60) } else { $rtInt }
                }

                $src = Get-Prop $j @('power_source','powerSource','status','input_source','line_status')
                $ob  = Get-Prop $j @('on_battery','onBattery','battery_mode','onBatt')
                $onBattery = if (($src -match 'battery') -or ($ob -eq $true) -or ($ob -eq 1)) { 1 } else { 0 }

                $gotData   = $true
                $upsSource = 'cyberpower'
                break portLoop
            } catch {}
        }
    }
}

# ── Method 4: ProgramData XML / JSON status files ─────────────────────────────
# pppd writes UPS status to ProgramData between API calls
if ($PPPDir -and -not $gotData) {
    $dataRoots = @(
        'C:\ProgramData\CyberPower\PowerPanel Personal',
        'C:\ProgramData\CyberPower'
    )
    foreach ($root in $dataRoots) {
        if (-not (Test-Path $root)) { continue }

        $files = Get-ChildItem $root -Recurse -Include '*.xml','*.json' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 20

        foreach ($f in $files) {
            try {
                if ($f.Extension -eq '.json') {
                    $j  = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                    $wf = Get-Prop $j @('load_w','load_watts','loadWatts','watts','load','power')
                    if ($null -ne $wf -and [double]$wf -gt 0) {
                        $loadWatts = [double]$wf
                        $gotData   = $true
                        $upsSource = 'cyberpower'
                        $batt = Get-Prop $j @('battery_charge','batteryCharge','battery','capacity')
                        if ($null -ne $batt) { $batteryPct = [int][double]$batt }
                    }
                } elseif ($f.Extension -eq '.xml') {
                    [xml]$xml = Get-Content $f.FullName -Raw -ErrorAction Stop
                    foreach ($nn in @('load','Load','watts','Watts','power','Power','outputLoad')) {
                        $node = $xml.SelectSingleNode("//$nn")
                        if ($node -and $node.InnerText -match '^\d+(\.\d+)?$') {
                            $v = [double]$node.InnerText
                            if ($v -gt 0 -and $v -lt 10000) {
                                $loadWatts = $v
                                $gotData   = $true
                                $upsSource = 'cyberpower'
                                # Try sibling nodes for battery/runtime
                                $p = $node.ParentNode
                                foreach ($bn in @('battery','Battery','capacity','Capacity')) {
                                    $bn2 = $p.SelectSingleNode($bn)
                                    if ($bn2 -and $bn2.InnerText -match '^\d+$') {
                                        $batteryPct = [int]$bn2.InnerText; break
                                    }
                                }
                                foreach ($rn in @('runtime','Runtime','remaining','timeRemaining')) {
                                    $rn2 = $p.SelectSingleNode($rn)
                                    if ($rn2 -and $rn2.InnerText -match '^\d+$') {
                                        $runtimeMin = [int]$rn2.InnerText; break
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            } catch {}
            if ($gotData) { break }
        }
        if ($gotData) { break }
    }
}

# ── Method 5: apcaccess.exe (APC UPS via apcupsd for Windows) ─────────────────
# Install apcupsd for Windows from https://www.apcupsd.com/
# apcaccess.exe is included and parses the same output as Linux apcupsd.
if (-not $gotData) {
    $ApcCandidates = @(
        'C:\Program Files\apcupsd\bin\apcaccess.exe',
        'C:\Program Files (x86)\apcupsd\bin\apcaccess.exe'
    )
    $ApcExe = $null
    foreach ($c in $ApcCandidates) {
        if (Test-Path $c) { $ApcExe = $c; break }
    }
    if (-not $ApcExe) {
        $found = Get-Command apcaccess.exe -ErrorAction SilentlyContinue
        $ApcExe = if ($found) { $found.Source } else { $null }
    }

    if ($ApcExe) {
        try {
            $out = & $ApcExe status 2>$null
            $s   = ($out -join "`n")
            # LOADPCT  : 15.0 Percent
            # NOMPOWER : 330 Watts
            # BCHARGE  : 100.0 Percent
            # TIMELEFT : 54.7 Minutes
            # STATUS   : ONLINE  or  ONBATT
            $loadPct = $null
            $nomPow  = $null
            if ($s -match 'LOADPCT\s*:\s*([\d.]+)')   { $loadPct = [double]$Matches[1] }
            if ($s -match 'NOMPOWER\s*:\s*([\d.]+)')   { $nomPow  = [double]$Matches[1] }
            if ($s -match 'BCHARGE\s*:\s*([\d.]+)')    { $batteryPct = [int][double]$Matches[1] }
            if ($s -match 'TIMELEFT\s*:\s*([\d.]+)')   { $runtimeMin = [int][double]$Matches[1] }
            if ($s -match 'STATUS\s*:\s*(\S+)') {
                $onBattery = if ($Matches[1] -like '*ONBATT*') { 1 } else { 0 }
            }
            if ($null -ne $loadPct -and $null -ne $nomPow -and $nomPow -gt 0) {
                $loadWatts = [math]::Round($loadPct / 100.0 * $nomPow, 1)
                $gotData   = $true
                $upsSource = 'apcupsd'
            }
        } catch {}
    }
}

# ── Method 6: Win32_Battery WMI (APC and other USB UPS, no watt data) ─────────
# APC USB UPS devices typically register as a Windows battery via the HID driver.
# This gives battery % and runtime but NOT load in watts.
if (-not $gotData) {
    try {
        $bat = Get-WmiObject -Class Win32_Battery -ErrorAction Stop |
               Select-Object -First 1
        if ($bat -and $null -ne $bat.EstimatedChargeRemaining) {
            $batteryPct = [int]$bat.EstimatedChargeRemaining
            # EstimatedRunTime is in minutes; 65535 means "unknown"
            if ($bat.EstimatedRunTime -and $bat.EstimatedRunTime -lt 65535) {
                $runtimeMin = [int]$bat.EstimatedRunTime
            }
            # BatteryStatus: 1=discharging (on battery), 2=AC power
            $onBattery = if ($bat.BatteryStatus -eq 1) { 1 } else { 0 }
            # No watt data from WMI — $loadWatts stays null
            # We still emit the ups measurement so the UPS Status panel works
            $gotData   = $true
            $upsSource = 'wmi'
        }
    } catch {}
}

if (-not $gotData) { exit 0 }

# ── Emit Telegraf line protocol ────────────────────────────────────────────────
# Use <COMPUTERNAME>-ups as host tag so the UPS appears as its own device in Grafana,
# separate from the CPU/DRAM power estimate for the same machine.
$upsHost = "$env:COMPUTERNAME-ups".ToLower()

# Power measurement — only emitted when we have actual watt data
# (Win32_Battery / WMI gives battery info but not load watts)
if ($null -ne $loadWatts) {
    Write-Output ("power,source={0},domain=total,host={1} watts={2}" -f $upsSource, $upsHost, $loadWatts)
}

# UPS health metrics
if ($null -ne $batteryPct) {
    Write-Output ("ups,source={0},host={1} battery_pct={2}i" -f $upsSource, $upsHost, $batteryPct)
}
if ($null -ne $runtimeMin) {
    Write-Output ("ups,source={0},host={1} runtime_min={2}i" -f $upsSource, $upsHost, $runtimeMin)
}
Write-Output ("ups,source={0},host={1} on_battery={2}i" -f $upsSource, $upsHost, $onBattery)
