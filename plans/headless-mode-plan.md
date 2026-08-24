# Command mode — explicit up, exec, shell, and stop

## Goal

Let a jailbox sandbox be driven without a GUI editor and expose a small command
API for terminal and automation use. The mode is selected by an explicit
command, not a `HEADLESS` config key and not by whether stdio happens to be a
TTY.

Bare `jailbox` remains backward compatible: it launches the sandbox and opens
the configured editor exactly as today. `up`, `exec`, `shell`, and `stop` never
launch or require an editor.

## Naming

"Headless" already has a different meaning in this repository:
`tests/e2e/headless.sh` and the `system/headless` suite in the runtime gate mean
"run the full CLI, then assert over SSH without driving an editor". User-facing
documentation therefore calls this feature **command mode** and otherwise names
the commands individually; the existing suite and gate label keep their current
meaning. This file keeps its `headless-mode-plan.md` name until it is archived.

## Commands

```text
jailbox [--config PATH] up
jailbox [--config PATH] exec [--] CMD [ARG...]
jailbox [--config PATH] shell
jailbox [--config PATH] stop
jailbox [--config PATH] --clean
```

| Command | Behavior |
|---|---|
| `up` | Launch the sandbox without opening an editor: bare launch minus `open_editor`. Replaces any existing sandbox, exactly as bare launch does. |
| `exec [--] CMD [ARG...]` | Attach to the project's running sandbox, run one non-interactive command as the managed user in `$REMOTE_PATH`, stream stdin/stdout/stderr, and propagate its exit status. A command is required; a leading `--` is optional. |
| `shell` | Attach to the project's running sandbox and open an interactive login Bash in `$REMOTE_PATH`; requires local TTYs. |
| `stop` | Stop the development container and proxy while preserving the home volume, networks, and the project state directory. |
| `--clean` | Full teardown as today: remove containers, networks, home volume, and SSH state. |

One command creates a sandbox, the others attach to it. `up` and bare launch are
the only commands that start or replace anything; `exec` and `shell` never
create, never replace, and never repair. That split is what keeps the rest of
this plan small.

`stop` is idempotent and succeeds when the relevant containers are already
stopped or absent. Repeated `exec` calls attach to the same sandbox, but the
command executed by `exec` is not itself assumed to be idempotent. `up` is not
idempotent — it replaces — so automation runs it once during setup and then
issues many `exec` calls.

`stop` leaves the container object in place but does not enable a restart fast
path: the next `up` or bare launch replaces it, because `start_jailbox_container`
always runs `podman run --replace` and `setup_ssh_keys` rotates the key pair and
sshd runtime directory on every bring-up. `stop` therefore preserves the home
volume, networks, and the state directory itself — not the credentials inside
it. A `podman start` fast path is out of scope.

## Sandbox handling

`exec` and `shell` decide what to do from the sandbox's live state, and the only
two outcomes are attach and fail:

- **Container running, SSH answers, and its recorded configuration matches the
  current one** — attach to it as-is. It was created by an explicit `up` or bare
  launch, and that launch defined its policy.
- **Anything else** — absent, stopped, unresponsive, or configured differently —
  fail with an actionable message naming `jailbox up` to launch or relaunch and
  `jailbox --clean` to start over.

Because these commands never mutate anything, they need no locking, no
double-checked state, and no decision about whether a sandbox is close enough to
reuse. Two `exec` calls racing each other is uninteresting. jailbox never has to
judge whether a running sandbox still matches the configuration well enough to
repair; staleness is surfaced and the user resolves it. That matches how the
tool already behaves — an editor session likewise keeps running until the user
relaunches.

Because `up` and bare launch still replace the sandbox unconditionally, either
one terminates any `exec` or `shell` session attached to the old container.
Document that; do not try to prevent it.

Concurrent `up`, `stop`, and `--clean` invocations can still interleave badly —
each mutates the same containers, credentials, and networks. That race exists
today between bare launch and `--clean`, is not introduced by command mode, and
is left alone here. Locking the lifecycle commands is a separate change.

### Configuration bootstrap and protected paths

Bare `jailbox` and `jailbox up` create `$PROJECT_DIR/jailbox.conf` atomically
when no `--config` argument was supplied and the default file does not exist.
The generated file is minimal and documents that every configured read-only path
must already exist:

```conf
# Project paths that jailbox must mount read-only.
# Every listed path must exist before launch.
READONLY_PATHS=
```

