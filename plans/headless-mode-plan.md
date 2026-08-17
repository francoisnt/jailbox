# Headless operation — explicit exec, shell, and stop

## Goal

Let a jailbox sandbox run without a GUI editor and expose a small command API for
terminal and automation use. The mode is selected by an explicit command, not a
`HEADLESS` config key and not by whether stdio happens to be a TTY.

Bare `jailbox` remains backward compatible: it launches the sandbox and opens
the configured editor exactly as today. `exec`, `shell`, and `stop` never launch
or require an editor.

## Commands

```text
jailbox [--config PATH] exec [--] CMD [ARG...]
jailbox [--config PATH] shell
jailbox [--config PATH] stop
jailbox [--config PATH] --clean
```

| Command | Behavior |
|---|---|
| `exec [--] CMD [ARG...]` | Ensure the sandbox is running, run one non-interactive command as the managed user in `$REMOTE_PATH`, stream stdin/stdout/stderr, and propagate its exit status. A command is required; a leading `--` is optional. |
| `shell` | Ensure the sandbox is running and open an interactive login Bash in `$REMOTE_PATH`; requires local TTYs. |
| `stop` | Stop the development container and proxy while preserving the home volume, networks, and SSH state. |
| `--clean` | Full teardown as today: remove containers, networks, home volume, and SSH state. |

`stop` is idempotent. Repeated `exec` calls reuse the same valid sandbox, but the
command executed by `exec` is not itself assumed to be idempotent. `stop`
succeeds when the relevant containers are already stopped or absent.

## Bring-up and safe reuse

Extract the editor-independent replacement/launch work into `bring_up_sandbox`.
Both the editor launch and headless commands use this core through a separate
`ensure_sandbox_running` decision layer:

1. Initialize the desired project and runtime state needed to calculate and
   inspect identity.
2. Inspect any existing development container and proxy.
3. Reuse them only if all reuse checks pass.
4. Otherwise perform the normal replacement path through `bring_up_sandbox`.

Bare editor launch continues to replace the sandbox as it does today unless
reuse for that path is deliberately added and tested as a separate change.

`exec` and `shell` may reuse an existing sandbox only when:

- the container is running;
- SSH answers;
- its runtime fingerprint matches the requested configuration; and
- the proxy is running with the same fingerprint when egress filtering is
  enabled.

Otherwise the normal bring-up path replaces it. Missing reuse metadata is a
safe mismatch so containers created by older jailbox versions are replaced.
Liveness alone is not enough: a changed write or egress policy must never reuse
stale, broader permissions.

Build one canonical runtime specification covering the effective container,
mount, network, SSH environment, image, resource-limit, and relevant jailbox
implementation inputs, then hash it. Local editor selection and editor-only
integration are excluded because they do not alter the sandbox. Use stable
image IDs after image selection or building, and include a deterministic
identity for relevant runtime files when running from a source checkout.

Store only this digest, never raw configuration contents or secrets, as a
project-scoped label on the development container and proxy. Reuse is
conservative: if a required resource, label, network attachment, or SSH check
is missing or mismatched, replace the sandbox instead of trying to repair stale
state. When egress filtering is disabled, no obsolete proxy may remain an
active route for the reused sandbox.

## `exec` transport

Use the generated SSH config and strict host-key state already used by the
editor:

```sh
ssh -F "$SSH_CONFIG" -T -- "$CONTAINER_NAME" <remote-command>
```

SSH options must precede the destination. `exec` always uses `-T` and is
non-interactive. `shell` requires both stdin and stdout to be local TTYs;
otherwise fail clearly before starting or reusing a sandbox. It uses `-tt`,
changes to `$REMOTE_PATH`, and opens an interactive login Bash explicitly.

### Argument fidelity

Do not interpolate caller arguments into a remote shell command. Encode argv as
a NUL-delimited payload and convert it to a single-line Base64 frame. Pass that
validated frame as one argument to a fixed remote decoder command; Base64's
restricted alphabet makes this safe without evaluating caller data. The remote
decoder decodes it into a Bash array, changes to `$REMOTE_PATH`, and `exec`s the
array. Stdin remains exclusively attached to the remote command so pipelines
work without a framing collision. Unix argv cannot contain NUL; every other
byte accepted by the host shell must round-trip without reinterpretation.

The implementation must:

- run in the repository's supported host Bash 4.4 or newer; only the entrypoint
  before its version guard and `install.sh` retain macOS Bash 3.2 constraints;
- use Base64 commands available on supported hosts and verify the host encoder
  and remote decoder during preflight/image validation;
- run array decoding under Bash explicitly rather than assuming SSH selected
  Bash;
- reject malformed frames and an empty decoded argv;
- preserve empty arguments and arguments containing whitespace, quotes,
  globbing characters, and newlines;
