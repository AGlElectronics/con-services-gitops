#!/usr/bin/env bash
# Enter the secrets only you know (provider credentials) into OpenBao. One
# way of several: the OpenBao web UI or "bao kv put" work just as well. The
# random values (database passwords, tokens, client secrets) are not here:
# External Secrets Operator creates them (charts/secret-store). Run from the
# root of your copy of this repository. On Windows, prefer openbao-seed.ps1.
#
#   BAO_TOKEN=... bash bootstrap/scripts/openbao-seed.sh   # token that may write conservices/*
#   # or, with the init file of a fresh OpenBao (root token):
#   INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-seed.sh
#   # or without either: the script asks for the token.
#
# Paths below use the mount "conservices"; with another openbao.kvPath in
# cluster.yaml the entries go under that mount instead.
#
# It reads cluster.yaml (through the root chart, so "helm" is needed) and
# asks for every entry the enabled modules and options need. Existing
# entries are kept, so running it again is safe: answer the prompts you
# skipped, or run it after enabling a module. To replace a wrong value, use
# --overwrite or --reenter. Nothing secret is printed (hidden answers show
# only their length and first and last four characters) and values never
# appear on a command line.
#
# Options:
#   --no-prompt           Ask nothing; list what exists and what is missing,
#                         with the Applications that stay Degraded.
#   --overwrite PATH      Ask again for this entry even if it exists, and
#                         replace it (e.g. conservices/infra/cloudflare).
#                         Repeat for several entries.
#   --reenter             Ask again for every entry, existing or not.
#   --modules a,b,c       Check exactly these modules instead of the
#                         modules.<name>.enabled settings of cluster.yaml.
#   --cluster-file PATH   Settings file (default: cluster.yaml).
#   -h, --help            This text.
#
# Asked for (empty answer = skip, run again later):
#   conservices/infra/postgres/backup-s3     access_key, secret_key
#   conservices/modules/den/s3               access_key, secret_key
#   conservices/modules/den/files-s3         access_key, secret_key (read only)
#   conservices/modules/den/backup-s3        access_key, secret_key
#   conservices/modules/<module>/s3          access_key, secret_key, for the
#                                            enabled modules with files
#                                            (stash rally learn wiki tasks)
#   conservices/infra/keycloak/smtp          host, port, from, username,
#                                            password   (keycloak.smtp.enabled)
#   conservices/infra/cloudflare             api-token  (acme.dns01.provider
#                                                        cloudflare)
#   conservices/infra/ghcr                   username, token
#                                            (images.pullSecret.enabled)
# Every S3 entry gets its own access key, limited to its own bucket.
#
# Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/
set -euo pipefail
umask 077

# shellcheck source=lib/openbao.sh
source "$(dirname "$0")/lib/openbao.sh"

usage() { sed -n '2,/^# Guide:/p' "$0" | sed 's/^# \{0,1\}//'; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_FILE="$REPO_ROOT/cluster.yaml"
PROMPT=1
REENTER=0
MODULES=""
OVERWRITE=()
ALL_MODULES=(stash hr rally finance learn wiki desk tasks)

while (($#)); do
  case "$1" in
    --no-prompt) PROMPT=0 ;;
    --reenter) REENTER=1 ;;
    --overwrite) shift; [[ -n "${1:-}" ]] || die "--overwrite needs a path, e.g. --overwrite conservices/infra/cloudflare"
                 OVERWRITE+=("$1") ;;
    --overwrite=*) OVERWRITE+=("${1#*=}") ;;
    --modules) shift; MODULES="${1:-}"; [[ -n "$MODULES" ]] || die "--modules needs a list, e.g. --modules stash,wiki" ;;
    --modules=*) MODULES="${1#*=}" ;;
    --cluster-file) shift; CLUSTER_FILE="${1:-}" ;;
    --cluster-file=*) CLUSTER_FILE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
need kubectl jq helm
if [[ "$PROMPT" == 1 && ! -t 0 ]]; then
  warn "standard input is not a terminal: asking nothing (as with --no-prompt)"
  PROMPT=0
