# Host state ownership

Status: completed and archived.

Host state is declared by the module that owns its lifecycle rather than by
the `jailbox` entrypoint:

- `host/common.sh` owns shared project identity, resource names, constants,
  the project state root, UID, and port.
- `host/dev-image.sh` owns selected image, shell, and package-manager state.
- `host/preflight.sh` owns editor selection.
- `host/ssh.sh` owns SSH paths and runtime state.
- `host/editor.sh` owns editor profile paths.
- `host/network.sh` owns selected network and proxy state.
- `host/container-runtime.sh` owns mount arrays and root-filesystem flags.

`initialize_launch_state` keeps initialization order visible in `jailbox`.
Module initializers clear stale output, and security-sensitive consumers reject
missing required state before invoking Podman or writing configuration.

Cross-module reads are intentional where one phase consumes another phase's
output. Keep those dependencies narrow and visible; do not introduce a generic
repository-wide state object or accessor functions that merely hide a global
read.

When changing a state boundary, add the lowest-layer test for initialization,
reset behavior, or missing prerequisites. Run `tests/run portable`, plus the
runtime gate for image, network, mount, SSH, container, or lifecycle changes
when Podman is available. Run the editor gate for editor integration changes.
