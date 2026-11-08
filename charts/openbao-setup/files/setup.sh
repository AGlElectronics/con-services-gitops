#!/bin/sh
# Runs in the openbao-setup Job (image: OpenBao, so "bao" and busybox).
# Logs in with the Job's service account token, then:
#   1. enables the KV version 2 engine at $KV_PATH (if missing);
#   2. writes the role $ESO_ROLE that External Secrets Operator logs in with.
# The OpenBao policy of $SETUP_ROLE allows exactly this; OpenBao rejects any
# other parameter values for the role. Safe to run again.
# shellcheck shell=sh
set -eu

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

jwt=/var/run/secrets/kubernetes.io/serviceaccount/token
BAO_TOKEN="$(bao write -field=token "auth/$AUTH_MOUNT/login" role="$SETUP_ROLE" jwt=@"$jwt")" \
  || die "login with role $SETUP_ROLE failed. Has the OpenBao administrator created it? (docs: deploy/secrets-openbao)"
export BAO_TOKEN
log "Logged in to $BAO_ADDR as role $SETUP_ROLE"

if options="$(bao read -field=options "sys/mounts/$KV_PATH" 2>/dev/null)"; then
  case "$options" in
    *version:2*) log "KV v2 engine $KV_PATH/ already enabled" ;;
    *) die "$KV_PATH/ exists but is not KV version 2 ($options); Con Services needs version 2" ;;
  esac
else
  bao secrets enable -path="$KV_PATH" -version=2 kv >/dev/null \
    || die "could not enable $KV_PATH/ (policy conservices-setup must allow sys/mounts/$KV_PATH)"
  log "Enabled KV v2 at $KV_PATH/"
fi

bao write "auth/$AUTH_MOUNT/role/$ESO_ROLE" \
  bound_service_account_names="$ESO_SERVICE_ACCOUNT" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  token_policies=conservices-external-secrets \
  token_ttl=1h >/dev/null \
  || die "could not write role $ESO_ROLE (the values must match policy conservices-setup)"
log "Wrote role $ESO_ROLE for $ESO_NAMESPACE/$ESO_SERVICE_ACCOUNT (policy conservices-external-secrets)"
log "Done."
