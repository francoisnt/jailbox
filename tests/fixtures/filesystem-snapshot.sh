#!/bin/bash
set -euo pipefail
for root in "$@"; do
    [[ -e "$root" ]] || continue
    (
        cd "$root" || exit 1
        find . -printf "%P|%y|%U|%G|%m|%i|%s|%T@|%l\n" | LC_ALL=C sort || exit 1
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum || exit 1
    ) || exit 1
done
