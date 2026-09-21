# Egress filtering phase 1 — strengthen tinyproxy enforcement

## Intent

### Concern

The proxy allowlist filters the hostname supplied to HTTP or CONNECT. After a
CONNECT is accepted, tinyproxy tunnels bytes and cannot verify that TLS SNI
matches the allowlisted hostname. Plain HTTP proxy requests can also address a
non-HTTPS port on an allowlisted host even though CONNECT is restricted to port
443.

These limitations are inherent in the current capability-free,
proxy-mediated design and remain bounded to allowlisted hosts, but the threat
model should state them plainly.

### Recommendation

Keep tinyproxy and make the existing enforcement boundary narrower and more
visible:

- Make hostname matching exact by default. If subdomains are supported, require
  an explicit syntax for them rather than granting them automatically.
- Expose the effective allowlist, including editor endpoints added by jailbox,
  so users can inspect the policy actually in force.
- Bind the proxy listener only to its internal-network address.
- Determine whether plain-HTTP forwarding can be disabled. If it remains
  enabled, document that `ConnectPort 443` does not restrict ordinary HTTP
  requests to port 443.
- Add adversarial runtime assertions for direct-route denial, non-allowlisted
  hosts, subdomain behavior, CONNECT ports, and plain-HTTP destination ports.
- Document that filtering validates proxy-request hostnames and does not inspect
  tunneled TLS or control what an allowed service does upstream.

The result should support the following claim:

> In egress mode, the development container has no direct external route.
> Outbound HTTP(S) must use the proxy, which enforces the visible effective
> hostname allowlist at the proxy-request boundary. CONNECT tunnels are limited
> to port 443; HTTPS remains end-to-end and relies on the client's normal
> certificate validation.

Stronger containment against intentional proxy-protocol abuse is a separate,
optional requirement in `egress-filter-phase-2-recommendation.md`.

### Automatic proxy settings for SSH sessions

This phase owns the proxy-delivery simplification handed off by
`03.2.11.5-frontend-verification-plan.md`. Implement it after the machine-boundary
series; it is not a dependency of closing the frontend/backend split. That
series retains its working server-side SSH session configuration and its
existing gate requirements until this migration is implemented.

Supply the core-generated proxy settings through the container environment and
explicitly carry them into SSH sessions at server startup. In filtered mode,
SSH-launched editors, terminals, exec commands, and tasks must receive all six
uppercase/lowercase proxy variables without client `SetEnv` support or generated
editor terminal settings.
Remove the separate mounted SSH session configuration file. This changes
settings delivery only: retain the explicit HTTP(S) proxy, effective allowlist,
no-direct-route enforcement, read-only root, and zero added capabilities.
Transparent traffic interception and a new public configuration surface are
outside this work.

Acceptance requires:

- Proxy values follow the actual allocated network, including collision
  fallback. Unfiltered launches do not acquire stale or image-inherited proxy
  settings through the new delivery path.
- Container reuse and attachment verify that delivered settings match current
  validated policy. Missing or inconsistent required settings fail explicitly;
  validation does not silently repair a surviving container.
- Startup accepts only the intended proxy variables and validated values;
  neither environment input nor proxy data can inject SSH policy directives
  or shell code. SSH authentication and strict host pinning remain unchanged.
- A real SSH client without client-side forwarding receives all six variables;
  the real editor task still proves inheritance on launch, reopen, and resume.
  Portable tests cover startup failure and stale/malformed delivery state;
  runtime/matrix retain enforcement, reuse, and non-mutation coverage. All four
  gates pass for the completed migration.
- README and `supported-versions.md` distinguish host SSH client requirements
  from the container server's required features and tested versions. Unsupported
  server features produce a clear wrapper-build error instead of a cryptic
  daemon startup failure.

## Implementation detail

### Migrate the existing SSH session configuration

The current implementation writes `server/session.conf` in the SSH generation
from `src/host/core/ssh.sh`, includes it from the configuration produced by
`src/container/setup.sh`, and requires it in
`src/container/runtime/bin/jailbox-start`. Replace that delivery path with
explicit container environment values and startup options for the SSH server.
Server `SetEnv` supplied through `sshd -o` is the intended mechanism; validate
its behavior against the supported servers before adopting it.

Remove the obsolete renderer, file publication/comparison, startup file check,
and `Include` directive. Update generation fixtures and immutable-mount tests
that require this file, preserving coverage for keys and authorized keys.
Adapt the existing no-client-`SetEnv` runtime test and real editor task proof
rather than duplicating them or moving core assertions into the editor gate.

The current server `Include` requires OpenSSH 8.2; server `SetEnv` requires
7.8. Removing `Include` eliminates its additional floor, but does not establish
that the complete wrapper works on every 7.8 server. Check required features
during the build and distinguish capability minima from versions actually
tested. Do not treat placement of an included file as a security boundary:
some SSH directives accumulate entries rather than using only the first value.
