# Automatically refresh floating development images

## Goal

Keep mutable `DEV_IMAGE` references current by default. Users who require
reproducible inputs can select an immutable digest reference such as
`node:22@sha256:...`.

`--clean` is not an image-refresh mechanism: it removes project containers,
networks, the home volume, and SSH state, but does not remove or pull Podman
images.

## Behavior

Before validating the development image or building the jailbox wrapper:

1. Resolve the locally cached image identity, if it exists.
2. Pull the configured `DEV_IMAGE` when it is eligible for registry refresh.
3. Resolve the resulting image identity.
4. Warn when an existing image changed.
5. Build the wrapper from the refreshed identity.

An initial pull is normal and does not produce an update warning. An unchanged
pull should be quiet beyond the normal status message. When a tag moves, report
both identities and explain how to opt into reproducibility:

```text
⚠️  Dev image updated: node:22
    previous: sha256:abc123…
    current:  sha256:def456…
    Use a digest-qualified DEV_IMAGE for reproducible builds.
```

The wrapper build must actually use the identity resolved after the pull. Do
not rely on an unverified assumption that Podman's cached `FROM` resolution was
invalidated.

## Pull failures

Automatic refresh is best-effort so jailbox remains usable offline:

- If the pull succeeds, use the refreshed image.
- If the pull fails and a local image exists, warn and continue with that
  cached identity.
- If the pull fails and no local image exists, fail clearly.

The fallback warning must say that freshness was not verified and identify the
cached image being used.

## Immutable and local references

Digest-qualified references may still be resolved or pulled, but their content
cannot silently move and they should not produce an update warning.

`DEV_IMAGE` can also name an image built only on the host. Do not make such an
image unusable merely because no registry copy exists. Define a small,
documented eligibility rule for automatic registry refresh; at minimum,
`localhost/...` references remain local-only. If a broader override proves
necessary, design it separately rather than adding an ambiguous pull-mode key
preemptively.

## Tests

- With no local image, a successful pull supplies the wrapper base.
- Pulling an unchanged floating tag retains the same identity without an update
  warning.
- When a floating tag moves, jailbox reports the old and new identities and the
  wrapper contains content from the new base.
- A digest-qualified reference remains stable and produces no update warning.
- A failed pull with a cached image warns and continues with that exact image.
- A failed pull without a cached image fails clearly.
- A local-only image launches without requiring a registry copy.

Run the portable gate and, because this changes image selection and wrapper
construction, the runtime gate wherever Podman is available.
