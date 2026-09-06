# Repository split and language rationale

Decision record, September 2026. This document explains three decisions that
shaped the 03.2 plan series: splitting the project into jailbox and JailIDE,
implementing JailIDE in Go, and keeping jailbox in Bash. It also records why
the planned shared shell release toolkit was retired. The addendum at the end
records the later deferral of the split itself; the sections before it are
kept as the rationale that will apply if the split is revived. It is
rationale, not an implementation plan; the numbered plans remain normative.

## Why split into jailbox and JailIDE

The project serves two audiences with different needs and different rates of
change:

- **Machines.** Orchestrators, scripts, and agents need a sandbox substrate
  with a strict, minimal, stable contract: environment-only configuration,
  deterministic identity, machine-readable schemas (`config-schema`,
  `status`, `connection-info`), and no interactive behavior.
- **Humans.** A developer wants a config file, `init`, editor discovery,
  profiles, and a one-command launch into VS Code or VSCodium.

Keeping both in one product forces the security-critical core to carry editor
discovery, profile generation, bootstrap composition, and configuration-file
parsing — surface that grows with editor churn, not with sandbox policy.
Splitting them:

- shrinks the core that must be security-reviewed to lifecycle, filesystem
  and egress policy, SSH, and identity;
- lets the human workflow evolve (editors, profiles, UX) without touching or
  re-releasing the sandbox boundary;
- makes the machine interface a first-class product rather than an internal
  detail, so third-party orchestrators are supported by construction; and
- keeps the runtime dependency one-directional: JailIDE drives jailbox only
  through its installed executable and documented interfaces, exactly like
  any other caller.

The interfaces between the products are deliberately language-neutral —
environment variables, TAB-separated schema records, NUL-delimited
connection records — which is what makes the rest of this document possible.

## Why JailIDE is written in Go

JailIDE is greenfield: at the time of this decision no standalone JailIDE
code exists, so there is nothing to port and no rewrite cost. The choice is
only about the best tool for what JailIDE is, and JailIDE is data-heavy:
strict config parsing, schema discovery and validation, deterministic
environment composition, NUL-delimited record parsing, editor settings
generation. In Bash, each of those requires elaborate defensive conventions
(indexed environment arrays with gap detection, refusing to hold NUL bytes
in variables, adversarial quoting tests) because the language makes
data-becomes-code the ambient hazard and has no real data structures. In Go
they are ordinary code with types, real argv handling, and a standard test
harness. For the same reason JailIDE does not inherit jailbox's shell-era
`KEY=value` config grammar: `jailide.toml` is standard TOML restricted to
string values by ordinary schema validation, so its strictness is a property
of the format itself rather than a documented custom dialect, and a Go
library parses it trivially.

Go also gives JailIDE:

- a single static binary per platform, which simplifies installation, update,
  and checksum verification, and removes the macOS Bash 3.2 constraint from
  the human-facing product entirely;
- a far lower barrier for outside contributors and for user trust in a
  young project; and
- a structural check that keeps jailbox's machine boundary honest: a Go
  consumer cannot source shell modules in-process, so every interaction
  must go through the installed executable and documented interfaces. The
  boundary itself is enforced by those contracts and their tests; JailIDE
  is their reference consumer and doubles as the reference implementation
  of the orchestrator story.

The only shell that remains in JailIDE is the editor-dependency setup script,
which must stay POSIX `sh` because it executes inside arbitrary container
base images.

## Why jailbox stays Bash, for now

jailbox is the opposite shape: it is mostly process orchestration —
constructing and running `podman` and `ssh` invocations — which is shell's
home ground, and its host code already exists, works, and carries the
project's accumulated security review. A rewrite would re-open every settled
invariant for months without changing what users get, and the enforcement
users actually rely on (namespaces, read-only roots, dropped capabilities,
proxy-only egress) lives in Podman and the kernel, not in the launcher's
language.

Shell transparency also has genuine product value for this specific tool.
jailbox's premise is "do not trust code running on your machine"; its
audience is exactly the crowd that wants to read what it is about to grant
power to. With shell, the installed artifact is the source: no build step,
no binary-to-source gap, patchable in place by any user, and a dependency
surface of exactly bash, podman, and ssh. That transparency is a trust aid,
not a verification guarantee — Bash is easy to read and hard to audit — so
it earns its keep only while the host code stays small enough for one
careful reader to hold.