An explicitly selected `--config PATH` is never created; it must exist. `exec`
and `shell` also never create configuration: if the default config is absent,
they fail and direct the user to `jailbox up`. `stop`, `--clean`, `doctor`, and
`ssh-config` retain their non-creating behavior.

Replace `READONLY_EXTRA` with `READONLY_PATHS`. There is no built-in list of
project policy paths and there are no mountpoint stubs. Every configured entry
must exist, contain no symlink component, resolve beneath the project, and be
mounted read-only; an absent entry is a configuration error with no override.

Jailbox automatically adds only two reachable launch inputs to the effective
read-only mount list:

- the selected config file, when it is inside the project; and
- the exact detected or configured Containerfile used for the build, when it is
  inside the project.

There is no special protection for a jailbox source checkout inside the project.
Project `.env`, workflow, Git configuration, hook, and other paths are protected
only when the user lists them in `READONLY_PATHS`.

Initialize and validate the user/config portion of the list after project and
config loading. Finalize the mount list only after
`build_or_select_dev_image` has identified the exact Containerfile, then build
the overlays. This ordering avoids protecting every discovery candidate while
still protecting the file jailbox actually executed.

### Config digest

Record a digest of the parsed effective configuration as a project-scoped
`jailbox.config-digest` label on the development container at start. `exec` and
`shell` compare it before attaching and refuse to run on mismatch, naming what
is stale — mount and egress policy — and telling the user to run `jailbox up` to
apply it.

Failing is the point, not a warning. If `EGRESS_ALLOW` or `READONLY_PATHS` was
tightened, the running sandbox holds broader permissions than the configuration
now requests, and a command run inside it would silently execute under the old
policy. A warning does not address that: automation redirects or discards
stderr, and automation is what this feature is for. Failing preserves the
no-automatic-replacement rule — jailbox still never destroys a sandbox the user
did not ask it to destroy — while making the operator's current declaration
authoritative for every command that runs.

Hash the *parsed* values rather than the config file's bytes, so reformatting is
not a policy change, and so `--config PATH` selection and the `JAILBOX_EDITOR`
override are covered. A missing label is a mismatch, so containers created by
older jailbox versions fail the same way and are resolved by a relaunch.

Cover **every** key by iterating `CONFIG_SCALAR_KEYS` and `CONFIG_ARRAY_KEYS`
from `host/public-api.sh`. Do not write the key names out, here or in the
implementation: a hand-maintained list means the next key added silently escapes
a digest that is now a hard gate, and `WRITABLE_PATHS` is already queued in
`writable-paths-plan.md`. Have the portable gate assert that no public config
key is missing from the digest, so adding a key without covering it fails CI
rather than weakening the check quietly.

Deliberately excluded, each to be stated in the README:

- **Image content.** Configured paths are hashed, their contents are not, so a
  rebuilt or re-pulled base image, an edited `DEV_CONTAINERFILE`, and changed
  files in the `DEV_BUILD_CONTEXT` all go unnoticed until the next launch.
  Someone iterating on their own Containerfile must relaunch.
- **The jailbox implementation itself.** A sandbox built by an older jailbox
  keeps running until relaunch, as an editor session already does across an
  update. Nothing in the tree carries a version constant — versions are git tags
  applied at release — so detecting this would mean hashing jailbox's own source
  to answer a question the digest is not for.

These two gaps are exactly the cases where a stale sandbox can still be
attached to without jailbox noticing. Each is documented rather than detected,
and each is resolved the same way: relaunch.

### Proxy liveness

When egress filtering is enabled, fail before attaching if the proxy container
is not running: the sandbox sits on an internal network with no external route,
so a dead proxy means every outbound request fails, and saying so up front beats
a confusing failure inside the user's command.

Do not compare the `SetEnv` proxy address in the SSH config against the live
proxy's address. The proxy is pinned to a fixed IP on a network whose subnet is
fixed at creation, so the two can only diverge through manual podman surgery,
and when they do the result is a loud connection-refused on the first outbound
request rather than a silent policy difference. Parsing the address back out of
the generated config to detect that is not worth the code.

## `exec` transport

Use the generated SSH config and strict host-key state already used by the
editor:

```sh
ssh -F "$SSH_CONFIG" -T -- "$CONTAINER_NAME" <remote-command>
```

