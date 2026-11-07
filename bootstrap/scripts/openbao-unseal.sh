#!/usr/bin/env bash
# Unseal every sealed OpenBao pod. Needed after EVERY pod restart (node
# reboot, upgrade, eviction): a sealed pod is not Ready and serves nothing.
#
#   bash bootstrap/scripts/openbao-unseal.sh
#
# Asks for unseal keys without echoing them (3 different keys of the 5).
# Key holders can take turns at the keyboard. Alternatively, while the init
# file is still on this computer: INIT_FILE=./openbao-init.json bash ...
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"
need kubectl jq

KEY_THRESHOLD="${KEY_THRESHOLD:-3}"
keys=()

get_keys() {
  ((${#keys[@]} > 0)) && return 0
  if [[ -n "${INIT_FILE:-}" ]]; then
    mapfile -t keys < <(jq -r ".unseal_keys_b64[0:$KEY_THRESHOLD][]" "$INIT_FILE")
  else
    local i k
    for ((i = 1; i <= KEY_THRESHOLD; i++)); do
      read -r -s -p "Unseal key $i of $KEY_THRESHOLD: " k; echo >&2
      keys+=("$k")
    done
  fi
}

for ((n = 0; n < OPENBAO_REPLICAS; n++)); do
  pod="$(pod_name "$n")"
  sealed="$(status_field "$pod" sealed)"
  case "$sealed" in
    false) log "$pod: unsealed" ;;
    true)
      get_keys
      log "$pod: unsealing"
      for k in "${keys[@]}"; do printf '%s\n' "$k" | bao_unseal_key "$pod"; done
      if [[ "$(status_field "$pod" sealed)" == "false" ]]; then
        log "$pod: unsealed"
      else
        log "$pod: STILL SEALED (wrong key?)"
      fi
      ;;
    *) log "$pod: not reachable (pod not running?)" ;;
  esac
done
keys=()