That is also the honest limit of the decision: it is "for now". The tipping
point is protocol complexity, not line count. If the roadmap forces jailbox
to keep growing framed binary protocols, encoders, and generated parsers in
Bash, the transparency being preserved is buried under exactly the machinery
that makes shell unreadable, and porting the host side to Go becomes the
better trade. Container-side scripts (`entrypoint.sh`, `setup.sh`) stay
POSIX `sh` regardless, because they run inside arbitrary images.

## Why the shared shell toolkit was retired

Earlier planning (archived plan 03.2.10) extracted jailbox's packaging,
installer, SemVer, and input-parsing mechanics into a shared shell toolkit
(prototyped as Shellship) so jailbox, JailIDE, and future shell products
could delete duplicated tooling. That justification depended on JailIDE
being a second Bash consumer. With JailIDE in Go:

- JailIDE gets packaging, releases, testing, and CLI/config handling from
  the standard Go ecosystem, which does this better than any bespoke shell
  toolkit could;
- jailbox is the toolkit's only remaining consumer, and a shared toolkit
  with one consumer is indirection, not reuse — jailbox simply keeps its
  own `install.sh`, `scripts/build-tarball.sh`, and `scripts/release.sh`;
  and
- the largest planned piece, a generated input runtime, was effectively a
  small compiler written in Bash to compensate for Bash — exactly the
  complexity the language decision removes.

The prototype is archived, not deleted; if a second real Bash product ever
appears, its plans remain a usable starting point. Retiring it now avoids
maintaining a product whose reason to exist has collapsed.

## Consequences accepted

- Two toolchains and two release pipelines for one maintainer. Accepted:
  each is the boring, well-supported default for its language.
- No code sharing between the products, ever; shared behavior must be
  expressed in jailbox's machine interfaces or duplicated deliberately.
  Accepted: this keeps the boundary honest and is enforced by the language
  split itself.
- jailbox continues paying the Bash rigor tax (strict quoting, adversarial
  input tests, portability discipline) for its remaining scope. Accepted
  while the core stays small; revisited at the tipping point above.

## Addendum: the split is deferred (September 2026)

The 03.2 series now builds the machine/human boundary inside one repository
and one installed command instead of two products; the charter is
`plans/03.2-machine-boundary-plan.md`. What changed in the assessment: the
valuable content of the split was always the interface — environment-only
configuration, the compatibility digest, deterministic identity,
`config-schema`, `status`, `connection-info` — and all of it lands
regardless. The editor workflow is restructured as a frontend layer that
reaches core only by executing the public CLI as child processes (plan
03.2.11), which makes it the reference consumer the split promised, at a
process boundary instead of a repository boundary. Meanwhile the split's
costs were concrete and immediate — two release pipelines, artifact-boundary
test harnesses, version-range machinery, a coordinated dual release, and the
generic `WRAPPER_SETUP` trusted-script mechanism whose only planned consumer
was JailIDE's single embedded script — while its benefits scale with
orchestrator adoption; the planned first-party orchestrator consumes the
machine interface identically whether the frontend lives in-repo or out, so
it does not require the split. That is the same shape of justification that
retired the shared shell toolkit above.

Deferred with the split: the JailIDE repository, the Go implementation,
`jailide.toml`, the `WRAPPER_SETUP` mechanism (editor-server packages stay in
core's generic wrapper contract), and the coordinated release. Plans 03.1.1
and 03.2.11–03.2.15 are archived as deferral stubs whose full text is
preserved in git history at `9a04def`.

Revival triggers, any one of which reopens the decision:

- a third-party orchestrator (beyond the planned first-party one) consuming
  the machine interface in earnest;
- editor churn that forces core releases despite the layering; or
- the human-facing surface outgrowing Bash — the same protocol-complexity
  tipping point recorded above for jailbox itself.

Because the boundary is enforced now, extraction later is mechanical: the
frontend already speaks only the interfaces a standalone JailIDE would.
