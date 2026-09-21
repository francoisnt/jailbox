#!/bin/bash
# Declaration additions must propagate to generic consumers and fail at every
# incomplete per-member mapping. No runtime engine is needed for these checks.
# shellcheck disable=SC2030,SC2031 # Mutations intentionally stay in subshells.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Sourcing the public contract declares data without loading implementation
# functions or changing runtime configuration and parsed option state.
(
    before=$(declare -F)
    DEV_IMAGE=untouched CONFIG_PATH_ARG=untouched
    # shellcheck source=src/public.sh
    source "$ROOT/src/public.sh"
    [[ $(declare -F) = "$before" && "$DEV_IMAGE" = untouched && "$CONFIG_PATH_ARG" = untouched ]]
    [[ ! -v CONFIG_SCALAR_KEY_SET ]]
)
# shellcheck source=src/public.sh
source "$ROOT/src/public.sh"
# shellcheck source=src/host/api-support.sh
source "$ROOT/src/host/api-support.sh"
initialize_public_api_lookups
# shellcheck source=src/host/cli.sh
source "$ROOT/src/host/cli.sh"
# shellcheck source=src/host/core/common.sh
source "$ROOT/src/host/core/common.sh"
# shellcheck source=src/host/core/preflight.sh
source "$ROOT/src/host/core/preflight.sh"
# shellcheck source=src/host/core/config-digest.sh
source "$ROOT/src/host/core/config-digest.sh"
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

validate_readme_keys() {
    # shellcheck disable=SC2034 # Both arrays are consumed through namerefs.
    local -a documented_keys=() declared_keys=("${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}" "${FRONTEND_SCALAR_KEYS[@]}")
    # shellcheck disable=SC2034
    mapfile -t documented_keys < <(awk -F '`' '/^\| `[A-Z][A-Z0-9_]*` \|/ {print $2 "=" $0}' "$ROOT/README.md")
    public_api_validate_mapping 'README configuration keys' declared_keys documented_keys
}
validate_readme_keys
expect_failure() {
    local expected="$1"
    shift
    if ("$@") > "$tmp/error" 2>&1; then fail "accepted $expected"; fi
    grep -Fq -- "$expected" "$tmp/error" || { cat "$tmp/error" >&2; fail "wrong diagnostic for $expected"; }
}

# The same contract applies to both representations, including empty defaults
# and values containing '='. No table is interpreted as shell code.
# shellcheck disable=SC2034 # Tables are consumed by name.
test_mapping_forms() {
    local -a members=(FIRST SECOND) entries=('FIRST=a=b' 'SECOND=')
    local -A mapping=([FIRST]='a=b' [SECOND]='')
    public_api_validate_mapping example members entries allow-empty
    public_api_validate_mapping example members mapping allow-empty
    expect_failure "empty mapping 'SECOND'" public_api_validate_mapping example members entries
    expect_failure "empty mapping 'SECOND'" public_api_validate_mapping example members mapping
    mapping[SECOND]=value
    public_api_validate_mapping example members mapping
    mapping[EXTRA]=value
    expect_failure "undeclared mapping 'EXTRA'" public_api_validate_mapping example members mapping
    entries=('FIRST=a=b' malformed)
    expect_failure "invalid entry 'malformed'" public_api_validate_mapping example members entries
    expect_failure "missing mapping table 'ABSENT_MAPPING'" public_api_validate_mapping example members ABSENT_MAPPING
    [[ $(cat "$tmp/error") = "Error: public API: example: missing mapping table 'ABSENT_MAPPING'" ]] || fail 'missing table emitted an extra diagnostic'
}
test_mapping_forms

