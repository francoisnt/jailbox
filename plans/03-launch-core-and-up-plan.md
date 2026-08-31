# 3. Launch core extraction and `jailbox up`

## Goal

Factor the launch sequence into a reusable core and add `jailbox up`: bare
launch without the editor. `up` is the entry point for terminal and automation
use, and the foundation every attach command builds on.

## Sequence

Order 3.0; second of the five command-mode changes. Requires
`02-explicit-stop-plan.md`, whose absence requirement `up` inherits.
`04-config-digest-plan.md` follows.

## Naming

"Headless" already has a different meaning in this repository:
`tests/e2e/headless.sh` and the `system/headless` suite in the runtime gate mean
"run the full CLI, then assert over SSH without driving an editor". User-facing
documentation therefore calls this feature **command mode** and otherwise names
the commands individually; the existing suite and gate label keep their current
meaning.

The mode is selected by an explicit command, not a `HEADLESS` config key and not
by whether stdio happens to be a TTY.

## Commands

```text
jailbox [--config PATH] up
```

| Command | Behavior |
|---|---|
| `up` | Launch the sandbox without opening an editor: bare launch minus `open_editor`. Like bare launch, it requires any running sandbox to be stopped explicitly first. |

Bare `jailbox` retains its current behavior: launch, then open the configured
editor. `up` never launches or requires an editor.

`up` and bare launch are the only commands that start anything, and both fail
when the sandbox is already running. Automation runs `up` once during setup and
calls `stop` before a deliberate relaunch.

## Non-binding implementation notes

The sequence below is normative only where ordering affects validation,
security, or visible behavior. Function names and extraction boundaries are
illustrative and may change during implementation.

```sh
bring_up_sandbox() {
    initialize_runtime_ids
    validate_configured_readonly_paths
    check_local_port_available
    build_or_select_dev_image
    validate_dev_image
    run_pre_build_hook          # optional; bare launch passes the Alpine warning
    build_jailbox_image
    configure_runtime_mounts
    configure_network
    setup_ssh_keys
    finalize_effective_readonly_paths
    build_readonly_mounts
    ensure_home_volume
    start_jailbox_container
    pin_ssh_host_key
    wait_for_ssh
    configure_downloader_proxy
    post_start_validation
}
```

Keep `initialize_runtime_ids` as the first operation in the shared launch core.
It derives `LOCAL_PORT` and `MY_UID`, which later launch steps require, from the
project identity plan 2 initializes before dispatch. It is not part of global
command initialization: `doctor` and `ssh-config` retain their existing focused
calls because they also consume runtime identifiers, while commands that do not
need them must not acquire that work implicitly.

- **Bare launch**: initialize editor state, call the core with
  `warn_if_alpine_dev_image_with_vscode` as the pre-build hook, then
  `open_editor`. The hook keeps the warning where it fires today — after
  `validate_dev_image`, before the wrapper build — instead of surfacing it only
  once the sandbox is up.
- **`up`**: call the core with no hook and stop there. This is the entire
  command; it is bare launch minus editor discovery, integration writes,
  compatibility warnings, and `open_editor`. Shared editor state initialization
  is unaffected, as described under "Editor separation".
- Route both bare launch and `up` through plan 2's pre-config
  `require_sandbox_absent` check before either command enters the shared launch
  core. Adding the `up` dispatch branch must not bypass or duplicate that
  ownership-aware absence decision.

## Editor separation

`initialize_editor_state` is pure path computation and `doctor_jailbox` reads
`JAILBOX_EDITOR_USER_SETTINGS`, so it stays in shared initialization; splitting
it out would break `doctor`. The prohibitions that matter for `up` are narrower:
do not require an installed editor in preflight, do not run
`write_jailbox_editor_user_settings` or `write_remote_editor_smoke_settings`, do
not run `warn_if_alpine_dev_image_with_vscode`, and do not call `open_editor`.

Preflight becomes command-aware:

