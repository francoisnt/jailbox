#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export CONVERGENCE_REAL_SLEEP
CONVERGENCE_REAL_SLEEP=$(command -v sleep)
export SETUP_TEST_REAL_MV
SETUP_TEST_REAL_MV=$(command -v mv)
export SETUP_TEST_REAL_RM
SETUP_TEST_REAL_RM=$(command -v rm)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"

export SETUP_TEST_PROJECT="$FIXTURE/project" SETUP_TEST_ROOT="$FIXTURE"
write_convergence_exec_helper "$SETUP_TEST_PROJECT"
state=${GENERATION%/*}
record=$state/home-setup-complete
volume="$CONVERGENCE_ENGINE/volume.$PREFIX-home"
generation="$CONVERGENCE_ENGINE/home-generation.$PREFIX-home"

write_scripts() {
    cat > "$SETUP_TEST_PROJECT/setup" <<'SETUP'
#!/bin/sh
set -eu
test "$#" = 0
test "$PWD" = "$SETUP_TEST_PROJECT"
printf 'setup\n' >> "$SETUP_TEST_ROOT/calls"
cat > "$SETUP_TEST_ROOT/received"
SETUP
    cat > "$SETUP_TEST_PROJECT/provider" <<'PROVIDER'
#!/bin/sh
set -eu
test "$#" = 0
test "$PWD" = "$SETUP_TEST_PROJECT"
printf 'provider\n' >> "$SETUP_TEST_ROOT/calls"
printf 'home-setup-test-payload\000\377\n\n'
PROVIDER
    chmod 755 "$SETUP_TEST_PROJECT/setup" "$SETUP_TEST_PROJECT/provider"
}

expect_exit() {
    local expected=$1 diagnostic=$2 status=0
    shift 2
    launch "$@" > "$FIXTURE/stdout" 2> "$FIXTURE/stderr" || status=$?
    if [[ "$status" != "$expected" ]] || ! grep -Fq "$diagnostic" "$FIXTURE/stderr"; then
        cat "$FIXTURE/stdout" "$FIXTURE/stderr" >&2
        printf 'Expected exit %s and %s, got %s\n' "$expected" "$diagnostic" "$status" >&2
        exit 1
    fi
    ! grep -q 'Sandbox is ready' "$FIXTURE/stdout"
}

assert_private_cleanup() {
    if compgen -G "$state/.setup-*" >/dev/null || compgen -G "$state/.home-setup-complete.*" >/dev/null; then
        printf 'Temporary setup files survived\n' >&2
        exit 1
    fi
}

write_scripts
export JAILBOX_CONFIG_HOME_SETUP_SCRIPT=setup JAILBOX_CONFIG_SETUP_INPUT_SCRIPT=provider
mkdir "$SETUP_TEST_PROJECT/scripts"
ln -s . "$SETUP_TEST_PROJECT/linked"
ln -s setup "$SETUP_TEST_PROJECT/link"
for key in HOME_SETUP_SCRIPT SETUP_INPUT_SCRIPT; do
    name=JAILBOX_CONFIG_$key
    for path in ../setup /setup link linked/setup scripts missing; do
        (export "$name=$path"; expect_exit 1 "$key" up)
    done
    chmod 644 "$SETUP_TEST_PROJECT/setup"
    (export "$name=setup"; expect_exit 1 'readable executable regular file' up)
    chmod 755 "$SETUP_TEST_PROJECT/setup"
done
JAILBOX_CONFIG_HIDDEN_PATHS_0=provider expect_exit 1 'conflicts with HIDDEN_PATHS' up
JAILBOX_CONFIG_HOME_SETUP_SCRIPT='' expect_exit 1 'SETUP_INPUT_SCRIPT requires HOME_SETUP_SCRIPT' up
printf '#!/bin/bash\nexit 42\n' > "$FIXTURE/bin/base64"
chmod 755 "$FIXTURE/bin/base64"
expect_exit 1 'could not encode jailbox up home setup arguments' up
rm "$FIXTURE/bin/base64"
[[ ! -e "$CONVERGENCE_LOG" && ! -e "$FIXTURE/calls" ]]

CONVERGENCE_SESSION_RESULT=hardening expect_exit 1 'live process hardening' up
[[ ! -e "$FIXTURE/calls" && ! -e "$volume" ]]
assert_private_cleanup
expect_success
[[ $(cat "$volume") = true ]]
[[ $(cat "$FIXTURE/calls") = $'provider\nsetup' ]]
printf 'home-setup-test-payload\000\377\n\n' > "$FIXTURE/expected"
cmp "$FIXTURE/expected" "$FIXTURE/received"
cmp "$generation" "$record"
for path in setup provider; do
    grep -Fq "/home/jailbox/project/$path:Z,ro,rprivate" "$CONVERGENCE_LOG"
done
if grep -RaFq 'home-setup-test-payload' "$CONVERGENCE_LOG" "$FIXTURE/output" "$CONVERGENCE_ENGINE" "$XDG_STATE_HOME"; then
    printf 'Provider bytes reached jailbox logs or metadata\n' >&2
    exit 1
fi
assert_private_cleanup
cp "$record" "$FIXTURE/first-record"
printf 'edit without a shebang\n' > "$SETUP_TEST_PROJECT/setup"
chmod 644 "$SETUP_TEST_PROJECT/setup"
mv "$SETUP_TEST_PROJECT/provider" "$SETUP_TEST_PROJECT/other-provider"
JAILBOX_CONFIG_EPHEMERAL_HOME=true expect_success
CONVERGENCE_VOLUME_INSPECTIONS="$FIXTURE/volume-inspections" launch connection-info > "$FIXTURE/connection"
[[ $(cat "$FIXTURE/volume-inspections") = "$PREFIX-home" ]]
launch exec true
JAILBOX_CONFIG_SETUP_INPUT_SCRIPT=other-provider expect_exit 1 'jailbox stop' up
podman stop "$PREFIX"
expect_exit 1 'SETUP_INPUT_SCRIPT path does not exist' up
mv "$SETUP_TEST_PROJECT/other-provider" "$SETUP_TEST_PROJECT/provider"
expect_success
[[ $(cat "$FIXTURE/calls") = $'provider\nsetup' ]]
printf '%064d\n' 1 > "$record"
expect_exit 1 'pending or unverified setup' connection-info
rm "$record"
expect_exit 1 'pending or unverified setup' connection-info
expect_exit 1 'pending or unverified setup' up
JAILBOX_CONFIG_HOME_SETUP_SCRIPT=missing launch stop
[[ ! -e "$volume" && ! -e "$record" ]]
write_scripts
unset JAILBOX_CONFIG_SETUP_INPUT_SCRIPT
expect_success
[[ ! -s "$FIXTURE/received" ]]
if cmp -s "$FIXTURE/first-record" "$record"; then
    printf 'Recreated home reused the original completion record\n' >&2
    exit 1
fi
cat > "$FIXTURE/bin/rm" <<'BLOCK'
#!/bin/bash
if [[ ${!#} = */home-setup-complete ]]; then exit 46; fi
exec "$SETUP_TEST_REAL_RM" "$@"
BLOCK
chmod 755 "$FIXTURE/bin/rm"
if launch stop; then
    printf 'Stop succeeded despite failure to remove completion record\n' >&2
    exit 1
