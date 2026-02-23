#!/bin/sh
# synology-power.sh — Estimate CPU power draw via TDP interpolation
# Runs inside the Telegraf Docker container on Synology.
# Reads host CPU stats from /rootfs/proc/stat (mounted from host).
#
# Method: two /proc/stat samples 1 second apart → CPU busy % →
#   interpolate between idle power (20% TDP) and full TDP.
#
# Output: power,source=tdp-estimate,domain=total watts=X.XXX

TDP=${CPU_TDP_WATTS:-13}

# Read total and idle jiffies from host /proc/stat
sample() {
    awk '/^cpu / { print $2+$3+$4+$5+$6+$7+$8, $5; exit }' /rootfs/proc/stat
}

s1=$(sample)
sleep 1
s2=$(sample)

awk -v s1="$s1" -v s2="$s2" -v tdp="$TDP" 'BEGIN {
    split(s1, a, " ")
    split(s2, b, " ")
    dt = b[1] - a[1]
    di = b[2] - a[2]

    if (dt <= 0) {
        # No delta — report idle power
        printf "power,source=tdp-estimate,domain=total watts=%.3f\n", tdp * 0.20
        exit
    }

    cpu_pct = (1.0 - di / dt) * 100.0
    idle_w  = tdp * 0.20
    watts   = idle_w + (cpu_pct / 100.0) * (tdp - idle_w)
    printf "power,source=tdp-estimate,domain=total watts=%.3f\n", watts
}'
