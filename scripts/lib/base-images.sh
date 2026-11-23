#!/bin/bash
# Shared rules for the base-image pins in versions.env. Sourced by
# scripts/canary-base-images.sh and scripts/bump-base-image.sh.

# Images with a BASE_IMAGE_<NAME> pin, in report order.
# shellcheck disable=SC2034 # Read by the sourcing scripts.
BASE_IMAGES=(alpine debian fedora)

# Print the version pattern for IMAGE. Pins are plain numbered releases, with
# Alpine's minor version, because versions.env is sourced as shell.
base_image_pattern() {
    case "$1" in
        alpine) printf '%s\n' '^[1-9][0-9]*[.](0|[1-9][0-9]*)$' ;;
        debian|fedora) printf '%s\n' '^[1-9][0-9]*$' ;;
        *) return 1 ;;
    esac
}