- forward stdin in non-TTY mode; and
- return the remote command's exit status.

The transport must preserve the SSH exit status, and encoding failures must not
accidentally be reported as successful command execution.

For login/profile PATH semantics, callers may explicitly run
`jailbox exec -- bash -lc '...'`. Ordinary command execution has no implicit
login-shell wrapper.

Signal and disconnect behavior must be tested. Ctrl-C should reach an attached
remote command. If the SSH transport dies, jailbox returns its failure status;
it does not claim the remote process was terminated unless that is confirmed.

## Working directory and environment

Commands start in `$REMOTE_PATH` under the sshd-created session environment.
That includes the proxy variables rendered through the generated SSH host block
when egress filtering is enabled.

## Implementation outline

```sh
bring_up_sandbox() {
    check_local_port_available
    build_or_select_dev_image
    validate_dev_image
    build_jailbox_image
    configure_runtime_mounts
    configure_network
    setup_ssh_keys
    ensure_readonly_stubs
    build_readonly_mounts
    ensure_home_volume
    start_jailbox_container
    pin_ssh_host_key
    wait_for_ssh
    configure_downloader_proxy
    post_start_validation
}
```

- Bare launch: initialize editor state, call the replacement core, run the
  editor-specific `warn_if_alpine_dev_image_with_vscode` check, then
  `open_editor`.
- `exec`: require a command, consume an optional leading `--`, call
  `ensure_sandbox_running`, then invoke non-interactive SSH. Do not discover,
  configure, or launch an editor.
- `shell`: validate its TTY requirements, call `ensure_sandbox_running`, then
  open the login shell over SSH. Do not discover, configure, or launch an
  editor.
- `stop`: stop only the project-scoped development container and proxy without
  deleting either container, the home volume, networks, or SSH state. Verify
  resource ownership labels before acting, and tolerate absent or already
  stopped resources.
- `--clean`: retain the existing full teardown behavior.

Preflight is command-aware:

- bare editor launch requires Podman, SSH tooling, and an editor;
- `exec` and `shell` require Podman and SSH tooling but no editor;
- `stop` requires Podman only;
- `doctor` and `ssh-config` keep their existing lighter requirements.

The host Base64 encoder required by `exec` is checked only for `exec`. The
remote decoder is part of development-image validation. `exec` and `shell` must
not discover or require an installed editor, initialize editor-only state, write
editor settings, run editor-specific compatibility warnings, or call
`open_editor`.

Add `exec`, `shell`, and `stop` to the public command list. Do not add a
`HEADLESS` configuration key. Extend argument parsing deliberately: `exec`
requires a command, consumes an optional initial `--`, and treats all remaining
arguments as the remote argv. Other commands continue rejecting trailing
arguments. Update README usage and the documented lifecycle/security behavior,
including the distinction between `stop` and `--clean` and the limits of SSH
disconnect semantics.

## Tests

- Bare `jailbox` retains current editor behavior.
- `exec` and `shell` work with no code/codium executable and never open or
  configure an editor.
- `exec -- sh -c 'echo hi'` prints `hi`; a remote exit of 7 returns 7.
- Argumentless `exec` fails with usage; `shell` opens a login Bash in the remote
  project directory.
- Arguments including empty strings, whitespace, quotes, glob characters, and
  newlines round-trip exactly.
- `printf data | jailbox exec -- cat` returns `data`.
- Binary stdin, including bytes that resemble framing and embedded newlines,
  reaches the command unchanged.
- Malformed or truncated argv frames fail without evaluating payload contents.
- `exec` never allocates a TTY; `shell` requires local TTYs on stdin and stdout.
- `exec` starts an absent sandbox; `stop` then `exec` starts it again.
- Repeated `stop` succeeds.
- A mismatched effective-config fingerprint forces replacement before command
  execution.
- Missing legacy fingerprint metadata forces replacement.
- Changing editor selection alone does not replace a reusable sandbox.
- A missing, stopped, incorrectly networked, or mismatched proxy cannot be
  reused; disabling egress filtering cannot retain an active stale proxy route.
- Ctrl-C and SSH disconnect behavior are covered by system tests.

Add focused unit coverage for command parsing, argv framing/decoding,
fingerprint/reuse decisions, and stop idempotence. Put real SSH, stdin, signal,
proxy, and replacement assertions in the existing runtime/headless system
tests. Bare editor behavior remains covered by the editor gate. Run
`tests/run portable` for the implementation, plus `tests/run runtime` when
Podman is available and `tests/run editor` for any editor-integration changes.

## Non-goals

- No `HEADLESS` config toggle or TTY-dependent meaning for bare `jailbox`.
- No profiles or multiple sandbox identities for one checkout.
- No task specification, timeout, loop, scheduling, or result collection.
- No claim that closing SSH always kills an unconfirmed remote process.
