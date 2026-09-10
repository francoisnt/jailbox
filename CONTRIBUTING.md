# Contributing to jailbox

## Repository layout

```text
.
├── jailbox                  # Host-side CLI entrypoint
├── host/                    # Host orchestration modules sourced by jailbox
├── container/               # Files copied into wrapper/proxy images
│   ├── Containerfile.wrapper
│   ├── entrypoint.sh        # Wrapper container runtime entrypoint
│   ├── setup.sh             # Wrapper image setup script
│   ├── downloader-proxy-manager.sh
│   └── tinyproxy/
├── scripts/                 # Repository tooling (lint, release, tarball)
├── tests/                   # Unit, integration, and e2e tests
├── install.sh               # Installer for the jailbox bundle
└── README.md
```

The `host/` tree runs on the developer machine. The `container/` tree is
copied into images or executed inside containers. Repository maintenance
commands stay under `scripts/`, and test suites stay under `tests/`.

`host/public-api.sh` declares the public config keys and CLI flags; changes
to it drive release version suggestions (see `scripts/release.sh --help`).

## Linting and tests

Host orchestration and the portable test gate require Bash 4.4 or newer. On
macOS, install it with `brew install bash`. The `jailbox` entrypoint remains
Bash 3.2-parseable through its version guard, and `install.sh` remains Bash
3.2-compatible.

```bash
tests/run            # Every gate in order
tests/run portable   # ShellCheck, unit tests, packaging, and installer lifecycle
tests/run runtime    # Container security and headless CLI behavior (Podman)
tests/run editor     # Real Remote SSH editor behavior (Podman + GUI/xvfb)
```

The three gates are independent, self-contained quality gates. Naming no gate
runs all three in order and stops at the first failing suite; it checks every
gate's prerequisites before the first suite, so a missing Podman or editor
fails immediately rather than after the portable gate. Pull requests must pass
the portable and runtime gates; releases also require the editor gate. Run
`tests/run portable` before sending a change, plus `tests/run runtime` when
Podman is available.

The runtime gate includes `tests/integration/lifecycle-state.sh`, a Linux
constructed-state matrix using the Debian test image and `setsid` for isolated
command groups. It covers damaged resources, refusal non-mutation, interrupted
launch/cleanup, dependency-safe rollback, and actual recovery. Cases live in
`tests/lib/lifecycle-matrix.sh`; mutation-boundary cases extend the same runner
through `tests/lib/lifecycle-runtime-faults.sh`. Read-only diagnostic and attach
interfaces extend the runner's `matrix_observe` hook as they land. Its current
observation log records expectations, not executed diagnostic assertions.

Failure injection uses test-only PATH wrappers and FIFO barriers. Each lifecycle
CLI process is registered in the existing exact-resource ledger before it can
mutate resources; the ledger lives outside the temporary fixture. Logs and
snapshots are retained under `testlog/lifecycle-*`. Permission-sensitive changes
should also be checked with `umask 0002`, alongside the usual `0022`.

## Releases

Releases are initiated manually and gated in CI: `scripts/release.sh`
previews the automatic version and allows a higher bump interactively or with
`--bump patch|minor|major`. It pushes an ephemeral request tag carrying that
minimum; the Release workflow applies it when re-selecting the version, runs
the full release gate, and creates the version tag and GitHub Release only
after everything passes. See [Versions and releases](README.md#versions-and-releases)
for the compatibility policy and manual workflow inputs.
