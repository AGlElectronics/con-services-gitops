#!/usr/bin/env bash
# Write every secret Con Services reads from OpenBao. Run after
# openbao-init.sh, from the root of your copy of this repository.
#
#   INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-seed.sh
#   # or, with a token that may write kv/*:
#   BAO_TOKEN=... bash bootstrap/scripts/openbao-seed.sh
#
# It reads cluster.yaml (through the root chart, so "helm" is needed) and
# only creates the entries the enabled modules and options need. Existing
# entries are kept, so running it again is safe: answer the prompts you
# skipped, or run it after enabling a module. Nothing secret is printed and
# values never appear on a command line.
#
# Options:
#   --rotate              Replace the rotatable random values (database
#                         passwords, Den operator token, service tokens).
#                         See "Rotation" below.
#   --no-prompt           Do not ask for the values only you know (S3 keys,
#                         SMTP, Cloudflare, GitHub); list the missing ones.
#   --modules a,b,c       Seed for exactly these modules instead of the
#                         modules.<name>.enabled settings of cluster.yaml.
#   --cluster-file PATH   Settings file (default: cluster.yaml).
#
# Generated here (random, 32 bytes hex):
#   kv/conservices/postgres/superuser          username (postgres), password
#   kv/conservices/postgres/roles/<role>       password  den, keycloak, and one
#                                              per enabled module (Rally: events)
#   kv/conservices/den/operator-token          token
#   kv/conservices/service-tokens/<module>     token     learn, wiki, tasks
#   kv/conservices/desk/secret-key             key       desk
#   kv/conservices/keycloak/bootstrap-admin    username (temp-admin), password
#   kv/conservices/keycloak/clients            den-keycloak, hr-provisioner,
#                                              learn-provisioner
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
#   kv/infra/github-arc                        github_app_id,
#                                              github_app_installation_id,
#                                              github_app_private_key (arc.enabled)
#   kv/infra/ghcr                              username, token
#                                              (images.pullSecret.enabled)
#
# Rotation (--rotate) only touches values that every side reads from the same
# OpenBao entry: database role and superuser passwords (CloudNativePG changes
# them in PostgreSQL), the Den operator token and the service tokens. After
# rotating, wait for External Secrets to refresh (up to 1 hour, or annotate
# the ExternalSecrets with force-sync) and restart the module Deployments.
# It never rotates:
#   - desk/secret-key: it encrypts stored mailbox passwords; a new key makes
#     them unreadable.
#   - keycloak/clients and keycloak/bootstrap-admin: Keycloak keeps its own
#     copy after the first import. Regenerate the client secret in the
#     Keycloak admin console, then store it with "bao kv patch".
#
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail
umask 077

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"
need kubectl jq openssl helm

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_FILE="$REPO_ROOT/cluster.yaml"
ROTATE=0
PROMPT=1
MODULES=""
ALL_MODULES=(stash hr rally finance learn wiki desk tasks)

while (($#)); do
  case "$1" in
    --rotate) ROTATE=1 ;;
    --no-prompt) PROMPT=0 ;;
    --modules) shift; MODULES="${1:-}"; [[ -n "$MODULES" ]] || die "--modules needs a list, e.g. --modules stash,wiki" ;;
    --modules=*) MODULES="${1#*=}" ;;
    --cluster-file) shift; CLUSTER_FILE="${1:-}" ;;
    --cluster-file=*) CLUSTER_FILE="${1#*=}" ;;
    -h|--help) sed -n '2,65p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
[[ -t 0 ]] || PROMPT=0
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE (run from your copy of the repository or pass --cluster-file)"

# --- What this cluster needs ----------------------------------------------------
helm_args=(template root "$REPO_ROOT/charts/root" -f "$CLUSTER_FILE"
           --set global.seedPlan=true --show-only templates/seed-plan.yaml)
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
plan="$(helm "${helm_args[@]}" | sed -n '/^{/p')" \
  || die "the root chart rejected $CLUSTER_FILE (fix the message above first)"
[[ -n "$plan" ]] || die "could not read the seed plan from charts/root"
log "Modules: $(jq -r '.modules | join(", ")' <<<"$plan")"

TOKEN="$(token_from_env_or_file)"
bao_cmd "$TOKEN" bao token lookup -format=json >/dev/null 2>&1 \
  || die "token rejected (is OpenBao unsealed? is the token valid?)"

MISSING=()

