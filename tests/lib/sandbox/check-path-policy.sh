#!/bin/bash
# Independent kernel assertions; only mutates disposable runtime fixtures.
set -euo pipefail
cd /project
for path in . lane/protected lane/protected/generated/restricted; do
    if touch "$path/denied" 2>/dev/null; then exit 1; fi
done
for path in lane lane/protected/generated lane/protected/generated/restricted/output; do
    printf writable > "$path/created"
    mv "$path/created" "$path/renamed"
    rm "$path/renamed"
done
if printf changed >> lane/protected/generated/Containerfile 2>/dev/null; then exit 1; fi
if rm lane/protected/generated/Containerfile 2>/dev/null; then exit 1; fi
# A link inside RO policy can reach a writable destination, and vice versa.
printf writable > lane/protected/link/through-link
[[ $(cat lane/protected/generated/through-link) = writable ]]
if touch lane/protected/generated/readonly-link/denied 2>/dev/null; then exit 1; fi
hidden=lane/protected/generated/restricted/output/hidden
[[ -z $(ls -A "$hidden") ]]
if cat "$hidden/data" 2>/dev/null; then exit 1; fi
if cat lane/protected/generated/hidden-link/data 2>/dev/null; then exit 1; fi
if touch "$hidden/changed" 2>/dev/null; then exit 1; fi
if rmdir "$hidden" 2>/dev/null; then exit 1; fi
if mv "$hidden" "${hidden}-moved" 2>/dev/null; then exit 1; fi
