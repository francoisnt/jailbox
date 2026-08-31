# 2. Explicit stop before relaunch

## Goal

Replace implicit container replacement with a two-command lifecycle. Add
`jailbox stop`, require both project containers to be absent before launch, and
remove `--replace` from the `podman run` invocations so jailbox never destroys a
sandbox the user did not ask it to destroy.

## Sequence

Order 2.0; first of the five command-mode changes. It follows
`01.1-init-config-plan.md` because launch fixtures now need a selected config,
and because `stop` must preserve the config-independent lifecycle behavior that
plan establishes. `stop` does not join the required-config predicate: its early
dispatch bypasses configuration selection entirely. `03-launch-core-and-up-plan.md`
follows and depends on the absence requirement established here.

## Why this comes first

Today `podman run --replace` silently destroys and recreates the development
container. For a tool whose only entry point is bare launch that is merely
racy: a running sandbox holds the project mounted writable and can change
project paths while the host validates them and builds images.

Once `exec` and `shell` exist, the same behavior tears down a container with
live attached sessions, as a side effect of a command the user issued for
another purpose. Attached sessions are what make implicit replacement
unacceptable, so this boundary must be in place before any command can attach.

## Behavior

### `jailbox stop`

`stop` removes the ephemeral development and proxy container objects while
preserving the home volume, networks, images, and the project state directory.
It is idempotent and succeeds when both containers are absent.

Containers are ephemeral runtime objects. The next launch creates fresh ones,
and `setup_ssh_keys` rotates the key pair and sshd runtime directory on every
bring-up, so `stop` preserves the state directory itself but not the
credentials inside it. A container restart fast path is out of scope.

Before mutating anything, `stop` inspects every present target and requires each
`jailbox.project` label to equal canonical `$PROJECT_DIR`. A missing or
mismatched label fails without stopping or removing either container. `stop`
fails rather than skipping, because it is a precondition for launch and the user
must resolve the mismatch before relaunching.

`stop` never creates or loads configuration and never validates project paths.

### Launch requires both names absent

Bare launch inspects `$CONTAINER_NAME` and `$PROXY_NAME` before path
validation or image work, and fails without mutating anything:

- a container whose `jailbox.project` label matches canonical `$PROJECT_DIR` is
  an owned leftover; name `jailbox stop`;
- an unlabeled or mismatched container is a name collision with something
  jailbox does not own; report it and tell the user to inspect and remove it
  with Podman directly. Do not name `stop`, which will correctly refuse it.

Relaunch is therefore a two-command operation. A failed build after
`jailbox stop` leaves no sandbox running; keeping a writable fallback alive
during the build would reintroduce the replacement this boundary removes.

Do not add a flag that relaunches over a running sandbox. The two-command flow
is the boundary this change exists to establish, and an opt-out would reintroduce
the hazard for the most common operation.

### Concurrency

Remove `--replace` from the development- and proxy-container `podman run`
commands. Concurrent launches can no longer silently replace each other's
containers, but they remain unsafe overall: both may mutate shared SSH, network,
and other lifecycle state before one loses the container-name race. Concurrent
lifecycle commands remain unsupported; locking them is separate work tracked in
`backlog.md`.

## Implementation

- Add `require_sandbox_absent` and `stop_jailbox` to
  `host/container-runtime.sh`. `require_sandbox_absent` is a read-only check
  used by top-level launch dispatch before required-config selection or loading,
  path validation, or image work; it
  distinguishes an owned leftover, which names `jailbox stop`, from an unlabeled
  or mismatched collision, which names manual Podman inspection and removal.
  `stop_jailbox` validates the ownership label of every present target, then
  stops and removes both containers without deleting persistent resources.
- Move `initialize_project_names` out of `initialize_launch_state` and call it
  once after argument parsing, before command-specific dispatch. Project and
  resource identity depends only on canonical `$PROJECT_DIR`, not on loaded
  configuration. The remaining module initializers stay in
  `initialize_launch_state` after configuration loading.
- Dispatch `--uninstall` immediately after argument parsing, ahead of
  project-name initialization and configuration selection. It execs the
  installer copy shipped inside the install and needs neither derived resource
  names nor parsed configuration. Moving it ahead of both preserves the intent
  its current placement already states — that uninstalling must not require the
  tooling a launch requires — and extends it: the command that removes a broken
  install must not be blocked by a malformed `jailbox.conf` either.
- Guard `podman` where `require_sandbox_absent` first uses it. Call
  `require_command podman` immediately before it in `main`, because it now runs
  ahead of the post-config `host_preflight "$@"` that checks it today.
  `host_preflight` keeps its own check; `require_command` is idempotent and the
  duplication is deliberate, so no command loses a guarantee if dispatch is
  reordered again.
