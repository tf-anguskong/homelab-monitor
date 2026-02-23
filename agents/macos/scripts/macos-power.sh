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
    cpu_mw=$(echo "$output"   | awk '/^CPU Power:/     {print $3}')
    gpu_mw=$(echo "$output"   | awk '/^GPU Power:/     {print $3}')
    ane_mw=$(echo "$output"   | awk '/^ANE Power:/     {print $3}')
    # "Combined Power (CPU + GPU + ANE): NNN mW"
    total_mw=$(echo "$output" | awk '/^Combined Power/ {print $NF}')

    awk -v cpu="${cpu_mw:-0}" \
        -v gpu="${gpu_mw:-0}" \
        -v ane="${ane_mw:-0}" \
        -v total="${total_mw:-0}" \
    'BEGIN {
        if (cpu+0   > 0) printf "power,source=powermetrics,domain=cpu   watts=%.3f\n", cpu/1000
        if (gpu+0   > 0) printf "power,source=powermetrics,domain=gpu   watts=%.3f\n", gpu/1000
        if (ane+0   > 0) printf "power,source=powermetrics,domain=ane   watts=%.3f\n", ane/1000
        if (total+0 > 0) printf "power,source=powermetrics,domain=total watts=%.3f\n", total/1000
    }'

elif echo "$output" | grep -q "Intel energy model"; then
    # ── Intel Mac ─────────────────────────────────────────────────────────────
    # "Intel energy model derived package power (eDPP): NN.NN W"
    pkg_w=$(echo "$output" | awk '/Intel energy model derived package power/ {print $NF}')

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
