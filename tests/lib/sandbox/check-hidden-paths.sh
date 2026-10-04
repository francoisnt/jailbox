#!/bin/bash
# Destructive probes are confined to disposable runtime fixtures.
set -euo pipefail
shape=$1
parent_policy=$2
cd /project
selected=lane/Containerfile
mask=$selected
if [[ "$shape" = ancestor ]]; then
    selected=lane/hidden/Containerfile
    mask=lane/hidden
    # The empty directory must expose neither ordinary nor dotfile contents.
    [[ -z $(ls -A -- "$mask") ]]
    if cat "$selected" 2>/dev/null; then exit 1; fi
    if printf changed > "$selected" 2>/dev/null; then exit 1; fi
    if touch "$mask/new" 2>/dev/null; then exit 1; fi
else
    # Reads/writes to a null-device substitute may succeed. They must never
    # reveal or change the original data (host assertions verify the latter).
    [[ -z $(cat "$selected" 2>/dev/null || true) ]]
    printf changed > "$selected" 2>/dev/null || true
fi
if rm -f -- "$selected" 2>/dev/null; then
    # Beneath an ancestor mask the file is absent, so rm -f may be a no-op.
    [[ "$shape" = ancestor ]] || exit 1
fi
if [[ "$shape" = ancestor ]] && rmdir -- "$mask" 2>/dev/null; then exit 1; fi
if mv -- "$mask" "$mask.moved" 2>/dev/null; then exit 1; fi
if [[ "$parent_policy" = writable ]]; then
    printf first > lane/sibling
    printf replacement > lane/replacement
    mv -f lane/replacement lane/sibling
    [[ $(cat lane/sibling) = replacement ]]
    rm lane/sibling
    # Sibling operations prove failure below isn't caused by a read-only parent.
    if [[ "$shape" = ancestor ]]; then
        mkdir lane/replacement-dir
        if mv -T lane/replacement-dir "$mask" 2>/dev/null; then exit 1; fi
        rmdir lane/replacement-dir
    else
        printf replacement > lane/replacement
        if mv -f lane/replacement "$mask" 2>/dev/null; then exit 1; fi
        rm lane/replacement
    fi
else
    if touch lane/sibling 2>/dev/null; then exit 1; fi
    if [[ "$shape" = ancestor ]]; then
        mkdir replacement-dir
        if mv -T replacement-dir "$mask" 2>/dev/null; then exit 1; fi
        rmdir replacement-dir
    else
        printf replacement > replacement
        if mv -f replacement "$mask" 2>/dev/null; then exit 1; fi
        rm replacement
    fi
fi
# Masking is pathname-scoped: aliases outside it retain their original bytes.
cmp /project/hardlink /project/copy
grep -q '^FROM ' /project/hardlink