- Do not guard `initialize_project_names` with `require_command cksum`.
  `jailbox_project_hash_for_path` (`host/project-id.sh`) tries `sha256sum`, then
  `shasum`, and reaches `cksum` only as a last fallback, so requiring `cksum`
  specifically would reject a host that hashes correctly. Any guard added here
  must accept any of the three; on supported platforms at least one is always
  present, so it would never fire in practice.
- Add `stop` to `CLI_FLAGS_WITHOUT_VALUES` and `CLI_HELP` in
  `host/public-api.sh`, and update parsing, dispatch, and generated public-API
  expectations. The `Options:` block in `usage` (`host/common.sh`) is generated
  from those arrays, but the literal `Usage:` synopsis above it must be edited by
  hand to list `stop`.
- In `host_preflight` (`host/preflight.sh`), add `stop` to the existing
  Podman-only early-return branch used by `--clean`, before SSH, `realpath`, and
  editor checks.
- Move `require_command cksum` from the top of `host_preflight` to after every
  early return, so it guards only the commands that reach the wrapper image
  build. `cksum` is there for `jailbox_install_cache_bust`
  (`host/dev-image.sh`), which pipes through it twice with no fallback; it is not
  a requirement of `doctor`, `ssh-config`, `stop`, or `--clean`, none of which
  build an image. This makes the contract exactly "`stop` requires Podman only"
  rather than leaving an unrelated tool check in front of it.
- Add a scoped early branch in `main` for `stop`: after argument parsing and
  project-name initialization, call `host_preflight stop`, dispatch
  `stop_jailbox`, and return before `prepare_config_selection` or
  `load_project_config`. Leave the existing post-config `host_preflight "$@"`
  call in place for every other command; do not move it globally ahead of config
  loading, because bare launch needs parsed `EDITOR` before editor preflight.
  Ignore a supplied `--config PATH` for `stop`: stopping project-scoped ephemeral
  containers does not depend on configuration, and malformed or missing policy
  must not block restoration of the launch precondition.
- Remove `--replace` from `start_jailbox_container`
  (`host/container-runtime.sh`) and from the proxy `podman run` in
  `configure_proxy_network` (`host/network.sh`). Remove the now-unreachable
  "Replacing existing jailbox container" and "Replacing existing proxy
  container" branches.
- Remove the container-exists exception from `check_local_port_available`
  (`host/preflight.sh`). No valid launch-time container can hold the port, so the
  exception only suppresses a clear conflict message for an unrelated listener.

Review the generated diff from `scripts/public-api-diff.sh`: adding one command
is a minor bump pre-1.0.

## Documentation

Document the explicit `jailbox stop` prerequisite for relaunch, that it removes
only ephemeral containers, the persistent resources it preserves, and that a
failed subsequent launch leaves no sandbox running.

Document that unowned name collisions require manual Podman resolution, that no
flag relaunches over a running sandbox, and that concurrent lifecycle commands
remain unsupported because they can corrupt shared state even though they no
longer silently replace containers.

Update the README command reference and lifecycle section with the distinction
between `stop` and `--clean`.

## Tests

- `stop` removes owned development and proxy container objects, leaves networks,
  images, the home volume, and SSH state in place, and creates no config.
- `stop` verifies every present target before mutation, refuses a missing or
  mismatched ownership label without partially removing resources, and succeeds
  when both targets are absent.
- Repeated `stop` succeeds; `stop` succeeds when only the proxy exists.
- `stop` succeeds with a missing, unreadable, or malformed config, including when
  `--config PATH` names a missing file, because it does not select or load
  configuration.
- `stop` requires Podman only — not `cksum`, SSH, `ssh-keygen`, `realpath`, or an
  editor.
- With Podman absent, bare launch reports `required command not found: podman`
  rather than probing container names first.
- On a host with `sha256sum` but no `cksum`, `stop`, `doctor`, `ssh-config`,
  `--clean`, and `--uninstall` all succeed; bare launch still fails with
  `required command not found: cksum` before building the wrapper image.
- `--uninstall` succeeds without Podman, without a hash tool, and with a
  malformed, unreadable, or missing `jailbox.conf`, and initializes no derived
  resource names.
- Launch reports `jailbox stop` for an owned development or proxy container, and
  reports an unlabeled or mismatched name collision with manual Podman
  inspection/removal guidance; neither case mutates the existing container.
- Development and proxy runs do not use `--replace`, and their dead replacement
  notices are removed.
- A foreign listener holding the derived port produces the clear port-conflict
  error before image work.
- A failed development-image build after `stop` leaves no sandbox running.
- `stop` appears in the literal `Usage:` synopsis, in the generated `Options:`
  block, and as an addition in the generated public-API diff.

Run `tests/run portable`, and `tests/run runtime` where Podman is available
because this changes container lifecycle.

## Non-goals

- Any new launch or attach command; `03-launch-core-and-up-plan.md` owns `up`.
- Lifecycle locking for concurrent commands.
- Ownership-aware `--clean` teardown.
- A `podman start` fast path for a stopped sandbox.
