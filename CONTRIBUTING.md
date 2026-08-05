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

```bash
tests/run portable   # ShellCheck, unit tests, packaging, and installer lifecycle
tests/run runtime    # Container security and headless CLI behavior (Podman)
tests/run editor     # Real Remote SSH editor behavior (Podman + GUI/xvfb)
```

The three commands are independent, self-contained quality gates. Pull requests
must pass the portable and runtime gates; releases also require the editor gate.
Run `tests/run portable` before sending a change, plus `tests/run runtime` when
Podman is available.

## Releases

Releases are initiated manually and gated in CI: `scripts/release.sh`
previews the auto-selected version and pushes an ephemeral `release-request`
tag; the Release workflow re-selects the version, runs the full release gate,
and creates the version tag and GitHub Release only after everything passes.
