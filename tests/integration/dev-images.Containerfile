# Test dev images for the jailbox integration test suite.
# Each stage is a plain OS base that tests/integration/wrapper-images.sh wraps with
# container/Containerfile.wrapper and exercises a distinct scenario.

# Base image pins live in versions.env; wrapper-images.sh passes them as build
# args. Defaults here must match (checked by scripts/gen-tested-matrix.sh --check).
ARG BASE_IMAGE_DEBIAN=debian:12
ARG BASE_IMAGE_ALPINE=alpine:3.21
ARG BASE_IMAGE_FEDORA=fedora:41

# ── OS matrix ────────────────────────────────────────────────────────────────
# These three stages verify that container/setup.sh works across all supported
# package managers (apt-get, apk, dnf). No user is pre-created; setup.sh creates
# one.

FROM ${BASE_IMAGE_DEBIAN} AS debian

FROM ${BASE_IMAGE_ALPINE} AS alpine

FROM ${BASE_IMAGE_FEDORA} AS fedora

# ── Arbitrary existing user conflict ──────────────────────────────────────────
# The host UID already belongs to a non-managed image user. container/setup.sh
# must fail instead of renaming, reusing, or chowning that user's files.
FROM ${BASE_IMAGE_DEBIAN} AS uid-owned-by-other-user
ARG HOST_UID=1000
RUN useradd -m -u "${HOST_UID}" -s /bin/bash appuser

# ── Managed user conflict ────────────────────────────────────────────────────
# jailbox pre-exists. container/setup.sh must fail clearly instead of reusing
# or mutating that user.
FROM ${BASE_IMAGE_DEBIAN} AS user-conflict
RUN useradd -m -u 1234 -s /bin/sh jailbox
