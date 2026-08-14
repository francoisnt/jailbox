# Recommendation: tighten proxy listener exposure

Tinyproxy listens on `0.0.0.0` and relies on its rendered subnet ACL while also
attached to the external network.

Investigate binding it only to the internal proxy address so the listener is
not exposed on the external interface. Retain the ACL as defense in depth and
add runtime coverage before changing the bind.
