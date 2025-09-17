#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/h-manifest.conf"

LOG_FILE="${CUSTOM_LOG_BASENAME}.log"
VERSION_VALUE="${CUSTOM_VERSION:-}"
ALGO_VALUE="${CUSTOM_ALGO:-}"
GPU_STATS_FILE=/run/hive/gpu-stats.json

json_escape() {
  local str=${1-}
  str=${str//\/\\}
  str=${str//"/\\"}
  str=${str//$'\n'/\\n}
  str=${str//$'\r'/\\r}
  str=${str//$'\t'/\\t}
  echo "$str"
}

array_to_json_numbers() {
  local -n arr_ref=$1
  local output="["
  local val
  for val in "${arr_ref[@]}"; do
    output+="${val:-0},"
  done
  if [[ $output == "[" ]]; then
    printf '[]'
  else
    printf '%s' "${output%,}]"
  fi
}

declare -a temp_arr fan_arr busids_hex bus_arr
if command -v jq >/dev/null 2>&1 && [[ -f $GPU_STATS_FILE ]]; then
  mapfile -t temp_arr   < <(jq -r '.temp[]? | tonumber' "$GPU_STATS_FILE")
  mapfile -t fan_arr    < <(jq -r '.fan[]? | tonumber' "$GPU_STATS_FILE")
  mapfile -t busids_hex < <(jq -r '.busids[]?' "$GPU_STATS_FILE")
fi

for id in "${busids_hex[@]}"; do
  bus_part=${id%%:*}
  if [[ $bus_part =~ ^[0-9a-fA-F]+$ ]]; then
    bus_arr+=( $((16#$bus_part)) )
  else
    bus_arr+=(0)
  fi
done

declare -A hs_map acc_map
if [[ -f $LOG_FILE ]]; then
  while IFS= read -r line; do
    if [[ $line =~ ^GPU\[([0-9]+)\][[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]+([0-9]+) ]]; then
      idx=${BASH_REMATCH[1]}
      rate=${BASH_REMATCH[2]}
      shares=${BASH_REMATCH[4]}
      hs_map[$idx]=$rate
      acc_map[$idx]=$shares
    fi
  done < <(tac "$LOG_FILE" | head -n 2000)
fi

# Determine GPU count
seen=()
for idx in "${!hs_map[@]}"; do
  seen+=("$idx")
done

count=${#temp_arr[@]}
(( ${#fan_arr[@]} > count )) && count=${#fan_arr[@]}
(( ${#bus_arr[@]} > count )) && count=${#bus_arr[@]}
for idx in "${seen[@]}"; do
  (( idx + 1 > count )) && count=$((idx + 1))
done

hs_arr=()
shares_arr=()
for ((i=0; i<count; i++)); do
  value=${hs_map[$i]:-0}
  if [[ $value == 0 ]]; then
    kh=0
  else
    kh=$(awk -v v="$value" 'BEGIN { printf "%.3f", v/1000 }')
  fi
  hs_arr[i]=$kh
  shares_arr[i]=${acc_map[$i]:-0}
  (( i >= ${#temp_arr[@]} )) && temp_arr[i]=0
  (( i >= ${#fan_arr[@]} )) && fan_arr[i]=0
  (( i >= ${#bus_arr[@]} )) && bus_arr[i]=0
done

sum_khs=0
for val in "${hs_arr[@]}"; do
  sum_khs=$(awk -v a="$sum_khs" -v b="$val" 'BEGIN { printf "%.3f", a + b }')
done

accepted_total=0
for val in "${shares_arr[@]}"; do
  accepted_total=$(( accepted_total + val ))
done

if [[ -f $LOG_FILE ]]; then
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
  (( uptime = now - file_mtime ))
  (( uptime < 0 )) && uptime=0
else
  uptime=0
fi

hs_json=$(array_to_json_numbers hs_arr)
temp_json=$(array_to_json_numbers temp_arr)
fan_json=$(array_to_json_numbers fan_arr)
bus_json=$(array_to_json_numbers bus_arr)
if command -v jq >/dev/null 2>&1; then
  stats=$(jq -nc \
    --argjson hs "$hs_json" \
    --argjson temp "$temp_json" \
    --argjson fan "$fan_json" \
    --argjson bus "$bus_json" \
    --arg ver "$VERSION_VALUE" \
    --arg algo "$ALGO_VALUE" \
    --argjson uptime "$uptime" \
    --arg total "$sum_khs" \
    --arg accepted "$accepted_total" \
    '{
      hs: $hs,
      hs_units: "khs",
      temp: $temp,
      fan: $fan,
      bus_numbers: $bus,
      uptime: $uptime,
      ver: $ver,
      ar: [($accepted | tonumber), 0],
      total_khs: ($total | tonumber)
    } | if $algo == "" then . else . + {algo: $algo} end')
else
  ver_json=$(json_escape "$VERSION_VALUE")
  hs_units="\"khs\""
  stats="{\"hs\":$hs_json,\"hs_units\":$hs_units,\"temp\":$temp_json,\"fan\":$fan_json,\"bus_numbers\":$bus_json,\"uptime\":$uptime,\"ver\":\"$ver_json\",\"ar\":[${accepted_total},0],\"total_khs\":$sum_khs"
  if [[ -n $ALGO_VALUE ]]; then
    algo_json=$(json_escape "$ALGO_VALUE")
    stats+=",\"algo\":\"$algo_json\"}"
  else
    stats+='}'
  fi
fi

[[ -z $sum_khs ]] && sum_khs=0
[[ -z $stats ]] && stats='{"hs":[],"hs_units":"khs","temp":[],"fan":[],"uptime":0,"ver":"","ar":[],"total_khs":0}'

echo "$sum_khs"
echo "$stats"
