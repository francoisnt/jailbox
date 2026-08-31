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

Two inputs beyond the public config keys must be included explicitly, because
neither is a member of `CONFIG_SCALAR_KEYS` or `CONFIG_ARRAY_KEYS`:

- the canonical selected-config identity; and
- the effective `JAILBOX_EDITOR` override.

`01.1-init-config-plan.md` makes an absent selected config unreachable for every
launch and attach command, so the digest has no absent-config marker or
defaults-only state.

### Only declared inputs, never launch-derived state

Every digest input must be reproducible from configuration and environment
alone, by any command, without knowing how the sandbox was launched. `exec`
performs no editor discovery, so it cannot observe a resolved `EDITOR_BIN` or
the editor bootstrap hosts `effective_egress_allowlist` (`host/network.sh`)
appends from one. Hashing either would make `exec` compute a "no editor" digest
and reject every sandbox bare `jailbox` created, with no configuration change at
all — breaking the primary workflow, where an editor session and `exec` run side
by side against one sandbox.

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
editor-override NUL inactive NUL
```

When a non-empty `JAILBOX_EDITOR` override is active, replace the final record
with `editor-override NUL active NUL VALUE NUL`. An unset and explicitly empty
`JAILBOX_EDITOR` are equivalent because `${JAILBOX_EDITOR:-$EDITOR}` gives them
identical behavior. Scalar and array keys are emitted in their declaration
order from `host/public-api.sh`; an empty scalar still has its terminating NUL,
and an empty array has count zero and no item records. Encode `COUNT` as
canonical unsigned decimal with no leading zeroes except `0`; emit each item as
the repeated `value NUL ITEM NUL` record shown above. Stream records directly to
the hash command; never store the NUL-containing serialization in a Bash
variable.

The canonical selected-config path is the classified absolute path used for
that invocation. This intentionally distinguishes two selected files with the
same parsed values.

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

- Compute the digest from parsed configuration and environment only. It must not
  read `EDITOR_BIN`, the output of `effective_egress_allowlist`, or any other
  value produced by the launch path, so that every command computes the same
  digest from the same declaration regardless of how it dispatches.
- Implement the exact versioned NUL-delimited serialization and portable
  SHA-256 selection above. Validate the normalized digest before adding it to a
  Podman label or comparing it.
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
- Changing a non-empty `JAILBOX_EDITOR` or changing `EDITOR` changes the digest,
  because both are declarations. Unset and explicitly empty `JAILBOX_EDITOR`
  produce the same digest, while a non-empty override produces a distinct
  digest.
- `up` and bare `jailbox` produce the *same* digest from identical
  configuration, and `exec` attaches to either. This is the reproducibility
  property the design depends on: assert it directly, because it is the
  regression that would make `exec` unusable alongside an editor session.
- With `EDITOR` and `JAILBOX_EDITOR` both unset, changing which editor is
  discoverable on `PATH` does not change the digest.
- The digest is identical whether computed on the launch path or by a command
  that never runs editor discovery.
- Adding a host to `EGRESS_ALLOW` changes the digest; reordering `EGRESS_ALLOW`
  without changing its members does not.
- Reordering `READONLY_PATHS` without changing its members *does* change the
  digest, because path arrays are hashed in declared order.
- A launched development container carries a non-empty `jailbox.config-digest`
  label.
- Launch and attach fail clearly before Podman inspection or mutation when
  neither `sha256sum` nor `shasum` is available.

Run `tests/run portable`, and `tests/run runtime` where Podman is available to
confirm the label reaches the container.

## Non-goals

- Comparing the digest or refusing to attach; `05-exec-command-plan.md` owns
  enforcement.
- Hashing image content, build context contents, or jailbox's own source.
- A reuse digest over derived runtime state.
