# 13. Development image compatibility (draft umbrella)

## Intent

Status: draft. This document records what jailbox expects from a project's
development image and is the umbrella for subplans that change or document
those expectations. It does not authorize implementation. Subplans extend this
number (`13.1`, `13.2`, …) and each one is approved separately.

### Context

jailbox should work out of the box with as many project Containerfiles as
possible. It is also opinionated: project code runs without root access,
inside a hardened container whose only startup process is jailbox's SSH
server. Some expectations follow from that design and stay; others are
accidental limits that block ordinary development images.

The question came up while fixing image entrypoints: probes and the wrapper
inherited the base image's `ENTRYPOINT`, which could make a valid image look
broken or stop `jailbox-start` from running. The fix ignores the entrypoint
(section "Entrypoints" explains why that is the safer default), which raised
the broader question of what else jailbox silently requires.

### Goal

Every expectation in the inventory below ends up in exactly one of three
states:

- **Addressed**: a subplan removes or relaxes the limit.
- **Documented**: the limit stays, and the image requirements in
  `docs/development.md` explain it with the recommended workaround.
- **By design**: the limit is part of jailbox's security model or opinionated
  design; it is documented as such and not revisited by subplans.

The "Disposition" column records each decision. Entries the security
invariants in `AGENTS.md` already settle are marked "By design". Other entries
stay "Undecided" with a suggestion in parentheses until a human developer
decides; they are settled before subplans are written for them.

### Expectation inventory

⚠️ marks expectations that are likely to block real projects.

#### 1. Building the project image

| Expectation | Limits projects? | Disposition |
|---|---|---|
| The Containerfile is found automatically, or set with `DEV_CONTAINERFILE` / `DEV_IMAGE`; `DEV_TARGET_STAGE` and `DEV_BUILD_CONTEXT` choose the stage and folder. | — | — |
| ⚠️ jailbox runs only `podman build -t … -f … [--target …] context`. Build arguments (`--build-arg`), build secrets (`--secret`), SSH forwarding during the build, and other build options cannot be passed. | Yes: Containerfiles that need a build argument without a default, or a private-registry token, cannot be built. | Undecided (suggest: Addressed) |
| ⚠️ The image architecture must be `amd64` or `arm64`. | Rarely. | Undecided (suggest: Documented) |

#### 2. What the wrapper build needs from the image

jailbox builds a second image (the "wrapper") on top of the project image to
add SSH and its own user.

| Expectation | Limits projects? | Disposition |
|---|---|---|
| A working `/bin/sh` or `bash`. | Distroless and `scratch` images; expected. | Undecided (suggest: By design) |
| ⚠️ One of `apt-get`, `apk`, `dnf`, `yum`. | Yes: Red Hat minimal images (UBI-minimal, `microdnf`), openSUSE (`zypper`), Arch (`pacman`), Photon/Mariner (`tdnf`), and Nix-based images are refused even though they are dev-friendly. | Undecided (suggest: Addressed) |
| ⚠️ The package manager must work at build time: network access, repositories still online, `apt-get update` succeeds. | Old distributions whose repositories were archived fail. | Undecided (suggest: Documented) |
| ⚠️ OpenSSH server 7.8 or newer (`SetEnv`). | CentOS 7, Ubuntu 16.04, and similarly old bases. | Undecided (suggest: Documented) |
| No existing `jailbox` user or group; a free ID in 1000–60000. | Rarely. | Undecided (suggest: By design) |
| `useradd`/`groupadd` or `adduser`/`addgroup` present. | Rarely. | Undecided (suggest: Documented) |
| jailbox installs `openssh-server`, `bash`, `curl`, `git`, `procps`, `tar`, and runtime libraries (Alpine also gets `gcompat` and `webkit2gtk`), and writes `/etc/ssh/jailbox_sshd_config` and an `/etc/profile.d` file. | Only if the image pins conflicting versions. | Undecided (suggest: Documented) |

#### 3. What happens to the image's instructions

