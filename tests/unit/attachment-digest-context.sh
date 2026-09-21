#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/public.sh
source "$ROOT/src/public.sh"
# shellcheck source=src/host/api-support.sh
source "$ROOT/src/host/api-support.sh"
initialize_public_api_lookups
# shellcheck source=src/host/core/common.sh
source "$ROOT/src/host/core/common.sh"
# shellcheck source=src/host/core/config-digest.sh
source "$ROOT/src/host/core/config-digest.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while IFS= read -r name; do unset "$name"; done < <(environment_config_names)
context=$(print_attachment_digest_context)
[[ "$context" = *'no recognized JAILBOX_CONFIG_'* ]] || fail 'missing empty invocation context'
[[ "$context" = *'cannot identify which launch-side key differed'* ]] || fail 'overclaimed digest diagnosis'
export JAILBOX_CONFIG_READONLY_PATHS_0=secret-path JAILBOX_CONFIG_DEV_IMAGE=secret-image
export JAILBOX_CONFIG_MEMORY_LIMIT=secret-memory JAILBOX_CONFIG_EGRESS_ALLOW_0=secret-domain
export JAILBOX_CONFIG_UNDECLARED=secret-unknown
context=$(print_attachment_digest_context)
expected='Current invocation configuration names: JAILBOX_CONFIG_DEV_IMAGE, JAILBOX_CONFIG_MEMORY_LIMIT, JAILBOX_CONFIG_EGRESS_ALLOW_0, JAILBOX_CONFIG_READONLY_PATHS_0'
[[ "${context%%$'\n'*}" = "$expected" ]] || fail 'context does not follow public declaration order'
[[ "$context" != *secret-* && "$context" != *UNDECLARED* ]] || fail 'context exposed values or unknown keys'
# Added public declarations automatically enter the diagnostic without a map.
CONFIG_SCALAR_KEYS+=(ADDED)
export JAILBOX_CONFIG_ADDED=secret-added
context=$(print_attachment_digest_context)
[[ "$context" = *JAILBOX_CONFIG_ADDED* ]] || fail 'new public key did not propagate'
printf 'PASS: attachment digest context exposes declared names in order, never values\n'

# Required refusal bytes precede advisory context, including when its helper
# fails under conditional invocation. No caller continuation may report success.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for context_status in 0 1; do
    status=0
    (
        CONFIG_DIGEST=$(printf '%064d' 1)
        CONFIG_DIGEST_LABEL_ARGS=(--label fixture)
        VOLUME_NAME=fixture-home
        config_digest_inventory() { printf 'container:fixture\n'; }
        jailbox_resource_exists() { return 0; }
        jailbox_resource_label() { printf '%064d' 2; }
        resolve_present_resources() { :; }
        print_attachment_digest_context() { printf 'advisory context\n'; return "$context_status"; }
        if require_compatible_project_resources attach; then printf 'unexpected success\n'; fi
        printf 'unexpected continuation\n'
    ) > "$tmp/out" 2> "$tmp/err" || status=$?
    [[ "$status" = 1 && ! -s "$tmp/out" ]] || fail 'context helper changed refusal status or allowed continuation'
    IFS= read -r first < "$tmp/err"
    [[ "$first" = 'Error: refusing to reuse project resources'* && "$first" = *"Run 'jailbox stop' and then 'jailbox up'"* ]] || fail 'required refusal and recovery did not come first'
    [[ $(tail -n 1 "$tmp/err") = 'advisory context' ]] || fail 'context was not attempted after the refusal'
done
printf 'PASS: digest refusal precedes advisory context and survives its failure\n'