missing_help() { CLI_OTHER_COMMANDS+=(sample); initialize_public_api_lookups; }
expect_failure "CLI help: missing mapping 'sample'" missing_help
missing_default() { FRONTEND_SCALAR_KEYS+=(SAMPLE); validate_public_api_declaration; }
expect_failure "frontend defaults: missing mapping 'SAMPLE'" missing_default
duplicate_help() { CLI_HELP+=("up=duplicate"); validate_public_api_declaration; }
expect_failure "CLI help: duplicate mapping 'up'" duplicate_help
unknown_help() { CLI_HELP+=("sample=unknown"); validate_public_api_declaration; }
expect_failure "CLI help: undeclared mapping 'sample'" unknown_help
unknown_argument_command() { CLI_ARGUMENT_COMMANDS+=(sample); validate_public_api_declaration; }
expect_failure "argument command 'sample' is undeclared" unknown_argument_command
(
    CLI_OTHER_COMMANDS+=(sample)
    CLI_HELP+=("sample=Sample command")
    CLI_ARGUMENT_COMMANDS+=(sample)
    initialize_public_api_lookups
    parse_args sample --config literal ''
) || fail 'declared argument support did not propagate to parsing'
expect_failure 'unexpected argument' parse_args status literal

add_command() {
    CLI_LIFECYCLE_COMMANDS+=(sample)
    CLI_HELP+=("sample=Sample command")
    initialize_public_api_lookups
}
missing_handler_mapping() {
    add_command
    public_api_validate_mapping 'command handlers' CLI_FLAGS_WITHOUT_VALUES CLI_COMMAND_HANDLERS
}
expect_failure "command handlers: missing mapping 'sample'" missing_handler_mapping
missing_lifecycle_contract() { add_command; lifecycle_jobs; }
expect_failure "lifecycle command contracts: missing mapping 'sample'" missing_lifecycle_contract
missing_fault_scenarios() {
    add_command
    LIFECYCLE_COMMAND_CONTRACTS[sample]=stop
    lifecycle_jobs
}
expect_failure "lifecycle fault scenarios: missing mapping 'sample'" missing_fault_scenarios
missing_fault_requirements() {
    LIFECYCLE_FAULT_SCENARIOS[up]+=' unsupported'
    lifecycle_jobs
}
expect_failure "missing fault requirements for 'up:unsupported'" missing_fault_requirements
unknown_lifecycle_contract() { LIFECYCLE_COMMAND_CONTRACTS[up]=unknown; lifecycle_fixed_cases; }
expect_failure "unknown lifecycle contract for 'up'" unknown_lifecycle_contract
duplicate_category() { CLI_OTHER_COMMANDS+=(up); initialize_public_api_lookups; }
expect_failure "duplicate declaration 'up'" duplicate_category
missing_option() {
    CLI_FLAGS_WITH_VALUES+=(--sample)
    CLI_HELP+=("--sample=Sample option")
    CLI_VALUE_NAMES[--sample]=VALUE
    initialize_public_api_lookups
    public_api_validate_mapping 'option targets' CLI_FLAGS_WITH_VALUES CLI_OPTION_TARGETS
}
expect_failure "option targets: missing mapping '--sample'" missing_option
missing_digest_mode() {
    CONFIG_ARRAY_KEYS+=(SAMPLE)
    CONFIG_DEFAULTS+=("SAMPLE=")
    initialize_public_api_lookups
    validate_digest_api_mapping
}
expect_failure "digest array modes: missing mapping 'SAMPLE'" missing_digest_mode
missing_documentation() { CONFIG_SCALAR_KEYS+=(SAMPLE); validate_readme_keys; }
expect_failure "README configuration keys: missing mapping 'SAMPLE'" missing_documentation

