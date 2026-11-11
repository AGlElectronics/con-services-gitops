#!/usr/bin/env bash
# The OpenBao administrator's one-time step for Con Services. OpenBao itself
# is a cluster prerequisite: it must already be initialised and unsealed. Run
# once, from the root of your copy of this repository, with a token that may
# manage auth methods and policies (for a fresh OpenBao: the root token).
# Safe to run again: every step checks what is already done. On Windows,
# openbao-configure.ps1 does the same in PowerShell.
#
#   BAO_TOKEN=... bash bootstrap/scripts/openbao-configure.sh
#   # or: INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-configure.sh
#   # or without either: the script asks for the token.
#
# It reads cluster.yaml (openbao.*, externalSecrets.*) through the root chart,
# so "helm" is needed, and then:
#   1. Enables the Kubernetes auth method at openbao.auth.mountPath (default
#      kubernetes/) if missing and points it at the cluster's API server.
#   2. Writes policy "conservices-external-secrets": read every entry of the
#      KV mount openbao.kvPath (default conservices/), and create and update
#      entries below modules/, infra/postgres/ and infra/keycloak/ (the
#      random values External Secrets generates with PushSecrets).
#   With openbao.setup.enabled (the default):
#   3. Writes policy "conservices-setup" and the role openbao.setup.role for
#      the setup Job's service account. The policy allows only: enable the KV
#      engine at kvPath, and write the role openbao.auth.role with exactly
#      the values from cluster.yaml. Argo CD's openbao-setup Application
#      does the rest when you press Sync.
#   With openbao.setup.enabled: false, it does that part itself:
#   3. Enables the KV version 2 engine at openbao.kvPath.
#   4. Writes the role openbao.auth.role (default external-secrets) for
#      externalSecrets.namespace/serviceAccount.
#
# Options:
#   --cluster-file PATH   Settings file (default: cluster.yaml; or set
#                         CLUSTER_FILE).
#   -h, --help            This text.
#
# If OpenBao does not run as pods openbao/openbao-N, set OPENBAO_NAMESPACE
# and OPENBAO_RELEASE.
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail
umask 077

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_FILE="${CLUSTER_FILE:-$REPO_ROOT/cluster.yaml}"
while (($#)); do
  case "$1" in
    --cluster-file) shift; CLUSTER_FILE="${1:-}" ;;
    --cluster-file=*) CLUSTER_FILE="${1#*=}" ;;
    -h|--help) sed -n '2,/^# Guide:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
need kubectl jq helm
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE (run from your copy of the repository or pass --cluster-file)"

plan="$(seed_plan "$CLUSTER_FILE")"
OPENBAO_KV="$(jqr -r '.kvPath' <<<"$plan")"
AUTH_MOUNT="$(jqr -r '.authMount' <<<"$plan")"
AUTH_ROLE="$(jqr -r '.authRole' <<<"$plan")"
ESO_NAMESPACE="$(jqr -r '.esoNamespace' <<<"$plan")"
ESO_SA="$(jqr -r '.esoServiceAccount' <<<"$plan")"
SETUP_ENABLED="$(jqr -r '.setup.enabled' <<<"$plan")"
SETUP_ROLE="$(jqr -r '.setup.role' <<<"$plan")"
SETUP_SA="$(jqr -r '.setup.serviceAccount' <<<"$plan")"
SETUP_NAMESPACE="$(jqr -r '.setupNamespace' <<<"$plan")"
ESO_POLICY=conservices-external-secrets
SETUP_POLICY=conservices-setup

header "OpenBao"
kubectl get pod -n "$OPENBAO_NAMESPACE" "$(pod_name 0)" >/dev/null 2>&1 \
  || die "pod $OPENBAO_NAMESPACE/$(pod_name 0) not found; set OPENBAO_NAMESPACE and OPENBAO_RELEASE"
log "Pod $OPENBAO_NAMESPACE/$(pod_name 0), KV mount $OPENBAO_KV/"

TOKEN="$(token_from_env_or_file)"
bao_cmd "$TOKEN" bao token lookup -format=json >/dev/null 2>&1 \
  || die "token rejected (is OpenBao unsealed? is the token valid?)"

# --- 1. Kubernetes auth --------------------------------------------------------------
header "1. Kubernetes auth method"
if bao_cmd "$TOKEN" bao auth list -format=json | jq -e --arg m "$AUTH_MOUNT/" 'has($m)' >/dev/null; then
  good "Kubernetes auth $AUTH_MOUNT/ already enabled"
