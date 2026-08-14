# Recommendation: document egress-filter limitations

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

Add a concise limitations section to the README explaining hostname/SNI
mismatch and plain-HTTP port behavior. Do not imply that the proxy inspects TLS
or provides destination enforcement beyond its actual request-level checks.
