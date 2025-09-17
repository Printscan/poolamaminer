#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/h-manifest.conf"

error() {
  echo "ERROR: $*" >&2
  return 1
}

[[ -z "${CUSTOM_CONFIG_FILENAME:-}" ]] && error "CUSTOM_CONFIG_FILENAME is not set"
[[ -z "${CUSTOM_TEMPLATE:-}" ]] && error "CUSTOM_TEMPLATE (wallet/login) is empty"

substitute_placeholders() {
  local value="$1"
  value="${value//%WORKER_NAME%/${WORKER_NAME:-}}"
  value="${value//%WORKER_ID%/${WORKER_ID:-}}"
  value="${value//%FARM_ID%/${FARM_ID:-}}"
  echo "$value"
}

wallet=$(substitute_placeholders "$CUSTOM_TEMPLATE")
raw_pass="${CUSTOM_PASS:-%WORKER_NAME%}"
raw_pass=$(substitute_placeholders "$raw_pass")
rig_name="${WORKER_NAME:-}"
secret=""

if [[ -n "$raw_pass" ]]; then
  read -r -a pass_tokens <<< "$raw_pass"
  for token in "${pass_tokens[@]}"; do
    [[ -z "$token" ]] && continue

    case $token in
      SECRET=*|secret=*)
        secret=${token#*=}
        continue
        ;;
      SECRET:*|secret:*)
        secret=${token#*:}
        continue
        ;;
      RIG=*|rig=*)
        rig_name=${token#*=}
        continue
        ;;
      RIG:*|rig:*)
        rig_name=${token#*:}
        continue
        ;;
      WALLET=*|wallet=*)
        wallet=${token#*=}
        continue
        ;;
      WALLET:*|wallet:*)
        wallet=${token#*:}
        continue
        ;;
    esac

    if [[ -z "$secret" ]]; then
      secret="$token"
    fi
  done
fi

if [[ -z "$secret" ]]; then
  secret="${WORKER_NAME:-}"
fi

extra_args="${CUSTOM_USER_CONFIG:-}"

if [[ -n "$extra_args" ]]; then
  eval "set -- $extra_args"
  remaining=()
  while (($#)); do
    token=$1
    shift
    case $token in
      RIG=*|rig=*)
        rig_name=${token#*=}
        ;;
      SECRET=*|secret=*)
        secret=${token#*=}
        ;;
      WALLET=*|wallet=*)
        wallet=${token#*=}
        ;;
      *)
        remaining+=("$token")
        ;;
    esac
  done
  extra_args="${remaining[*]:-}"
fi

mkdir -p "$(dirname "$CUSTOM_CONFIG_FILENAME")"
cat > "$CUSTOM_CONFIG_FILENAME" <<CFG
RIG=$(printf '%q' "$rig_name")
SECRET=$(printf '%q' "$secret")
WALLET=$(printf '%q' "$wallet")
EXTRA_ARGS=$(printf '%q' "$extra_args")
CFG

chmod 600 "$CUSTOM_CONFIG_FILENAME"