fi
[[ ! -e "$volume" && -f "$record" ]]
"$SETUP_TEST_REAL_RM" "$FIXTURE/bin/rm"
launch stop
[[ ! -e "$record" ]]

# File-driven launch composes the same paths, preserves omission, and
# allows explicit policy to take precedence.
for retention in omitted true false; do
    printf 'DEV_IMAGE=localhost/convergence\nHOME_SETUP_SCRIPT=setup\nSETUP_INPUT_SCRIPT=provider\n' > "$SETUP_TEST_PROJECT/jailbox.conf"
    if [[ "$retention" != omitted ]]; then
        printf 'EPHEMERAL_HOME=%s\n' "$retention" >> "$SETUP_TEST_PROJECT/jailbox.conf"
    fi
    : > "$CONVERGENCE_LOG"
    (unset JAILBOX_CONFIG_DEV_IMAGE JAILBOX_CONFIG_HOME_SETUP_SCRIPT; launch --no-editor)
    for path in setup provider; do
        grep -Fq "/home/jailbox/project/$path:Z,ro,rprivate" "$CONVERGENCE_LOG"
    done
    expected=true
    [[ "$retention" != false ]] || expected=false
    [[ $(cat "$volume") = "$expected" ]]
    launch stop
done
[[ -f "$volume" && -f "$record" ]]
before=$(cat "$FIXTURE/calls")
expect_exit 1 'Set EPHEMERAL_HOME=false' up
JAILBOX_CONFIG_EPHEMERAL_HOME=false expect_success
[[ $(cat "$FIXTURE/calls") = "$before" ]]
launch --clean

# An unmarked persistent home predates setup support and is left alone.
printf 'false\n' > "$volume"
JAILBOX_CONFIG_EPHEMERAL_HOME=false expect_success
[[ $(cat "$FIXTURE/calls") = "$before" && ! -e "$record" ]]
launch --clean

