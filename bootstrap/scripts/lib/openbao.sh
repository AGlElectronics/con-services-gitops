# shellcheck shell=bash
# Helpers shared by the OpenBao scripts (openbao-init.sh, openbao-unseal.sh,
# openbao-seed.sh). Source it, do not run it.
#
# Everything runs "bao" INSIDE the OpenBao pods with kubectl exec, so the
# operator's computer needs only kubectl and jq. Tokens and secret values
# are passed on stdin, never as command-line arguments (which would show up
# in process lists and shell history).

OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPENBAO_RELEASE="${OPENBAO_RELEASE:-openbao}"
# Number of OpenBao pods (openbao.replicas in cluster.yaml); read from the
# StatefulSet when not set.
if [[ -z "${OPENBAO_REPLICAS:-}" ]]; then
  OPENBAO_REPLICAS="$(kubectl get statefulset -n "$OPENBAO_NAMESPACE" "$OPENBAO_RELEASE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  OPENBAO_REPLICAS="${OPENBAO_REPLICAS:-3}"
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed"
  done
}

pod_name() { printf '%s-%s' "$OPENBAO_RELEASE" "$1"; }

# bao_status <pod>: prints "bao status -format=json" (exit code 2 = sealed is fine).
bao_status() {
  kubectl exec -n "$OPENBAO_NAMESPACE" "$1" -- bao status -format=json 2>/dev/null || true
}

# status_field <pod> <field>: "true", "false", or empty if the pod does not
# answer. (jq's "// empty" would also swallow false.)
status_field() {
  bao_status "$1" | jq -r --arg f "$2" '.[$f] | select(. != null) | tostring' 2>/dev/null || true
}

# bao_unseal_key <pod>: reads ONE unseal key from stdin and submits it.
bao_unseal_key() {
  # shellcheck disable=SC2016 # $k expands inside the pod
  kubectl exec -i -n "$OPENBAO_NAMESPACE" "$1" -- \
    sh -c 'read -r k; exec bao operator unseal -format=json "$k"' >/dev/null
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

# token_from_env_or_file: BAO_TOKEN, or the root token in $INIT_FILE.
token_from_env_or_file() {
  if [[ -n "${BAO_TOKEN:-}" ]]; then
    printf '%s' "$BAO_TOKEN"
  elif [[ -n "${INIT_FILE:-}" && -r "$INIT_FILE" ]]; then
    jq -r '.root_token' "$INIT_FILE"
  else
    die "set BAO_TOKEN or INIT_FILE (path to openbao-init.json) to authenticate"
  fi
}

# gen_secret [bytes]: random URL- and shell-safe value (hex), default 32 bytes.
gen_secret() { openssl rand -hex "${1:-32}"; }

# kv_exists <token> <path>: true if kv/<path> has data.
kv_exists() {
  bao_cmd "$1" bao kv get -format=json "kv/$2" >/dev/null 2>&1
}

# kv_put_json <token> <path> <json>: writes the JSON object to kv/<path>.
kv_put_json() {
  printf '%s' "$3" | bao_as "$1" bao kv put "kv/$2" - >/dev/null
}
