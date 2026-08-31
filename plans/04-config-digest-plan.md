# 4. Sandbox configuration digest

## Goal

Record a digest of the parsed effective configuration as a label on the
development container at start, and add a CI gate ensuring no public
configuration key escapes it. This change writes the label and proves its
coverage; nothing reads it yet.

## Sequence

Order 4.0; third of the five command-mode changes. Requires
`03-launch-core-and-up-plan.md`. `05-exec-command-plan.md` follows and is the first
consumer.

## Why this lands before its consumer

The digest is pure addition: a label nobody reads is zero behavior change, which
makes the piece with the most design weight — what is hashed, how absence is
represented, how CI enforces coverage — reviewable on its own.

It also front-runs the migration. A missing label counts as a mismatch, so
landing the writer first means that by the time `exec` ships, sandboxes already
carry a digest and the mismatch path is rare rather than something every user
hits once.

## Behavior

Record the digest as a project-scoped `jailbox.config-digest` label on the
development container in `start_jailbox_container`.

Hash the *parsed* values rather than the config file's bytes, so reformatting is
not a policy change.

Three inputs beyond the public config keys must be included explicitly, none of
which is a member of `CONFIG_SCALAR_KEYS` or `CONFIG_ARRAY_KEYS`:

- the canonical selected-config identity;
- the classified identity of the exact Containerfile selected for the
  development-image build, or an explicit `none` marker when `DEV_IMAGE` means
  no Containerfile is used; and
- the effective `JAILBOX_EDITOR` override.

`01.1-init-config-plan.md` makes an absent selected config unreachable for every
launch and attach command, so the digest has no absent-config marker or
defaults-only state.

### Reproducible inputs, never launch-derived state

Every digest input must be reproducible from configuration, environment, and
read-only inspection of the project inputs, by any launch or attach command,
without knowing how the sandbox was launched. This permits the deterministic
Containerfile discovery that selects the first existing candidate, but excludes
state produced by launching. `exec` performs no editor discovery, so it cannot
observe a resolved `EDITOR_BIN` or the editor bootstrap hosts
`effective_egress_allowlist` (`host/network.sh`) appends from one. Hashing either
would make `exec` compute a "no editor" digest and reject every sandbox bare
`jailbox` created, with no configuration change at all — breaking the primary
workflow, where an editor session and `exec` run side by side against one
sandbox.

`JAILBOX_EDITOR` and `EDITOR` are declarations and belong in the digest. The
editor jailbox *discovered*, and the hosts it added as a consequence, are
launch-mode state and must not gate attachment.

### Canonical serialization

Use SHA-256. On the host, prefer `sha256sum`; otherwise use
`shasum -a 256`. Launch and attach commands require one of those implementations
and normalize their output to a lowercase 64-hex-character digest. Do not use
`cksum`, because this label is a security-sensitive comparison rather than a
short resource-name hash.

Feed the hash command one versioned, NUL-delimited byte stream. Configuration
values cannot contain NUL because Unix argv and shell variables cannot contain
it, so the delimiter is unambiguous. Emit exactly:

```text
jailbox-config-digest-v1 NUL
scalar NUL KEY NUL VALUE NUL                         for each scalar key
array NUL KEY NUL COUNT NUL value NUL ITEM NUL ...  for each array key
selected-config NUL CANONICAL_PATH NUL
containerfile NUL none NUL
editor-override NUL inactive NUL
```

When a Containerfile is used, replace its record with
`containerfile NUL path NUL CANONICAL_PATH NUL`. When no Containerfile can be
classified because an explicit configured path is now absent or implicit
discovery has no candidate, replace it with
`containerfile NUL missing NUL`. This state cannot produce a successful launch,
but an attach command can observe it after the file used by the running sandbox
was deleted. The scalar records still distinguish explicit from implicit
configuration; the identity record does not need separate missing variants.
When a non-empty `JAILBOX_EDITOR` override is active, replace the final record
with `editor-override NUL active NUL VALUE NUL`. An unset and explicitly empty
`JAILBOX_EDITOR` are equivalent because
`${JAILBOX_EDITOR:-$EDITOR}` gives them identical behavior. Scalar and array
keys are emitted in their declaration order from `host/public-api.sh`; an empty
scalar still has its terminating NUL, and an empty array has count zero and no
item records. Encode `COUNT` as canonical unsigned decimal with no leading
zeroes except `0`; emit each item as the repeated
`value NUL ITEM NUL` record shown above. Stream records directly to the hash
command; never store the NUL-containing serialization in a Bash variable.

The canonical selected-config path is the classified absolute path used for
that invocation. This intentionally distinguishes two selected files with the
same parsed values.

The Containerfile identity uses the same discovery order and trusted-input
classification as `build_or_select_dev_image`, without building or inspecting
an image. Adding or removing a higher-priority default candidate therefore
changes the digest when it changes the exact file that would be consumed and
protected. Keep discovery in one shared helper so launch and attach cannot
select different identities. `DEV_IMAGE` always emits `none`, even if candidate
files exist or `DEV_CONTAINERFILE` is also configured with an invalid or missing
path, because that launch consumes and protects no Containerfile. Digest
computation short-circuits before Containerfile discovery or classification in
this mode; the configured `DEV_CONTAINERFILE` remains present in its ordinary
scalar record.

