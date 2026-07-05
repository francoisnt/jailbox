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
scripts/lint.sh              # shellcheck over all shipped and test scripts
tests/run --unit-tests       # pure-shell unit suites, no podman required
tests/run --core-tests       # + integration and headless e2e (podman required)
tests/run                    # everything, including editor smoke (GUI/xvfb)
```

Run at least `scripts/lint.sh` and `tests/run --unit-tests` before sending a
change; CI runs the full matrix on pull requests and gates releases on it.

## Releases

Releases are initiated manually and gated in CI: `scripts/release.sh`
previews the auto-selected version and pushes an ephemeral `release-request`
tag; the Release workflow re-selects the version, runs the full release gate,
and creates the version tag and GitHub Release only after everything passes.
