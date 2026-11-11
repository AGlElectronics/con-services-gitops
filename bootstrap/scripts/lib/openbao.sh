# shellcheck shell=bash
# Helpers shared by the OpenBao scripts (openbao-configure.sh,
# openbao-seed.sh). Source it, do not run it.
# The PowerShell scripts next to them (*.ps1, lib/openbao.ps1) do the same.
#
# Everything runs "bao" INSIDE an OpenBao pod with kubectl exec, so the
# operator's computer needs only kubectl, jq and helm. Tokens and secret
# values are passed on stdin, never as command-line arguments (which would
# show up in process lists and shell history).
#
# OpenBao itself is a cluster prerequisite. Point these at its pods if they
# are not openbao/openbao-0:
#   OPENBAO_NAMESPACE (default openbao), OPENBAO_RELEASE (default openbao).
# NO_COLOR=1 turns the colours off (they are off anyway when stderr is not
# a terminal).

OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_RELEASE="${OPENBAO_RELEASE:-openbao}"
# Mount path of the KV version 2 engine (openbao.kvPath in cluster.yaml);
# the scripts set it from the seed plan.
OPENBAO_KV="${OPENBAO_KV:-conservices}"

# --- Output ---------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BOLD='' C_RESET=''
fi

die()     { printf '%sERROR: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
log()     { printf '==> %s\n' "$*" >&2; }
header()  { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
good()    { printf '%s  ok    %s%s\n' "$C_GREEN" "$*" "$C_RESET" >&2; }
warn()    { printf '%s  warn  %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
bad()     { printf '%s  error %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
# note <text>: an indented line without a status word.
note()    { printf '        %s\n' "$*" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed"
  done
}

# jqr <jq args...>: jq without the carriage returns jq on Windows may add.
jqr() { jq "$@" | tr -d '\r'; }

pod_name() { printf '%s-%s' "$OPENBAO_RELEASE" "$1"; }

# seed_plan <cluster file> [helm args...]: the root chart's seed plan (JSON)
# for that settings file. Stops with the chart's message if it is invalid.
seed_plan() {
  local file=$1 root plan; shift
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  plan="$(helm template root "$root/charts/root" -f "$file" \
            --set global.seedPlan=true --show-only templates/seed-plan.yaml "$@" \
            | tr -d '\r' | sed -n '/^{/p')" \
    || die "the root chart rejected $file (fix the message above first)"
  [[ -n "$plan" ]] || die "could not read the seed plan from charts/root"
  printf '%s' "$plan"
}

# bao_as <token> <command...>: runs a bao command in the first pod with the
# given token. The caller's stdin is passed on to the command after the
# token, e.g. JSON for "bao kv put <path> -". Always give it a stdin.
bao_as() {
  local token=$1; shift
  { printf '%s\n' "$token"; cat; } | kubectl exec -i -n "$OPENBAO_NAMESPACE" "$(pod_name 0)" -- \
    sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec "$@"' sh "$@"
}

# bao_cmd <token> <command...>: bao_as without input.
bao_cmd() { bao_as "$@" </dev/null; }

# --- Input ------------------------------------------------------------------------

# clean <value>: the value without carriage returns and surrounding
# whitespace (a paste on Windows often brings a CR or a trailing space).
clean() {
  local v=${1//$'\r'/}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# mask <value>: what may be shown of a secret: its length, and for longer
# values the first and last four characters.
mask() {
  local v=$1 n=${#1}
  if ((n >= 16)); then
    printf '%d characters, %s...%s' "$n" "${v:0:4}" "${v: -4}"
  else
    printf '%d characters' "$n"
  fi
}

# check_value <kind> <value>: fails, printing the reason on stdout, when the
# value cannot be right. Warnings for unusual but possible values go to
# stderr. Kinds: s3-access, s3-secret, smtp-password, cloudflare,
# ghcr-token, bao-token, text.
check_value() {
  local kind=$1 v=$2 n=${#2}
  [[ -n "$v" ]] || { echo "is empty"; return 1; }
  if [[ "$v" =~ [[:cntrl:]] ]]; then
    echo "contains control characters (the paste did not arrive as text)"; return 1
  fi
  if [[ "$kind" != smtp-password && "$kind" != text ]]; then
    [[ "$v" != *\\* ]] || { echo "contains a backslash (\\); no key or token has one, the paste probably failed"; return 1; }
    [[ ! "$v" =~ [[:space:]] ]] || { echo "contains whitespace"; return 1; }
  fi
  case "$kind" in
    s3-access)
      ((n >= 3)) || { echo "is only $n characters long; S3 access key IDs are longer"; return 1; } ;;
    s3-secret)
      ((n >= 8)) || { echo "is only $n characters long; S3 secret keys are longer"; return 1; } ;;
    cloudflare)
      [[ "$v" =~ ^[A-Za-z0-9_-]+$ ]] \
        || { echo "has characters a Cloudflare API token never has (only letters, digits, _ and -)"; return 1; }
      [[ "$v" != cfk_* ]] \
        || { echo "is a Global API Key (cfk_...), not an API token; create an API token instead"; return 1; }
      ((n >= 32 && n <= 120)) \
        || { echo "is $n characters long; Cloudflare API tokens have 40 (older) or 53 (cfut_/cfat_) characters"; return 1; }
      if ((n != 40)) && [[ ! "$v" =~ ^cf(ut|at)_ ]]; then
        warn "unusual for a Cloudflare API token ($n characters, expected 40 or cfut_/cfat_ + 48); keeping it"
      fi ;;
    ghcr-token)
      [[ "$v" =~ ^[A-Za-z0-9_]+$ ]] \
        || { echo "has characters a GitHub token never has (only letters, digits and _)"; return 1; }
      ((n >= 20)) || { echo "is only $n characters long; GitHub tokens are 40 or more"; return 1; }
      [[ "$v" == ghp_* ]] \
        || warn "not a classic token (ghp_...); ghcr.io needs a classic token with read:packages" ;;
    bao-token)
      ((n >= 8)) || { echo "is only $n characters long; OpenBao tokens are longer"; return 1; } ;;
    smtp-password)
      if [[ "$v" == \\ ]]; then echo "is a single backslash; the paste probably failed"; return 1; fi
      if [[ "$v" == *\\* || "$v" =~ [[:space:]] ]]; then
        warn "contains a backslash or a space; fine if your password really has one"
      fi ;;
  esac
  return 0
}

# prompt_value <var> <prompt> <kind> <hidden: 0|1> <optional: 0|1>
# Asks on the terminal, cleans and checks the answer, and asks again (three
# attempts) if it cannot be right. Hidden answers are confirmed by their
# masked form only. An empty answer is accepted when optional (the caller
# then skips). Returns 1 after three unusable answers or at end of input.
prompt_value() {
  local __var=$1 __prompt=$2 __kind=$3 __hidden=$4 __optional=$5 __v __why __try
  for __try in 1 2 3; do
    if [[ "$__hidden" == 1 ]]; then
      IFS= read -r -s -p "$__prompt" __v || { echo >&2; return 1; }
      echo >&2
    else
      IFS= read -r -p "$__prompt" __v || { echo >&2; return 1; }
    fi
    __v="$(clean "$__v")"
    if [[ -z "$__v" && "$__optional" == 1 ]]; then
      printf -v "$__var" '%s' ''
      return 0
    fi
    if __why="$(check_value "$__kind" "$__v")"; then
      [[ "$__hidden" == 1 ]] && good "received: $(mask "$__v")"
      printf -v "$__var" '%s' "$__v"
      return 0
    fi
    bad "That value $__why. Try again ($__try of 3)."
  done
  bad "No usable value after 3 attempts."
  printf -v "$__var" '%s' ''
  return 1
}

# windows_hint: warns about hidden input in Git Bash on Windows.
windows_hint() {
  case "${OSTYPE:-}" in msys* | cygwin*) ;; *) return 0 ;; esac
  if [[ "${TERM_PROGRAM:-}" == mintty ]]; then
    warn "Git Bash window (mintty): paste with Shift+Insert or a right click. Ctrl+V does not"
    note "paste there, it sends a control character. Hidden answers show their length and"
    note "first and last characters, so you can see whether the paste arrived. More reliable:"
    note "the PowerShell version of this script (bootstrap/scripts/*.ps1)."
  else
    warn "Git Bash on Windows: hidden input may lose pasted text in some terminals. Check the"
    note "length shown after each hidden answer, or use the PowerShell version of this script"
    note "(bootstrap/scripts/*.ps1)."
  fi
}

