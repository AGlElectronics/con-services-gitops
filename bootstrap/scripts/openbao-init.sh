#!/usr/bin/env bash
# Initialise and configure OpenBao for Con Services. Run ONCE from a computer
# with kubectl access to the cluster, when the openbao-0/1/2 pods are
# Running (but not Ready: they are sealed). Safe to run again: every step
# checks what is already done.
#
#   INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-init.sh
#
# What it does:
#   1. bao operator init (5 unseal keys, 3 needed) -> written ONLY to
#      $INIT_FILE (mode 600). Nothing secret is printed.
#   2. Unseals all three pods with 3 keys from that file.
#   3. Enables the KV v2 engine at kv/ and the Kubernetes auth method, and
#      checks the audit log (declared in values/openbao.yaml) is active.
#   4. Creates policy "external-secrets-read" (read kv/data/*) and role
#      "external-secrets" for service account external-secrets/external-secrets
#      (used by ClusterSecretStore "openbao").
#
# AFTERWARDS: run openbao-seed.sh, then move $INIT_FILE OFFLINE (password
# manager, encrypted USB stick, paper in a safe; split the 5 keys between
# people). Anyone holding 3 keys and cluster access can read every secret.
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail
umask 077

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"
need kubectl jq

INIT_FILE="${INIT_FILE:-./openbao-init.json}"
KEY_SHARES="${KEY_SHARES:-5}"
KEY_THRESHOLD="${KEY_THRESHOLD:-3}"

pod0="$(pod_name 0)"
kubectl get pod -n "$OPENBAO_NAMESPACE" "$pod0" >/dev/null 2>&1 \
  || die "pod $OPENBAO_NAMESPACE/$pod0 not found; wait for the openbao Application to sync"

# --- 1. Initialise -----------------------------------------------------------
initialized="$(status_field "$pod0" initialized)"
[[ -n "$initialized" ]] || die "cannot read 'bao status' from $pod0 (is the pod running?)"

if [[ "$initialized" == "true" ]]; then
  log "OpenBao is already initialised"
  [[ -r "$INIT_FILE" ]] || die "already initialised but $INIT_FILE is missing; unseal with openbao-unseal.sh and configure with BAO_TOKEN"
else
  [[ ! -e "$INIT_FILE" ]] || die "$INIT_FILE exists although OpenBao is not initialised; move it away first"
  log "Initialising ($KEY_SHARES key shares, threshold $KEY_THRESHOLD) -> $INIT_FILE"
  kubectl exec -n "$OPENBAO_NAMESPACE" "$pod0" -- \
    bao operator init -key-shares="$KEY_SHARES" -key-threshold="$KEY_THRESHOLD" -format=json \
    > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  jq -e '.root_token and (.unseal_keys_b64 | length > 0)' "$INIT_FILE" >/dev/null \
    || die "init output in $INIT_FILE looks wrong; inspect it (it may contain keys!)"
  log "Init done. Keys and root token are in $INIT_FILE (not shown)."
fi

# --- 2. Unseal every pod -------------------------------------------------------
unseal_pod() {
  local pod=$1 i sealed
  for ((i = 0; i < 60; i++)); do
    sealed="$(status_field "$pod" sealed)"
    [[ -n "$sealed" ]] && break
    sleep 5
  done
  [[ "$sealed" == "false" ]] && { log "$pod is unsealed"; return 0; }
  [[ "$sealed" == "true" ]] || die "$pod does not answer"
  log "Unsealing $pod"
  for ((i = 0; i < KEY_THRESHOLD; i++)); do
    jq -r ".unseal_keys_b64[$i]" "$INIT_FILE" | bao_unseal_key "$pod"
  done
  [[ "$(status_field "$pod" sealed)" == "false" ]] || die "$pod is still sealed"
}

unseal_pod "$pod0"
# The other pods join the Raft cluster on their own (retry_join) once the
# first one is unsealed; then they need the keys too.
for ((n = 1; n < OPENBAO_REPLICAS; n++)); do
  pod="$(pod_name "$n")"
  log "Waiting for $pod to join the Raft cluster"
  for ((i = 0; i < 60; i++)); do
    [[ "$(status_field "$pod" initialized)" == "true" ]] && break
    sleep 5
  done
  unseal_pod "$pod"
done

# --- 3. Engines and auth -------------------------------------------------------
TOKEN="$(jq -r '.root_token' "$INIT_FILE")"

if bao_cmd "$TOKEN" bao secrets list -format=json | jq -e 'has("kv/")' >/dev/null; then
  log "KV engine kv/ already enabled"
else
  bao_cmd "$TOKEN" bao secrets enable -path=kv -version=2 kv >/dev/null
  log "Enabled KV v2 at kv/"
fi

if bao_cmd "$TOKEN" bao audit list -format=json 2>/dev/null | jq -e 'has("file/")' >/dev/null; then
  log "Audit log active (declared in the server configuration)"
else
  log "WARNING: no audit device; check the 'audit' stanza in values/openbao.yaml"
fi

if bao_cmd "$TOKEN" bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  log "Kubernetes auth already enabled"
else
  bao_cmd "$TOKEN" bao auth enable kubernetes >/dev/null
  log "Enabled Kubernetes auth"
fi
# OpenBao checks service account tokens against the API server with its own
# service account (the chart grants it system:auth-delegator).
bao_cmd "$TOKEN" bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
log "Configured Kubernetes auth"

# --- 4. Policy and role for External Secrets Operator ----------------------------
bao_as "$TOKEN" bao policy write external-secrets-read - >/dev/null <<'EOF'
# External Secrets Operator: read every secret under kv/.
# Add "list" on kv/metadata/* if you use ExternalSecret dataFrom.find.
path "kv/data/*" {
  capabilities = ["read"]
}
EOF
log "Wrote policy external-secrets-read"

bao_cmd "$TOKEN" bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  token_policies=external-secrets-read \
  token_ttl=1h >/dev/null
log "Wrote role external-secrets"

cat >&2 <<EOF

Done. OpenBao is initialised, unsealed and ready for External Secrets Operator.

Next:
  1. Seed the secrets:   INIT_FILE=$INIT_FILE bash bootstrap/scripts/openbao-seed.sh
  2. Move $INIT_FILE OFFLINE and delete it from this computer.
  3. After any OpenBao pod restart: bash bootstrap/scripts/openbao-unseal.sh
EOF
