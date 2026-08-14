# Recommendation: verify SELinux project mount labels

## Concern

`host/container-runtime.sh` mounts the project and its read-only overlays with
`:Z`. On an SELinux-enforcing host, `:Z` gives host files a private,
container-specific MCS label. Because the project is the user's real working
tree, that persistent relabel can interfere with host tools or another
container. Overlay files beneath the project are also relabeled a second time.

This needs verification on an SELinux-enforcing host; `:Z` is effectively a
no-op on common non-SELinux hosts, so the failure mode is easy to miss.

## Recommendation

Verify whether shared `:z` labels provide the required container access without
the private-label footgun. If changed, retain the existing write-denial checks
and add a regression assertion that the container can read the project and its
read-only overlays.
