# 5. `jailbox exec` — run one command in the running sandbox

## Goal

Attach to the project's running sandbox, run one non-interactive command as the
managed user in `$REMOTE_PATH`, stream stdin/stdout/stderr, and propagate its
exit status. This is the primary automation entry point.

## Sequence

Order 5.0; fourth of the five command-mode changes. Requires
`03-launch-core-and-up-plan.md` for a sandbox to attach to and
`04-config-digest-plan.md` for the label it compares.
`06-shell-command-plan.md` follows and reuses the attach machinery defined here.

## Commands

```text
jailbox [--config PATH] exec [--] CMD [ARG...]
```

| Command | Behavior |
|---|---|
| `exec [--] CMD [ARG...]` | Attach to the project's running sandbox, run one non-interactive command as the managed user in `$REMOTE_PATH`, stream stdin/stdout/stderr, and propagate its exit status. A command is required; a leading `--` is optional. |

`exec` never creates, replaces, or repairs a sandbox. Repeated `exec` calls
attach to the same sandbox, but the command executed is not itself assumed to be
idempotent.

## Sandbox handling

`exec` decides what to do from the sandbox's live state, and the only two
outcomes are attach and fail:

- **Container running, its `jailbox.project` ownership label equals canonical
  `$PROJECT_DIR`, SSH answers, and its recorded configuration matches the
  current one** — attach to it as-is. It was created by an explicit `up` or bare
  launch, and that launch defined its policy.
- **Absent, stopped, unresponsive, or configured differently** — fail with an
  actionable message naming `jailbox up` to launch or relaunch and
  `jailbox --clean` to start over.
- **Present but not owned by this project** — fail as a foreign name collision
  with manual Podman inspection guidance.

A missing or mismatched ownership label is a foreign name collision, not a
stale jailbox. Refuse it before reading the digest or opening SSH, and direct the
user to inspect the container with Podman; do not suggest `jailbox --clean`,
which must not be used as permission to remove an unowned object. When egress
filtering requires the proxy, require its ownership label to match as well as
requiring it to be running. These checks prevent a container that merely
occupies jailbox's deterministic name from being treated as this project's
sandbox.

Because `exec` never mutates anything, it needs no locking, no double-checked
state, and no decision about whether a sandbox is close enough to reuse. Two
`exec` calls racing each other is uninteresting. jailbox never has to judge
whether a running sandbox still matches the configuration well enough to repair;
staleness is surfaced and the user resolves it. That matches how the tool already
behaves — an editor session likewise keeps running until the user relaunches.

### Digest enforcement

Compare the `jailbox.config-digest` label recorded by `04-config-digest-plan.md`
before attaching, and refuse to run on mismatch, naming what is stale — mount and
egress policy — and telling the user to run `jailbox up` to apply it. A missing
label is a mismatch, so containers created by older jailbox versions fail the
same way and are resolved by a relaunch.

Failing is the point, not a warning. If egress or read-only path policy was
tightened, the running sandbox holds broader permissions than the configuration
now requests, and a command run inside it would silently execute under the old
policy. A warning does not address that: automation redirects or discards stderr,
and automation is what this feature is for. Failing preserves the
no-automatic-replacement rule — jailbox still never destroys a sandbox the user
did not ask it to destroy — while making the operator's current declaration
authoritative for every command that runs.

### Proxy liveness

When egress filtering is enabled, fail before attaching if the proxy container is
not running: the sandbox sits on an internal network with no external route, so a
dead proxy means every outbound request fails, and saying so up front beats a
confusing failure inside the user's command.

Do not compare the `SetEnv` proxy address in the SSH config against the live
proxy's address. The proxy is pinned to a fixed IP on a network whose subnet is
fixed at creation, so the two can only diverge through manual podman surgery, and
when they do the result is a loud connection-refused on the first outbound
request rather than a silent policy difference. Parsing the address back out of
the generated config to detect that is not worth the code.

## Transport

Use the generated SSH config and strict host-key state already used by the
editor:

```sh
ssh -F "$SSH_CONFIG" -T -- "$CONTAINER_NAME" <remote-command>
```

SSH options must precede the destination. `exec` always uses `-T` and is
non-interactive.

### Argument fidelity

Do not interpolate caller arguments into a remote shell command. Encode argv as a
NUL-delimited payload and convert it to a single-line Base64 frame. Pass that
validated frame as the sole argument to an installed fixed helper,
`/usr/local/bin/jailbox-exec-argv`; Base64's restricted alphabet makes this safe
in OpenSSH's remote command string without evaluating caller data. The Bash
helper validates and decodes it into an array, changes to `$REMOTE_PATH`, and
`exec`s the array. Stdin remains exclusively attached to the remote command so
pipelines work without a framing collision. Unix argv cannot contain NUL; every
other byte accepted by the host shell must round-trip without reinterpretation.