# token_from_env_or_file: BAO_TOKEN, or the root token in $INIT_FILE, or
# asked for without echoing.
token_from_env_or_file() {
  local t
  if [[ -n "${BAO_TOKEN:-}" ]]; then
    clean "$BAO_TOKEN"
  elif [[ -n "${INIT_FILE:-}" && -r "$INIT_FILE" ]]; then
    t="$(jqr -r '.root_token // empty' "$INIT_FILE")"
    [[ -n "$t" ]] || die "$INIT_FILE has no root_token"
    clean "$t"
  elif [[ -t 0 ]]; then
    prompt_value t "OpenBao token: " bao-token 1 0 || die "no usable token given"
    printf '%s' "$t"
  else
    die "set BAO_TOKEN or INIT_FILE (path to the OpenBao init file) to authenticate"
  fi
}

# --- KV version 2 ---------------------------------------------------------------------

# kv_exists <token> <path>: true if $OPENBAO_KV/<path> has data.
kv_exists() {
  bao_cmd "$1" bao kv get -format=json "$OPENBAO_KV/$2" >/dev/null 2>&1
}

# kv_get_json <token> <path>: prints $OPENBAO_KV/<path> as JSON (values
# under .data.data); fails if it does not exist. Keep the output in memory.
kv_get_json() {
  bao_cmd "$1" bao kv get -format=json "$OPENBAO_KV/$2" 2>/dev/null
}

# json_field <json> <field>: one value of a kv_get_json result, read
# through a pipe (no here-string, which may be a temporary file).
json_field() {
  printf '%s' "$1" | jq -r --arg f "$2" '.data.data[$f] // empty | tostring' | tr -d '\r'
}

# kv_put_lines <token> <path> <field>...: writes $OPENBAO_KV/<path> with the
# given fields; their values are read from stdin, one line each, so they
# never appear on a command line (not even jq's).
kv_put_lines() {
  local token=$1 path=$2; shift 2
  jq -Rn --args '[inputs] as $v | [$ARGS.positional, $v] | transpose | map({(.[0]): .[1]}) | add' "$@" \
    | bao_as "$token" bao kv put "$OPENBAO_KV/$path" - >/dev/null
}