else
  bao_cmd "$TOKEN" bao auth enable -path="$AUTH_MOUNT" kubernetes >/dev/null
  good "Enabled Kubernetes auth at $AUTH_MOUNT/"
fi
# OpenBao checks service account tokens against the API server with its own
# service account (the upstream chart grants it system:auth-delegator).
bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/config" \
  kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
good "Configured Kubernetes auth"

# --- 2. External Secrets Operator's policy ---------------------------------------------
header "2. Policy $ESO_POLICY"
bao_as "$TOKEN" bao policy write "$ESO_POLICY" - >/dev/null <<EOF
# External Secrets Operator: read every Con Services entry in $OPENBAO_KV/,
# and create the random ones (PushSecret, updatePolicy IfNotExists) below
# modules/, infra/postgres/ and infra/keycloak/. It never deletes:
# PushSecrets use deletionPolicy None. Entries only a person enters
# (infra/cloudflare, infra/ghcr) stay read-only for it.
path "$OPENBAO_KV/data/*" {
  capabilities = ["read"]
}
path "$OPENBAO_KV/metadata/*" {
  capabilities = ["read"]
}
path "$OPENBAO_KV/data/modules/*" {
  capabilities = ["read", "create", "update"]
}
path "$OPENBAO_KV/metadata/modules/*" {
  capabilities = ["read", "create", "update"]
}
path "$OPENBAO_KV/data/infra/postgres/*" {
  capabilities = ["read", "create", "update"]
}
path "$OPENBAO_KV/metadata/infra/postgres/*" {
  capabilities = ["read", "create", "update"]
}
path "$OPENBAO_KV/data/infra/keycloak/*" {
  capabilities = ["read", "create", "update"]
}
path "$OPENBAO_KV/metadata/infra/keycloak/*" {
  capabilities = ["read", "create", "update"]
}
EOF
good "Wrote policy $ESO_POLICY (read $OPENBAO_KV/*, write modules/*, infra/postgres/*, infra/keycloak/*)"

if [[ "$SETUP_ENABLED" == "true" ]]; then
  # --- 3. The setup Job's policy and role ---------------------------------------------
  header "3. Setup Job: policy $SETUP_POLICY and role $SETUP_ROLE"
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
  good "Wrote policy $SETUP_POLICY"
  bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/role/$SETUP_ROLE" \
    bound_service_account_names="$SETUP_SA" \
    bound_service_account_namespaces="$SETUP_NAMESPACE" \
    token_policies="$SETUP_POLICY" \
    token_ttl=10m \
    token_max_ttl=10m >/dev/null
  good "Wrote role $SETUP_ROLE for $SETUP_NAMESPACE/$SETUP_SA"
  cat >&2 <<EOF

Done. Next: Argo CD stops at the Application "openbao-setup". Review its
diff, then press Sync (or: argocd app sync openbao-setup). It enables
$OPENBAO_KV/ and writes the role $AUTH_ROLE.
EOF
  exit 0
fi

# --- 3. KV engine (openbao.setup.enabled: false) ----------------------------------------
header "3. KV version 2 engine $OPENBAO_KV/"
mounts="$(bao_cmd "$TOKEN" bao secrets list -format=json)"
if jq -e --arg m "$OPENBAO_KV/" 'has($m)' <<<"$mounts" >/dev/null; then
  version="$(jqr -r --arg m "$OPENBAO_KV/" '.[$m].options.version // "1"' <<<"$mounts")"
  [[ "$version" == "2" ]] || die "$OPENBAO_KV/ exists but is KV version $version; Con Services needs version 2"
  good "KV v2 engine $OPENBAO_KV/ already enabled"
else
  bao_cmd "$TOKEN" bao secrets enable -path="$OPENBAO_KV" -version=2 kv >/dev/null
  good "Enabled KV v2 at $OPENBAO_KV/"
fi

# --- 4. External Secrets' role --------------------------------------------------------------
header "4. Role $AUTH_ROLE"
bao_cmd "$TOKEN" bao write "auth/$AUTH_MOUNT/role/$AUTH_ROLE" \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  token_policies="$ESO_POLICY" \
  token_ttl=1h >/dev/null
good "Wrote role $AUTH_ROLE for $ESO_NAMESPACE/$ESO_SA"

cat >&2 <<EOF

Done. OpenBao is ready for External Secrets Operator.
EOF