fi
if [[ "$PROMPT" == 0 ]] && ((${#OVERWRITE[@]} || REENTER)); then
  die "--overwrite and --reenter need a terminal to ask on (not with --no-prompt)"
fi
[[ -r "$CLUSTER_FILE" ]] || die "cannot read $CLUSTER_FILE (run from your copy of the repository or pass --cluster-file)"

# --- What this cluster needs ----------------------------------------------------
header "Cluster"
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
plan="$(seed_plan "$CLUSTER_FILE" ${helm_args[@]+"${helm_args[@]}"})"
OPENBAO_KV="$(jqr -r '.kvPath' <<<"$plan")"
modules="$(jqr -r '.modules | if length == 0 then "none (Den only)" else join(", ") end' <<<"$plan")"
log "Settings: $CLUSTER_FILE"
log "Modules:  $modules"
log "Mount:    $OPENBAO_KV/ (KV version 2)"

# The entries a person enters, in order: path, kind, fields, Applications, description.
PATHS=() KINDS=() FIELDS=() APPS=() WHATS=()
while IFS=$'\t' read -r p k f a w; do
  PATHS+=("$p") KINDS+=("$k") FIELDS+=("$f") APPS+=("$a") WHATS+=("$w")
done < <(jqr -r '.manual[] | [.path, .kind, (.fields | join(", ")), (.apps | join(", ")), .what] | @tsv' <<<"$plan")
GENERATED=()
while IFS= read -r p; do GENERATED+=("$p"); done < <(jqr -r '.generated[].path' <<<"$plan")

# rel <path>: the path below the mount (accepts it with or without the mount).
rel() { local p=${1#/}; p=${p#"$OPENBAO_KV/"}; printf '%s' "${p%/}"; }
index_of() {
  local i
  for i in "${!PATHS[@]}"; do [[ "${PATHS[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done
  return 1
}
FORCE=()
for o in ${OVERWRITE[@]+"${OVERWRITE[@]}"}; do
  r="$(rel "$o")"
  if index_of "$r" >/dev/null; then
    FORCE+=("$r")
  elif [[ " ${GENERATED[*]} " == *" $r "* ]]; then
    die "$OPENBAO_KV/$r is generated by External Secrets, not entered here. To get a new value, see \"Rotate a generated value\" in the guide."
  else
    die "$OPENBAO_KV/$r is not an entry this cluster.yaml needs. One of: $(printf '%s ' "${PATHS[@]/#/$OPENBAO_KV/}")"
  fi
done
forced() { ((REENTER)) || [[ " ${FORCE[*]-} " == *" $1 "* ]]; }

TOKEN="$(token_from_env_or_file)"
bao_cmd "$TOKEN" bao token lookup -format=json >/dev/null 2>&1 \
  || die "token rejected (is OpenBao unsealed? is the token valid? does $OPENBAO_KV/ exist?)"
if [[ "$PROMPT" == 1 ]]; then windows_hint; fi

# --- Values only you know ------------------------------------------------------------
WRITTEN=() KEPT=() MISSING=() HIDDEN_WRITTEN=()
S3_PATHS=() S3_KEYS=()   # access key of every S3 entry seen so far

# s3_reuse <path> <access key>: warns if another S3 entry has the same key.
s3_reuse() {
  local i
  for i in "${!S3_PATHS[@]}"; do
    if [[ "${S3_PATHS[$i]}" != "$1" && "${S3_KEYS[$i]}" == "$2" ]]; then
      warn "$OPENBAO_KV/$1 uses the same access key as $OPENBAO_KV/${S3_PATHS[$i]}."
      note "Give every bucket its own key, limited to that bucket: a leaked or"
      note "compromised key then exposes one bucket, not all of them."
    fi
  done
}
s3_remember() {
  local i
  for i in "${!S3_PATHS[@]}"; do
    if [[ "${S3_PATHS[$i]}" == "$1" ]]; then S3_KEYS[$i]=$2; return; fi
  done
  S3_PATHS+=("$1") S3_KEYS+=("$2")
}

# missing <i>: records entry i as missing.
missing() {
  MISSING+=("$OPENBAO_KV/${PATHS[$1]} (${FIELDS[$1]}): Application(s) ${APPS[$1]} stay Degraded")
}

# check_existing <i> <json>: checks the fields of an existing entry the same
# way as typed answers, so a broken value (a failed paste stored as "\")
# shows up. Values stay in memory; only the reason is printed.
BROKEN=()
check_existing() {
  local i=$1 json=$2 p=${PATHS[$1]} spec="" f kind v why
  case "${KINDS[$i]}" in
    s3) spec="access_key:s3-access secret_key:s3-secret" ;;
    smtp) spec="host:text from:text password:smtp-password?" ;;
    cloudflare) spec="api-token:cloudflare" ;;
    ghcr) spec="username:text token:ghcr-token" ;;
  esac
  for f in $spec; do
    kind=${f#*:} f=${f%%:*}
    v="$(json_field "$json" "$f")"
    if [[ -z "$v" && "$kind" == *\? ]]; then continue; fi
    kind=${kind%\?}
    if ! why="$(check_value "$kind" "$v")"; then
      bad "$OPENBAO_KV/$p: $f $why"
      note "Replace it: --overwrite $OPENBAO_KV/$p (or edit it in the OpenBao web UI)"
      BROKEN+=("$OPENBAO_KV/$p ($f $why)")
    fi
  done
  if [[ "${KINDS[$i]}" == s3 ]]; then
    v="$(json_field "$json" access_key)"
    if [[ -n "$v" ]]; then s3_reuse "$p" "$v"; s3_remember "$p" "$v"; fi
  fi
}

# Section headers, in plan order.
section_of() {
  case "$1" in
    s3) echo "S3 keys (one per bucket, limited to that bucket)" ;;
    smtp) echo "Mail server for Keycloak (SMTP)" ;;
    cloudflare) echo "Cloudflare API token (Let's Encrypt DNS-01)" ;;
    ghcr) echo "GitHub Container Registry (private images)" ;;
  esac
}

# put <path> <field>...: kv_put_lines with a clear message if OpenBao refuses.
# Callers add "|| exit 1": it runs in a pipeline, so "die" ends only that.
put() {
  kv_put_lines "$TOKEN" "$@" || die "could not write $OPENBAO_KV/$1 (may the token write there?)"
}

# ask_<kind> <i>: asks for entry i and writes it; false if skipped.
ask_s3() {
  local p=${PATHS[$1]} ak sk
  prompt_value ak "  Access key ID (empty = skip): " s3-access 0 1 || return 1
  [[ -n "$ak" ]] || return 1
  s3_reuse "$p" "$ak"
  prompt_value sk "  Secret access key (hidden): " s3-secret 1 0 || return 1
  printf '%s\n%s\n' "$ak" "$sk" | put "$p" access_key secret_key || exit 1
  unset sk
  s3_remember "$p" "$ak"
}

ask_smtp() {
  local p=${PATHS[$1]} host port from user pass
  prompt_value host "  SMTP host, e.g. smtp.example.org (empty = skip): " text 0 1 || return 1
  [[ -n "$host" ]] || return 1
  local try
  for try in 1 2 3; do
    prompt_value port "  Port [587]: " text 0 1 || return 1
    port=${port:-587}
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port > 0 && 10#$port < 65536)) && break
    bad "The port must be a number such as 587 or 465 ($try of 3)."
    ((try < 3)) || return 1
  done
  for try in 1 2 3; do
    prompt_value from "  From address, e.g. no-reply@example.org: " text 0 0 || return 1
    [[ "$from" == *@*.* && ! "$from" =~ [[:space:]] ]] && break
    bad "That is not an e-mail address ($try of 3)."
    ((try < 3)) || return 1
  done
  prompt_value user "  Username (empty = no login): " text 0 1 || return 1
  pass=""
  if [[ -n "$user" ]]; then
    prompt_value pass "  Password (hidden): " smtp-password 1 0 || return 1
  fi
  printf '%s\n%s\n%s\n%s\n%s\n' "$host" "$port" "$from" "$user" "$pass" \
    | put "$p" host port from username password || exit 1
  unset pass
}

ask_cloudflare() {
  local p=${PATHS[$1]} t
  prompt_value t "  API token (hidden, empty = skip): " cloudflare 1 1 || return 1
  [[ -n "$t" ]] || return 1
  printf '%s\n' "$t" | put "$p" api-token || exit 1
  unset t
}

ask_ghcr() {
  local p=${PATHS[$1]} user t
  prompt_value user "  GitHub user name (empty = skip): " text 0 1 || return 1
  [[ -n "$user" ]] || return 1
  prompt_value t "  Classic token with only read:packages (hidden): " ghcr-token 1 0 || return 1
  printf '%s\n%s\n' "$user" "$t" | put "$p" username token || exit 1
  unset t
}

ask_entry() {
  case "$1" in
    s3) ask_s3 "$2" ;;
    smtp) ask_smtp "$2" ;;
    cloudflare) ask_cloudflare "$2" ;;
    ghcr) ask_ghcr "$2" ;;
    *) bad "unknown kind of entry: $1"; return 1 ;;
  esac
}

