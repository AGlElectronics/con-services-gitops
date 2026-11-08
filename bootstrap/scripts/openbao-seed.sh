#!/usr/bin/env bash
# Enter the secrets only you know (provider credentials) into OpenBao. One
# way of several: the OpenBao web UI or "bao kv put" work just as well. The
# random values (database passwords, tokens, client secrets) are not here:
# External Secrets Operator creates them (charts/secret-store). Run from the
# root of your copy of this repository.
#
#   BAO_TOKEN=... bash bootstrap/scripts/openbao-seed.sh   # token that may write kv/*
#   # or, with the init file of a fresh OpenBao (root token):
#   INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-seed.sh
#   # or without either: the script asks for the token.
#
# Paths below use "kv"; with another openbao.kvPath in cluster.yaml the
# entries go under that mount instead.
#
# It reads cluster.yaml (through the root chart, so "helm" is needed) and
# only asks for the entries the enabled modules and options need. Existing
# entries are kept, so running it again is safe: answer the prompts you
# skipped, or run it after enabling a module. Nothing secret is printed and
# values never appear on a command line.
#
# Options:
#   --no-prompt           Ask nothing; list the entries that are missing.
#   --modules a,b,c       Check exactly these modules instead of the
#                         modules.<name>.enabled settings of cluster.yaml.
#   --cluster-file PATH   Settings file (default: cluster.yaml).
#
# Asked for (empty answer = skip, run again later):
#   kv/conservices/<app>/s3                    access_key, secret_key
#                                              den and the enabled modules with
#                                              files (stash rally learn wiki tasks)
#   kv/conservices/den/files-s3                access_key, secret_key
#   kv/conservices/den/backup-s3               access_key, secret_key
#   kv/conservices/postgres/backup-s3          access_key, secret_key
#   kv/conservices/keycloak/smtp               host, port, from, username,
#                                              password   (keycloak.smtp.enabled)
#   kv/infra/cloudflare                        api-token  (acme.dns01.provider
#                                                          cloudflare)
#   kv/infra/ghcr                              username, token
#                                              (images.pullSecret.enabled)
#
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail
umask 077

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"
need kubectl jq helm

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_FILE="$REPO_ROOT/cluster.yaml"
PROMPT=1
MODULES=""
ALL_MODULES=(stash hr rally finance learn wiki desk tasks)

while (($#)); do
  case "$1" in
    --no-prompt) PROMPT=0 ;;
    --modules) shift; MODULES="${1:-}"; [[ -n "$MODULES" ]] || die "--modules needs a list, e.g. --modules stash,wiki" ;;
    --modules=*) MODULES="${1#*=}" ;;
    --cluster-file) shift; CLUSTER_FILE="${1:-}" ;;
    --cluster-file=*) CLUSTER_FILE="${1#*=}" ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
[[ -t 0 ]] || PROMPT=0
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE (run from your copy of the repository or pass --cluster-file)"

# --- What this cluster needs ----------------------------------------------------
helm_args=()
if [[ -n "$MODULES" ]]; then
  IFS=, read -r -a wanted <<<"$MODULES"
  for m in "${wanted[@]}"; do
    [[ " ${ALL_MODULES[*]} " == *" $m "* ]] || die "unknown module '$m' (one of: ${ALL_MODULES[*]})"
  done
  for m in "${ALL_MODULES[@]}"; do
    if [[ ",$MODULES," == *",$m,"* ]]; then
      helm_args+=(--set "modules.$m.enabled=true")
    else
      helm_args+=(--set "modules.$m.enabled=false")
    fi
  done
fi
plan="$(seed_plan "$CLUSTER_FILE" "${helm_args[@]}")"
OPENBAO_KV="$(jq -r '.kvPath' <<<"$plan")"
log "Modules: $(jq -r '.modules | join(", ")' <<<"$plan")"

TOKEN="$(token_from_env_or_file)"
bao_cmd "$TOKEN" bao token lookup -format=json >/dev/null 2>&1 \
  || die "token rejected (is OpenBao unsealed? is the token valid?)"

MISSING=()

