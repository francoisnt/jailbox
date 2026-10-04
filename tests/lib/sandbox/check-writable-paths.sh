#!/bin/bash
# Controlled fixture mutations, separate from production attachment validation.
set -euo pipefail
cd /project
printf 'in-place\n' > single
[[ $(cat single) = in-place ]]
if touch outside 2>/dev/null; then exit 1; fi
if touch single.tmp 2>/dev/null; then exit 1; fi
printf replacement > lane/replacement
if mv lane/replacement single 2>/dev/null; then exit 1; fi
printf writable > lane/created
mv lane/created lane/renamed
rm lane/renamed
if touch lane/protected/denied 2>/dev/null; then exit 1; fi
if printf changed > lane/policy 2>/dev/null; then exit 1; fi
# Repository identity is fixture-local; no developer Git configuration is used.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
printf commit > lane/tracked
git -c safe.directory=/project -c user.name=Fixture -c user.email=fixture@example.invalid add lane/tracked
git -c safe.directory=/project -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture
git -c safe.directory=/project log -1 --format=%s | grep -qx fixture
if touch .git/hooks/denied 2>/dev/null; then exit 1; fi
if printf changed > .git/config 2>/dev/null; then exit 1; fi