current=""
for i in "${!PATHS[@]}"; do
  p=${PATHS[$i]} k=${KINDS[$i]}
  s="$(section_of "$k")"
  if [[ "$s" != "$current" ]]; then header "$s"; current=$s; fi

  exists=0 json=""
  if json="$(kv_get_json "$TOKEN" "$p")"; then exists=1; fi

  if [[ "$exists" == 1 ]] && ! forced "$p"; then
    good "$OPENBAO_KV/$p exists, keeping it"
    KEPT+=("$p")
    check_existing "$i" "$json"
    json=""
    continue
  fi
  json=""
  if [[ "$PROMPT" == 0 ]]; then
    bad "$OPENBAO_KV/$p is missing (${FIELDS[$i]}); Application(s) ${APPS[$i]} stay Degraded"
    missing "$i"
    continue
  fi

  if [[ "$exists" == 1 ]]; then
    log "$OPENBAO_KV/$p: replacing it (empty answer = keep the current value)"
  else
    log "$OPENBAO_KV/$p"
  fi
  note "${WHATS[$i]}"
  if ask_entry "$k" "$i"; then
    good "$OPENBAO_KV/$p written"
    WRITTEN+=("$p")
    HIDDEN_WRITTEN+=("$OPENBAO_KV/$p")
  elif [[ "$exists" == 1 ]]; then
    warn "$OPENBAO_KV/$p: nothing entered, keeping the current value"
    KEPT+=("$p")
  else
    warn "$OPENBAO_KV/$p skipped; Application(s) ${APPS[$i]} stay Degraded until it exists"
    missing "$i"
  fi