`DEV_CONTAINERFILE` in the scalar records is always the parsed configured value:
empty when discovery is implicit and the caller's configured spelling when it
is explicit. Discovery must not mutate that public configuration variable.
Plan 1 stores the discovered or explicit classified result separately as
`SELECTED_DEV_CONTAINERFILE`; the dedicated identity record uses that result.
Launch and attach both call the shared selection helper before serialization,
so the scalar and identity records cannot depend on whether an image build has
already run.

The shared selector reports either kind of missing selection without exiting. A
launch caller reports a path-specific configured-input error for an explicit
miss or retains the existing actionable discovery error for an implicit miss,
because launch cannot proceed. An attach digest emits the canonical `missing`
record, compares it with the running container's recorded path digest, and
reaches plan 5's ordinary stale-sandbox failure naming `jailbox up`. Do not leak
either launch-oriented Containerfile error from `exec` or `shell`.

Hash array keys in **declared order by default**. Sort only keys named as
set-valued, which today is `EGRESS_ALLOW` alone: it is a domain allowlist that
`effective_egress_allowlist` deduplicates, so its order carries no meaning and
reordering it must not force a relaunch.

Before serialization, render a set-valued array as its bytewise `LC_ALL=C`
sorted unique values. Keep the names of set-valued arrays in one explicit
`DIGEST_SET_ARRAY_KEYS` declaration next to the digest implementation. The
portable coverage test must verify that every name in that declaration is a
public array key; all public arrays not named there automatically retain their
declared order.

Path arrays keep declared order. `01-protected-path-policy-plan.md` constructs
mounts in configuration order and tests for it, and `07-writable-paths-plan.md`
adds lanes whose nesting interacts with the protected-overlay precedence rule.
Neither plan proves order is irrelevant to the resulting policy, and the digest
must not assume it: sorting them would hide a reordering that turns out to
matter.

The default is deliberately the conservative direction. An order-sensitive hash
over an array whose order is meaningless costs one unnecessary relaunch; an
order-insensitive hash over an array whose order does matter fails open, which is
the failure this gate exists to prevent. A key added later without anyone
thinking about it therefore over-invalidates rather than under-invalidates.

Promote a key to set-valued only when its implementation demonstrates order
cannot affect behavior, and record that reasoning alongside the list.

## Key coverage

Cover **every** key by iterating `CONFIG_SCALAR_KEYS` and `CONFIG_ARRAY_KEYS`
from `host/public-api.sh`. Do not write the key names out, here or in the
implementation: a hand-maintained list means the next key added silently escapes
a digest that becomes a hard gate in `05-exec-command-plan.md`, and
`WRITABLE_PATHS` is already queued in `07-writable-paths-plan.md`.

Have the portable gate assert that no public config key is missing from the
digest, so adding a key without covering it fails CI rather than weakening the
check quietly.

## Documented gaps

Three categories are deliberately excluded, each to be stated in the README:

- **Image content.** Configured paths are hashed, their contents are not, so a
  rebuilt or re-pulled base image, an edited `DEV_CONTAINERFILE`, and changed
  files in the `DEV_BUILD_CONTEXT` all go unnoticed until the next launch.
  Someone iterating on their own Containerfile must relaunch.
- **The jailbox implementation itself.** A sandbox built by an older jailbox
  keeps running until relaunch, as an editor session already does across an
  update. Nothing in the tree carries a version constant — versions are git tags
  applied at release — so detecting this would mean hashing jailbox's own source
  to answer a question the digest is not for.
- **Editor bootstrap egress hosts.** A sandbox created by bare `jailbox` allows
  the discovered editor's Remote SSH hosts; one created by `up` does not, as
  `03-launch-core-and-up-plan.md` describes. Those hosts are a consequence of the
  command the user ran, not of what they declared, and `exec` cannot observe them
  without performing the editor discovery it is defined not to do. For
  `EDITOR=codium` the difference includes `github.com` and
  `githubusercontent.com`, so state it plainly rather than describing the
  allowlist as fully determined by `EGRESS_ALLOW`.

These three gaps are exactly the cases where a stale or broader sandbox can still
be attached to without jailbox noticing. Each is documented rather than detected,
and each is resolved the same way: relaunch.

The first two are content behind a reference the digest did hash. The third is
different in kind and worth stating separately in the threat model: it is policy
the digest deliberately declines to gate on, because gating on it would reject
every editor-launched sandbox and make `exec` unusable alongside an editor
session.

## Implementation

- Compute the digest from parsed configuration, environment, and the shared
  read-only Containerfile discovery/classification helper. It must not read
  `EDITOR_BIN`, the output of `effective_egress_allowlist`, or any other value
  produced by the launch path, so that every command computes the same digest
  from the same reproducible inputs regardless of how it dispatches.
- Keep parsed configuration immutable during digest computation and image
  selection. Refactor `discover_dev_containerfile` so it returns or assigns
  image-owned `SELECTED_DEV_CONTAINERFILE` without overwriting
  `DEV_CONTAINERFILE`; both launch and attach use the same helper.
