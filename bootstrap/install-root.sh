#!/usr/bin/env bash
# Apply the root Application: the one object that makes Argo CD install
# everything else from your copy of this repository. Run from the root of
# your copy, after Argo CD is installed and cluster.yaml is complete AND
# pushed (Argo CD reads cluster.yaml from Git, not from this computer).
#
#   bash bootstrap/install-root.sh
#   bash bootstrap/install-root.sh --dry-run     # print it, apply nothing
#
# The root chart checks cluster.yaml first and stops with a list of the
# values still set to "change-me". Then the script checks the cluster
# prerequisites the template uses but does not install (cert-manager,
# trust-manager, External Secrets Operator, CloudNativePG with the Barman
# Cloud plugin, and the OpenBao CA bundle); --skip-preflight skips that.
# Guide: https://aglelectronics.github.io/con-services/deploy/argocd/
set -euo pipefail

# shellcheck source=scripts/lib/openbao.sh
source "$(dirname "$0")/scripts/lib/openbao.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_FILE="${CLUSTER_FILE:-$REPO_ROOT/cluster.yaml}"
DRY_RUN=0
PREFLIGHT=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-preflight) PREFLIGHT=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option: $arg (see --help)" ;;
  esac
done

need helm kubectl jq
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE"

log "Checking $CLUSTER_FILE"
manifest="$(helm template root "$REPO_ROOT/charts/root" -f "$CLUSTER_FILE" \
  --show-only templates/root-application.yaml)" || die "fix cluster.yaml as described above, push it, and run this again"

if ((DRY_RUN)); then
  printf '%s\n' "$manifest"
  exit 0
fi

kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
  || die "Argo CD is not installed in this cluster (see the guide, 'Install Argo CD')"

if ((PREFLIGHT)); then
  log "Checking the cluster prerequisites"
  missing=()
  for crd in certificates.cert-manager.io:cert-manager \
             bundles.trust.cert-manager.io:trust-manager \
             clustersecretstores.external-secrets.io:"External Secrets Operator" \
             clusters.postgresql.cnpg.io:"CloudNativePG operator" \
             objectstores.barmancloud.cnpg.io:"Barman Cloud plugin"; do
    kubectl get crd "${crd%%:*}" >/dev/null 2>&1 || missing+=("${crd#*:} (CRD ${crd%%:*} not found)")
  done
  plan="$(seed_plan "$CLUSTER_FILE")"
  eso_ns="$(jq -r '.esoNamespace' <<<"$plan")"
  eso_sa="$(jq -r '.esoServiceAccount' <<<"$plan")"
  kubectl get serviceaccount -n "$eso_ns" "$eso_sa" >/dev/null 2>&1 \
    || missing+=("External Secrets service account $eso_ns/$eso_sa (cluster.yaml externalSecrets.*)")
  ca="$(jq -r '.caBundle | select(.name != "") | "\(.kind) \(.namespace) \(.name)"' <<<"$plan")"
  if [[ -n "$ca" ]]; then
    read -r kind ns name <<<"$ca"
    kubectl get "${kind,,}" -n "$ns" "$name" >/dev/null 2>&1 \
      || missing+=("OpenBao CA $kind $ns/$name (cluster.yaml openbao.caBundle)")
  fi
  if ((${#missing[@]})); then
    printf '  missing: %s\n' "${missing[@]}" >&2
    die "install the cluster prerequisites first (guide: deploy/prerequisites), or rerun with --skip-preflight"
  fi
  log "Prerequisites found"
fi

repo="$(sed -n 's/^ *- repoURL: //p' <<<"$manifest" | head -n1)"
log "Argo CD will read $repo"
if ! git -C "$REPO_ROOT" diff --quiet -- cluster.yaml 2>/dev/null; then
  log "WARNING: cluster.yaml has changes that are not committed; Argo CD only sees what is pushed"
fi

printf '%s\n' "$manifest" | kubectl apply -f -
cat >&2 <<EOF

Root Application applied. Follow the sync waves with:

  kubectl get applications -n argocd -w

Applications that read secrets stay Degraded until OpenBao is prepared and
filled (once per cluster):

  BAO_TOKEN=... bash bootstrap/scripts/openbao-configure.sh
  BAO_TOKEN=... bash bootstrap/scripts/openbao-seed.sh
EOF