Base64 line folding is not portable and must not be papered over with a flag: GNU
`base64` spells single-line output `-w0`, macOS spells it `-b 0`, and busybox
supports neither. Fold on the host with `base64 | tr -d '\n'` and decode remotely
with plain `base64 -d`, which tolerates wrapping in either direction.

The frame travels as one argument inside the sshd command string, so total argv
size is bounded by the remote `ARG_MAX` minus Base64's 33% inflation, and stdin
is unavailable as a side channel because it belongs to the remote command.
Set the maximum encoded frame to 49,152 bytes (48 KiB), measured after newline
folding and before invoking SSH. This leaves ample room for the fixed command and
environment on supported Linux development images while giving identical
behavior across hosts. Fail above it with the explicit message "argument list
too long for jailbox exec" rather than letting sshd or the remote `exec` fail
opaquely. This is a jailbox protocol limit, not a dynamically calculated
fraction of the current host's `ARG_MAX`.

The implementation must:

- run in the repository's supported host Bash 4.4 or newer; only the entrypoint
  before its version guard and `install.sh` retain macOS Bash 3.2 constraints;
- use Base64 commands available on supported hosts, fold to one line portably as
  above, and verify the host encoder and remote decoder during preflight/image
  validation;
- validate the frame against `[A-Za-z0-9+/=]` on the host before sending;
- run array decoding under Bash explicitly rather than assuming SSH selected
  Bash — the wrapper image installs Bash and sets it as the managed user's shell,
  but the remote command must not depend on that;
- reject malformed frames and an empty decoded argv;
- preserve empty arguments and arguments containing whitespace, quotes, globbing
  characters, and newlines;
- forward stdin in non-TTY mode; and
- return the remote command's exit status.

### Exit status

Report the remote command's status verbatim. OpenSSH returns 255 both for its own
transport failures and for a remote command that genuinely exits 255, and ssh's
diagnostics reach the caller on the same stderr stream as the command's, so
jailbox cannot tell the two apart. Document 255 as ambiguous and leave it there;
do not introduce a side-channel status protocol to disambiguate it.

Local failures before the transport runs — usage errors, encoding failures,
preflight failures — use the existing local codes (2 for usage, 1 for other local
errors) and must never be reported as 0.

### Signals and disconnect

`exec` runs without a PTY, so there is no signal channel to the remote process.
Ctrl-C delivers SIGINT to the local `ssh` in the foreground process group; the
remote command observes a closed channel, not SIGINT, and may survive. jailbox
returns the transport failure status and must not claim the remote process was
terminated unless that is confirmed. Test the behavior that is actually true:
Ctrl-C terminates `jailbox exec` promptly with a non-zero status.

An opt-in `-t` mode is deliberately excluded: allocating a PTY would enable signal
delivery but break byte fidelity through CR/LF translation.

Install `jailbox-exec-argv` through the wrapper image alongside the other
jailbox-owned runtime helpers. It accepts exactly one frame, rejects characters
outside `[A-Za-z0-9+/=]`, decodes into a private temporary file under `/tmp`,
checks Base64 decoding success, reads NUL-delimited elements with Bash without
command substitution, requires a final NUL and a non-empty argv, removes the
temporary file on every pre-exec path, changes to `$REMOTE_PATH`, and `exec`s the
target argv. Create the temporary file with `mktemp` under a restrictive umask.

Implement the helper as the new executable Bash file
`container/jailbox-exec-argv`. Install it as
`/usr/local/bin/jailbox-exec-argv` in `container/Containerfile.wrapper` with mode
0755; keeping it under `container/` also places it under the existing wrapper
image cache-bust. Bash is intentional here because reconstructing arbitrary
NUL-delimited argv safely requires arrays. Do not add Bash syntax to the POSIX
`container/setup.sh` or `container/entrypoint.sh` scripts.

Add the helper to the Bash section of `scripts/lint.sh` so the portable gate
runs ShellCheck on it. Add a direct `bash -n` assertion alongside the existing
syntax checks as well. The transport component that parses untrusted framed argv
must not sit outside lint or syntax-test coverage.

## Working directory and environment

Commands start in `$REMOTE_PATH` under the sshd-created session environment. That
includes the proxy variables rendered through the generated SSH host block when
egress filtering is enabled: the host block emits a single `SetEnv` line and the
wrapper's sshd config already lists those names in `AcceptEnv`.

