# Contributing to jailbox

Start with [Understanding jailbox](ARCHITECTURE.md) for the lifecycle,
core/frontend responsibilities, security concepts, testing strategy, and
glossary. The guide describes the implemented frontend and machine boundary.

## Repository layout

```text
.
├── src/
│   ├── jailbox              # Host CLI entrypoint
│   ├── install.sh           # Installer for the jailbox bundle
│   ├── public-api.sh        # App-wide declarations only
│   ├── host/                # Shared CLI/API helpers, frontend/, and core/
│   └── container/           # Files copied into wrapper/proxy images
├── scripts/                 # Repository tooling (lint, release, tarball)
├── tests/                   # Unit, integration, and e2e tests
└── README.md
```

Run the checkout CLI as `src/jailbox`, or install it with `bash src/install.sh`.
Releases flatten `src/` into the bundle root and add `README.md`; maintenance
scripts and tests do not ship.

The `src/host/` tree runs on the developer machine. The `src/container/` tree is
copied into images or executed inside containers. Repository maintenance
commands stay under `scripts/`, and test suites stay under `tests/`.
Add installed wrapper helpers to `src/container/runtime/bin/` and library data to
`src/container/runtime/lib/jailbox/`. Setup discovers files recursively, installing
programs as 0755 and library files as 0644; no Containerfile entry is needed.

`src/public-api.sh` declares the public config keys and CLI flags; changes
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

Test ownership follows the behavior being asserted. The editor gate covers
real editor integration and relies on public core readiness checks. Runtime
and matrix own core SSH, networking, proxy enforcement, and sandbox-security
assertions; do not repeat those checks in editor tests. Portable combines
frontend contracts, core contracts, and shared declaration, boundary,
packaging, and installation checks in one gate.

Host orchestration and the portable test gate require Bash 4.4 or newer. On
macOS, install it with `brew install bash`. The `jailbox` entrypoint remains
Bash 3.2-parseable through its version guard, and `src/install.sh` remains Bash
3.2-compatible.

The macOS portable gate also needs GNU coreutils and findutils. Run
`bash tests/ci/setup-portable.sh` to install the test dependencies; for local
runs, put their Homebrew `libexec/gnubin` directories on `PATH`.

All four gates require Python 3: portable, runtime, and matrix use it for
bounded pseudoterminal tests, and editor uses it to package the proof extension.
The CI setup scripts install it; jailbox itself does not require Python.
Lint, portable unit suites, runtime stages, editor stages, and the lifecycle
matrix share a Bash process pool
and resource detection. Worker counts adapt to available CPUs and memory,
including Linux affinity/cgroup limits and macOS available-page estimates.
Unknown resource data selects one worker; all pools have a ceiling of 16.
Lint budgets one CPU and 1.5 GiB per worker, with 512 MiB reserved; portable units
budget one CPU and 256 MiB per worker with the same reserve. The matrix retains
its two-CPU/2-GiB allowance and 1-GiB reserve. Runtime stages use the same
allowance; editor stages budget two CPUs and 4 GiB with a 1-GiB reserve. Runtime
and editor allowances are conservative starting estimates pending measurements
on a Podman host, including build processes, containers, and editor descendants.
These are scheduling estimates,
not enforced limits. Two fixed-concurrency ShellCheck samples peaked at
1.21–1.24 GiB for the entrypoint; sampled complete unit-suite process trees
peaked at 16–35 MiB. Larger or changed workloads may require revisiting these
allowances.

The portable lint driver (`scripts/lint.sh`) shows a single updating terminal
progress line, occasional progress snapshots
in redirected output, and grouped diagnostics. Detailed batch timings and output
remain in the reported `testlog/shellcheck.*` directory. Source analysis and file
discovery remain enabled for every run.

Portable runs lint, generated-file checks, unit suites, and distribution in
that order. Reviewed unit suites in `tests/lib/portable-parallel.txt` run in
parallel, with separate logs and timings under `testlog/portable.*`. New or
unlisted suites run exclusively until their shared paths, ports, external
effects, and nested concurrency have been reviewed. Pool tests run exclusively
because they deliberately create nested workers; distribution remains sequential
because it writes fixed release-artifact paths. A failed suite stops new
scheduling, joins active suites, and prevents subsequent gate phases. Nested
auto-sized tools inherit `JAILBOX_TEST_JOB_LIMIT=1`; that test-only variable can
also cap lint, portable, runtime, or editor concurrency for diagnosis without changing gate modes.

