#!/usr/bin/env bash
# Prepare the cluster's OpenBao for Con Services. OpenBao itself is a cluster
# prerequisite: it must already be initialised and unsealed. Run once, from
# the root of your copy of this repository, with a token that may manage
# mounts, auth methods and policies (for a fresh OpenBao: the root token).
# Safe to run again: every step checks what is already done.
#
#   BAO_TOKEN=... bash bootstrap/scripts/openbao-configure.sh
#   # or: INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-configure.sh
#   # or without either: the script asks for the token.
#
# It reads cluster.yaml (openbao.kvPath, openbao.auth.*, externalSecrets.*)
# through the root chart, so "helm" is needed, and then:
#   1. Enables the KV version 2 engine at openbao.kvPath (default kv/).
#   2. Enables the Kubernetes auth method at openbao.auth.mountPath (default
#      kubernetes/) and points it at the cluster's API server.
#   3. Writes policy "conservices-external-secrets-read" (read <kvPath>/data/*).
#   4. Writes role openbao.auth.role (default external-secrets) for the
#      service account externalSecrets.namespace/serviceAccount, which
#      ClusterSecretStore "openbao" logs in as.
#
# If OpenBao does not run as pods openbao/openbao-N, set OPENBAO_NAMESPACE
# and OPENBAO_RELEASE. Next: bash bootstrap/scripts/openbao-seed.sh
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
POLICY=conservices-external-secrets-read

kubectl get pod -n "$OPENBAO_NAMESPACE" "$(pod_name 0)" >/dev/null 2>&1 \
  || die "pod $OPENBAO_NAMESPACE/$(pod_name 0) not found; set OPENBAO_NAMESPACE and OPENBAO_RELEASE"

TOKEN="$(token_from_env_or_file)"
bao_cmd "$TOKEN" bao token lookup -format=json >/dev/null 2>&1 \
  || die "token rejected (is OpenBao unsealed? is the token valid?)"

# --- 1. KV engine ----------------------------------------------------------------
mounts="$(bao_cmd "$TOKEN" bao secrets list -format=json)"
if jq -e --arg m "$OPENBAO_KV/" 'has($m)' <<<"$mounts" >/dev/null; then
  version="$(jq -r --arg m "$OPENBAO_KV/" '.[$m].options.version // "1"' <<<"$mounts")"
  [[ "$version" == "2" ]] || die "$OPENBAO_KV/ exists but is KV version $version; Con Services needs version 2"
  log "KV v2 engine $OPENBAO_KV/ already enabled"
else
  bao_cmd "$TOKEN" bao secrets enable -path="$OPENBAO_KV" -version=2 kv >/dev/null
  log "Enabled KV v2 at $OPENBAO_KV/"
fi

# --- 2. Kubernetes auth --------------------------------------------------------------
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

# --- 3. Policy and role for External Secrets Operator ----------------------------------
bao_as "$TOKEN" bao policy write "$POLICY" - >/dev/null <<EOF
# External Secrets Operator: read every Con Services secret under $OPENBAO_KV/.
# Add "list" on $OPENBAO_KV/metadata/* if you use ExternalSecret dataFrom.find.
path "$OPENBAO_KV/data/*" {
  capabilities = ["read"]
}
EOF
log "Wrote policy $POLICY"

bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/role/$AUTH_ROLE" \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  token_policies="$POLICY" \
  token_ttl=1h >/dev/null
log "Wrote role $AUTH_ROLE for $ESO_NAMESPACE/$ESO_SA"

cat >&2 <<EOF

Done. OpenBao is ready for External Secrets Operator.

Next: seed the secrets:   bash bootstrap/scripts/openbao-seed.sh
EOF
