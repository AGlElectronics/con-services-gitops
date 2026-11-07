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
# values still set to "change-me".
# Guide: https://aglelectronics.github.io/con-services/deploy/argocd/
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_FILE="${CLUSTER_FILE:-$REPO_ROOT/cluster.yaml}"
DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) die "unknown option: $1 (see --help)" ;;
esac

for c in helm kubectl; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed"
done
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

repo="$(sed -n 's/^ *- repoURL: //p' <<<"$manifest" | head -n1)"
log "Argo CD will read $repo"
if ! git -C "$REPO_ROOT" diff --quiet -- cluster.yaml 2>/dev/null; then
  log "WARNING: cluster.yaml has changes that are not committed; Argo CD only sees what is pushed"
fi

printf '%s\n' "$manifest" | kubectl apply -f -
cat >&2 <<EOF

Root Application applied. Follow the sync waves with:

  kubectl get applications -n argocd -w

The "openbao" Application stays Progressing until you initialise OpenBao:

  INIT_FILE=\$HOME/openbao-init.json bash bootstrap/scripts/openbao-init.sh
  INIT_FILE=\$HOME/openbao-init.json bash bootstrap/scripts/openbao-seed.sh
EOF
