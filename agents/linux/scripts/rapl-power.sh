#!/usr/bin/env bash
# rapl-power.sh — Read Intel RAPL energy counters and emit Telegraf line protocol
# Requires root or read access to /sys/class/powercap/intel-rapl
# Output: power,source=rapl,domain=<name> watts=<value>
#         power,source=rapl,domain=total  watts=<sum of package-level domains>

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

# Compute watts for each domain and store results
declare -A watts_result

for key in "${!energy_start[@]}"; do
    if [[ "$key" =~ ^intel-rapl:[0-9]+$ ]]; then
        energy_file="$RAPL_BASE/$key/energy_uj"
    else
        parent_key=$(echo "$key" | sed 's/:[0-9]*$//')
        energy_file="$RAPL_BASE/$parent_key/$key/energy_uj"
    fi

    [[ -f "$energy_file" ]] || continue

    energy_end=$(cat "$energy_file")
    e_start=${energy_start["$key"]}
    e_max=${energy_max["$key"]}

    watts_val=$(awk -v e_start="$e_start" \
        -v e_end="$energy_end" \
        -v e_max="$e_max" \
        -v delta_us="$delta_us" \
    'BEGIN {
        delta_uj = e_end - e_start
        if (delta_uj < 0) {
            delta_uj = e_max - e_start + e_end
        }
        watts = delta_uj / delta_us
        if (watts >= 0 && watts < 10000) {
            printf "%.3f", watts
        }
    }')

    [[ -n "$watts_val" ]] && watts_result["$key"]="$watts_val"
done

# Emit individual domain lines
for key in "${!watts_result[@]}"; do
    echo "power,source=rapl,domain=${domain_name[$key]} watts=${watts_result[$key]}"
done

# Emit total = sum of package-level domains only (intel-rapl:N, not intel-rapl:N:M)
# Package-level already includes core + uncore + dram — don't double-count sub-domains
total_watts="0"
for key in "${!watts_result[@]}"; do
    if [[ "$key" =~ ^intel-rapl:[0-9]+$ ]]; then
        total_watts=$(awk -v a="$total_watts" -v b="${watts_result[$key]}" \
            'BEGIN { printf "%.3f", a + b }')
    fi
done

if awk -v t="$total_watts" 'BEGIN { exit !(t > 0) }'; then
    echo "power,source=rapl,domain=total watts=$total_watts"
fi