| Instruction | What jailbox does | Limits projects? | Disposition |
|---|---|---|---|
| `USER` | Replaced by the `jailbox` user. | ⚠️ Yes: tools installed under another user's home (`/home/node`, `/home/vscode`, `/root`; for example nvm, pyenv, pipx, per-user rustup) are unreachable. The docs say "install globally". | Undecided (suggest: By design for the replacement; Documented for per-user installs) |
| `ENV` | ⚠️ Lost in every session (SSH builds each session's environment from scratch), except `PATH` when host command forwarding is on. | Yes, very common: in the official `golang` image `go` is not on `PATH`; `JAVA_HOME`, `GOPATH`, `CARGO_HOME`, and `LANG` disappear. | Undecided (suggest: Addressed by `13.1-image-environment-plan.md`, draft) |
| `WORKDIR` | Ignored; the project is always at `/home/jailbox/project`. | ⚠️ Yes: anything that hard-codes `/app`, `/workspace`, or `/src` (scripts, compose files, configuration) breaks. | Undecided (suggest: Addressed) |
| `ENTRYPOINT` / `CMD` | Ignored; only `jailbox-start` (the SSH server) runs. | ⚠️ See "Entrypoints". | Undecided (suggest: Addressed through an opt-in) |
| `EXPOSE`, `HEALTHCHECK`, `STOPSIGNAL` | Ignored; ports are reached through SSH forwarding. | No. | — |

#### 4. The running sandbox

| Expectation | Limits projects? | Disposition |
|---|---|---|
| ⚠️ The system filesystem is read-only. Writable: the home volume, the project, `/tmp` (512 MB), `/run` (64 MB). | Yes: (a) installing globally at runtime fails (`npm i -g`, system `pip install`, `apt install`); (b) images that point a writable cache at a system path break: the official `rust` image (`CARGO_HOME=/usr/local/cargo`) cannot download crates, `golang` (`GOPATH=/go`) cannot download modules. | By design for the read-only system; (a) undecided (suggest: Documented); (b) undecided (suggest: Addressed) |
| ⚠️ Not root: no `sudo`, no added capabilities, `no-new-privileges` disables setuid programs. | By design, but it also breaks entrypoints that use `gosu`/`su-exec` and tools that expect `sudo`. | By design |
| ⚠️ The SSH server is the only process at start: no init system, no background services. | Projects that expect a database or other service started by the image must start it themselves in a session, as a normal user, with its data in the home or `/tmp`. | Undecided (suggest: By design) |
| No container engine inside: no Docker or Podman socket. | Docker-in-docker and testcontainers workflows. | By design |
| Memory, CPU, and process-count limits (configurable). | Large builds with the defaults (4 GB memory, 256 processes). | Undecided (suggest: Documented) |
| In egress mode only HTTP(S) leaves, through the allowlist. | Configuration choice, not an image expectation. | By design |

### Entrypoints

Running the image's entrypoint gains less than it seems. Variables it exports
reach only the SSH server, not sessions, because SSH starts each session with
a fresh environment (the same problem as `ENV`). Only files it writes to
writable places and background processes it starts would carry over.

Entrypoints fall into four kinds:

1. Wrappers that do light setup and then run the given command
   (`exec "$@"`, like `docker-entrypoint.sh` in many official images).
   Running them is harmless, and mostly useless for the reason above.
2. Root-only setup (`chown`, `gosu`, `su-exec`, editing `/etc`). These fail
   under jailbox's non-root, read-only runtime.
3. Starting services, then running the command. The one kind that benefits.
4. Running the app and ignoring the command. This replaces the SSH server, so
   jailbox never starts; in image probes it made the image look shell-less.

Running entrypoints by default would break kinds 2 and 4 to help kind 3, so
jailbox ignores them by default.

### Candidate subplans

Ordered by how many projects each would unblock. Each needs approval before
its subplan is written; several add public configuration keys.

1. Bring image `ENV` into sessions (`13.1-image-environment-plan.md`).
2. Make cache variables that point at read-only system paths work: when the
   image sets `CARGO_HOME`/`GOPATH` under a read-only path, redirect the
   writable part into the home, or at least warn at build time.
3. An optional `DEV_ENTRYPOINT=image` setting that runs the image's entrypoint
   alongside `jailbox-start`, without SSH startup depending on it. Off by
   default, for kind 3 (services) projects.
4. Pass build arguments and secrets to the project image build (for example
   `DEV_BUILD_ARGS`).
5. Support more package managers: `microdnf` first (UBI-minimal), then
   `zypper` and `tdnf`.
6. Let the project choose the mount path, or add a link at the `WORKDIR`
   path, for projects that hard-code `/app` or `/workspace`.
7. Document the remaining limits (per-user tool installs, runtime global
   installs, no services, old OpenSSH) in the image requirements in
   `docs/development.md`, each with its workaround.

### Acceptance

The umbrella is complete when every inventory entry has a disposition other
than "Undecided", every "Addressed" entry's subplan is implemented, and the
image requirements in `docs/development.md` describe every "Documented" and
"By design" entry.

## Implementation detail

Inventory facts were taken from `src/container/setup.sh`,
`src/container/Containerfile.wrapper`, `src/container/runtime/bin/jailbox-start`,
`src/host/core/resources/images.sh`, and `src/host/core/resources/container.sh`.
Recheck them against the tree when writing each subplan.
