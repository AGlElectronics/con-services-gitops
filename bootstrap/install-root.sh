#!/usr/bin/env bash
# Apply the root Application (rootApplication.name in cluster.yaml, default
# conservices-stack): the one object that makes Argo CD install everything
# else from your copy of this repository. Run from the root of your copy,
# after Argo CD is installed and cluster.yaml is complete AND pushed (Argo CD
# reads cluster.yaml from Git, not from this computer).
#
#   bash bootstrap/install-root.sh
#   bash bootstrap/install-root.sh --dry-run          # print it, apply nothing
#   bash bootstrap/install-root.sh --skip-preflight   # skip the prerequisite check
#
# The root chart checks cluster.yaml first and stops with a list of the
# values still set to "change-me". Then the script checks the cluster
# prerequisites the template uses but does not install (cert-manager,
# trust-manager, External Secrets Operator, CloudNativePG with the Barman
# Cloud plugin, the OpenBao CA bundle, Argo CD's Application health check).
# Windows: bootstrap\install-root.ps1 does the same.
# Guide: https://aglelectronics.github.io/con-services/deploy/argocd/
set -euo pipefail

# shellcheck source=scripts/lib/openbao.sh
source "$(dirname "$0")/scripts/lib/openbao.sh"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_STEP=$'\033[1;36m' C_OK=$'\033[1;32m' C_WARN=$'\033[1;33m' C_ERR=$'\033[1;31m' C_OFF=$'\033[0m'
else
  C_STEP='' C_OK='' C_WARN='' C_ERR='' C_OFF=''
fi
die() { printf '%sERROR:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
log() { printf '%s==>%s %s\n' "$C_STEP" "$C_OFF" "$*" >&2; }
ok() { printf '%s==>%s %s\n' "$C_OK" "$C_OFF" "$*" >&2; }
warn() { printf '%sWARNING:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_FILE="${CLUSTER_FILE:-$REPO_ROOT/cluster.yaml}"
DOCS="https://aglelectronics.github.io/con-services/deploy"
HEALTH_KEY="resource.customizations.health.argoproj.io_Application"
DRY_RUN=0
PREFLIGHT=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-preflight) PREFLIGHT=0 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown option: $arg (see --help)" ;;
  esac
done

need helm kubectl jq
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE"

log "Checking $CLUSTER_FILE"
manifest="$(helm template root "$REPO_ROOT/charts/root" -f "$CLUSTER_FILE" \
  --show-only templates/root-application.yaml)" || die "fix cluster.yaml as described above, push it, and run this again"
name="$(sed -n 's/^  name: //p' <<<"$manifest" | head -n1)"
repo="$(sed -n 's/^ *- repoURL: //p' <<<"$manifest" | head -n1)"

if ((DRY_RUN)); then
  printf '%s\n' "$manifest"
  exit 0
fi

kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
  || die "Argo CD is not installed in this cluster (it is a prerequisite: $DOCS/prerequisites/#9-argo-cd)"

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
    read -r kind ns cname <<<"$ca"
    kubectl get "${kind,,}" -n "$ns" "$cname" >/dev/null 2>&1 \
      || missing+=("OpenBao CA $kind $ns/$cname (cluster.yaml openbao.caBundle)")
  fi
  if ((${#missing[@]})); then
    printf '  %smissing:%s %s\n' "$C_ERR" "$C_OFF" "${missing[@]}" >&2
    die "install the cluster prerequisites first (guide: deploy/prerequisites), or rerun with --skip-preflight"
  fi
  if [[ "$(kubectl get cm argocd-cm -n argocd -o json 2>/dev/null | jq -r --arg k "$HEALTH_KEY" '.data[$k] // "" | length > 0')" != "true" ]]; then
    printf '%s\n' "$C_WARN" >&2
    printf '!!! %s\n' \
      "argocd-cm has no $HEALTH_KEY." \
      "Without this health check Argo CD does not wait for one sync wave to be" \
      "Healthy before the next: every component starts at once and the first" \
      "install fails in confusing ways (Keycloak before its operator, apps" \
      "before the database). Add the block from" \
      "$DOCS/prerequisites/#9-argo-cd" \
      "to argocd-cm (Helm chart: configs.cm) before you continue." >&2
    printf '%s\n' "$C_OFF" >&2
    warn "continuing in 10 seconds; press Ctrl+C to stop"
    sleep 10
  fi
  ok "Prerequisites found"
fi

log "Argo CD will read $repo"
if ! git -C "$REPO_ROOT" diff --quiet -- cluster.yaml 2>/dev/null; then
  warn "cluster.yaml has changes that are not committed; Argo CD only sees what is pushed"
fi

printf '%s\n' "$manifest" | kubectl apply -f -
plan="$(seed_plan "$CLUSTER_FILE")"
setup="$(jq -r '.setup.enabled' <<<"$plan")"
if [[ "$(jq -r '.backupSameAsData' <<<"$plan")" == "true" ]]; then
  warn "backups go to the same S3 service as the live data (s3.backup is empty or equals s3.endpoint)." \
       "Set s3.backup to another provider or account: https://aglelectronics.github.io/con-services/operations/databases-and-backups/#where-backups-go"
fi

ok "Root Application \"$name\" applied."
n=0
step() { n=$((n + 1)); printf '  %s%d.%s %s\n' "$C_STEP" "$n" "$C_OFF" "$1" >&2; shift; printf '     %s\n' "$@" >&2; }
printf '\nNext steps:\n\n' >&2
step "Follow the sync waves:" "  kubectl get applications -n argocd -w"
if [[ "$setup" == "true" ]]; then
  step "Sync \"openbao-setup\" by hand. Argo CD never syncs it automatically and" \
       "the later waves wait for it: review its diff in Argo CD, then press Sync" \
       "(or: argocd app sync openbao-setup). The OpenBao administrator must have" \
       "run bootstrap/scripts/openbao-configure.sh once before."
fi
step "Enter your provider credentials (S3, SMTP, Cloudflare) in OpenBao:" \
     "  bash bootstrap/scripts/openbao-seed.sh" \
     "Applications that read them stay Degraded until they exist." \
     "Guide: $DOCS/secrets-openbao/"
step "Create the DNS records and the S3 buckets:" "$DOCS/dns-and-certificates/"
