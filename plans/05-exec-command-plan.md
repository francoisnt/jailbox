# 5. jailbox exec

## Goal

Run one non-interactive command in an already-running compatible sandbox with
byte-faithful argv/stdin and the remote exit status.

## Sequence

Requires `03-launch-core-and-up-plan.md`,
`03.1-environment-only-configuration-plan.md`,
`03.2.02-configuration-digest-plan.md`,
`03.2.06-constrained-up-plan.md`, and
`03.2.09-connection-info-and-doctor-plan.md`. Plan 6 reuses its transport and
validator boundary.

## Attach behavior

`jailbox exec [--] CMD [ARG...]` consumes the canonical environment policy
and invokes 03.2.09's shared validator over every exact-named policy-bearing
resource. It attaches only to a running healthy match. Absent, stopped,
unresponsive, structurally invalid, missing/inconsistent/mismatched digest, SSH,
network, or proxy state refuses with appropriate up or destructive-warning
recovery. It never creates, starts, stops, replaces, or repairs.

On digest mismatch, list the current invocation's recognized
`JAILBOX_CONFIG_*` key names in public declaration order without values, or
state explicitly that none are present. Explain that this is current-side
context only and cannot identify which launch-side key differed. Attachment
requires the same effective policy, not the same provenance.

## Transport

Use generated strict-host-key SSH with `-T`. A jailbox host module encodes
NUL-delimited argv to single-line Base64, validates its alphabet, and sends
one frame to installed Bash helper `/usr/local/bin/jailbox-exec-argv`.
The helper securely decodes to an array, requires final NUL/non-empty argv,
changes to literal `/home/jailbox/project`, and execs without evaluation.
Preserve empty, whitespace, quote, glob, newline, and non-UTF-8 arguments.
Cap encoded frames at 49,152 bytes with the specified error. Stdin remains the
command stream.

Propagate remote status; 255 remains ambiguous with SSH failure. Ctrl-C ends
local SSH promptly but does not promise SIGINT delivery or remote termination.
No PTY is allocated.

Create executable Bash source `container/jailbox-exec-argv`, install it from
`container/Containerfile.wrapper` as
`/usr/local/bin/jailbox-exec-argv` mode 0755, and keep it under the wrapper
cache-bust. The decoder ships from jailbox's own tree as part of its wrapper
image. It accepts exactly one frame, validates `[A-Za-z0-9+/=]`, decodes under
restrictive umask into a `mktemp` file, reconstructs NUL-delimited argv without
command substitution, requires a final NUL and non-empty argv, removes
temporary data on every pre-exec path, changes directory, and `exec`s the
array. Run under Bash explicitly; do not add Bash syntax to POSIX
`container/setup.sh` or `entrypoint.sh`.

Use `base64 | tr -d '\n'` on the host and plain `base64 -d` remotely rather
than GNU/macOS-specific wrapping flags. The 49,152-byte limit is measured after
folding and before SSH and fails exactly with
`argument list too long for jailbox exec`.

## Working directory and environment

Commands begin in the host/helper-shared literal `/home/jailbox/project` under
the sshd-created session environment. Preserve the generated SSH `SetEnv` /
sshd `AcceptEnv` contract for `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`,
`http_proxy`, `https_proxy`, and `no_proxy`. No implicit login shell is
inserted; callers needing profile/PATH semantics explicitly run
`jailbox exec -- bash -lc '...'`.

## CLI and preflight

Add `CLI_COMMANDS_WITH_ARGS=(exec)` and help in `host/public-api.sh`.
Teach `initialize_public_api_lookups`, `scripts/public-api-diff.sh`'s
`cli_api_values`, command dispatch, and `tests/unit/public-api-diff.sh`
about that declaration, including compatibility with older refs lacking it.
Relax `parse_args` only for exec; consume optional leading `--`; keep
`is_cli_flag_allowed` away from caller argv; and restrict the old misplaced
`--config` guard to pre-command arguments until 03.2.11 confines `--config`
to the frontend launch path.
Update hard-coded `usage()` in `host/common.sh`.

Update the preflight command classification: remove `ssh-config` from the
final list; `init` and the frontend launch paths keep their frontend-owned
preflight (03.2.11) outside the machine command classes; and include `up`,
`config-schema`, `status`, and `connection-info` with their owning
requirements. Exec's attach branch
requires Podman, SSH, realpath, SHA-256, and Base64, but no wrapper-build
`cksum` or editor. It performs only configuration, identity, Containerfile
classification, existing SSH-path, and shared-validator initialization—never
launch-only editor/network/mount initialization.

Add `container/jailbox-exec-argv` explicitly to Bash ShellCheck discovery in
`scripts/lint.sh` and the explicit `bash -n` list in
`tests/portable/smoke.sh`; its extensionless name is not covered by `*.sh`
globs. Host code requires Bash 4.4; `install.sh` and the entrypoint's
pre-version-guard prefix retain their separate Bash 3.2 rules.

## Tests and documentation

Portable/runtime tests cover parsing, empty/whitespace/quotes/globs/newlines/
non-UTF-8 argv, binary stdin, framing corruption/truncation/limit, statuses
including ambiguous 255, signals, absent/stopped/unresponsive state, every
shared-validator refusal, concurrent read-only attaches, proxy liveness, no
`cksum`/editor dependency, and no mutation. Document transport limitations,
aggregate mismatch guidance, and that closing SSH may not kill an unconfirmed
remote process.

Run `tests/run portable` and `tests/run runtime`.

## Acceptance criteria

- Valid attach executes exactly the supplied argv/input in the remote path.
- Every compatibility failure occurs before command execution and mutation.
- Digest diagnostics expose current key names but never values or unsupported
  claims about the differing launch input.
- Helper installation, lint, portability, and path invariants are gated.
- Proxy/session environment reaches the command, while ordinary exec adds no
  login-shell semantics.
- CLI/public API parsing preserves every caller argument after the command.

## Non-goals

- Creation/repair, PTY, scheduling, timeouts, or guaranteed remote termination.
- An interactive shell, loops, result collection, or a side-channel that
  disambiguates remote exit 255 from SSH failure.