SSH options must precede the destination. `exec` always uses `-T` and is
non-interactive. `shell` requires both stdin and stdout to be local TTYs;
otherwise fail clearly before attaching. It uses `-tt`, changes to
`$REMOTE_PATH`, and opens an interactive login Bash explicitly. A failed remote
`cd` must abort rather than silently opening a shell in the home directory.

### Argument fidelity

Do not interpolate caller arguments into a remote shell command. Encode argv as
a NUL-delimited payload and convert it to a single-line Base64 frame. Pass that
validated frame as one argument to a fixed remote decoder command; Base64's
restricted alphabet makes this safe without evaluating caller data. The remote
decoder decodes it into a Bash array, changes to `$REMOTE_PATH`, and `exec`s the
array. Stdin remains exclusively attached to the remote command so pipelines
work without a framing collision. Unix argv cannot contain NUL; every other byte
accepted by the host shell must round-trip without reinterpretation.

Base64 line folding is not portable and must not be papered over with a flag:
GNU `base64` spells single-line output `-w0`, macOS spells it `-b 0`, and
busybox supports neither. Fold on the host with `base64 | tr -d '\n'` and decode
remotely with plain `base64 -d`, which tolerates wrapping in either direction.

The frame travels as one argument inside the sshd command string, so total argv
size is bounded by the remote `ARG_MAX` minus Base64's 33% inflation, and stdin
is unavailable as a side channel because it belongs to the remote command.
Enforce a conservative encoded-frame limit on the host and fail with an explicit
"argument list too long for jailbox exec" message rather than letting sshd or
the remote `exec` fail opaquely.

The implementation must:

- run in the repository's supported host Bash 4.4 or newer; only the entrypoint
  before its version guard and `install.sh` retain macOS Bash 3.2 constraints;
- use Base64 commands available on supported hosts, fold to one line portably as
  above, and verify the host encoder and remote decoder during preflight/image
  validation;
- validate the frame against `[A-Za-z0-9+/=]` on the host before sending;
- run array decoding under Bash explicitly rather than assuming SSH selected
  Bash — the wrapper image installs Bash and sets it as the managed user's
  shell, but the remote command must not depend on that;
- reject malformed frames and an empty decoded argv;
- preserve empty arguments and arguments containing whitespace, quotes, globbing
  characters, and newlines;
- forward stdin in non-TTY mode; and
- return the remote command's exit status.

### Exit status

Report the remote command's status verbatim. OpenSSH returns 255 both for its
own transport failures and for a remote command that genuinely exits 255, and
ssh's diagnostics reach the caller on the same stderr stream as the command's,
so jailbox cannot tell the two apart. Document 255 as ambiguous and leave it
there; do not introduce a side-channel status protocol to disambiguate it.
Local failures before the transport runs — usage errors, encoding failures,
preflight failures — use the existing local codes (2 for usage, 1 for other
local errors) and must never be reported as 0.

### Signals and disconnect

`exec` runs without a PTY, so there is no signal channel to the remote process.
Ctrl-C delivers SIGINT to the local `ssh` in the foreground process group; the
remote command observes a closed channel, not SIGINT, and may survive. jailbox
returns the transport failure status and must not claim the remote process was
terminated unless that is confirmed. Test the behavior that is actually true:
Ctrl-C terminates `jailbox exec` promptly with a non-zero status.

An opt-in `-t` mode for `exec` is deliberately excluded: allocating a PTY would
enable signal delivery but break byte fidelity through CR/LF translation.

The remote decoder must `exec` the target argv so no wrapper shell lingers after
a disconnect.

For login/profile PATH semantics, callers may explicitly run
`jailbox exec -- bash -lc '...'`. Ordinary command execution has no implicit
login-shell wrapper.

## Working directory and environment

Commands start in `$REMOTE_PATH` under the sshd-created session environment.
That includes the proxy variables rendered through the generated SSH host block
when egress filtering is enabled: the host block emits a single `SetEnv` line and
the wrapper's sshd config already lists those names in `AcceptEnv`.

A sandbox brought up by `up` omits the editor CDN hosts that
`effective_egress_allowlist` adds from a discovered `EDITOR_BIN`, because `up`
never discovers an editor. That is correct — no editor is attached — and it needs
no code change; document that bare `jailbox` replaces the sandbox with one whose
allowlist includes them.

## Implementation outline