For login/profile PATH semantics, callers may explicitly run
`jailbox exec -- bash -lc '...'`. Ordinary command execution has no implicit
login-shell wrapper.

## CLI parsing and public API

`exec` takes arguments, so it cannot simply join `CLI_FLAGS_WITHOUT_VALUES`:

- add a third list — `CLI_COMMANDS_WITH_ARGS=(exec)` — to `host/public-api.sh`.
  Extend `CLI_HELP` and `initialize_public_api_lookups` accordingly;
- `parse_args` currently rejects any second argument; relax that for `exec` only
  and keep the rejection for every other command;
- `is_cli_flag_allowed`'s regex rejects `--`, which is fine: the optional `--` is
  consumed by the `exec` branch and the remaining argv is never flag-validated;
- the "`--config` must appear before the command" guard inspects `$1` and `$2`
  unconditionally; restrict it to arguments before the command so
  `jailbox exec -- foo --config bar` is not misdiagnosed;
- `usage()` in `host/common.sh` hardcodes the command list and must be updated
  alongside `CLI_HELP`.

Preflight for `exec` requires Podman and SSH tooling but no editor. The host
Base64 encoder is checked only for `exec`; the remote decoder is part of
development-image validation.

Review the generated diff from `scripts/public-api-diff.sh`: adding one command
is a minor bump pre-1.0.

## Documentation

Update README usage with `exec`, the attach/fail rules, the digest enforcement
behavior and its documented gaps, and the limits of SSH disconnect and
exit-status semantics — including that 255 is ambiguous.

## Tests

Transport fidelity:

- `exec -- sh -c 'echo hi'` prints `hi`; a remote exit of 7 returns 7.
- Arguments including empty strings, whitespace, quotes, glob characters,
  newlines, and non-UTF-8 bytes round-trip exactly.
- `printf data | jailbox exec -- cat` returns `data`.
- Binary stdin, including bytes that resemble framing and embedded newlines,
  reaches the command unchanged.
- Malformed or truncated argv frames fail without evaluating payload contents.
- `container/jailbox-exec-argv` is installed with mode 0755, included in the
  wrapper cache-bust, checked as Bash by ShellCheck, and covered by `bash -n`.
- An argv above the encoded-frame limit fails with the explicit message.
- A remote command exiting 255 returns 255. No test asserts a distinction between
  that and a transport failure; there is none.
- `exec` never allocates a TTY.
- Ctrl-C terminates `jailbox exec` promptly with a non-zero status.
- Argumentless `exec` fails with usage.

Attach and staleness:

- `up` then `exec` attaches to the sandbox `up` created.
- `exec` against an absent sandbox fails with the `jailbox up` message and creates
  nothing.
- After `stop`, `exec` fails against the absent container; `up` then creates a
  fresh one using the preserved persistent state.
- `exec` fails the same way when the container is running but SSH does not answer.
- A changed `jailbox.conf` makes `exec` fail with the relaunch message without
  running the command, and does not stop or replace the container; a missing
  `jailbox.config-digest` label fails the same way; a reformatted config with
  unchanged values runs normally.
- Tightening egress or read-only path policy cannot be bypassed by an `exec`
  against the sandbox launched under the looser policy.
- With no default policy anchor, `exec` fails before attachment with the
  explanatory `jailbox init` message, even when `--config PATH` selects an
  existing external file. A sandbox launched with an external config requires
  both the anchor and the same canonical selected-config identity when
  attaching.
- With egress filtering enabled, a missing or stopped proxy fails before the
  command runs.
- A development container or required proxy with a missing or mismatched
  `jailbox.project` label is rejected as a foreign collision before digest
  inspection or SSH; the error names manual Podman inspection and does not name
  `--clean`.
- Concurrent `exec` invocations against one running sandbox all succeed; none of
  them mutates sandbox state.
- `exec` creates no configuration file; an explicit missing `--config PATH` fails
  and is never created.
- `jailbox exec -- foo --config bar` is not misdiagnosed as misplaced `--config`.

Add focused unit coverage for command parsing, argv framing/decoding, and the
attach/fail decision table. Put real SSH, stdin, signal, proxy, and lifecycle
assertions in the runtime system tests. Run `tests/run portable`, plus
`tests/run runtime` where Podman is available.

## Non-goals

- Sandbox creation, replacement, or repair by `exec`.
- A `-t`/PTY mode.
- An interactive shell; `06-shell-command-plan.md` owns it.
- Task specification, timeouts, loops, scheduling, or result collection.
- Any claim that closing SSH always kills an unconfirmed remote process.
