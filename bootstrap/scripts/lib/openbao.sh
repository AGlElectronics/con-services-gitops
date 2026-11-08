# shellcheck shell=bash
# Helpers shared by the OpenBao scripts (openbao-configure.sh,
# openbao-seed.sh). Source it, do not run it.
#
# Everything runs "bao" INSIDE an OpenBao pod with kubectl exec, so the
# operator's computer needs only kubectl and jq. Tokens and secret values
# are passed on stdin, never as command-line arguments (which would show up
# in process lists and shell history).
#
# OpenBao itself is a cluster prerequisite. Point these at its pods if they
# are not openbao/openbao-0:
#   OPENBAO_NAMESPACE (default openbao), OPENBAO_RELEASE (default openbao).

OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_RELEASE="${OPENBAO_RELEASE:-openbao}"
# Mount path of the KV version 2 engine (openbao.kvPath in cluster.yaml);
# the scripts set it from the seed plan.
OPENBAO_KV="${OPENBAO_KV:-kv}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed"
  done
}

pod_name() { printf '%s-%s' "$OPENBAO_RELEASE" "$1"; }

# seed_plan <cluster file> [helm args...]: the root chart's seed plan (JSON)
# for that settings file. Stops with the chart's message if it is invalid.
seed_plan() {
  local file=$1 root plan; shift
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  plan="$(helm template root "$root/charts/root" -f "$file" \
            --set global.seedPlan=true --show-only templates/seed-plan.yaml "$@" | sed -n '/^{/p')" \
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

# token_from_env_or_file: BAO_TOKEN, or the root token in $INIT_FILE, or
# asked for without echoing.
token_from_env_or_file() {
  local t
  if [[ -n "${BAO_TOKEN:-}" ]]; then
    printf '%s' "$BAO_TOKEN"
  elif [[ -n "${INIT_FILE:-}" && -r "$INIT_FILE" ]]; then
    jq -r '.root_token' "$INIT_FILE"
  elif [[ -t 0 ]]; then
    read -r -s -p "OpenBao token: " t; echo >&2
    [[ -n "$t" ]] || die "no token given"
    printf '%s' "$t"
  else
    die "set BAO_TOKEN or INIT_FILE (path to the OpenBao init file) to authenticate"
  fi
}

# kv_exists <token> <path>: true if $OPENBAO_KV/<path> has data.
kv_exists() {
  bao_cmd "$1" bao kv get -format=json "$OPENBAO_KV/$2" >/dev/null 2>&1
}

# kv_put_json <token> <path> <json>: writes the JSON object to $OPENBAO_KV/<path>.
kv_put_json() {
  printf '%s' "$3" | bao_as "$1" bao kv put "$OPENBAO_KV/$2" - >/dev/null
}