```sh
bring_up_sandbox() {
    check_local_port_available
    build_or_select_dev_image
    validate_dev_image
    finalize_readonly_paths     # add the exact selected Containerfile
    run_pre_build_hook          # optional; bare launch passes the Alpine warning
    build_jailbox_image
    configure_runtime_mounts
    configure_network
    setup_ssh_keys
    build_readonly_mounts
    ensure_home_volume
    start_jailbox_container
    pin_ssh_host_key
    wait_for_ssh
    configure_downloader_proxy
    post_start_validation
}
```

- Bare launch: initialize editor state, call the core with
  `warn_if_alpine_dev_image_with_vscode` as the pre-build hook, then
  `open_editor`. The hook keeps the warning where it fires today — after
  `validate_dev_image`, before the wrapper build — instead of surfacing it only
  once the sandbox is up.
- `up`: call the core with no hook and stop there. This is the entire command;
  it is bare launch minus editor discovery, integration writes, compatibility
  warnings, and `open_editor`. Shared editor state initialization is unaffected,
  as described under "Editor separation".
- `exec`: require a command, consume an optional leading `--`, resolve the
  sandbox per "Sandbox handling", then invoke non-interactive SSH. Do not
  discover, configure, or launch an editor, and do not call `bring_up_sandbox`.
- `shell`: validate its TTY requirements, resolve the sandbox, then open the
  login shell over SSH. Same prohibitions as `exec`.
- `stop`: stop only the project-scoped development container and proxy without
  deleting either container, the home volume, networks, or SSH state. Verify the
  `jailbox.project` ownership label before acting, and tolerate absent or
  already stopped resources.
- `--clean`: retain the existing full teardown behavior.

`check_local_port_available` currently returns early whenever the container
merely *exists*. `stop` makes "exists but is not running" a common state, in
which a foreign listener on the derived port would produce a confusing
`wait_for_ssh` timeout for the next `up` instead of the intended clear error.
Narrow the short-circuit to a *running* jailbox container.

### Editor separation

`initialize_editor_state` is pure path computation and `doctor_jailbox` reads
`JAILBOX_EDITOR_USER_SETTINGS`, so it stays in shared initialization; splitting
it out would break `doctor`. The prohibitions that matter for `up`, `exec`, and
`shell` are narrower: do not require an installed editor in preflight, do not
run `write_jailbox_editor_user_settings` or `write_remote_editor_smoke_settings`,
do not run `warn_if_alpine_dev_image_with_vscode`, and do not call
`open_editor`.

Preflight is command-aware:

- bare editor launch requires Podman, SSH tooling, and an editor;
- `up`, `exec`, and `shell` require Podman and SSH tooling but no editor;
- `stop` requires Podman only;
- `doctor` and `ssh-config` keep their existing lighter requirements.

The host Base64 encoder required by `exec` is checked only for `exec`. The
remote decoder is part of development-image validation.

Config creation is command-aware and occurs before config loading. Only bare
launch and `up` may create the default config. Validation of `READONLY_PATHS`
occurs after project initialization so canonical containment and path existence
can be checked before any mount is constructed. Rename the public configuration
key from `READONLY_EXTRA` to `READONLY_PATHS` in `host/public-api.sh`, defaults,
parser assignment, help, README, generated public-API expectations, and tests;
do not retain the old key as an alias.

### CLI parsing and public API

`exec` takes arguments, so it cannot simply join `CLI_FLAGS_WITHOUT_VALUES`:

- add a third list — `CLI_COMMANDS_WITH_ARGS=(exec)` — and put `up`, `shell`,
  and `stop` in `CLI_FLAGS_WITHOUT_VALUES`; extend `CLI_HELP` and
  `initialize_public_api_lookups` accordingly;
- `parse_args` currently rejects any second argument; relax that for `exec` only
  and keep the rejection for every other command;
- `is_cli_flag_allowed`'s regex rejects `--`, which is fine: the optional `--`
  is consumed by the `exec` branch and the remaining argv is never
  flag-validated;
- the "`--config` must appear before the command" guard inspects `$1` and `$2`
  unconditionally; restrict it to arguments before the command so
  `jailbox exec -- foo --config bar` is not misdiagnosed;
- `usage()` in `host/common.sh` hardcodes the command list and must be updated
  alongside `CLI_HELP`.

