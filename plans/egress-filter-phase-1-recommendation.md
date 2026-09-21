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

Proxy delivery is owned by and must be verified in
`03.2.11.5-frontend-verification-plan.md` before this phase. That plan originally
handed the simplification to phase 1; the work now returns to frontend closing
verification at the user's request. This phase preserves the resulting contract
below while changing filtering, and does not repeat the delivery migration.

Supply the core-generated proxy settings through the container environment and
explicitly carry them into SSH sessions at server startup. In filtered mode,
SSH-launched editors, terminals, exec commands, and tasks must receive all six
uppercase/lowercase proxy variables without client `SetEnv` support or generated
editor terminal settings.
Keep proxy delivery free of a separate mounted SSH session configuration file.
Preserve the delivery contract: retain the explicit HTTP(S) proxy, effective allowlist,
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

### Preserve the integrated SSH delivery path

Core passes the live proxy address through a container environment input.
Startup validates it and supplies one server `SetEnv` option containing all six
session variables. Core validates the immutable container input on reuse and
attachment. Empty unfiltered input clears the SSH session's proxy values.

Reuse the startup and generation unit tests, the no-client-`SetEnv` runtime
assertion, and the real editor task proof when changing proxy behavior. Keep
core validation and infrastructure assertions in runtime/matrix.

The server requires `SetEnv` support (introduced in OpenSSH 7.8), checked during
wrapper build. No server `Include` directive is needed. `supported-versions.md`
separates required features from versions actually tested; a feature minimum
alone does not establish a fully tested wrapper floor.
