# Egress filtering phase 2 — optional strict proxy enforcement

## Goal

Offer stronger containment when the threat model includes code that
deliberately abuses proxy protocols or shared hosting. This phase is optional:
phase 1 remains the baseline unless strict enforcement proves compatible and
maintainable enough to replace it.

If both policies ship, they must have distinct names and visible status. Strict
claims must never be made for the baseline policy. Prototype the strict policy
before adding a permanent public configuration key.

Phase 2 retains every proxy-independent phase 1 requirement: exact hostname
semantics, a visible effective allowlist, internal-only listener binding,
accurate documentation, and the baseline adversarial runtime assertions.
Replacing tinyproxy must not weaken those properties.

## Required enforcement

The strict proxy must enforce all of the following without terminating TLS:

- approved destination ports for every request type;
- rejection of loopback, private, link-local, Podman, host-gateway, multicast,
  unspecified, and other reserved destination addresses after DNS resolution;
- connection to the exact address that was checked, avoiding a second DNS
  lookup and DNS-rebinding race;
- an allowlisted CONNECT hostname and TLS ClientHello SNI, with missing,
  malformed, or non-TLS traffic rejected when a TLS tunnel is required; and
- opaque TLS splicing after inspection, preserving end-to-end TLS between the
  client and remote server.

The runtime gate must exercise each property, including mismatched SNI,
unexpected ports, hostnames resolving to reserved addresses, DNS rebinding, and
normal editor and package-manager traffic.

## Proxy candidates

### Squid — leading candidate

Squid is the best-established fit for a prototype. Its ACL system can restrict
destination domains, ports, request methods, and resolved destination IPs. Its
TLS peek-and-splice flow can read ClientHello SNI and then splice the connection
without decrypting application traffic.

Relevant upstream documentation:

- [ACL configuration](https://www.squid-cache.org/Doc/config/acl/)
- [TLS peek and splice](https://wiki.squid-cache.org/Features/SslPeekAndSplice)
- [`ssl_bump` configuration](https://www.squid-cache.org/Doc/config/ssl_bump/)

Before selection, verify with adversarial tests that Squid connects to the same
resolved address checked by its ACL, rejects missing SNI rather than falling
back to CONNECT alone, and independently requires both CONNECT and SNI names to
be allowlisted. Use only peek and splice, never TLS bumping.

Costs and risks:

- substantially larger image and configuration surface than tinyproxy;
- OpenSSL-enabled build required for peek-and-splice;
- subtle rule ordering and multi-stage TLS ACL semantics; and
- `ssl_bump` is documented through Squid 7 but absent from Squid 8, creating a
  version and maintenance concern.

### Envoy — not recommended for the hostile-client boundary

Envoy provides HTTP and SNI dynamic-forward-proxy components, DNS caching, TLS
inspection, and upstream certificate verification. It is operationally heavier
and more complex for this narrow use case. More importantly, Envoy documents
its SNI dynamic-forward-proxy extension as having limited production burn time
and an unknown security posture, and recommends it only when downstream and
upstream are trusted.

Relevant upstream documentation:

- [HTTP dynamic forward proxy](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/dynamic_forward_proxy_filter)
- [SNI dynamic forward proxy](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/sni_dynamic_forward_proxy/v3/sni_dynamic_forward_proxy.proto)

That warning conflicts with this phase's deliberately hostile downstream, so
Envoy should not be the default candidate without a new security assessment.

### Purpose-built proxy — avoid unless mature options fail

A small CONNECT-only proxy could implement the exact desired policy with less
runtime surface than Squid. It would also make jailbox responsible for a
security-critical HTTP parser, TLS ClientHello parser, DNS resolver, IP-range
policy, timeout handling, and bidirectional relay. Do not choose this route
solely for image size or configuration simplicity. It requires fuzzing,
protocol-level tests, dependency review, and a long-term maintenance owner.

## Explicit non-goal: TLS interception

Do not install a jailbox CA or decrypt application traffic. TLS interception
would expose credentials and payloads to the proxy, break certificate-pinned
clients, and add substantial security, privacy, compatibility, and maintenance
cost. It still could not prove that an allowed service never obtains data from
another service upstream.

## Adoption decision

Prototype Squid in isolation and compare compatibility, startup time, image
size, and maintenance cost with the phase 1 tinyproxy design. Only after the
runtime and editor gates pass should the project decide whether strict mode is
an opt-in policy, becomes the default, or is rejected as disproportionate.
