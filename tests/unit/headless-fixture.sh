#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Exercise the allocator without launching the end-to-end script or Podman.
# shellcheck disable=SC1090
source <(sed -n '/^headless_fixture() {/,/^}/p' "$ROOT/tests/e2e/headless.sh")
declare -F headless_fixture >/dev/null || fail 'could not extract headless_fixture'
stub_dir="$fixture/stubs"
mkdir -p "$stub_dir/ports/62000"
printf '0\n' > "$fixture/count"
mktemp() {
    local count
    count=$(cat "$fixture/count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$fixture/count"
    mkdir "$fixture/candidate-$count"
    printf '%s\n' "$fixture/candidate-$count"
}
jailbox_project_hash_for_path() { printf '%s\n' "${1##*-}"; }
jailbox_project_hash_port_offset() {
    case "$1" in
        1) printf '0\n' ;; # Rejected by the availability check.
        2) printf '12848\n' ;; # 62000 is already claimed by a sibling.
        *) printf '12849\n' ;; # 62001 is usable once.
    esac
}
test_fixture_port_available() { [[ "$1" != 49152 ]]; }
die() { printf '%s\n' "$*" >&2; return 1; }

project=$(headless_fixture debian)
[[ "$project" = "$fixture/candidate-3" && -d "$project" ]] || fail 'wrong fixture selected'
[[ ! -e "$fixture/candidate-1" && ! -e "$fixture/candidate-2" ]] || fail 'rejected directories leaked'
[[ -d "$stub_dir/ports/62000" && -d "$stub_dir/ports/62001" ]] || fail 'port claims lost'
# The first stage keeps its claim even before its container binds the port.
if headless_fixture alpine > "$fixture/output" 2> "$fixture/error"; then
    fail 'a second stage reused a claimed port'
fi
[[ $(cat "$fixture/count") = 103 ]] || fail 'allocation retry bound changed'
[[ ! -s "$fixture/output" ]] || fail 'failed allocation published a project'
grep -Fq 'could not allocate a free SSH port' "$fixture/error"
[[ $(find "$fixture" -maxdepth 1 -name 'candidate-*' | wc -l) = 1 ]] || fail 'failed allocation leaked directories'
printf 'PASS: headless fixtures reject unavailable and claimed ports with bounded cleanup\n'

# Status artifacts survive fixture cleanup, remain outside PATH, and retain
# repeated observations of the same state within each parallel stage.
(
    # shellcheck disable=SC1090
    source <(sed -n '/^assert_status() {/,/^}/p' "$ROOT/tests/e2e/headless.sh")
    mkdir -p "$fixture/cli/src" "$fixture/project" "$fixture/logs/debian.status" "$fixture/logs/alpine.status"
    cat > "$fixture/cli/src/jailbox" <<'CLI'
#!/bin/bash
printf 'absent\n'
CLI
    chmod 755 "$fixture/cli/src/jailbox"
    # shellcheck disable=SC2034 # Used by the extracted assert_status.
    JAILBOX_DIR="$fixture/cli"
    # shellcheck disable=SC2329 # Called by the extracted assert_status.
    pass() { :; }
    for stage in debian alpine; do
        status_artifact_dir="$fixture/logs/$stage.status"
        # shellcheck disable=SC2034 # Updated by the extracted assert_status.
        status_observation=0
        assert_status "$fixture/project" absent
        assert_status "$fixture/project" absent
        for observation in 1 2; do
            [[ -f "$status_artifact_dir/$observation-absent.expected" &&
               -f "$status_artifact_dir/$observation-absent.stdout" &&
               -f "$status_artifact_dir/$observation-absent.stderr" ]]
        done
    done
    [[ -z $(find "$stub_dir" -type f) ]] || fail 'status artifacts entered the stub directory'
)
printf 'PASS: headless status artifacts retain each stage and observation outside PATH\n'

# Use the runtime harness's actual stubs for preflight and launch. Inventory
# must work before a profile exists, while the headless guard rejects both.
(
    # shellcheck disable=SC1090
    source <(sed -n '/^setup_stub_editor() {/,/^}/p' "$ROOT/tests/e2e/headless.sh")
    # shellcheck disable=SC2034 # Consumed by the extracted setup function.
    JAILBOX_DIR="$ROOT"
    setup_stub_editor
    export JAILBOX_E2E_PROJECT="$fixture/project" JAILBOX_E2E_REJECT_EDITOR=0
    for editor in codium code; do
        case "$editor" in
            codium) expected=jeanp413.open-remote-ssh ;;
            code) expected=ms-vscode-remote.remote-ssh ;;
        esac
        [[ $("$stub_dir/$editor" --extensions-dir "$fixture/extensions" --list-extensions) = "$expected" ]]
        if JAILBOX_E2E_REJECT_EDITOR=1 "$stub_dir/$editor" \
            --extensions-dir "$fixture/extensions" --list-extensions > "$fixture/output" 2>&1; then
            fail 'headless guard allowed editor discovery'
        fi
        if "$stub_dir/$editor" --user-data-dir "$fixture/profile" --remote ssh-remote+test > "$fixture/output" 2>&1; then
            fail 'stub accepted missing profile settings'
        fi
    done
    mkdir -p "$fixture/profile/User"
    printf '{"remote.SSH.configFile":"/test/ssh_config"}\n' > "$fixture/profile/User/settings.json"
    for editor in codium code; do
        "$stub_dir/$editor" --extensions-dir "$fixture/extensions" \
            --user-data-dir "$fixture/profile" --remote ssh-remote+test /home/jailbox/project
        if JAILBOX_E2E_REJECT_EDITOR=1 "$stub_dir/$editor" \
            --user-data-dir "$fixture/profile" --remote ssh-remote+test > "$fixture/output" 2>&1; then
            fail 'headless guard allowed editor launch'
        fi
    done
)
printf 'PASS: runtime editor stubs support preflight, validate launch, and preserve headless refusal\n'
