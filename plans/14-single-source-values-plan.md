# 14. Single source for repeated values

## Intent

Several values are written by hand in more than one place, so changing one
copy can silently leave another stale. Give each value below one
authoritative declaration that the other users read. Where a copy must remain
because its reader cannot load the source (a standalone installer, a static
workflow matrix, a file built outside jailbox), keep the copy and add a check
that fails when it drifts. This extends the approach already used for
configuration and commands in `src/public-api.sh`.

This plan is independent of the Go series. It assumes the Alpine 3.24 bump
and the `versions.env` cleanup are committed, including the `FROM` rewrites
that `scripts/gen-tested-matrix.sh --write` performs.

### Required changes

1. **Documented configuration defaults.** The Default column of the
   configuration table in `docs/development.md` must match `CONFIG_DEFAULTS`
   for every key with a literal, non-empty default (today `MEMORY_LIMIT`,
   `CPU_LIMIT`, `PIDS_LIMIT`). Extend the existing documented-key check in
   `tests/unit/public-api.sh` (`validate_documented_keys`) to compare those
   values. Descriptive defaults such as "auto-discovered" stay prose.
2. **Project path in the container.** `src/host/core/commands/shell.sh` uses
   `REMOTE_PATH` instead of the literal `/home/jailbox/project`.
3. **Proxy port.** Host code declares the egress proxy port once, in
   `src/host/api-support.sh`, where both the frontend and core read it.
   Replace the literal `8888` in `src/host/core/resources/network.sh`,
   `proxy.sh`, `src/host/core/commands/up.sh`, and
   `src/host/frontend/connection.sh`. The proxy configuration rendered at
   launch (`print_tinyproxy_conf`) writes the `Port` line from that
   declaration; the packaged `src/container/tinyproxy/tinyproxy.conf` no
   longer sets it. Remove `EXPOSE 8888` from the tinyproxy Containerfile. The
   URL check in `jailbox-start` keeps its own port, since it validates
   untrusted input inside the container.
4. **State directory default.** A shared helper in `src/host/api-support.sh`
   resolves `${XDG_STATE_HOME:-$HOME/.local/state}`. It replaces the copies in
   `src/host/core/project/identity.sh`, `src/host/core/project/paths.sh`, and
   `src/host/frontend/editor.sh`. Existing behavior for unset, empty, and
   relative values is unchanged.
5. **Highest managed user ID.** Host code declares 60000 once and uses it in
   `src/host/core/resources/container.sh` and `images.sh`. In the container,
   `src/container/setup.sh` declares it once and passes it to
   `select-user-id.awk`, which no longer contains the number.
6. **SSH port in the container.** Host code declares 2222 once and uses it
   for both the port publication and its inspection check in
   `src/host/core/resources/container.sh`. Remove `EXPOSE 2222` from
   `src/container/Containerfile.wrapper`. The sshd configuration written by
   `setup.sh` keeps its own copy.
7. **ShellCheck version.** `versions.env` declares `SHELLCHECK_VERSION`. The
   two copied ShellCheck install steps in `.github/workflows/test-gates.yml`
   become one script, under `tests/ci/`, that both jobs call and that reads
   the version from `versions.env`. The root `Containerfile` cannot read
   `versions.env`, so it keeps its copy, and a portable test fails when that
   copy differs, like the existing Go series check in
   `tests/unit/release-workflow.sh`.
8. **Release platforms.** A shared list in `scripts/lib/` replaces the
   platform lists in `scripts/build-programs.sh`, `scripts/build-tarball.sh`,
   and `scripts/validate-release.sh`. The installer's `release_platform`
   mapping in `src/install.sh` and the install matrix in
   `.github/workflows/release.yml` keep their copies, and a portable test
   fails when either one names a different set of platforms.
