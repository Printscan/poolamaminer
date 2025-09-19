#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/h-manifest.conf"

LOG_FILE="${CUSTOM_LOG_BASENAME}.log"
VERSION_VALUE="${CUSTOM_VERSION:-}"
ALGO_VALUE="${CUSTOM_ALGO:-}"
BIN_PATH="$SCRIPT_DIR/gpu"

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

should_skip_bus_id() {
  local id=${1,,}
  if [[ $id =~ ^([0-9a-f]{4}|[0-9a-f]{8}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$ ]]; then
    local bus=${BASH_REMATCH[2]}
    local func=${BASH_REMATCH[4]}
    if [[ $bus == "00" ]] && [[ $func == "0" ]]; then
      return 0
    fi
  elif [[ $id =~ ^([0-9a-f]{2}):([0-9a-f]{1,2})\.([0-7])$ ]]; then
    local bus=${BASH_REMATCH[1]}
    local func=${BASH_REMATCH[3]}
    if [[ $bus == "00" ]] && [[ $func == "0" ]]; then
      return 0
    fi
  fi
  return 1
}

get_proc_uptime() {
  if [[ ! -x $BIN_PATH ]]; then
    return 1
  fi
  if ! command -v pgrep >/dev/null 2>&1; then
    return 1
  fi

  mapfile -t pids < <(pgrep -f "$BIN_PATH" 2>/dev/null || true)
  for pid in "${pids[@]}"; do
    [[ -z $pid ]] && continue
    etimes=$(ps -p "$pid" -o etimes= 2>/dev/null | awk 'NR==1 { gsub(/^[ \t]+/, ""); print }')
    if [[ $etimes =~ ^[0-9]+$ ]]; then
      echo "$etimes"
      return 0
    fi
  done

  return 1
}

declare -a temp_arr fan_arr busids_hex bus_arr
declare -A skip_idx

if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=, read -r idx temp fan busid; do
    idx=${idx//[[:space:]]/}
    [[ -z $idx ]] && continue

    temp=${temp//[[:space:]]/}
    if [[ ! $temp =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      temp=0
    fi
    temp=${temp%%.*}

    fan=${fan//[[:space:]]/}
    if [[ ! $fan =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      fan=0
    fi
    fan=${fan%%.*}

    busid=${busid//[[:space:]]/}
    [[ -z $busid ]] && busid="0000:00:00.0"

    temp_arr[idx]=$temp
    fan_arr[idx]=$fan
    busids_hex[idx]=${busid,,}
  done < <(nvidia-smi --query-gpu=index,temperature.gpu,fan.speed,pci.bus_id --format=csv,noheader,nounits 2>/dev/null || true)
fi

for idx in "${!busids_hex[@]}"; do
  id=${busids_hex[idx]}
  if should_skip_bus_id "$id"; then
    skip_idx[$idx]=1
  fi
  bus_part=${id%%:*}
  if [[ $id =~ ^([0-9a-fA-F]{4}|[0-9a-fA-F]{8}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.[0-7]$ ]]; then
    bus_part=${BASH_REMATCH[2]}
  elif [[ $id =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{1,2})\.[0-7]$ ]]; then
    bus_part=${BASH_REMATCH[1]}
  fi
  if [[ $bus_part =~ ^[0-9a-fA-F]+$ ]]; then
    bus_arr[$idx]=$((16#$bus_part))
  else
    bus_arr[$idx]=0
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
temp_out=()
fan_out=()
bus_out=()
for ((i=0; i<count; i++)); do
  if [[ -n ${skip_idx[$i]:-} ]]; then
    continue
  fi
  value=${hs_map[$i]:-0}
  if [[ $value == 0 ]]; then
    kh=0
  else
    kh=$(awk -v v="$value" 'BEGIN { printf "%.3f", v/1000 }')
  fi
  hs_arr+=("$kh")
  shares_arr+=("${acc_map[$i]:-0}")
  temp_out+=("${temp_arr[i]:-0}")
  fan_out+=("${fan_arr[i]:-0}")
  bus_out+=("${bus_arr[i]:-0}")
done

sum_khs=0
for val in "${hs_arr[@]}"; do
  sum_khs=$(awk -v a="$sum_khs" -v b="$val" 'BEGIN { printf "%.3f", a + b }')
done

accepted_total=0
for val in "${shares_arr[@]}"; do
  accepted_total=$(( accepted_total + val ))
done

if uptime=$(get_proc_uptime); then
  :
elif [[ -f $LOG_FILE ]]; then
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
  (( uptime = now - file_mtime ))
  (( uptime < 0 )) && uptime=0
else
  uptime=0
fi

hs_json=$(array_to_json_numbers hs_arr)
temp_json=$(array_to_json_numbers temp_out)
fan_json=$(array_to_json_numbers fan_out)
bus_json=$(array_to_json_numbers bus_out)
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