Do not add a `HEADLESS` configuration key. Review the generated diff from
`scripts/public-api-diff.sh`: adding four commands is a minor bump pre-1.0.
Update README usage and the documented lifecycle/security behavior, including
the `up`/`exec` split, the distinction between `stop` and `--clean`, the
sandbox-handling rules and the config digest's documented gaps, and the limits
of SSH disconnect and exit-status semantics. Update the threat model explicitly:
jailbox no longer automatically protects `.env`, workflows, Git configuration,
hooks, or its own source checkout; those are user policy expressed through
`READONLY_PATHS`.

## Tests

Command surface and editor independence:

- Bare `jailbox` retains current editor behavior.
- `up`, `exec`, and `shell` work with no code/codium executable and never open
  or configure an editor.
- `up` launches a usable sandbox and returns without opening one.
- `doctor` still reports editor integration after the editor-state split.
- Argumentless `exec` fails with usage; `shell` opens a login Bash in the remote
  project directory, and a failed remote `cd` aborts.

Transport fidelity:

- `exec -- sh -c 'echo hi'` prints `hi`; a remote exit of 7 returns 7.
- Arguments including empty strings, whitespace, quotes, glob characters,
  newlines, and non-UTF-8 bytes round-trip exactly.
- `printf data | jailbox exec -- cat` returns `data`.
- Binary stdin, including bytes that resemble framing and embedded newlines,
  reaches the command unchanged.
- Malformed or truncated argv frames fail without evaluating payload contents.
- An argv above the encoded-frame limit fails with the explicit message.
- A remote command exiting 255 returns 255. No test asserts a distinction
  between that and a transport failure; there is none.
- `exec` never allocates a TTY; `shell` requires local TTYs on stdin and stdout.
- Ctrl-C terminates `jailbox exec` promptly with a non-zero status.

Lifecycle:

- `up` then `exec` attaches to the sandbox `up` created.
- `exec` against an absent sandbox fails with the `jailbox up` message and
  creates nothing.
- After `stop`, `exec` fails the same way and does not replace the stopped
  container; `up` then brings it back.
- `exec` fails the same way when the container is running but SSH does not
  answer.
- Repeated `stop` succeeds; `stop` succeeds when only the proxy exists.
- Bare launch and `up` atomically create a missing default `jailbox.conf` with
  `READONLY_PATHS=`; no other command creates it.
- An explicit missing `--config PATH` fails and is never created.
- Every `READONLY_PATHS` entry must exist and resolve safely beneath the project;
  a missing, outside, or symlinked entry fails before launch.
- The selected in-project config and exact in-project Containerfile used for the
  build are mounted read-only even when absent from `READONLY_PATHS`.
- No other project path is protected unless listed in `READONLY_PATHS`.
- A changed `jailbox.conf` makes `exec` fail with the relaunch message without
  running the command, and does not stop or replace the container; a missing
  `jailbox.config-digest` label fails the same way; a reformatted config with
  unchanged values runs normally.
- Tightening `EGRESS_ALLOW` or `READONLY_PATHS` cannot be bypassed by an `exec`
  against the sandbox launched under the looser policy.
- With egress filtering enabled, a missing or stopped proxy fails before the
  command runs.
- Concurrent `exec` invocations against one running sandbox all succeed; none of
  them mutates sandbox state.
- After `stop`, a foreign listener on the derived port produces the clear port
  error rather than an SSH timeout on the next `up`.
- SSH disconnect behavior is covered by system tests.

Add focused unit coverage for command parsing, argv framing/decoding, the config
digest, the attach/fail decision table, and stop idempotence. Put real SSH,
stdin, signal, proxy, and lifecycle assertions in the existing runtime system
tests. Bare editor
behavior remains covered by the editor gate. Run `tests/run portable` for the
implementation, plus `tests/run runtime` when Podman is available and
`tests/run editor` for any editor-integration changes.

## Non-goals

- No `HEADLESS` config toggle or TTY-dependent meaning for bare `jailbox`.
- No sandbox creation, replacement, or repair by `exec` or `shell`, and no reuse
  digest over derived runtime state.
- No locking for the lifecycle commands. The bare launch versus `--clean` race
  predates this change and stays out of scope.
- No `-t`/PTY mode for `exec`.
- No `podman start` fast path for a stopped sandbox.
- No profiles or multiple sandbox identities for one checkout.
- No task specification, timeout, loop, scheduling, or result collection.
- No claim that closing SSH always kills an unconfirmed remote process.
