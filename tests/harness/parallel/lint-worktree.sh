#!/bin/bash
# Changed-file selection must not miss staged/untracked files or lint old blobs.
# shellcheck disable=SC2016 # Fixture programs intentionally contain literal expansions.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
mkdir -p "$tmp/tree/scripts/lib" "$tmp/tree/tests" "$tmp/tree/src/host" \
    "$tmp/tree/src/container/runtime/bin" "$tmp/bin" "$tmp/no-repo"
cp "$ROOT/scripts/lint.sh" "$tmp/tree/scripts/"
cp "$ROOT/scripts/lib/lint-worktree.py" "$tmp/tree/scripts/lib/"
cp "$ROOT/tests/fixtures/lint-shellcheck.sh" "$tmp/bin/shellcheck"
chmod 755 "$tmp/bin/shellcheck"
export LINT_INVOCATIONS="$tmp/calls"
cd "$tmp/tree"
git init -q
for file in scripts/staged.sh scripts/unstaged.sh scripts/deleted.sh scripts/old.sh src/jailbox; do
    printf '#!/bin/bash\ntrue\n' > "$file"
done
# This intentionally broken, unchanged file must not enter a partial check.
printf '#!/bin/bash\necho $unquoted\n' > scripts/unchanged.sh
printf 'ignored.sh\n' > .gitignore
git add -- scripts src .gitignore
git -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm baseline
run_lint() { PATH="$tmp/bin:$PATH" bash scripts/lint.sh --worktree > "$tmp/output" 2>&1; }
run_lint
grep -Fq 'no changed shell files' "$tmp/output"
[[ ! -e "$LINT_INVOCATIONS" ]]
printf '# staged\n' >> scripts/staged.sh
git add scripts/staged.sh
printf '# unstaged\n' >> scripts/unstaged.sh
git mv scripts/old.sh 'scripts/new name.sh'
rm scripts/deleted.sh
printf '# changed entrypoint\n' >> src/jailbox
printf '#!/bin/bash\nvalue=unused\n' > src/host/new.sh
printf '#!/bin/sh\ntrue\n' > src/container/runtime/bin/portable
printf '#!/bin/bash\ntrue\n' > tests/untracked.sh
printf '#!/bin/bash\necho $unquoted\n' > ignored.sh
printf 'documentation\n' > README.md
run_lint
for file in scripts/staged.sh scripts/unstaged.sh 'scripts/new name.sh' src/jailbox \
    src/host/new.sh src/container/runtime/bin/portable tests/untracked.sh; do
    grep -Fq "$file" "$LINT_INVOCATIONS"
done
if grep -Eq 'unchanged|deleted|old.sh|ignored|README' "$LINT_INVOCATIONS"; then exit 1; fi
grep -Fq -- '--shell=sh -- src/container/runtime/bin/portable' "$LINT_INVOCATIONS"
grep -Fq -- '--exclude=SC2034,SC2329 -- src/host/new.sh' "$LINT_INVOCATIONS"
grep -Fq -- '--check-sourced --external-sources --shell=bash -- src/jailbox' "$LINT_INVOCATIONS"
[[ ! -e testlog/shellcheck-cache/success ]]
mkdir -p testlog/shellcheck-cache
printf 'unrelated-full-lint-success\n' > testlog/shellcheck-cache/success

# Real ShellCheck: current contents win over a failing staged version.
printf '#!/bin/bash\necho $unquoted\n' > scripts/staged.sh
git add scripts/staged.sh
printf '#!/bin/bash\ntrue\n' > scripts/staged.sh
bash scripts/lint.sh --worktree > "$tmp/output" 2>&1
[[ $(cat testlog/shellcheck-cache/success) = unrelated-full-lint-success ]]
printf '#!/bin/bash\nvalue="two words"\necho $value\n' > tests/untracked.sh
if bash scripts/lint.sh --worktree > "$tmp/output" 2>&1; then exit 1; fi
grep -Fq SC2086 "$tmp/output"
printf 'missing interpreter\n' > src/container/runtime/bin/portable
if run_lint; then exit 1; fi
grep -Fq 'unsupported shell shebang' "$tmp/output"
# Discovery failure must not become an empty successful check.
if (cd "$tmp/no-repo" && python3 "$tmp/tree/scripts/lib/lint-worktree.py") > "$tmp/output" 2>&1; then exit 1; fi
grep -Fq 'Worktree ShellCheck failed' "$tmp/output"
printf 'PASS: worktree selection, dialects, current contents and failure propagation\n'
