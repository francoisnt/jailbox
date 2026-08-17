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

Do not change `:Z` to `:z` based only on inspection. `:Z` provides useful
container-to-container isolation, while `:z` still relabels host files and makes
them shareable with other containers. Verify the current behavior on a real
SELinux-enforcing host and choose deliberately from the observed results.

## Is a relabel suffix required?

Podman does not require `:Z` or `:z` syntactically. Without either suffix it
preserves the source's existing host label. On an enforcing host, a normal
project under a user's home directory is commonly not labeled for access by a
confined container, so the mount may be present but reads and writes are denied
by SELinux.

No suffix can work when SELinux is disabled or permissive, when an administrator
has already assigned a compatible container label or custom policy, or when the
container uses `--security-opt label=disable`. The first two do not validate the
enforcing-host contract, pre-labeling is not a reasonable default prerequisite,
and disabling label separation would weaken jailbox's container isolation.

The likely minimal policy is therefore:

```text
independent project root:       :Z
nested protected-path overlay:  ro, with no additional relabel suffix
independent SSH/state mounts:    :Z
```

The project-root `:Z` recursively establishes a private label compatible with
the jailbox container. A nested source such as `.env` or
`.github/workflows` already lies beneath that relabeled root, so its overlay may
only need `ro`; omitting a nested `:Z` preserves the label established by the
parent mount. This must be proven on Fedora before changing the emitted mount
options.

Do not use `--security-opt label=disable` as the general solution. It avoids
host relabeling by disabling SELinux separation for the whole container, which
is a broader security-model change than adjusting bind-mount labels.

## Manual Fedora VM test

Run the verification in a disposable local Fedora VM. Do not use a Fedora
container on an Ubuntu host: containers share the host kernel and cannot supply
SELinux enforcement when the host did not enable it at boot.

Use a fresh VM snapshot because the test intentionally relabels a checkout.
Install rootless Podman and the normal runtime-test prerequisites, clone the
repository inside the VM, and confirm the environment before testing:

```sh
test "$(getenforce)" = Enforcing
sestatus
uname -a
cat /etc/os-release
podman version
podman info
```

If `getenforce` is not exactly `Enforcing`, stop. A permissive or disabled host
cannot validate the security behavior.

### Evidence to capture

Record the following in the test log:

- Fedora, kernel, Podman, SELinux policy, and container-selinux versions;
- the project directory's label before launch;
- the project root and representative protected-path labels after launch;
- the development container's process label and MCS category;
- labels after container replacement and `--clean`, plus `stop` once that
  command exists; and
- relevant AVC denials from the audit log.

Use `ls -Zd`, `ps -eZ`, `podman inspect`, and, when available,
`ausearch -m AVC` to collect evidence. Never run `restorecon -R` outside the
disposable test checkout.

### Behavioral assertions

The manual test must prove all of these properties:

1. The jailbox container can read ordinary project files.
2. Writes to an ordinary writable project path succeed.
3. Writes to built-in and configured protected overlays fail.
4. The project and its protected overlays receive labels compatible with the
   jailbox container's MCS category.
5. An unrelated rootless container running as the same host user cannot read
   the `:Z`-labeled project through a mount that does not relabel it.
6. Replacing the jailbox container relabels safely and the replacement retains
   the intended read and write behavior.
7. Two different jailbox projects receive independent private labels and both
   remain usable at the same time.
8. Nested `:Z` protected-path overlays do not acquire a conflicting category or
   make the parent project unreadable.
9. Host-side access after launch and cleanup matches the documented behavior.
10. `--clean`, and `stop` once implemented, do not claim to restore labels if
    labels actually remain on disk.

Run `tests/run runtime` in the VM as the baseline, then execute the focused
checks above against a disposable project created specifically for the test.
The result is not valid if only selected unit or wrapper-image tests ran.

Repeat the protected-overlay assertions with the project root mounted using
`:Z` and nested overlays using only `ro`. Confirm that the nested paths retain a
category compatible with the container, remain readable, deny writes, and do
not trigger unexpected AVC denials. Also confirm that an independent state path
without any compatible label is denied, demonstrating that the test is
actually exercising SELinux rather than merely observing successful mounts.

### Decision criteria

Keep private `:Z` on independent project and state roots if the assertions pass
and ordinary host-side use is not disrupted. Remove redundant nested relabel
options if testing proves the parent label is sufficient and read-only
enforcement remains intact.

Consider shared `:z` labels only if jailbox intentionally supports concurrent
containers mounting the same checkout and that requirement outweighs the loss
of private container isolation. If neither relabel mode gives acceptable host
behavior, investigate a project copy or another mount design rather than
silently weakening the label policy.

## Future automation

The focused SELinux checks may later become a script invoked manually from the
existing runtime gate. It must skip clearly unless `getenforce` reports
`Enforcing`; a skip on Ubuntu is not a pass. Do not add a fourth user-facing
test gate. Continuous enforcement requires a genuine Fedora/RHEL host or VM,
not SELinux userspace packages installed on a GitHub-hosted Ubuntu runner.
