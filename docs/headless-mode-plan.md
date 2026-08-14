# Headless operation — explicit start, exec, and stop

## Goal

Let a jailbox sandbox run without a GUI editor and expose a small command API for
terminal and automation use. The mode is selected by an explicit command, not a
`HEADLESS` config key and not by whether stdio happens to be a TTY.

Bare `jailbox` remains backward compatible: it launches the sandbox and opens
the configured editor exactly as today.

## Commands

```text
jailbox [--config PATH] start
jailbox [--config PATH] exec [-t] [--] [CMD...]
jailbox [--config PATH] stop
jailbox [--config PATH] --clean
```

| Command | Behavior |
|---|---|
| `start` | Ensure the sandbox is running without opening an editor, print connection information, and return. |
| `exec [-t] [--] CMD...` | Ensure the sandbox is running, run one command as the managed user in `$REMOTE_PATH`, stream stdio, and propagate its exit status. |
| `exec` with no command | Open an interactive login shell in `$REMOTE_PATH`; requires a local TTY. |
| `stop` | Stop the development container and proxy while preserving the home volume, networks, and SSH state. |
| `--clean` | Full teardown as today: remove containers, networks, home volume, and SSH state. |

`start`, `stop`, and repeated `exec` calls are idempotent. `stop` succeeds when
the relevant containers are already stopped or absent.

## Bring-up and safe reuse

Extract the editor-independent launch work into `bring_up_sandbox`. Both the
editor launch and headless commands use this core.

`start` and `exec` may reuse an existing sandbox only when:

- the container is running;
- SSH answers;
- its effective-config fingerprint matches the requested configuration; and
- the expected proxy state also matches when egress filtering is enabled.

Otherwise the normal bring-up path replaces it. Liveness alone is not enough:
a changed write or egress policy must never reuse stale, broader permissions.
The fingerprint must cover every effective setting that affects the container,
mounts, networking, SSH environment, editor integration, image/build inputs,
and jailbox implementation version. Store only its digest, never secrets or raw
config contents, on the container and proxy.

## `exec` transport

Use the generated SSH config and strict host-key state already used by the
editor:

```sh
ssh -F "$SSH_CONFIG" -T -- "$CONTAINER_NAME" <remote-command>
```

SSH options must precede the destination. With `-t`, use `-tt` before the host.
If `-t` or commandless `exec` is requested without a local TTY, fail clearly.

### Argument fidelity

Do not interpolate caller arguments into a remote shell command. Encode the
argv as a NUL-delimited payload, transport it through a portable ASCII framing,
and decode it with the installed remote Bash before `exec`-ing the resulting
array. Unix argv cannot contain NUL; every other byte accepted by the host shell
must round-trip without reinterpretation.

The implementation must:

- use no host-side Bash feature newer than macOS Bash 3.2;
- verify the remote decoder commands it relies upon during image validation;
- run array decoding under Bash explicitly rather than assuming SSH selected
  Bash;
- preserve empty arguments and arguments containing whitespace, quotes,
  globbing characters, and newlines;
- forward stdin in non-TTY mode; and
- return the remote command's exit status.

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

## Connection output

`start` prints stable shell-oriented fields:

```text
JAILBOX_STATUS=ready
JAILBOX_HOST_ALIAS=<CONTAINER_NAME>
JAILBOX_SSH_CONFIG=<SSH_CONFIG>
JAILBOX_PORT=<LOCAL_PORT>
JAILBOX_REMOTE_PATH=<REMOTE_PATH>
```

Values must be safely shell-quoted if they can contain special characters. The
human status text may be printed separately to stderr so stdout remains usable
by automation.

## Implementation outline

```sh
bring_up_sandbox() {
    initialize_runtime_ids
    check_local_port_available
    build_or_select_dev_image
    validate_dev_image
    build_jailbox_image
    configure_runtime_mounts
    configure_network
    setup_ssh_keys
    ensure_readonly_stubs
    build_writable_mounts
    build_readonly_mounts
    ensure_home_volume
    start_jailbox_container
    pin_ssh_host_key
    wait_for_ssh
    configure_downloader_proxy
    post_start_validation
}
```

- Bare launch: call the core, then `open_editor`.
- `start`: safely reuse or call the core, then print connection fields.
- `exec`: safely reuse or call the core, then invoke SSH.
- `stop`: stop the development container and proxy without deleting persistent
  state.

Preflight is command-aware:

- bare editor launch requires Podman, SSH tooling, and an editor;
- `start` and `exec` require Podman and SSH tooling but no editor;
- `stop` requires Podman only;
- `doctor` and `ssh-config` keep their existing lighter requirements.

Add `start`, `exec`, and `stop` to the public command list. Do not add a
`HEADLESS` configuration key.

## Tests

- Bare `jailbox` retains current editor behavior.
- `start` works with no code/codium executable, returns promptly, opens no
  editor, and prints the connection fields.
- `exec -- sh -c 'echo hi'` prints `hi`; a remote exit of 7 returns 7.
- Arguments including empty strings, whitespace, quotes, glob characters, and
  newlines round-trip exactly.
- `printf data | jailbox exec -- cat` returns `data`.
- `exec -t` and commandless `exec` require a local TTY.
- `exec` starts an absent sandbox; `stop` then `exec` starts it again.
- Repeated `stop` succeeds.
- A mismatched effective-config fingerprint forces replacement before command
  execution.
- Ctrl-C and SSH disconnect behavior are covered by system tests.

## Non-goals

- No `HEADLESS` config toggle or TTY-dependent meaning for bare `jailbox`.
- No profiles or multiple sandbox identities for one checkout.
- No task specification, timeout, loop, scheduling, or result collection.
- No claim that closing SSH always kills an unconfirmed remote process.