# A failing provider never reaches the consumer. Rollback removes the fresh
# home so the user can fix the provider and relaunch without destructive clean.
write_scripts
printf '\nexit 42\n' >> "$SETUP_TEST_PROJECT/provider"
export JAILBOX_CONFIG_SETUP_INPUT_SCRIPT=provider JAILBOX_CONFIG_EPHEMERAL_HOME=false
expect_exit 42 'SETUP_INPUT_SCRIPT failed' up
[[ $(tail -n 1 "$FIXTURE/calls") = provider && ! -e "$volume" && ! -e "$record" ]]
grep -Fq 'relaunch to create a new home' "$FIXTURE/stderr"
if grep -Fq 'jailbox stop' "$FIXTURE/stderr"; then exit 1; fi
assert_private_cleanup
[[ $(JAILBOX_CONFIG_HOME_SETUP_SCRIPT=missing launch status) = absent ]]
write_scripts
expect_success
launch stop
[[ -f "$volume" ]]
JAILBOX_CONFIG_HOME_SETUP_SCRIPT=missing launch --clean
write_scripts
printf '\nexit 43\n' >> "$SETUP_TEST_PROJECT/setup"
JAILBOX_CONFIG_EPHEMERAL_HOME=true expect_exit 43 'HOME_SETUP_SCRIPT failed' up
[[ ! -e "$volume" && ! -e "$record" ]]
grep -Fq 'relaunch to create a new home' "$FIXTURE/stderr"
assert_private_cleanup

write_scripts
cat > "$FIXTURE/bin/mv" <<'BLOCK'
#!/bin/bash
if [[ ${!#} = */home-setup-complete ]]; then exit 45; fi
exec "$SETUP_TEST_REAL_MV" "$@"
BLOCK
chmod 755 "$FIXTURE/bin/mv"
expect_exit 45 'The persistent home is retained' up
[[ $(grep -Fc 'The persistent home is retained' "$FIXTURE/stderr") = 1 ]]
[[ $(tail -n 1 "$FIXTURE/calls") = setup && -f "$volume" && ! -e "$record" ]]
assert_private_cleanup
rm "$FIXTURE/bin/mv"
expect_exit 1 'pending or unverified setup' up
launch --clean

interrupt_launch_at() {
    local marker=$1 pid attempt
    (cd "$SETUP_TEST_PROJECT" && exec "$ROOT/src/jailbox" up) > "$FIXTURE/stdout" 2> "$FIXTURE/stderr" &
    pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ ! -s "$marker" ]] || break
        "$CONVERGENCE_REAL_SLEEP" 0.05
    done
    kill -TERM "$pid" 2>/dev/null || true
    if wait "$pid" || [[ ! -s "$marker" ]]; then
        cat "$FIXTURE/stdout" "$FIXTURE/stderr" >&2
        exit 1
    fi
    grep -Fq 'home setup was interrupted' "$FIXTURE/stderr"
}

write_scripts
cat >> "$SETUP_TEST_PROJECT/provider" <<'BLOCK'
(
    # Simulate a child command retaining the provider's stdout.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if [ -f "$SETUP_TEST_ROOT/provider-release" ]; then
            : > "$SETUP_TEST_ROOT/provider-child-survived"
            exit 0
        fi
        "$CONVERGENCE_REAL_SLEEP" 0.2
    done
) &
printf 'provider diagnostic before interruption\n' >&2
printf '%s\n' "$$" > "$SETUP_TEST_ROOT/provider-started"
wait
BLOCK
interrupt_launch_at "$FIXTURE/provider-started"
grep -Fxq 'provider diagnostic before interruption' "$FIXTURE/stderr"
grep -Fq 'Fix the setup error, then relaunch' "$FIXTURE/stderr"
if grep -Fq 'Killed' "$FIXTURE/stderr"; then
    cat "$FIXTURE/stderr" >&2
    exit 1
fi
touch "$FIXTURE/provider-release"
"$CONVERGENCE_REAL_SLEEP" 0.4
[[ ! -e "$FIXTURE/provider-child-survived" && ! -e "$volume" && ! -e "$record" ]]
assert_private_cleanup

write_scripts
cat >> "$SETUP_TEST_PROJECT/setup" <<'BLOCK'
printf '%s\n' "$$" > "$SETUP_TEST_ROOT/setup-started"
exec "$CONVERGENCE_REAL_SLEEP" 30
BLOCK
interrupt_launch_at "$FIXTURE/setup-started"
if kill -0 "$(cat "$FIXTURE/setup-started")" 2>/dev/null; then
    printf 'Interrupted setup process survived\n' >&2
    exit 1
fi
[[ -f "$volume" && ! -e "$record" ]]
assert_private_cleanup
expect_exit 1 'pending or unverified setup' up
launch --clean

printf 'PASS: home setup policy, input, retention and interrupted launch\n'