done

# Generated entries: only listed with --no-prompt (External Secrets makes them).
if [[ "$PROMPT" == 0 ]]; then
  header "Generated by External Secrets"
  eso_ns="$(jqr -r .esoNamespace <<<"$plan")"
  for p in "${GENERATED[@]}"; do
    if kv_exists "$TOKEN" "$p"; then
      good "$OPENBAO_KV/$p exists"
    else
      warn "$OPENBAO_KV/$p not created yet (kubectl get pushsecret -n $eso_ns)"
    fi
  done
fi

# --- Summary ----------------------------------------------------------------------------
header "Summary"
good "${#WRITTEN[@]} written, ${#KEPT[@]} kept"
if ((${#MISSING[@]})); then
  bad "${#MISSING[@]} missing:"
  for m in "${MISSING[@]}"; do printf '%s        %s%s\n' "$C_RED" "$m" "$C_RESET" >&2; done
  note "Run this script again (without --no-prompt) to enter them; the Applications"
  note "continue on their own a few minutes after the entry exists."
else
  good "Nothing missing."
fi
if ((${#BROKEN[@]})); then
  bad "${#BROKEN[@]} existing value(s) cannot be right:"
  for m in "${BROKEN[@]}"; do printf '%s        %s%s\n' "$C_RED" "$m" "$C_RESET" >&2; done
  note "Replace them: --overwrite <path> (repeatable), or edit them in the OpenBao web UI."
fi
if ((${#HIDDEN_WRITTEN[@]})); then
  warn "Check the values you just entered in the OpenBao web UI (Secrets, $OPENBAO_KV):"
  for p in "${HIDDEN_WRITTEN[@]}"; do note "$p"; done
fi
if [[ "$PROMPT" == 1 ]]; then
  warn "Hidden values (S3 secret keys, SMTP password, tokens) are only checked for their"
  note "form here. A wrong one fails later (for example cert-manager: \"Invalid format for"
  note "Authorization header\"). Compare them in the OpenBao web UI; to replace one:"
  note "--overwrite <path>, or edit it there."
fi
log "Check with: kubectl get externalsecret,pushsecret -A"