9. **Proxy base image from `versions.env` at build time.** The committed
   tinyproxy Containerfile becomes a template whose base image is a visible
   placeholder for `BASE_IMAGE_ALPINE`, so readers can see it is generated
   and cannot build it directly. `scripts/build-programs.sh` renders it, for
   both checkout and release builds, next to the programs it builds under
   `libexec/`. Jailbox builds the proxy image from the rendered file, using
   `container/tinyproxy/` as the build context. If the rendered file is
   missing, jailbox refuses with the same guidance it gives for missing
   programs. Remove the `FROM` rewrite and its check from
   `scripts/gen-tested-matrix.sh`. `scripts/validate-release.sh` requires the
   rendered file in each release archive.
10. **Project template base image from `versions.env` at build time.** The
    Containerfile that `jailbox init` writes, from
    `src/host/frontend/Containerfile.template`, gets its base image from
    `BASE_IMAGE_DEBIAN` the same way item 9 handles the proxy: a visible
    placeholder in the committed file, rendered by `scripts/build-programs.sh`
    under `libexec/`. The rendered `FROM` keeps the fully qualified registry
    name (`docker.io/library/` followed by the pin), so the written file still
    resolves on hosts without short-name configuration. `jailbox init` copies
    the rendered file; when it needs one and the file is missing, it refuses
    with the guidance item 9 uses. Remove the template's `FROM` rewrite and
    check from `scripts/gen-tested-matrix.sh`. Update
    `tests/unit/frontend-init.sh`, which compares the written file with the
    committed template, and `tests/unit/base-image-updates.sh`, which checks
    both `FROM` rewrites. Each lifecycle matrix worker runs
    jailbox from a private runtime tree in `tests/lib/lifecycle-runtime.sh`
    that links individual `libexec/` entries; include both rendered files
    there.

### Constraints

- The rendering in items 9 and 10 accepts only a single container image reference
  (no whitespace, newlines, or other characters that could add Containerfile
  instructions), and fails the build otherwise.
- Behavior, generated files, and release archives are otherwise unchanged:
  same ports, paths, limits, and image contents.
- Tests keep stating expected values literally. A test is an independent
  check and must not read the value from the code it verifies.
- Front-end code keeps reaching core only through public CLI child processes.
  Shared declarations go in `src/host/api-support.sh`, not in core modules.
- Container paths that Bash and Go both hard-code (`/home/jailbox/project`,
  `/usr/local/lib/jailbox/jailbox-container`,
  `/run/jailbox-sshd/host-commands`) are out of scope. They collapse when
  core moves to Go.

### Acceptance

- For each item, changing the single declaration changes every consumer, or
  a check fails with a message naming the stale copy. Regression tests show
  this for items 1, 3, 7, 8, 9, and 10.
- The proxy and SSH ports, the state directory, and the managed ID range
  behave exactly as before; the dev gate passes, and CI's runtime and matrix
  gates pass.
- A checkout without built programs fails a filtered launch, and a
  `jailbox init` that would write a Containerfile, with the existing "build
  checkout programs" guidance.
- Each release archive contains the rendered proxy Containerfile and project
  template, whose base images match `BASE_IMAGE_ALPINE` and
  `docker.io/library/` followed by `BASE_IMAGE_DEBIAN`.

## Implementation detail

Guidance only; the implementer may choose better mechanisms.

- Item 1: the documented default is the backquoted value in the Default
  column; compare it with the `CONFIG_DEFAULTS` entry for keys whose
  declared default is non-empty.
- Item 3: `proxy.sh` builds its readiness probe as a shell string run in the
  proxy container; pass the port as an argument, as it already does for the
  address.
- Item 5: `awk -v` is enough to pass the limit into `select-user-id.awk`.
- Item 7: the root `Containerfile` names ShellCheck in a `COPY --from` image
  tag, so the check can compare that tag with `v$SHELLCHECK_VERSION`.
- Item 9: `src/libexec/` is already ignored for checkouts. Rendering can
  reuse `build-programs.sh`'s staging and publish-after-success pattern, so a
  failed render publishes nothing.
