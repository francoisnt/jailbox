# Security guide

[Home](../README.md) · [Development](development.md) · [Automation](automation.md) · [Security](security.md)

jailbox reduces the access that code in your development container has to your
host. Its protections apply to both the development workflow and the automation
interface. Project files remain writable and outbound access unrestricted by
default; choose additional restrictions to match your work.

- [Protections](#what-jailbox-does-well)
- [Limits and path policy](#important-realities)
- [Network enforcement](#network-enforcement)

## What jailbox does well
- Read-only root filesystem
- Zero capabilities + no-new-privileges
- Rootless Podman containers (`--userns=keep-id`)
- Fresh client and server SSH key pairs per container, with strict pinned host-key checking
- No container runtime sockets mounted
- Strict sshd configuration (key auth only, local TCP forwarding only,
  agent and X11 forwarding explicitly disabled in client and server policy)
- Optional egress control: when `EGRESS_ALLOW` is set, the container is
  placed on an internal-only network with no direct external route and no
  DNS; an unprivileged tinyproxy sidecar is the only outbound gateway,
  accepts clients from the internal network only, and enforces the domain
  allowlist for HTTP/HTTPS

## Important realities
- The container maps your **host UID/GID** to its own non-root `jailbox`
  account, so it can edit project files and new files remain owned by you
- Launch and attachment refuse projects that equal or contain the host home
  directory or jailbox runtime-state directory. Normal projects beneath the
  home directory remain supported.
- Project files are mounted writable by default. With non-empty `WRITABLE_PATHS`,
  the project base is read-only and only the declared lanes are writable.
  Core automatically overlays the exact in-project Containerfile used for the
  build read-only. File-driven launches
  also protect the default `jailbox.conf` and selected in-project config.
  Selecting an external config does not remove protection from the default.
- File-driven launch requires that default config even when an external config is selected.
  Keeping this anchor present and read-only prevents the sandbox from creating
  policy that a later bare launch would trust.
- Only additional paths explicitly listed in `READONLY_PATHS` receive
  read-only overlays. They must already exist as regular files or directories;
  missing paths are rejected and no stubs are created. Other project paths,
  including unused Containerfile candidates, follow the base or writable-lane
  policy unless explicitly configured otherwise.
- Writable lanes must be existing project-relative regular files or directories,
  without dot segments, colons, trailing slashes, or symlink components.
  Read-only and writable entries may nest: the most specific entry wins,
  with read-only winning an exact tie. Automatic Containerfile and frontend
  config-file protection always remains read-only unless hidden. Overlaps are
  resolved silently, including writable declarations for automatically protected
  files. Every declared path is validated even if stronger policy suppresses it. Control
  characters cannot be represented by either configuration interface. Indexed
  environment members support literal commas; file configuration uses commas
  as separators.
- For example, `WRITABLE_PATHS=src,build` allows changes in those directories
  while other project paths stay read-only. A regular-file lane supports
  in-place writes, but its read-only parent prevents sibling temporary files
  and atomic replacement. List its parent directory if those operations are needed.
  `READONLY_PATHS=src,src/generated/policy` with `WRITABLE_PATHS=src/generated`
  allows writes under `src/generated` except its `policy` child; the rest of
  `src` stays read-only. Array order does not change this precedence. A nonempty
  writable list keeps the project base read-only even if every lane is suppressed.
- `HIDDEN_PATHS=secrets,private.key` masks those existing paths at runtime.
  Machine callers use indexed `JAILBOX_CONFIG_HIDDEN_PATHS_0`, `_1`, etc.; each
  indexed value is literal, including commas. Entries must be project-relative
  regular files or directories, with no symlink components, dot segments,
  colons, trailing slash, or distinct entries with overlapping hidden ancestors.
  Missing paths are rejected; masks do not reserve names.
- Hidden masks take precedence over protected read-only paths, writable lanes,
  and the project base. All paths are validated before launch; overlays at or
  below a hidden path are omitted. A selected Containerfile or frontend configuration file may
  be hidden after the host consumes it. Project mounts use private propagation.
  Unsupported masking fails creation without retrying with weaker protection.
- Native masking hides original contents and prevents their modification through
  the masked path. Filenames can remain visible. Reads or directory listings may
  succeed with empty results, and file writes may succeed while discarding data;
  the original host content stays unchanged. The sandbox cannot delete or replace
  the mask. Other hardlinks and copies remain readable. Changed hidden policy
  requires explicit `stop`/`up` recovery, like other configuration changes.
- Masks apply only at runtime. Containerfiles can read or copy hidden paths from
  `DEV_BUILD_CONTEXT` during image builds. Keep secrets outside the build context
  or exclude them with container ignore files. jailbox does not edit ignore files
  or remove secrets from images, caches, Git history, logs, or existing copies.
- Allowing `.git` is explicit. Protecting `.git/config` and `.git/hooks` can
  coexist with commits that write objects and refs. Agent-authored commits are
  still untrusted, and multiple sandboxes must not share a writable Git directory.
- Changing writable policy requires explicit `jailbox stop` then `jailbox up`;
  existing resources refuse reuse or attachment under a different policy.
- Exact duplicates in read-only, writable, and hidden lists are accepted and
  produce no duplicate overlays or masks. Configuration digests still include
  entry order and repetitions, so changing them requires explicit stop/up even
  when effective access stays the same. File-driven commands append config-file
  protection anchors only when not already listed; machine callers reproducing
  that configuration must include any appended entries.
- Symlinks inside configured directories are not scanned and do not propagate
  policy. Making `src` read-only does not protect a writable destination reached
  through `src/link`; configure that destination separately. Intermediate link
  directories receive no automatic protection. Broken, cyclic, external, and
  project-root links inside directories do not block launch or attachment, and
  creating or retargeting them alone does not require recreation. Explicit
  configured paths still cannot contain symlink components, and trusted build
  input validation remains unchanged. External links do not introduce host mounts.
  Hidden directories do not hide linked destinations elsewhere; a link to a
  masked pathname still encounters the mask.
- Protection is pathname-based: pre-existing writable hard-link aliases can
  still modify the same inode.
- Read-only overlays protect integrity, not secrecy: code in the sandbox can
  still read their contents.
- Paths are validated before launch and rechecked while mount arguments are
  assembled, but host-side filesystem races before Podman resolves each bind
  source are not eliminated.
- The AI (or any code running in the container) can still exfiltrate or
  destroy project contents
- You still share the kernel and container runtime trust boundary
- Persistent home contents are sandbox-controlled state retained across policy
  and version changes. They are not integrity-checked; use an ephemeral home
  when each new container generation should start with fresh home contents
- `stop` and `--clean` delete the project's exact derived Podman names using
  your own Podman authority. Neither a name nor a label can authenticate a
  resource against a host process that already holds that authority, so these
  commands are not a guard against other host-side processes. What jailbox
  does guarantee is that the sandbox never holds that authority: no
  container-engine socket is mounted into it
- Without `EGRESS_ALLOW`, the container has unrestricted outbound internet
  access
- Host services listening on `0.0.0.0` (local dev servers, LLM runtimes,
  databases) remain reachable from the container through the Podman bridge
  gateway IP — even in egress mode, since the internal network's bridge
  interface still exists on the host. Bind sensitive host services to
  `127.0.0.1` if the container must not reach them
- Egress enforcement is proxy-mediated (HTTP/HTTPS domain filter), not
  packet-level: tinyproxy only filters traffic that passes through it and
  cannot inspect TLS payload; allowed endpoints can still receive exfiltrated
  data; this is not equivalent to a firewall, VM network isolation, or
  kernel-enforced packet filtering
- In filtered mode, the effective allowlist depends on the launch command:
  bare `jailbox` includes the discovered editor's bootstrap hosts, while
  `jailbox up` does not. In particular, VSCodium adds `github.com` and
  `githubusercontent.com` to a bare-launch sandbox

jailbox focuses on reducing accidental host exposure and limiting common
container escape vectors, not defending against a determined kernel- or
runtime-level attacker. It provides much better defaults than running agents
directly on the host or in privileged containers, but it is **not** a full
sandbox.

## Network enforcement

**How egress enforcement works:** When `EGRESS_ALLOW` is set, jailbox places
the container on an internal-only Podman network — created with no external
route and no DNS service. A tinyproxy sidecar is attached to both that
internal network and a separate external-facing network, and acts as the sole
outbound gateway at a fixed internal IP. Applications that ignore
`HTTP_PROXY`/`HTTPS_PROXY` cannot reach the public internet directly: the
internal network has no gateway, so outbound connections fail at the network
level regardless of proxy cooperation. tinyproxy enforces the domain
allowlist for all HTTP and HTTPS traffic that passes through it, and
restricts HTTPS CONNECT tunnels to port 443.

Without `EGRESS_ALLOW`, the container runs on a standard Podman network with
unrestricted outbound internet access.
