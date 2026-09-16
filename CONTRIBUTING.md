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
Help, parsing, configuration assignment, digest membership, and lifecycle command
selection derive their lists from these declarations. Command handlers, option
targets, defaults, and digest array ordering
must provide complete mappings; omissions fail explicitly. The portable gate
checks these contracts and README configuration-key coverage. After changing
command help or membership, run `bash scripts/gen-public-api.sh --write` to
refresh the generated command reference.
Declare sandbox lifecycle commands in `CLI_LIFECYCLE_COMMANDS` and other
commands in `CLI_OTHER_COMMANDS`; the lifecycle matrix consumes the former
directly. These describe command responsibilities, not dispatch sequences.
Each lifecycle command also needs a test contract and fault scenarios in
`tests/lib/lifecycle-contracts.sh`. Contracts define state outcomes, recovery,
and independent required operations; share one only for equivalent behavior.
Scheduling fails for missing mappings or unsupported scenarios. Individual
interruption points continue to come from healthy execution traces.
The matrix covers selected tool-call boundaries, not every internal write,
image build/pull step, rollback step, or possible timing interaction. Restart
and plain-network scenarios target their distinct operations; proxy-file
publication and recovery are additionally checked in portable unit tests.

Use `public_api_validate_mapping LABEL DECLARATIONS MAPPING` for completeness
checks. It accepts associative maps or arrays of `KEY=value` records, rejects
missing/unknown/duplicate names and empty values, and accepts `allow-empty` as
the fourth argument for defaults. Keep value-specific checks with the consumer.

## Linting and tests

Host orchestration and the portable test gate require Bash 4.4 or newer. On
macOS, install it with `brew install bash`. The `jailbox` entrypoint remains
Bash 3.2-parseable through its version guard, and `install.sh` remains Bash
3.2-compatible.

```bash
tests/run            # Every gate in order
tests/run portable   # ShellCheck, unit tests, packaging, and installer lifecycle
tests/run runtime    # Container security and headless CLI behavior (Podman)
tests/run matrix     # Full lifecycle state and interruption matrix (Linux + Podman)
tests/run editor     # Real Remote SSH editor behavior (Podman + GUI/xvfb)
```

The four gates are independent, self-contained quality gates. Naming no gate
runs all four in order and stops at the first failing suite; it checks every
gate's prerequisites before the first suite, so a missing Podman or editor
fails immediately rather than after the portable gate. Pull requests must pass
the portable, runtime and matrix gates; releases also require the editor gate. Run
`tests/run portable` before sending a change, plus `tests/run runtime` when
Podman is available.

The full lifecycle matrix runs independently in PR, release and canary CI.
Run it locally with `tests/run matrix`; it prepares only the required Debian
images before running
`tests/integration/lifecycle-state.sh`, a Linux constructed-state matrix using
the Debian test image and `setsid` for isolated command groups. It covers
damaged resources, refusal non-mutation, interrupted launch/cleanup, dependency-safe rollback, and actual recovery. Cases live in
`tests/lib/lifecycle-matrix.sh`; mutation-boundary cases extend the same runner
through `tests/lib/lifecycle-runtime-faults.sh`. Read-only diagnostic and attach
interfaces extend the runner's `matrix_observe` hook as they land. Its current
observation log records expectations, not executed diagnostic assertions.

Case labels separate the 144 matrix command cases, seven discovery traces,
13 targeted failures, and interruption cases numbered within each trace.
An interactive terminal shows one updating progress line beneath case output,
with completed/total counts by type and overall, clipped to the terminal width.
Redirected output, CI, and saved worker logs keep plain timestamped progress
records. Terminals with `TERM=dumb` use the same plain format. Totals marked `known` grow as traces discover interruption points;
they become final when all seven discovery cases complete. Case numbers are
catalog positions, so parallel workers can start them out of order.