- bare editor launch requires Podman, SSH tooling, and an editor;
- `up` requires Podman and SSH tooling but no editor;
- `stop` requires Podman only, as established in `02-explicit-stop-plan.md`;
- `doctor` and `ssh-config` keep their existing lighter requirements.

## Configuration files

Only `init`, defined by `01.1-init-config-plan.md`, creates configuration. `up`
selects and loads configuration exactly as bare launch does and never creates or
repairs it.

Both commands require the default `jailbox.conf` policy anchor. Without
`--config`, it is also the selected config. An explicitly selected
`--config PATH` may be external and becomes the only parsed config, but does not
bypass the default anchor requirement. Missing either required file fails and
neither is created automatically.

## Egress allowlist difference

A sandbox brought up by `up` with egress filtering enabled omits the editor CDN
hosts that `effective_egress_allowlist` adds from a discovered `EDITOR_BIN`,
because `up` never discovers an editor. That is correct — no editor is attached
— and needs no code change. Document that after an explicit stop, bare
`jailbox` launches a filtered sandbox whose allowlist includes them. With empty
`EGRESS_ALLOW`, `configure_network` selects the ordinary network instead of the
allowlisting proxy, so neither command has an enforced host allowlist and this
difference does not arise.

When filtering is enabled, this difference is real policy, not cosmetic: a
bare-launch sandbox permits egress a fresh `up` would not, and for
`EDITOR=codium` that includes `github.com` and `githubusercontent.com`. It is
nonetheless deliberately outside the config digest —
`04-config-digest-plan.md` records why — because `exec` cannot observe a
discovered editor without performing the discovery it is defined not to do.
Gating on it would reject every editor-launched sandbox. Document it in the
threat model instead, as a consequence of which command the user ran.

## Public API

- Add `up` to `CLI_FLAGS_WITHOUT_VALUES` and `CLI_HELP` in
  `host/public-api.sh`, and update dispatch and
  `tests/unit/public-api-diff.sh` expectations.
- `usage()` in `host/common.sh` hardcodes the command list in its literal
  `Usage:` synopsis and must be updated alongside `CLI_HELP`.
- Do not add a `HEADLESS` configuration key.

Review the generated diff from `scripts/public-api-diff.sh`: adding one command
is a minor bump pre-1.0.

## Documentation

Update README usage with the `up` command, the bare-launch/`up` split, and the
fact that `up` neither requires nor opens an editor. Document the egress
allowlist difference above.

## Acceptance criteria

- Bare `jailbox` retains current editor behavior.
- `up` works with no `code` or `codium` executable and never opens or configures
  an editor.
- `up` launches a usable sandbox and returns without opening one.
- `doctor` still reports editor integration after the editor-state split.
- `up` against a running sandbox fails with the `jailbox stop` instruction before
  creating or loading configuration.
- With no selected config, `up` fails with the `jailbox init` instruction and
  creates nothing.
- `up` creates no configuration file. An external `--config PATH` works only
  with the default anchor present; a missing anchor names `jailbox init`, while a
  missing selected path retains its path-specific error.
- The Alpine/VS Code warning still fires for bare launch at its current point in
  the sequence, and does not fire for `up`.
- With non-empty `EGRESS_ALLOW`, bare launch adds the discovered editor's fixed
  bootstrap hosts to the rendered proxy filter while `up` does not. With empty
  `EGRESS_ALLOW`, both commands use the ordinary network and neither renders an
  allowlist merely because an editor is discoverable.
- `up` appears in the literal `Usage:` synopsis, in the generated `Options:`
  block, and as an addition in the generated public-API diff.

Run `tests/run portable`, `tests/run runtime` where Podman is available, and
`tests/run editor` because this refactors the editor path.

## Non-goals

- Attaching to a running sandbox; `05-exec-command-plan.md` and
  `06-shell-command-plan.md` own that.
- Recording or comparing configuration state; `04-config-digest-plan.md` owns it.
- A `HEADLESS` config toggle or TTY-dependent meaning for bare `jailbox`.
- Profiles or multiple sandbox identities for one checkout.