list() { jq -r --arg k "$1" '.[$k][]' <<<"$plan"; }
flag() { [[ "$(jq -r --arg k "$1" '.[$k]' <<<"$plan")" == "true" ]]; }

# --- Values only you know ------------------------------------------------------------
# ask <path> <fields> <description>: true if the caller should prompt for <path>.
ask() {
  if kv_exists "$TOKEN" "$1"; then
    log "$OPENBAO_KV/$1 already exists, keeping it"
    return 1
  fi
  if [[ "$PROMPT" == "0" ]]; then
    MISSING+=("$OPENBAO_KV/$1 ($2)")
    return 1
  fi
  log "$OPENBAO_KV/$1: $3"
  return 0
}

while read -r path; do
  if ask "conservices/$path" "access_key, secret_key" "S3 access key from your object storage provider"; then
    read -r -p "  Access key (empty = skip): " s3_access
    if [[ -n "$s3_access" ]]; then
      read -r -s -p "  Secret key: " s3_secret; echo >&2
      [[ -n "$s3_secret" ]] || die "the secret key is required"
      kv_put_json "$TOKEN" "conservices/$path" \
        "$(jq -n --arg a "$s3_access" --arg s "$s3_secret" '{access_key: $a, secret_key: $s}')"
      unset s3_secret
      log "$OPENBAO_KV/conservices/$path written"
    else
      MISSING+=("$OPENBAO_KV/conservices/$path (access_key, secret_key)")
    fi
  fi
done < <(list s3)

if flag smtp && ask conservices/keycloak/smtp "host, port, from, username, password" \
    "mail server Keycloak sends password-reset and verification mail through"; then
  read -r -p "  SMTP host (empty = skip): " smtp_host
  if [[ -n "$smtp_host" ]]; then
    read -r -p "  Port [587]: " smtp_port
    read -r -p "  From address (e.g. no-reply@example.org): " smtp_from
    read -r -p "  Username: " smtp_user
    read -r -s -p "  Password: " smtp_pass; echo >&2
    kv_put_json "$TOKEN" conservices/keycloak/smtp \
      "$(jq -n --arg h "$smtp_host" --arg p "${smtp_port:-587}" --arg f "$smtp_from" \
         --arg u "$smtp_user" --arg w "$smtp_pass" \
         '{host: $h, port: $p, from: $f, username: $u, password: $w}')"
    unset smtp_pass
    log "$OPENBAO_KV/conservices/keycloak/smtp written"
  else
    MISSING+=("$OPENBAO_KV/conservices/keycloak/smtp (host, port, from, username, password)")
  fi
fi

if flag cloudflare && ask infra/cloudflare "api-token" \
    "Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read for your zone only"; then
  read -r -s -p "  API token (empty = skip): " cf; echo >&2
  if [[ -n "$cf" ]]; then
    kv_put_json "$TOKEN" infra/cloudflare "$(jq -n --arg t "$cf" '{"api-token": $t}')"
    unset cf
    log "$OPENBAO_KV/infra/cloudflare written"
  else
    MISSING+=("$OPENBAO_KV/infra/cloudflare (api-token)")
  fi
fi

if flag ghcr && ask infra/ghcr "username, token" \
    "registry user and token with only read:packages, for the ghcr-pull Secrets"; then
  read -r -p "  Username (empty = skip): " gh_user
  if [[ -n "$gh_user" ]]; then
    read -r -s -p "  Token (read:packages): " gh_token; echo >&2
    [[ -n "$gh_token" ]] || die "the token is required"
    kv_put_json "$TOKEN" infra/ghcr \
      "$(jq -n --arg u "$gh_user" --arg t "$gh_token" '{username: $u, token: $t}')"
    unset gh_token
    log "$OPENBAO_KV/infra/ghcr written"
  else
    MISSING+=("$OPENBAO_KV/infra/ghcr (username, token)")
  fi
fi

if ((${#MISSING[@]})); then
  log "Still missing (the Applications that read them stay Degraded until they exist):"
  printf '      %s\n' "${MISSING[@]}" >&2
  log "Run this script again (without --no-prompt) to enter them."
fi
log "Done. Check with: kubectl get externalsecret,pushsecret -A"