- Implement the exact versioned NUL-delimited serialization and portable
  SHA-256 selection above. Validate the normalized digest before adding it to a
  Podman label or comparing it.
- Add a focused preflight helper that accepts either `sha256sum` or
  `shasum -a 256` and fails clearly when neither is available. Invoke it for
  bare launch and `up` after command dispatch has excluded `init`, `stop`,
  `doctor`, `ssh-config`, `--clean`, and `--uninstall`. Run it after plan 2's
  read-only `require_sandbox_absent` name check and required-config loading, but
  before digest computation and every launch mutation. Do not put it at the top
  of `host_preflight`: plan 2's config-independent and Podman-only command
  contracts must remain intact. Plan 5 extends the same requirement to `exec`,
  and plan 6 inherits it for `shell` through the shared attach preflight.
- Add a portable-gate assertion that the digest computation depends on no
  launch-derived state. The reproducibility requirement above is the property
  `exec` relies on, and it is easy to break by adding an input that happens to be
  in scope at the call site.
- Add the `jailbox.config-digest` label to the development container's
  `podman run` in `start_jailbox_container` (`host/container-runtime.sh`),
  alongside the existing `jailbox.project` label.
- Add the key-coverage assertion to the portable gate. It must fail when a key
  present in `CONFIG_SCALAR_KEYS` or `CONFIG_ARRAY_KEYS` is not reachable by the
  digest computation.

This adds no configuration key and no CLI flag, so it carries no public-API
diff.

## Documentation

Document that jailbox records the configuration a sandbox was launched with, and
state all three documented gaps above. Defer describing the enforcement behavior
to `05-exec-command-plan.md`, which introduces it.

## Tests

- The digest covers every key in `CONFIG_SCALAR_KEYS` and `CONFIG_ARRAY_KEYS`;
  adding a key without covering it fails the portable gate.
- A reformatted config with unchanged values produces an unchanged digest;
  changing any single key's parsed value changes it.
- Empty scalars, empty arrays, multi-element arrays, and values that could be
  ambiguous under newline or delimiter-based concatenation produce distinct,
  stable digests. The v1 byte stream is covered by fixed digest vectors.
- Selecting a different config file with identical values still changes the
  digest, because the selected-config identity is an input.
- With implicit discovery, adding or removing a higher-priority Containerfile
  candidate changes the digest when it changes the exact selected file. An
  explicit `DEV_CONTAINERFILE` hashes its classified canonical identity, while
  `DEV_IMAGE` emits the stable `none` marker regardless of candidate files or an
  invalid concurrently configured `DEV_CONTAINERFILE`, without inspecting that
  path.
- Implicit discovery leaves the `DEV_CONTAINERFILE` scalar record empty in both
  launch and attach even after image selection. The selected path appears only
  in the dedicated Containerfile identity record.
- If an explicitly configured or implicitly discovered Containerfile is deleted
  after launch, `exec` and `shell` serialize the same `missing` identity, reject
  the digest mismatch, and show their normal `jailbox up` stale-sandbox guidance
  rather than either launch-only Containerfile error. The explicit and implicit
  cases remain distinguishable through the `DEV_CONTAINERFILE` scalar record.
- Changing a non-empty `JAILBOX_EDITOR` or changing `EDITOR` changes the digest,
  because both are declarations. Unset and explicitly empty `JAILBOX_EDITOR`
  produce the same digest, while a non-empty override produces a distinct
  digest.
- `up` and bare `jailbox` produce the *same* digest from identical
  configuration. This is the launch-side reproducibility property the design
  depends on. Plan 5 owns the corresponding assertion that `exec` attaches to
  either sandbox, because `exec` does not exist at order 4.0.
- With `EDITOR` and `JAILBOX_EDITOR` both unset, changing which editor is
  discoverable on `PATH` does not change the digest.
- The digest implementation has a focused test entry point that computes it
  with no editor discovery or launch-derived state initialized and produces the
  same result as both launch modes. Plan 5 repeats this through the real attach
  command once that consumer exists.
- Adding a host to `EGRESS_ALLOW` changes the digest; reordering `EGRESS_ALLOW`
  without changing its members does not.
- Reordering `READONLY_PATHS` without changing its members *does* change the
  digest, because path arrays are hashed in declared order.
- A launched development container carries a non-empty `jailbox.config-digest`
  label.
- After plan 2's read-only sandbox-absence check, bare launch and `up` fail
  clearly before digest computation or any launch mutation when neither
  `sha256sum` nor `shasum` is available. `init`, `stop`, `doctor`, `ssh-config`,
  `--clean`, and `--uninstall` retain their lighter requirements. Plan 5 owns
  the attach-command assertion.

Run `tests/run portable`, and `tests/run runtime` where Podman is available to
confirm the label reaches the container.

## Non-goals

- Comparing the digest or refusing to attach; `05-exec-command-plan.md` owns
  enforcement.
- Hashing image content, build context contents, or jailbox's own source.
- A reuse digest over derived runtime state.
