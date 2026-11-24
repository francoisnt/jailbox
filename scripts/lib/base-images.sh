#!/bin/bash
# Look up stable base-image series in Docker Official Images. Sourced by
# scripts/resolve-updates.sh. Version formats come from
# scripts/lib/dependency_updates.py.

# Images with a BASE_IMAGE_<NAME> pin.
# shellcheck disable=SC2034 # Read by the sourcing scripts.
BASE_IMAGES=(debian alpine fedora)

# Print the numbered stable version of IMAGE, in the precision of its pin.
stable_image_version() {
    local image=$1 pattern lib
    lib=$(dirname "${BASH_SOURCE[0]}")
    pattern=$(python3 "$lib/dependency_updates.py" image-pattern "$image") || return 1
    # Fedora publishes a numbered Rawhide tag. Read only the tag list that
    # also contains latest.
    curl -fsSL --retry 3 --retry-all-errors --retry-max-time 45 --connect-timeout 10 --max-time 60 \
        "https://raw.githubusercontent.com/docker-library/official-images/master/library/$image" |
        awk -v pattern="$pattern" '
            /^Tags: / {
                count = split(substr($0, 7), tags, /, */)
                for (i = 1; i <= count; i++) {
                    if (tags[i] != "latest") continue
                    for (j = 1; j <= count; j++) {
                        if (tags[j] !~ pattern) continue
                        candidate = tags[j]
                        matches++
                    }
                }
            }
            END {
                if (matches != 1) exit 1
                print candidate
            }
        '
}
