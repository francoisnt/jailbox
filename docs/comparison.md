# Compare jailbox

[Home](../README.md) · [Development](development.md) · [Automation](automation.md) · [Security](security.md)

Choose by workflow and required protections. These tables compare documented
behavior, not measured performance or an independent security audit.

**Legend:** ✅ supported · ❌ not provided · ⚙️ requires configuration or depends
on deployment · ◐ mixed/limited · **?** not verified · **N/A** not applicable.
A ✅ means the row's statement is true, not that the tool is safer overall.

**Scope:** Dev Containers means the VS Code integration; DevPod means its
community project; Coder means workspaces; Docker Sandboxes means local mode.
Ona is the current product formerly named Gitpod. Sources checked **2026-10-08**.

## Ownership and setup

| Criterion | [jailbox](#jailbox) | [Dev Containers](#dev-containers) | [DevPod](#devpod) | [Codespaces](#codespaces) | [Ona](#ona) | [Coder](#coder) | [Docker Sandboxes](#docker-sandboxes) |
|---|---|---|---|---|---|---|---|
| FOSS | ✅ MIT | ◐ CLI only¹ | ✅ MPL-2.0 | ❌ | ❌ | ◐ AGPL core | ❌ |
| Local execution | ✅ Podman | ✅ | ✅ | ❌ | ◐ deprecated² | ⚙️ deployment | ✅ |
| No vendor account required | ✅ | ✅ local | ✅ local | ❌ | ❌ | ✅ core | ❌ |
| No workspace control service to operate | ✅ | ✅ local | ✅ | ✅ hosted | ✅ hosted | ❌ | ✅ local |
| Use your own image / Dockerfile | ✅ compatible³ | ✅ | ✅ | ✅ | ✅ | ✅ template | ✅ adapted |
| Leaves host editor and SSH configuration unchanged | ✅ separate files | ? | ? | ? | ? | ? | ? |
| Policy configuration cannot execute shell commands | ✅ data only | ? | ? | ? | ? | ? | ? |

1. The specification is open and its reference CLI is MIT-licensed. Microsoft's
   Dev Containers and Remote SSH extensions are proprietary; this also matters
   when choosing an editor for jailbox.
2. Ona documents cloud/VPC runners; its API marks local Linux runners deprecated.
3. jailbox adds an SSH wrapper to a compatible development image. It does not run
   an unchanged production image. See [image requirements](development.md#project-image-requirements).

jailbox's policy configuration is data only; image builds still execute
Containerfile instructions. Its generated editor and SSH settings live separately
from your normal configuration. See [host integration](development.md#how-it-works).

## Isolation and defaults

These rows describe defaults or enforced behavior, not everything a user could
configure. A VM boundary and container restrictions provide different protections.

| Criterion | jailbox | Dev Containers | DevPod | Codespaces | Ona | Coder | Docker Sandboxes |
|---|---|---|---|---|---|---|---|
| Separate kernel per workspace | ❌ shared⁴ | ⚙️ host | ⚙️ provider | ✅ VM | ✅ VM | ⚙️ template | ✅ microVM |
| Read-only root enforced | ✅ | ⚙️ | ⚙️ | ? | ? | ⚙️ | ❌ writable VM |
| All Linux capabilities dropped | ✅ | ⚙️ | ⚙️ | ? | ? | ⚙️ | ❌ different model |
| Privilege escalation disabled | ✅ | ⚙️ | ⚙️ | ? | ? | ⚙️ | ❌ sudo in VM |
| No host engine socket exposed | ✅ enforced | ⚙️ configuration | ⚙️ configuration | N/A laptop | N/A laptop | ⚙️ template | ✅ private engine |
| SSH agent forwarding disabled | ✅ | ❌ automatic | ❌ automatic | ? | ? | ⚙️ | ❌ automatic |
| No automatic host Git credential-helper sharing | ✅ | ❌ | ❌ | N/A laptop⁵ | N/A laptop⁵ | ⚙️ | ? |
| Working project writable | ✅ except anchors | ✅ usual setup | ✅ usual setup | ✅ remote copy | ✅ remote copy | ⚙️ | ✅ direct mode |
| Selected build/config files automatically read-only | ✅⁶ | ? | ? | ? | ? | ⚙️ | ❌ direct mode |
| Refuses reuse when requested policy changes | ✅ | ? | ? | ? | ? | ? | ? |
| Verifies runtime protections before attachment | ✅ | ? | ? | ? | ? | ? | ? |

4. On macOS, Podman adds a Linux VM boundary around its containers. They still
   share that VM's kernel. jailbox's Mac container/editor behavior is unverified.
5. Remote services can supply credentials of their own. Codespaces automatically
   provides a scoped GitHub token and can inject authorized secrets; Ona provides
   source-control and secret integrations. N/A does not mean credential-free.
6. Core protects the selected in-project build file. File-driven launches also
   protect their configuration anchors. Other files require explicit policy.

jailbox's editor launch, `exec`, `shell`, and connection metadata share the same
core attachment checks. These are point-in-time checks: changing configuration
does not revoke existing sessions. See [attachment behavior](automation.md#connection-metadata-and-local-validation).

## Project-file controls

“Hidden” means original contents are inaccessible through the selected runtime
path. It does not mean excluded from image builds or removed from Git history.

| Criterion | jailbox | Dev Containers | DevPod | Codespaces | Ona | Coder | Docker Sandboxes |
|---|---|---|---|---|---|---|---|
| Selected read-only paths | ✅ setting | ⚙️ mounts | ⚙️ mounts | ? | ? | ⚙️ template | ✅ workspace mount |
| Read-only project with writable exceptions | ✅ setting | ⚙️ nested mounts | ⚙️ provider/mounts | ? | ? | ⚙️ template | ? nested paths |
| Hide selected project contents | ✅ setting | ⚙️ overlay mounts | ⚙️ provider/mounts | ? | ? | ⚙️ template | ? |
| Unified read-only / writable / hidden policy | ✅ | ❌ mount recipe | ? | ? | ? | ⚙️ custom template | ? |
| Edit host working tree directly | ✅ | ✅ local mounts | ⚙️ provider | ❌ remote checkout | ❌ cloud checkout | ⚙️ deployment | ✅ direct mode |
| Separate clone with explicit import of edits | ❌ built-in | ⚙️ manual workflow | ? | ⚙️ Git workflow | ⚙️ Git workflow | ⚙️ template | ✅ clone mode |

Mount recipes are building blocks, not verified equivalents to jailbox's path
validation and precedence rules. Docker's filesystem governance controls which
workspace mounts are allowed; it does not document an equivalent to masking
selected children inside a mounted project. See [jailbox's path limitations](security.md#important-realities).

## Network access

| Criterion | jailbox | Dev Containers | DevPod | Codespaces | Ona | Coder | Docker Sandboxes |
|---|---|---|---|---|---|---|---|
| Outbound access restricted by default | ❌ | ⚙️ engine/config | ⚙️ provider | ❌ | ? | ⚙️ template | ◐ preset choice⁷ |
| Built-in HTTP(S) domain allowlist | ✅ opt-in | ❌ separate setup | ? | ? | ◐ advertised⁸ | ⚙️ infrastructure | ✅ |
| Broader TCP destination policy | ❌ built-in | ⚙️ infrastructure | ⚙️ provider | ? | ? | ⚙️ infrastructure | ✅ |
| Host-service access filtered | ❌ bridge caveat | ⚙️ networking | ⚙️ provider | N/A laptop | N/A laptop | ⚙️ deployment | ✅ policy |

7. Docker offers Open, Balanced, and Locked Down presets. Balanced includes common
   development destinations; agent kits can add permissions even under Locked Down.
8. Ona advertises egress controls, but equivalent domain-policy behavior and defaults
   were not verified here.

jailbox's filtered mode has no direct external route: HTTP(S) goes through its
allowlisting proxy. Host services reachable through the bridge can remain
accessible. Allowed destinations can still receive data. See [network enforcement](security.md#network-enforcement).

## Workflow and support evidence

| Criterion | jailbox | Dev Containers | DevPod | Codespaces | Ona | Coder | Docker Sandboxes |
|---|---|---|---|---|---|---|---|
| Editor integration | ✅ VS Code/Codium | ✅ VS Code | ✅ multiple | ✅ browser/desktop | ✅ browser/desktop | ✅ multiple | ✅ SSH editors |
| Headless CLI / automation | ✅ | ✅ separate CLI | ✅ | ✅ | ✅ CLI/API | ✅ | ✅ |
| Container engine inside environment | ❌ provided engine | ⚙️ configure | ⚙️ configure | ⚙️ Docker-in-Docker | ? | ⚙️ template | ✅ private engine |
| Linux local execution | ✅ tested | ✅ | ✅ provider | N/A | N/A supported model | ⚙️ deployment | ✅ Ubuntu/KVM |
| macOS local execution | ◐ unverified runtime | ✅ engine VM | ✅ provider | N/A | N/A supported model | ⚙️ deployment | ✅ Apple Silicon |
| Windows local execution | ? | ✅ engine/WSL | ✅ provider | N/A | N/A supported model | ⚙️ deployment | ✅ Windows 11 x64 |
| Public source and releases for core | ✅ | ✅ CLI | ✅ | ❌ service | ❌ service | ✅ | ◐ binaries |
| Integration-test coverage reviewed here | ✅ Linux; Mac portable | ? | ? | ? | ? | ? | ? |

Platform entries reflect published support, not tests performed for this comparison.
Docker lists additional OS/version/hardware prerequisites. For jailbox's actual
coverage, see [tested configurations](development.md#tested-configurations).
Maturity is not a checkbox: release history, support, security response, and
recovery reliability need separate assessment. No comparative performance or
reliability measurements were made.

## Sources

### jailbox

[License](../LICENSE) · [Security and path policy](security.md) ·
[Images and tested platforms](development.md) · [Automation](automation.md)

### Dev Containers

[Specification](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainerjson-reference.md) ·
[Setup](https://code.visualstudio.com/docs/devcontainers/create-dev-container) ·
[Mounts](https://code.visualstudio.com/remote/advancedcontainers/add-local-file-mount) ·
[Docker mount semantics](https://docs.docker.com/engine/storage/bind-mounts/) ·
[Credential sharing](https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials) ·
[CLI and MIT license](https://github.com/devcontainers/cli) ·
[Extension licensing](https://code.visualstudio.com/docs/remote/faq#license-and-privacy)

### DevPod

[Source and license](https://github.com/loft-sh/devpod) ·
[Providers and editors](https://devpod.sh/docs/what-is-devpod) ·
[Configuration](https://devpod.sh/docs/developing-in-workspaces/devcontainer-json) ·
[Credential defaults](https://devpod.sh/docs/developing-in-workspaces/credentials) ·
[Platform downloads](https://website.devpod.sh/)

### Codespaces

[Overview](https://docs.github.com/en/codespaces/about-codespaces/what-are-codespaces) ·
[Security, credentials, and networking](https://docs.github.com/en/codespaces/reference/security-in-github-codespaces) ·
[Docker-in-Docker](https://docs.github.com/en/codespaces/reference/allowing-your-codespace-to-access-a-private-registry) ·
[Service terms](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#codespaces)

### Ona

[Architecture](https://ona.com/docs/ona/understanding/architecture) ·
[Dedicated VMs](https://ona.com/stories/the-last-year-of-localhost) ·
[Configuration](https://ona.com/docs/ona/configuration/devcontainer/overview) ·
[Deprecated local runners](https://ona.com/api-reference/go/resources/runners/methods/create) ·
[Environment controls](https://ona.com/cases/ona-environments) ·
[Overview](https://ona.com/docs/ona/getting-started) ·
[Service terms](https://ona.com/legal/terms-of-service)

### Coder

[Core license](https://github.com/coder/coder/blob/main/LICENSE) ·
[Premium licensing](https://coder.com/docs/install/prepare/licensing) ·
[Infrastructure templates](https://coder.com/docs/admin/templates) ·
[Editor and SSH access](https://coder.com/docs/user-guides/workspace-access) ·
[Agent permissions and network responsibilities](https://coder.com/docs/ai-coder/agents)

### Docker Sandboxes

[Proprietary license and releases](https://github.com/docker/sbx-releases#license) ·
[Isolation and credential defaults](https://docs.docker.com/ai/sandboxes/security/isolation/) ·
[Workspace modes](https://docs.docker.com/ai/sandboxes/usage/) ·
[Filesystem policies](https://docs.docker.com/ai/sandboxes/governance/access-controls/filesystem/) ·
[Network presets](https://docs.docker.com/ai/sandboxes/governance/access-controls/local/) ·
[Custom images](https://docs.docker.com/ai/sandboxes/customize/author/base-images/) ·
[Platforms and sign-in](https://docs.docker.com/ai/sandboxes/install/)
