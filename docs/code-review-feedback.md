# Code review feedback

Observations from a full read of the host, container, and tooling code
(`docs/` deliberately not read). Overall the codebase is disciplined: the
"why" comments are excellent, the security posture is coherent, Bash 3.2
compatibility is handled carefully, and the config-as-data parser in
`host/common.sh` is a genuine strength. The notes below are sharp edges, not
baseline-quality problems. Severity is a judgment call, not a verified defect —
items marked "verify" need confirmation on a real host before acting.

---

## 1. `:Z` SELinux relabeling of the whole project directory — verify

**Where:** `host/container-runtime.sh:201` (`-v "$PROJECT_DIR:$REMOTE_PATH:Z"`),
plus the per-file overlays at `host/container-runtime.sh:202` and
`host/container-runtime.sh:102` (`:Z,ro`).

**What `:Z` does:** On an SELinux-enforcing host (Fedora/RHEL/CentOS — and the
test matrix includes Fedora), `:Z` relabels the mounted host files with a
*private*, container-specific MCS category (e.g. `container_file_t:s0:c123,c456`)
so only that one container may access them. The lowercase `:z` variant instead
applies a *shared* label that the host and other containers can still access.

**Concern:**

- `$PROJECT_DIR` is the user's real working tree, not a copy. `:Z` rewrites the
  SELinux label of every file in it, on disk, with an effect that outlasts the
  container. Host-side tools that relied on the previous label can then be
  denied access, and a second consumer mounting the same tree with `:Z`
  re-privatizes it under a different category, breaking the first.
- The per-file `:Z,ro` overlays relabel files that already live inside the
  `:Z`'d parent, so those files are relabeled twice in a single `podman run` —
  redundant, and a sign the labeling mode was not chosen deliberately per mount.

**Why it's "verify" not "definite bug":** On non-SELinux hosts (most
Debian/Ubuntu, macOS) `:Z` is a no-op, so most users never see it. Whether host
breakage manifests depends on what else touches the project files under which
label. jailbox already scopes one container per project, which contains the
blast radius.

**Likely fix:** Use `:z` (shared) on the project mount and the read-only
overlays. Container access still works; the host-label mutation footgun goes
away. The isolation that matters (read-only rootfs, dropped caps,
no-new-privileges, egress control) is unaffected by `z` vs `Z`. Before changing,
confirm the container can still read the project and that the read-only overlays
still deny writes — `host/validation.sh` `check_readonly_mounts` covers the
write-denial half; add a read check for the other half.

---

## 2. `ensure_readonly_stubs` writes into the user's project and never cleans up

**Where:** `host/container-runtime.sh:78-96`.

Running jailbox once creates, in the user's actual repo:

- an empty `.env` file,
- empty `.github/workflows` and `.gitea/workflows` directories,

if they are absent, and never removes them. The empty directories are invisible
to git, but:

- An empty `.env` is **not** inert to every dotenv loader — some libraries
  branch on file existence — and it shows up in `git status`.
- It's a "jailbox mutated my tree" surprise the first time it happens.

The code comments justify this as deliberate (an unstubbed protected path could
be created writable from inside the container, which is exactly what the
overlays exist to prevent). The tradeoff is sound; this is flagged as a UX wart
to reconsider, not a correctness bug.

---

## 3. Global-variable coupling across modules — maintainability

**Where:** `jailbox:40-76` declares ~30 globals that the `host/*.sh` modules
populate by side effect; `run_launch` (`jailbox:101`) has a load-bearing step
order (e.g. `configure_proxy_env` sets globals later consumed by the editor,
ssh, and downloader-proxy modules).

It works and is documented, but modules can't be reasoned about or unit-tested
in isolation — a reader has to trace mutation across files, and any new step
must be placed carefully in the ordering. Not worth a refactor; called out so
new work respects the implicit coupling.

---

## 4. Egress filtering limitations — mostly inherent, worth documenting honestly

**Where:** `host/network.sh` (proxy topology, filter rendering),
`container/tinyproxy/tinyproxy.conf`.

- **Hostname-based CONNECT filtering** is structurally open to domain-fronting /
  SNI mismatch: a client can `CONNECT` to an allowlisted host and then present a
  different SNI inside the TLS handshake. tinyproxy tunnels raw bytes after the
  CONNECT, so it cannot see the real destination.
- **`ConnectPort 443` restricts CONNECT tunnels, but plain-HTTP proxying via an
  absolute-URI `GET` is not port-restricted the same way** — e.g.
  `http://allowed-host:22/` would proxy to port 22 on an allowlisted host.

Both are inherent to a capability-free, proxy-mediated model (no NET_ADMIN, no
transparent interception) and only reach allowlisted domains, so severity is
low. The README's confident framing slightly undersells them; a short
"limitations" note would be more honest.

---

## 5. Minor hardening / staleness notes

- **tinyproxy `Listen 0.0.0.0`** (`container/tinyproxy/tinyproxy.conf`) is backed
  by the rendered `Allow <subnet>` ACL (good defense-in-depth), but the proxy is
  also attached to the external network. Binding it to the internal proxy IP
  would remove the "exposed listener behind an ACL" shape entirely.
- **Wrapper image staleness:** a floating `DEV_IMAGE` (e.g. `node:22`) won't
  re-pull on rebuild because the wrapper `FROM` layer is cached; users need
  `--clean` to pick up upstream updates. Worth a documentation line.

---

## Suggested priority

1. Verify item **1** (`:Z`) on an SELinux-enforcing host — most likely to be a
   real bug.
2. Decide on item **2** (`.env` stub) as an explicit UX tradeoff.
3. Items **4** and **5** are cheap documentation/hardening improvements.
4. Item **3** is context for future work, not an action.
