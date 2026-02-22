#!/usr/bin/env bash
# rapl-power.sh — Read Intel RAPL energy counters and emit Telegraf line protocol
# Requires read access to /sys/class/powercap/intel-rapl (root or 'power' group)
# Output: power,source=rapl,domain=<name> watts=<value>

set -euo pipefail

RAPL_BASE="/sys/class/powercap/intel-rapl"

if [[ ! -d "$RAPL_BASE" ]]; then
    echo "# RAPL not available at $RAPL_BASE" >&2
    exit 0
fi

# Collect all RAPL domains (package + sub-domains like core, uncore, dram)
declare -A energy_start
declare -A energy_max
declare -A domain_name

for domain_path in "$RAPL_BASE"/intel-rapl:*; do
    [[ -d "$domain_path" ]] || continue
    [[ -f "$domain_path/energy_uj" ]] || continue

    key=$(basename "$domain_path")
    energy_start["$key"]=$(cat "$domain_path/energy_uj")
    energy_max["$key"]=$(cat "$domain_path/max_energy_range_uj" 2>/dev/null || echo "4294967295")

    if [[ -f "$domain_path/name" ]]; then
        raw_name=$(cat "$domain_path/name")
        # Sanitize name: replace spaces and colons with dashes
        domain_name["$key"]="${raw_name// /-}"
        domain_name["$key"]="${domain_name["$key"]//:/-}"
    else
        domain_name["$key"]="$key"
    fi

    # Also collect sub-domains (e.g., core, uncore, dram)
    for sub_path in "$domain_path"/intel-rapl:*; do
        [[ -d "$sub_path" ]] || continue
        [[ -f "$sub_path/energy_uj" ]] || continue

        sub_key=$(basename "$sub_path")
        energy_start["$sub_key"]=$(cat "$sub_path/energy_uj")
        energy_max["$sub_key"]=$(cat "$sub_path/max_energy_range_uj" 2>/dev/null || echo "4294967295")

        if [[ -f "$sub_path/name" ]]; then
            raw_name=$(cat "$sub_path/name")
            domain_name["$sub_key"]="${raw_name// /-}"
            domain_name["$sub_key"]="${domain_name["$sub_key"]//:/-}"
        else
            domain_name["$sub_key"]="$sub_key"
        fi
    done
done

if [[ ${#energy_start[@]} -eq 0 ]]; then
    echo "# No RAPL domains found" >&2
    exit 0
fi

# Record start time in microseconds
t_start=$(date +%s%6N)

sleep 1

# Record end time and energy
t_end=$(date +%s%6N)
delta_us=$(( t_end - t_start ))

for key in "${!energy_start[@]}"; do
    # Find the energy_uj file for this key
    energy_file=""
    if [[ "$key" =~ ^intel-rapl:[0-9]+$ ]]; then
        energy_file="$RAPL_BASE/$key/energy_uj"
    else
        # Sub-domain: e.g., intel-rapl:0:0
        parent_key=$(echo "$key" | sed 's/:\([0-9]*\)$//')
        energy_file="$RAPL_BASE/$parent_key/$key/energy_uj"
    fi

    [[ -f "$energy_file" ]] || continue

    energy_end=$(cat "$energy_file")
    e_start=${energy_start["$key"]}
    e_max=${energy_max["$key"]}
    name=${domain_name["$key"]}

    # Handle counter wraparound
    awk -v e_start="$e_start" \
        -v e_end="$energy_end" \
        -v e_max="$e_max" \
        -v delta_us="$delta_us" \
        -v name="$name" \
    'BEGIN {
        delta_uj = e_end - e_start
        if (delta_uj < 0) {
            delta_uj = e_max - e_start + e_end
        }
        watts = delta_uj / delta_us
        if (watts >= 0 && watts < 10000) {
            printf "power,source=rapl,domain=%s watts=%.3f\n", name, watts
        }
    }'
done
