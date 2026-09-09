# Automatically refresh floating development images

## Intent

### Goal

Keep mutable `DEV_IMAGE` references current during new generation builds.
Users who require reproducible inputs can select an immutable digest reference such as
`node:22@sha256:...`.

`--clean` is destructive cleanup, not an image-refresh mechanism. Under
03.2.04 it removes runtime state, the home, and the three exact project-derived
image names. It does not pull images and leaves external `DEV_IMAGE` references
untouched unless they deliberately use one of those derived names. Refresh
must not require deleting the home.

### Sequence and lifecycle integration

Implement after `03.2.06-constrained-up-plan.md`, using the cleanup contract
in `03.2.04-home-volume-lifecycle-plan.md`. This recommendation owns integration
and verification of registry refresh during new generation builds. The 03.2
series does not depend on automatic registry refresh shipping.

Resolve the registry result before building a new development generation.
Existing containers are reused or resumed without pulls, builds, or image
comparison. To incorporate new images, users explicitly run `jailbox stop`
followed by the original launch command under the intended policy. Never
automatically stop, replace, or repair the sandbox. Explain that stop preserves
persistent homes and deletes ephemeral homes according to recorded policy.
Retain 03.2.06's home-aware recovery precedence for incompatible state.

Image building may update the image cache, but compatibility refusal preserves
pre-existing containers, networks, home contents, and SSH material.
Attachment-only commands never pull or build images.

### Behavior

Resolve refresh before development-image validation and wrapper construction;
construct the wrapper from that result for the new generation.

An initial pull is normal and does not produce an update warning. An unchanged
pull should be quiet beyond the normal status message. When a tag moves, report
the image reference and previous/current identities, and explain how to opt
into reproducibility with a digest-qualified reference.

The wrapper build must actually use the identity resolved after the pull. Do
not rely on an unverified assumption that Podman's cached `FROM` resolution was
invalidated.

### Pull failures

Automatic refresh is best-effort so jailbox remains usable offline:

- If the pull succeeds, use the refreshed image.
- If the pull fails and a local image exists, warn and continue with that
  cached identity.
- If the pull fails and no local image exists, fail clearly.

The fallback warning must say that freshness was not verified and identify the
cached image being used.

### Immutable and local references

Digest-qualified references may still be resolved or pulled, but their content
cannot silently move and they should not produce an update warning.

`DEV_IMAGE` can also name an image built only on the host. Do not make such an
image unusable merely because no registry copy exists. Define a small,
documented eligibility rule for automatic registry refresh; at minimum,
`localhost/...` references remain local-only. If a broader override proves
necessary, design it separately rather than adding an ambiguous pull-mode key
preemptively.

### Acceptance criteria

- With no local image, a successful pull supplies the wrapper base.
- Pulling an unchanged floating tag retains the same identity without an update
  warning.
- When a floating tag moves, jailbox reports the old and new identities and the
  wrapper contains content from the new base.
- A digest-qualified reference remains stable and produces no update warning.
- A failed pull with a cached image warns and continues with that exact image.
- A failed pull without a cached image fails clearly.
- A local-only image launches without requiring a registry copy.
- Explicit stop and relaunch uses the selected registry or cached image and
  applies recorded persistent/ephemeral home retention correctly.
- Ordinary running reuse and stopped resume perform no builds or pulls;
  partial creation builds only images needed for missing containers.
- Attachment-only commands perform no refresh or image construction.
- Documentation explains explicit rebuilds and home retention without
  recommending destructive clean as an image-refresh operation.

### Non-goals

- Automatic removal of superseded images, including dangling base images, is outside refresh scope.

## Implementation detail

### Suggested refresh procedure

1. Resolve the locally cached image identity, if it exists.
2. Pull the configured `DEV_IMAGE` when it is eligible for registry refresh.
3. Resolve the resulting image identity.
4. Warn when an existing image changed.
5. Build the wrapper from the refreshed identity.

Illustrative warning; exact wording and formatting are implementation guidance:

```text
⚠️  Dev image updated: node:22
    previous: sha256:abc123…
    current:  sha256:def456…
    Use a digest-qualified DEV_IMAGE for reproducible builds.
```

### Verification

Extend portable and real-Podman lifecycle coverage with controlled mutable
image references and pull failures. Verify actual wrapper base and container
image identities. Cover new generation builds through machine and frontend
launch, including explicit stop then up. Verify reuse performs no pulls or
builds and preserves surviving containers and SSH credentials.

Run the portable gate and, because this changes image selection and wrapper
construction, the runtime gate wherever Podman is available.
