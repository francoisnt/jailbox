# Recommendation: contain cross-module global state

## Concern

`jailbox` declares many globals that `host/*.sh` modules populate by side
effect. Launch behavior depends on step order; for example, proxy configuration
sets values later consumed by editor, SSH, and downloader-proxy code. This makes
individual modules harder to reason about and test.

## Recommendation

Implement `modern-bash-runtime-plan.md` first. Bash 5 associative arrays and
namerefs make module-owned state and explicit array outputs practical, but do
not remove the need for a visible, ordered orchestration pipeline.

Do not introduce one repository-wide generic state object. Prefer small,
module-owned state maps and purpose-specific indexed arrays whose complete
lifecycle can be reviewed locally.

Contain coupling incrementally, preferably while implementing a feature that
already touches the relevant modules.

## Plan

### 1. Define state ownership

Move declarations to the module that owns each value. Use an associative state
map for related scalar outputs and ordinary indexed arrays for ordered values.
At minimum, establish these boundaries:

- `common.sh`: project hash, resource names, ports, and project-scoped state
  paths;
- `preflight.sh`: selected editor;
- `dev-image.sh`: selected development image, usable shell, and package
  manager;
- `network.sh`: selected container network, proxy URL, no-proxy value, rendered
  proxy files, and SSH proxy environment;
- `container-runtime.sh`: root-filesystem flags and constructed mount arrays;
  and
- `ssh.sh`: generated credentials, host-key state, and SSH configuration.

For example, `network.sh` may own a `NETWORK_STATE` associative array while
`container-runtime.sh` owns indexed mount arrays. Every cross-module read must
have one unambiguous owner; do not copy the same value into multiple maps.

### 2. Namespace module outputs

Rename ambiguous shared outputs when a module is already being changed. For
example, network-owned values should use a consistent prefix rather than names
such as `PROXY_URL` or `JAILBOX_NETWORK` that do not identify their owner.

Do not perform a repository-wide rename solely for consistency. Keep each
increment small enough for its complete data flow to be reviewed in one diff.

### 3. Pass small dependency sets explicitly

When a function needs only one or two external values, accept them as arguments
instead of reading unrelated globals. Use nameref output parameters when a
function needs to return an array. Good candidates include validation and
warning helpers whose inputs are already known at the call site.

Do not replace a readable function with a long positional interface. Functions
that produce a coordinated group of scalar results may populate their
documented module-owned state map.

### 4. Enforce launch-order preconditions

Add explicit internal checks at security-sensitive boundaries. Before starting
the container, verify that image, mount, network, SSH, and port state has been
initialized. Before rendering editor or downloader configuration, verify that
the required proxy and SSH state exists.

An absent prerequisite must fail with an internal-error message naming the
missing phase. It must never silently select a broader mount or network default.

### 5. Keep orchestration centralized

Keep the high-level phase order visible in `jailbox`. Modules should not invoke
later orchestration phases implicitly. When headless commands introduce shared
bring-up behavior, use one editor-independent orchestration function rather
than duplicating the state pipeline.

### 6. Add focused contract tests

For each boundary changed:

- test the module with its documented minimum inputs;
- test that a missing prerequisite fails clearly;
- test that stale state from a prior invocation is reset;
- cover empty indexed and associative state explicitly; and
- add the lowest-layer regression assertion for any mount, network, SSH, or
  image behavior affected by the refactor.

## Sequencing

After the modern Bash runtime requirement lands, apply containment alongside
the feature that exercises each boundary:

1. image-owned state during automatic development-image refresh;
2. network-owned state during egress phase 1;
3. config-loading inputs during `--config PATH`;
4. shared orchestration and preconditions during headless mode; and
5. mount-owned state during writable-path implementation.

Avoid a preliminary repository-wide cleanup commit. Each feature should leave
the state boundary it touches clearer than before without rewriting unrelated
modules.

## Verification

Run `tests/run portable` for every containment change. Also run
`tests/run runtime` for image, container, mount, network, SSH, or lifecycle
changes, and `tests/run editor` when editor launch or Remote SSH state is
affected. A documentation-only update to this recommendation requires no gate.