Runtime and editor keep image preparation before dependent tests. Their stage
runners use the shared pool, report compact progress, and retain per-stage logs,
statuses, worker counts, and timings in the reported log directory. Stage logs
carry capture timestamps. Runtime stages also write `<stage>.phases` records
(`phase|elapsed-seconds|exit-status`) covering preparation, launch, assertions,
recovery, and cleanup. These timings include the whole phase, not just CPU work.
Stopped and missing proxy recovery run in the lifecycle matrix; runtime owns
proxy enforcement and frontend launch integration.
SSH forwarding is exercised through the CLI-created sandbox in headless tests;
wrapper contract tests focus on image hardening and startup. VSCodium remote
server bootstrap and attachment, including Alpine, belong to the editor gate.
Portable tests retain simulated failures, declaration propagation, packaging,
and test-harness regressions; matrix tests retain real engine state transitions
and interruption cleanup. Similar assertions at those boundaries are intentional:
a simulated engine cannot establish real resource behavior, and a working SSH
session cannot establish editor task inheritance. Each gate prepares its own
required images so it remains independently runnable.
The full terminal exit-status and direct-signal sequence runs once per runtime
distribution. The later filtered-frontend check retains real login startup,
proxy environment, customization, and changed-policy refusal without repeating
the baseline attachment or terminal mechanics. All selected
stages are attempted and any crash or assertion failure fails the gate. Editor
workers retain their slot through teardown; cache writes retain their existing
locks. Debian contract checks still build from restrictive input permissions;
preparation then retains a normally built `jailbox-wrapper-debian` tag so later
CLI builds can reuse its layers through project cleanup. Preparation-only runs
use normal inputs directly. Runtime and editor fixture allocation reserves SSH ports across each
run, including intervals when stop/reopen tests leave them unbound. Workers
start in fresh Bash processes so coordinator error handling cannot suppress
their errexit behavior. Cancellation joins workers before the coordinator releases shared state.

```bash
tests/run            # Every gate in order
tests/run portable   # ShellCheck, unit tests, packaging, and installer lifecycle
tests/run runtime    # Container security and headless CLI behavior (Podman)
tests/run matrix     # Full lifecycle state and interruption matrix (Linux + Podman)
tests/run editor     # Real Remote SSH editor behavior (Podman + GUI/xvfb)
```

For a specific editor, run `JAILBOX_EDITOR=code tests/run editor` or use
`codium`. This is a test-harness selector: fixtures write the chosen editor to
file `EDITOR`. Product launches never use `JAILBOX_EDITOR` as an override.

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
through `tests/lib/lifecycle-runtime-faults.sh`. The runner's `matrix_observe`
hook asserts status bytes, connection-info outcomes, exec execution/refusal
with binary stdin, and shell attachment/refusal with valid local TTYs for
constructed-state and targeted-failure fixtures. Discovered interruption sweeps
use status and full connection-info validation, retaining every recovery,
identity, data, and dependency assertion without repeating both transports.
Observation records include `full` or `readiness` as their trailing field.
The [core coverage inventory](tests/core-verification.md) maps the assertions
and their negative controls. Fault expectations come from independent surviving-resource and
live-service observations, never the attachment command's verdict.

The `running.up` case also checks eight health variants: writable root, retained capabilities, missing
no-new-privileges, writable protected mount, unexpected socket-path mount,
unresponsive SSH, unresponsive proxy, and an advisory upstream outage.
It executes stop/up recovery for required health failures and checks persistent
home retention. Full resource/filesystem/image comparisons are bounded to
36 observation points, independent of interruption count; every connection,
exec, and shell observer also rejects mutation attempts. The bounded snapshots
include exec and shell, and `running.up` additionally verifies argv, working
directory, exit statuses, and independent concurrent attachments.
The recovered `missing-proxy.up` observation also verifies the command's proxy
environment and absence of an implicit login shell.

The deterministic 50- and 150-case samples retain their declared case membership
and counts. Observations include connection, exec, and PTY shell validation;
`running.up` adds the transport and concurrency assertions described above.
Each SSH defect proves its own refusal and repaired baseline; explicit metadata
and key-content representatives supply the final relaunch proof. Group contracts
must match and their representative must be selected. `recovery-coverage` logs
these assignments. This leaves the 50-case workload unchanged but changes the
150-case workload. Establish a new 150-case baseline or compare exactly shared
work; identical case names do not make old timings comparable. Samples remain partial coverage, never replacements
for the four gates.

Case labels separate the 144 matrix command cases, nine discovery traces,
13 targeted failures, and interruption cases numbered within each trace.
An interactive terminal shows one updating progress line beneath case output,
with completed/total counts by type and overall, clipped to the terminal width.
Redirected output, CI, and saved worker logs keep plain timestamped progress
records. Terminals with `TERM=dumb` use the same plain format. Totals marked `known` grow as traces discover interruption points;
they become final when all nine discovery cases complete. Case numbers are
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
