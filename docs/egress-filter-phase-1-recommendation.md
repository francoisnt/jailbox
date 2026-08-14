# Egress filtering phase 1 — strengthen tinyproxy enforcement

## Concern

The proxy allowlist filters the hostname supplied to HTTP or CONNECT. After a
CONNECT is accepted, tinyproxy tunnels bytes and cannot verify that TLS SNI
matches the allowlisted hostname. Plain HTTP proxy requests can also address a
non-HTTPS port on an allowlisted host even though CONNECT is restricted to port
443.

These limitations are inherent in the current capability-free,
proxy-mediated design and remain bounded to allowlisted hosts, but the threat
model should state them plainly.

## Recommendation

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
