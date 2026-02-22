#Requires -Version 5.1
# windows-power.ps1 — Estimate system power draw and emit Telegraf line protocol
# Outputs: power,source=wmi,domain=<cpu|dram|total> watts=<value>
#
# For laptops on battery: reads real discharge rate from MSAcpi_BatteryStatus
# For desktops / laptops on AC: interpolates CPU load against TDP estimate
# Set CPU_TDP_WATTS env var to match your CPU's rated TDP (default: 65W)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BatteryWatts {
    try {
        $battery = Get-WmiObject -Namespace 'root\wmi' -Class 'MSAcpi_BatteryStatus' -ErrorAction Stop
        if ($null -eq $battery) { return $null }

        # DischargeRate is in mW, ChargeRate also in mW
        # If discharging, DischargeRate > 0 and gives real power draw
        foreach ($b in $battery) {
            if ($b.DischargeRate -gt 0) {
                return [math]::Round($b.DischargeRate / 1000.0, 2)
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-CpuLoadPercent {
    try {
        $cpus = Get-WmiObject -Class 'Win32_Processor' -ErrorAction Stop
        $total = 0
        $count = 0
        foreach ($cpu in $cpus) {
            $total += $cpu.LoadPercentage
            $count++
        }
        if ($count -eq 0) { return 0 }
        return [math]::Round($total / $count, 1)
    }
    catch {
        return 0
    }
}

function Get-DramWatts {
    try {
        $os = Get-WmiObject -Class 'Win32_ComputerSystem' -ErrorAction Stop
        # TotalPhysicalMemory is in bytes
        $ramGb = [math]::Round($os.TotalPhysicalMemory / 1GB, 1)
        # DDR4 typical: ~0.375W per GB at idle, ~0.5W under load
        $dramWatts = [math]::Round($ramGb * 0.375, 2)
        return $dramWatts
    }
    catch {
        return 0
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────

$tdpWatts = 65.0
if ($env:CPU_TDP_WATTS -and $env:CPU_TDP_WATTS -match '^\d+(\.\d+)?$') {
    $tdpWatts = [double]$env:CPU_TDP_WATTS
}

# Try battery first (gives real readings on laptops discharging)
$batteryWatts = Get-BatteryWatts

if ($null -ne $batteryWatts -and $batteryWatts -gt 0) {
    # Real discharge measurement — attribute all to system total
    # Still break out estimated DRAM for info
    $dramWatts = Get-DramWatts
    $cpuWatts = [math]::Round($batteryWatts - $dramWatts, 2)
    if ($cpuWatts -lt 0) { $cpuWatts = 0 }

    Write-Output "power,source=battery,domain=cpu watts=$cpuWatts"
    Write-Output "power,source=battery,domain=dram watts=$dramWatts"
    Write-Output "power,source=battery,domain=total watts=$batteryWatts"
}
else {
    # Desktop or laptop on AC — estimate from CPU load + TDP
    $cpuLoad = Get-CpuLoadPercent

    # Interpolate between idle (~12% TDP) and full load (100% TDP)
    # idle_fraction = 0.12, scale rest linearly with load
    $idleFraction = 0.12
    $cpuWatts = [math]::Round($tdpWatts * ($idleFraction + (1.0 - $idleFraction) * ($cpuLoad / 100.0)), 2)

    $dramWatts = Get-DramWatts
    $totalWatts = [math]::Round($cpuWatts + $dramWatts, 2)

    Write-Output "power,source=wmi,domain=cpu watts=$cpuWatts"
    Write-Output "power,source=wmi,domain=dram watts=$dramWatts"
    Write-Output "power,source=wmi,domain=total watts=$totalWatts"
}
