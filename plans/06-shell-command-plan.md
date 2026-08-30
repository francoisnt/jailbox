# 6. `jailbox shell` — interactive shell in the running sandbox

## Goal

Attach to the project's running sandbox and open an interactive login Bash in
`$REMOTE_PATH`. This is the interactive counterpart to `exec` and the last of the
command-mode changes.

## Sequence

Order 6.0; last of the five command-mode changes. Requires `05-exec-command-plan.md`,
whose attach decision, digest enforcement, and proxy liveness check `shell`
reuses unchanged.

## Commands

```text
jailbox [--config PATH] shell
```

| Command | Behavior |
|---|---|
| `shell` | Attach to the project's running sandbox and open an interactive login Bash in `$REMOTE_PATH`; requires local TTYs. |

`shell` never creates, replaces, or repairs a sandbox.

## Sandbox handling

`shell` uses the attach-or-fail rules, digest enforcement, and proxy liveness
check defined in `05-exec-command-plan.md` without change. It adds one precondition
of its own and one difference in transport.

## TTY requirement

`shell` requires both stdin and stdout to be local TTYs. When either is not a
TTY, fail clearly before attaching rather than opening a session that cannot be
driven. This is the one precondition `exec` does not share: `exec` is explicitly
non-interactive and forwards non-TTY stdin as data.

## Transport

Use the same generated SSH config and strict host-key state as `exec`, with
`-tt` rather than `-T`:

```sh
ssh -F "$SSH_CONFIG" -tt -- "$CONTAINER_NAME" <remote-command>
```

The remote command changes to `$REMOTE_PATH` and opens an interactive login Bash
explicitly. A failed remote `cd` must abort rather than silently opening a shell
in the home directory — a shell in the wrong directory is worse than no shell,
because the user will not notice before running something.

`shell` needs no argv framing: it passes no caller arguments. The Base64 encoder
requirement belongs to `exec` alone.

## Working directory and environment

As with `exec`, the session starts in `$REMOTE_PATH` under the sshd-created
session environment, including the proxy variables rendered through the generated
SSH host block when egress filtering is enabled.

Because `shell` opens a login shell, profile and PATH semantics apply
automatically; the explicit `bash -lc` workaround `exec` documents is not needed
here.

## CLI parsing and public API

- Add `shell` to `CLI_FLAGS_WITHOUT_VALUES` and `CLI_HELP` in
  `host/public-api.sh`, and update dispatch and generated public-API
  expectations. It takes no arguments, so it does not join
  `CLI_COMMANDS_WITH_ARGS`.
- `usage()` in `host/common.sh` hardcodes the command list and must be updated
  alongside `CLI_HELP`.

Preflight for `shell` requires Podman and SSH tooling but no editor.

Review the generated diff from `scripts/public-api-diff.sh`: adding one command
is a minor bump pre-1.0.

## Documentation

Update README usage with `shell`, its local-TTY requirement, and the distinction
from `exec`. Note that `shell` opens a login shell while `exec` does not.

With this change the command reference is complete: document the full lifecycle —
bare launch, `up`, `exec`, `shell`, `stop`, `--clean` — as one table.

## Tests

- `shell` opens a login Bash in the remote project directory.
- A failed remote `cd` aborts rather than opening a shell in the home directory.
- `shell` requires local TTYs on both stdin and stdout, and fails clearly when
  either is not a TTY.
- `shell` works with no `code` or `codium` executable and never opens or
  configures an editor.
- `shell` against an absent, stopped, or unresponsive sandbox fails with the
  `jailbox up` message and creates nothing.
- A changed `jailbox.conf` or a missing `jailbox.config-digest` label makes
  `shell` fail with the relaunch message without attaching.
- With egress filtering enabled, a missing or stopped proxy fails before the
  session opens.
- `shell` creates no configuration file. With no default policy anchor it fails
  with the explanatory `jailbox init` message even when an external config is
  selected; an external-config sandbox requires both the anchor and the same
  canonical `--config PATH`, and a missing selected path fails without being
  created.
- `shell` appears in the literal `Usage:` synopsis, in the generated `Options:`
  block, and as an addition in the generated public-API diff.

SSH disconnect behavior is covered by the runtime system tests. Run
`tests/run portable`, plus `tests/run runtime` where Podman is available.

## Non-goals

- Sandbox creation, replacement, or repair by `shell`.
- Argument passing; use `exec` for that.
- A non-TTY fallback mode.
