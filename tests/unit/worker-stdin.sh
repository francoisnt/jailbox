#!/bin/bash
# File redirection, unlike a pipeline, exposes Bash's async stdin substitution.
set -euo pipefail
set +m
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/resource-ledger.sh
source "$REPO_ROOT/tests/lib/resource-ledger.sh"
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$REPO_ROOT/tests/lib/lifecycle-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
matrix_die() { fail "$@"; }
export JAILBOX_TEST_LEDGER_DIR="$tmp/ledger"
ledger_begin_run stdin-pool
export LIFECYCLE_POOL_LEDGER="$LEDGER_FILE"
ledger_begin_run stdin-worker
ROOT="$tmp/toolroot"
FIXTURE="$tmp/fixture"
PROJECT="$FIXTURE/project"
mkdir -p "$PROJECT" "$FIXTURE/bin" "$ROOT/tests/lib/sandbox" "$ROOT/tests/lib/lifecycle" "$ROOT/src/host/core"
cp "$REPO_ROOT/tests/fixtures/worker-stdin-cli.sh" "$ROOT/src/jailbox"
cp "$REPO_ROOT/tests/lib/sandbox/check-proxy-environment.sh" "$ROOT/tests/lib/sandbox/"
cp "$REPO_ROOT/tests/lib/lifecycle/shell-command.sh" "$ROOT/tests/lib/lifecycle/"
cp "$REPO_ROOT/tests/lib/resource-ledger.sh" "$REPO_ROOT/tests/lib/shell-terminal.py" "$ROOT/tests/lib/"
cp "$REPO_ROOT/src/host/core/project-id.sh" "$ROOT/src/host/core/"
# Process-group isolation is independent of stdin and unavailable on macOS.
printf '#!/bin/bash\nexec "$@"\n' > "$FIXTURE/bin/setsid"
chmod 755 "$ROOT/src/jailbox" "$FIXTURE/bin/setsid"
PATH="$FIXTURE/bin:$PATH"

observe_exec allow "$tmp/observed"
observe_shell allow "$tmp/shell"
printf 'first\0binary\377\n' > "$tmp/first.input"
printf 'second\0binary\376\n' > "$tmp/second.input"
cli exec cat < "$tmp/first.input" > "$tmp/first.output" & first=$!
cli exec cat < "$tmp/second.input" > "$tmp/second.output" & second=$!
wait "$first"
wait "$second"
cmp "$tmp/first.input" "$tmp/first.output"
cmp "$tmp/second.input" "$tmp/second.output"
printf 'exit 42\n' > "$tmp/failure.sh"
result=0
cli exec bash -s < "$tmp/failure.sh" || result=$?
[[ "$result" = 42 ]] || fail 'streamed command lost its exit status'

NETWORK=fixture-net
podman() { printf '10.240.57.0/24\n'; }
export HTTP_PROXY=http://10.240.57.2:8888 HTTPS_PROXY=http://10.240.57.2:8888
export http_proxy=http://10.240.57.2:8888 https_proxy=http://10.240.57.2:8888
export NO_PROXY=localhost no_proxy=localhost
verify_exec_proxy_environment
if (HTTP_PROXY=http://wrong:8888; verify_exec_proxy_environment) > "$tmp/out" 2> "$tmp/err"; then
    fail 'streamed proxy assertion accepted the wrong environment'
fi
grep -Fq 'exec lost proxy environment or added a login shell' "$tmp/err"
printf 'PASS: real CLI worker launch preserves binary stdin, concurrent streams, and failing assertions\n'