(
    add_command
    CLI_COMMAND_HANDLERS[sample]='usage'
    public_api_validate_mapping 'command handlers' CLI_FLAGS_WITHOUT_VALUES CLI_COMMAND_HANDLERS
    is_cli_flag_allowed sample
    usage > "$tmp/help"
    grep -Eq '(\[|\|)sample(\||\])' "$tmp/help"
    grep -Fq 'Sample command' "$tmp/help"
    LIFECYCLE_COMMAND_CONTRACTS[sample]=stop
    LIFECYCLE_FAULT_SCENARIOS[sample]='false true'
    lifecycle_fixed_cases > "$tmp/cases"
    grep -Fxq 'absent.sample' "$tmp/cases"
    lifecycle_jobs > "$tmp/jobs"
    grep -Fxq 'fault.sample.true|fault|sample|true' "$tmp/jobs"
)
(
    CLI_OTHER_COMMANDS+=(sample)
    CLI_HELP+=("sample=Sample command")
    initialize_public_api_lookups
    is_cli_flag_allowed sample
    lifecycle_fixed_cases > "$tmp/cases"
    if grep -Fq '.sample' "$tmp/cases"; then fail 'non-lifecycle command entered matrix'; fi
)
(
    CONFIG_ARRAY_KEYS+=(SAMPLE)
    CONFIG_DEFAULTS+=("SAMPLE=")
    DIGEST_ARRAY_MODES[SAMPLE]=ordered
    initialize_public_api_lookups
    apply_config_defaults
    set_config_array SAMPLE 'first value' second
    [[ "${SAMPLE[0]}" = 'first value' && "${SAMPLE[1]}" = second ]]
    validate_digest_api_mapping
    [[ $(config_digest_array_members SAMPLE) = $'first value\nsecond' ]]
)
printf 'PASS: public API additions propagate and incomplete mappings fail\n'

# Exercise the actual dispatcher with an added harmless early command. Its
# registration must be sufficient; no case statement in the entrypoint changes.
mkdir "$tmp/cli"
cp "$ROOT/src/jailbox" "$tmp/cli/jailbox"
cp -R "$ROOT/src/host" "$tmp/cli/host"
cp "$ROOT/src/public.sh" "$tmp/cli/public.sh"
cat >> "$tmp/cli/public.sh" <<'API'
CLI_OTHER_COMMANDS+=(sample)
CLI_HELP+=("sample=Sample command")
API
expect_failure "command handlers: missing mapping 'sample'" bash "$tmp/cli/jailbox" --help
printf '%s\n' "CLI_COMMAND_HANDLERS[sample]='missing_handler'" >> "$tmp/cli/host/cli.sh"
expect_failure "missing command handler 'missing_handler'" bash "$tmp/cli/jailbox" sample
printf '%s\n' "CLI_COMMAND_HANDLERS[sample]='usage'" >> "$tmp/cli/host/cli.sh"
bash "$tmp/cli/jailbox" sample > "$tmp/dispatched"
grep -Fq 'Sample command' "$tmp/dispatched"
# A new value option also propagates to parsing through its declared target.
cat >> "$tmp/cli/public.sh" <<'API'
CLI_FLAGS_WITH_VALUES+=(--sample2)
CLI_HELP+=("--sample2=Sample value")
CLI_VALUE_NAMES[--sample2]=VALUE
API
# shellcheck disable=SC2016 # Function body is evaluated by the copied CLI.
printf '%s\n' 'CLI_OPTION_TARGETS[--sample2]=SAMPLE_VALUE' \
    "CLI_COMMAND_HANDLERS[sample]='sample_value'" \
    'sample_value() { printf "%s\n" "$SAMPLE_VALUE"; }' >> "$tmp/cli/host/cli.sh"
[[ $(bash "$tmp/cli/jailbox" --sample2 'value with spaces' sample) = 'value with spaces' ]]
for token in "${CLI_FLAGS_WITH_VALUES[@]}" "${CLI_FLAGS_WITHOUT_VALUES[@]}" --sample2; do
    [[ "$token" = -* ]] || continue
    result=0
    bash "$tmp/cli/jailbox" --config "$token" > "$tmp/error" 2>&1 || result=$?
    [[ "$result" = 2 ]] || fail "option value accepted declared flag $token"
    grep -Fq 'Error: --config requires a PATH value' "$tmp/error" || fail 'wrong missing-value diagnostic'
done
for value in up --undeclared ./--clean; do
    [[ $(bash "$tmp/cli/jailbox" --sample2 "$value" sample) = "$value" ]] || fail "ordinary value rejected: $value"
done
printf 'PASS: real dispatcher requires and uses newly declared command handlers\n'
