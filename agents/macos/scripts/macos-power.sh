#!/usr/bin/env bash
# macos-power.sh — Read power via powermetrics and emit Telegraf line protocol
# Must run as root (powermetrics requires root access)
# Supports Apple Silicon (M-series) and Intel Macs
# Output: power,source=powermetrics,domain=<name> watts=<value>

set -euo pipefail

# One sample at 1000ms interval — this call blocks for ~1 second
output=$(powermetrics --samplers cpu_power -n 1 -i 1000 2>/dev/null)

if [[ -z "$output" ]]; then
    echo "# powermetrics returned no output" >&2
    exit 0
fi

if echo "$output" | grep -q "Combined Power"; then
    # ── Apple Silicon (M-series) ──────────────────────────────────────────────
    # CPU Power includes all efficiency + performance clusters
    # Parse "VALUE mW" or "VALUE W" — normalise everything to watts
    cpu_w=$(echo "$output"   | awk '/^CPU Power:/     {v=$(NF-1); print ($NF=="mW" ? v/1000 : v)}')
    gpu_w=$(echo "$output"   | awk '/^GPU Power:/     {v=$(NF-1); print ($NF=="mW" ? v/1000 : v)}')
    ane_w=$(echo "$output"   | awk '/^ANE Power:/     {v=$(NF-1); print ($NF=="mW" ? v/1000 : v)}')
    # "Combined Power (CPU + GPU + ANE): NNN mW"  or  "... NNN W"
    total_w=$(echo "$output" | awk '/^Combined Power/ {v=$(NF-1); print ($NF=="mW" ? v/1000 : v)}')

    awk -v cpu="${cpu_w:-0}" \
        -v gpu="${gpu_w:-0}" \
        -v ane="${ane_w:-0}" \
        -v total="${total_w:-0}" \
    'BEGIN {
        if (cpu+0   > 0) printf "power,source=powermetrics,domain=cpu   watts=%.3f\n", cpu
        if (gpu+0   > 0) printf "power,source=powermetrics,domain=gpu   watts=%.3f\n", gpu
        if (ane+0   > 0) printf "power,source=powermetrics,domain=ane   watts=%.3f\n", ane
        if (total+0 > 0) printf "power,source=powermetrics,domain=total watts=%.3f\n", total
    }'

elif echo "$output" | grep -q "Intel energy model"; then
    # ── Intel Mac ─────────────────────────────────────────────────────────────
    # "Intel energy model derived package power (eDPP): NN.NN W"  or  "... NN.NN mW"
    pkg_w=$(echo "$output" | awk '/Intel energy model derived package power/ {v=$(NF-1); print ($NF=="mW" ? v/1000 : v)}')

    awk -v pkg="${pkg_w:-0}" \
    'BEGIN {
        if (pkg+0 > 0) {
            printf "power,source=powermetrics,domain=package watts=%.3f\n", pkg
            printf "power,source=powermetrics,domain=total   watts=%.3f\n", pkg
        }
    }'

else
    echo "# Unrecognised powermetrics output — unsupported macOS/hardware version" >&2
    exit 0
fi
