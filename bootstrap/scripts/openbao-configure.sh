#!/usr/bin/env bash
# The OpenBao administrator's one-time step for Con Services. OpenBao itself
# is a cluster prerequisite: it must already be initialised and unsealed. Run
# once, from the root of your copy of this repository, with a token that may
# manage auth methods and policies (for a fresh OpenBao: the root token).
# Safe to run again: every step checks what is already done.
#
#   BAO_TOKEN=... bash bootstrap/scripts/openbao-configure.sh
#   # or: INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-configure.sh
#   # or without either: the script asks for the token.
#
# It reads cluster.yaml (openbao.*, externalSecrets.*) through the root chart,
# so "helm" is needed, and then:
#   1. Enables the Kubernetes auth method at openbao.auth.mountPath (default
#      kubernetes/) if missing and points it at the cluster's API server.
#   2. Writes policy "conservices-external-secrets": read and create entries
#      below openbao.kvPath. External Secrets Operator reads every secret
#      with it and creates the random ones (PushSecrets).
#   With openbao.setup.enabled (the default):
#   3. Writes policy "conservices-setup" and the role openbao.setup.role for
#      the setup Job's service account. The policy allows only: enable the KV
#      engine at kvPath, and write the role openbao.auth.role with exactly
#      the values from cluster.yaml. Argo CD's openbao-setup Application
#      does the rest when you press Sync.
#   With openbao.setup.enabled: false, it does that part itself:
#   3. Enables the KV version 2 engine at openbao.kvPath (default kv/).
#   4. Writes the role openbao.auth.role (default external-secrets) for
#      externalSecrets.namespace/serviceAccount.
#
# If OpenBao does not run as pods openbao/openbao-N, set OPENBAO_NAMESPACE
# and OPENBAO_RELEASE.
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail
umask 077

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"
need kubectl jq helm

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_FILE="${CLUSTER_FILE:-$REPO_ROOT/cluster.yaml}"
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE (run from your copy of the repository or set CLUSTER_FILE)"

plan="$(seed_plan "$CLUSTER_FILE")"
OPENBAO_KV="$(jq -r '.kvPath' <<<"$plan")"
AUTH_MOUNT="$(jq -r '.authMount' <<<"$plan")"
AUTH_ROLE="$(jq -r '.authRole' <<<"$plan")"
ESO_NAMESPACE="$(jq -r '.esoNamespace' <<<"$plan")"
ESO_SA="$(jq -r '.esoServiceAccount' <<<"$plan")"
SETUP_ENABLED="$(jq -r '.setup.enabled' <<<"$plan")"
SETUP_ROLE="$(jq -r '.setup.role' <<<"$plan")"
SETUP_SA="$(jq -r '.setup.serviceAccount' <<<"$plan")"
SETUP_NAMESPACE="$(jq -r '.setupNamespace' <<<"$plan")"
ESO_POLICY=conservices-external-secrets
SETUP_POLICY=conservices-setup

kubectl get pod -n "$OPENBAO_NAMESPACE" "$(pod_name 0)" >/dev/null 2>&1 \
  || die "pod $OPENBAO_NAMESPACE/$(pod_name 0) not found; set OPENBAO_NAMESPACE and OPENBAO_RELEASE"

TOKEN="$(token_from_env_or_file)"
bao_cmd "$TOKEN" bao token lookup -format=json >/dev/null 2>&1 \
  || die "token rejected (is OpenBao unsealed? is the token valid?)"

# --- 1. Kubernetes auth --------------------------------------------------------------
if bao_cmd "$TOKEN" bao auth list -format=json | jq -e --arg m "$AUTH_MOUNT/" 'has($m)' >/dev/null; then
  log "Kubernetes auth $AUTH_MOUNT/ already enabled"
else
  bao_cmd "$TOKEN" bao auth enable -path="$AUTH_MOUNT" kubernetes >/dev/null
  log "Enabled Kubernetes auth at $AUTH_MOUNT/"
fi
# OpenBao checks service account tokens against the API server with its own
# service account (the upstream chart grants it system:auth-delegator).
bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/config" \
  kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
log "Configured Kubernetes auth"

# --- 2. External Secrets Operator's policy ---------------------------------------------
bao_as "$TOKEN" bao policy write "$ESO_POLICY" - >/dev/null <<EOF
# External Secrets Operator: read every Con Services secret under $OPENBAO_KV/,
# and create the random ones (PushSecret, updatePolicy IfNotExists). It
# never deletes: PushSecrets use deletionPolicy None.
path "$OPENBAO_KV/data/*" {
  capabilities = ["read", "create", "update"]
}
path "$OPENBAO_KV/metadata/*" {
  capabilities = ["read", "create", "update"]
}
EOF
log "Wrote policy $ESO_POLICY"

if [[ "$SETUP_ENABLED" == "true" ]]; then
  # --- 3. The setup Job's policy and role ---------------------------------------------
  bao_as "$TOKEN" bao policy write "$SETUP_POLICY" - >/dev/null <<EOF
# Con Services' openbao-setup Job (Argo CD Application openbao-setup).
# Enable the KV engine Con Services uses. No delete: it cannot remove it.
path "sys/mounts/$OPENBAO_KV" {
  capabilities = ["create", "read", "update"]
}
# Write External Secrets' role, with exactly these values.
path "auth/$AUTH_MOUNT/role/$AUTH_ROLE" {
  capabilities = ["create", "read", "update"]
  allowed_parameters = {
    "bound_service_account_names"      = ["$ESO_SA"]
    "bound_service_account_namespaces" = ["$ESO_NAMESPACE"]
    "token_policies"                   = ["$ESO_POLICY"]
    "token_ttl"                        = ["1h"]
  }
}
EOF
  log "Wrote policy $SETUP_POLICY"
  bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/role/$SETUP_ROLE" \
    bound_service_account_names="$SETUP_SA" \
    bound_service_account_namespaces="$SETUP_NAMESPACE" \
    token_policies="$SETUP_POLICY" \
    token_ttl=10m \
    token_max_ttl=10m >/dev/null
  log "Wrote role $SETUP_ROLE for $SETUP_NAMESPACE/$SETUP_SA"
  cat >&2 <<EOF

Done. Next: Argo CD stops at the Application "openbao-setup". Review its
diff, then press Sync (or: argocd app sync openbao-setup). It enables
$OPENBAO_KV/ and writes the role $AUTH_ROLE.
EOF
  exit 0
fi

# --- 3. KV engine (openbao.setup.enabled: false) ----------------------------------------
mounts="$(bao_cmd "$TOKEN" bao secrets list -format=json)"
if jq -e --arg m "$OPENBAO_KV/" 'has($m)' <<<"$mounts" >/dev/null; then
  version="$(jq -r --arg m "$OPENBAO_KV/" '.[$m].options.version // "1"' <<<"$mounts")"
  [[ "$version" == "2" ]] || die "$OPENBAO_KV/ exists but is KV version $version; Con Services needs version 2"
  log "KV v2 engine $OPENBAO_KV/ already enabled"
else
  bao_cmd "$TOKEN" bao secrets enable -path="$OPENBAO_KV" -version=2 kv >/dev/null
  log "Enabled KV v2 at $OPENBAO_KV/"
fi

# --- 4. External Secrets' role --------------------------------------------------------------
bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/role/$AUTH_ROLE" \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  token_policies="$ESO_POLICY" \
  token_ttl=1h >/dev/null
log "Wrote role $AUTH_ROLE for $ESO_NAMESPACE/$ESO_SA"

cat >&2 <<EOF

Done. OpenBao is ready for External Secrets Operator.
EOF