The lifecycle suite automatically sizes its worker pool at startup using
process-available CPUs and Linux available memory, reduced by visible cgroup-v2
CPU quotas and memory headroom. It budgets two CPUs and 2 GiB per worker,
reserves 1 GiB of memory, and selects between one and 16 workers. These are
conservative scheduling estimates, not measured per-worker consumption or
memory reservations. Unknown memory or cgroup layouts fall back to one worker.
The startup log reports the selection and detected resources. The pool stays
fixed for the run. Each worker owns
its project, derived SSH port, resources, state directory, logs, and ledger.
It runs each claimed row's three commands on independently reconstructed state;
each interruption group discovers and tests its trace on the same worker.
Fixture reset removes mutable resources directly and retains derived
images for the build cache. Actual `--clean` cases still remove and verify image
names. Final image cleanup waits until all workers and their CLI owners stop.

Set `JAILBOX_LIFECYCLE_JOBS=1` for a serial comparison, or `=4` to measure four
workers (accepted range: 1–16). The suite retains every case at every worker
count. Each run writes sorted `completed-cases`, per-case `case-timings`, and
per-job `timings` files under its `testlog/lifecycle-*` directory. A full run also
writes `run-summary` with worker count, exit status, and elapsed seconds including
worker setup and final cleanup, excluding image preparation. It verifies
completed jobs and cases against the catalog and discovered fault points before
passing. Compare `completed-cases` between runs to check coverage as well as
elapsed time. `JAILBOX_LIFECYCLE_TIMINGS=/absolute/path/to/previous/timings`
prioritizes previously slow jobs; idle workers claim the next available job.
Without history, interruption groups start first, followed by the inspection job
and rows. History changes only order.

For a short before/after performance comparison, prepare the Debian images once
and run the opt-in 50-case sample with a fixed worker count:

```bash
tests/integration/wrapper-images.sh --prepare-only debian
JAILBOX_LIFECYCLE_JOBS=8 tests/integration/lifecycle-state.sh --sample-50
```

The sample selects the first 50 constructed state/command cases in declaration
order, including only the selected commands of the last row. It schedules those
rows in a fixed order, without timing-history reordering. Workers may finish them
in a different order. Each case retains its complete setup, assertions, recovery,
and cleanup. Discovery traces, interruption sweeps, and targeted fault scenarios
are outside this sample; passing it does not mean the matrix gate passed.
`tests/run matrix` continues to run the full matrix.

The `absent.stop` case requires status to remain `absent`: stopping a project
with no sandbox resources must not report a stopped container.

For a larger sample, use `--sample-150`: all 144 constructed state/command cases
plus the six home-inspection failure cases. The inspection job starts first to
avoid leaving its longer workload until other workers finish. It retains the
same assertions and cleanup, and excludes discovery traces and interruption sweeps. The selection
fails explicitly if catalog changes no longer fit these 150 cases. Compare runs
with the same sample size; a 150-case run is not comparable to a 50-case run.

Save each run's log directory. Compare `completed-cases` to confirm identical
membership, `sample-summary` for worker count, exit status, and elapsed seconds
including worker setup and cleanup, and `case-timings` for individual cases.
Image preparation is outside the sample timing. Keep the worker count, host
resource limits, and image preparation the same for both versions. Run a warm-up
sample, then two measured samples per version; compare the spread as well as the
elapsed times. This measures this sample's speed, not the whole matrix's speed.

Failure injection uses test-only PATH wrappers and FIFO barriers. Each lifecycle
CLI process is registered in the existing exact-resource ledger before it can
mutate resources; the ledger lives outside the temporary fixture. Logs and
snapshots are retained under `testlog/lifecycle-*`. Permission-sensitive changes
should also be checked with `umask 0002`, alongside the usual `0022`.

All test-gate output and saved diagnostic logs carry UTC timestamps with
one-second resolution. Buffered stage logs retain their capture timestamps when
replayed. Gate summaries report elapsed seconds for each suite and the gate;
timestamped lifecycle `CASE` lines locate time spent constructing and exercising
each case. Machine-readable snapshots, fault-event records, and assertion inputs
retain their original formats. Timestamps indicate when output was read; tools
that buffer their own output can delay individual lines.

## Releases

Releases are initiated manually and gated in CI: `scripts/release.sh`
previews the automatic version and allows a higher bump interactively or with
`--bump patch|minor|major`. It pushes an ephemeral request tag carrying that
minimum; the Release workflow applies it when re-selecting the version, runs
the full release gate, and creates the version tag and GitHub Release only
after everything passes. See [Versions and releases](README.md#versions-and-releases)
for the compatibility policy and manual workflow inputs.