# put_generated <path> <json> <rotatable 0|1>
put_generated() {
  if kv_exists "$TOKEN" "$1"; then
    if [[ "$3" == "1" && "$ROTATE" == "1" ]]; then
      kv_put_json "$TOKEN" "$1" "$2"
      log "kv/$1 rotated"
    else
      log "kv/$1 already exists, keeping it"
    fi
    return 0
  fi
  kv_put_json "$TOKEN" "$1" "$2"
  log "kv/$1 written"
}

one() { jq -n --arg k "$1" --arg v "$(gen_secret)" '{($k): $v}'; }
list() { jq -r --arg k "$1" '.[$k][]' <<<"$plan"; }
flag() { [[ "$(jq -r --arg k "$1" '.[$k]' <<<"$plan")" == "true" ]]; }

# --- Generated values -------------------------------------------------------------
put_generated conservices/postgres/superuser \
  "$(jq -n --arg p "$(gen_secret)" '{username: "postgres", password: $p}')" 1
while read -r role; do
  put_generated "conservices/postgres/roles/$role" "$(one password)" 1
done < <(list roles)
put_generated conservices/den/operator-token "$(one token)" 1
while read -r module; do
  put_generated "conservices/service-tokens/$module" "$(one token)" 1
done < <(list serviceTokens)
if flag desk; then
  put_generated conservices/desk/secret-key "$(one key)" 0
fi
put_generated conservices/keycloak/bootstrap-admin \
  "$(jq -n --arg p "$(gen_secret)" '{username: "temp-admin", password: $p}')" 0
put_generated conservices/keycloak/clients \
  "$(jq -n --arg a "$(gen_secret)" --arg b "$(gen_secret)" --arg c "$(gen_secret)" \
     '{"den-keycloak": $a, "hr-provisioner": $b, "learn-provisioner": $c}')" 0

# --- Values only you know ------------------------------------------------------------
# ask <path> <fields> <description>: true if the caller should prompt for kv/<path>.
ask() {
  if kv_exists "$TOKEN" "$1"; then
    log "kv/$1 already exists, keeping it"
    return 1
  fi
  if [[ "$PROMPT" == "0" ]]; then
    MISSING+=("kv/$1 ($2)")
    return 1
  fi
  log "kv/$1: $3"
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
      log "kv/conservices/$path written"
    else
      MISSING+=("kv/conservices/$path (access_key, secret_key)")
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
    log "kv/conservices/keycloak/smtp written"
  else
    MISSING+=("kv/conservices/keycloak/smtp (host, port, from, username, password)")
  fi
fi

if flag cloudflare && ask infra/cloudflare "api-token" \
    "Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read for your zone only"; then
  read -r -s -p "  API token (empty = skip): " cf; echo >&2
  if [[ -n "$cf" ]]; then
    kv_put_json "$TOKEN" infra/cloudflare "$(jq -n --arg t "$cf" '{"api-token": $t}')"
    unset cf
    log "kv/infra/cloudflare written"
  else
    MISSING+=("kv/infra/cloudflare (api-token)")
  fi
fi

if flag githubArc && ask infra/github-arc "github_app_id, github_app_installation_id, github_app_private_key" \
    "GitHub App the self-hosted Actions runners register with"; then
  read -r -p "  GitHub App ID (empty = skip): " app_id
  if [[ -n "$app_id" ]]; then
    read -r -p "  Installation ID: " inst_id
    read -r -p "  Path to the private key (.pem): " pem
    [[ -r "$pem" ]] || die "cannot read $pem"
    kv_put_json "$TOKEN" infra/github-arc "$(jq -n --arg a "$app_id" --arg i "$inst_id" \
      --rawfile k "$pem" \
      '{github_app_id: $a, github_app_installation_id: $i, github_app_private_key: $k}')"
    log "kv/infra/github-arc written (you may now delete $pem)"
  else
    MISSING+=("kv/infra/github-arc (github_app_id, github_app_installation_id, github_app_private_key)")
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
    log "kv/infra/ghcr written"
  else
    MISSING+=("kv/infra/ghcr (username, token)")
  fi
fi

if ((${#MISSING[@]})); then
  log "Still missing (the Applications that read them stay Degraded until they exist):"
  printf '      %s\n' "${MISSING[@]}" >&2
  log "Run this script again (without --no-prompt) to enter them."
fi
log "Seeding done. Check with: kubectl get externalsecret -A"
