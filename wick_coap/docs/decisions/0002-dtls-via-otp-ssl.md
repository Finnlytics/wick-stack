# ADR 0002 — DTLS via OTP `:ssl`, accepting two missing extensions

**Status:** Accepted
**Date:** 2026-05-17

## Context

CoAP over UDP is unauthenticated and unencrypted. LwM2M's security model is DTLS ([RFC 6347](https://www.rfc-editor.org/rfc/rfc6347)) with three defined modes: Pre-Shared Key (mode 0), Raw Public Key (mode 3), and X.509 certificate (mode 2). Any serious deployment needs at least one.

The options for DTLS on the BEAM:

- **OTP `:ssl`.** Ships with Erlang, supports DTLS 1.2, and is maintained by the OTP team. Same crash and supervision domain as everything else.
- **A NIF binding to a C DTLS stack** (OpenSSL, mbedTLS, tinydtls). Full protocol coverage, at the cost of a build toolchain, a crash domain outside the BEAM, and cross-compilation for constrained targets.
- **A userspace DTLS implementation in Elixir.** Full control, and an enormous amount of security-critical code to write and maintain. Writing a wire format from an RFC is one thing; writing a TLS stack is another.

Two DTLS extensions matter specifically for constrained devices, and their availability drove the decision:

- **[RFC 9146](https://www.rfc-editor.org/rfc/rfc9146) — Connection ID.** Lets a DTLS session survive the peer's address changing. Without it, NAT rebinding — routine on cellular, where a device may get a new source port every time its radio sleeps — breaks the session and forces a full handshake.
- **[RFC 7250](https://www.rfc-editor.org/rfc/rfc7250) — Raw Public Keys.** A public key without a certificate chain. This is LwM2M Security Mode 3, and it is attractive precisely because it avoids shipping a PKI to constrained devices.

Neither is available in OTP 28. `ssl_handshake.hrl` marks the RPK extension explicitly as `Not supported`, and there is no Connection ID implementation.

## Decision

Use OTP `:ssl`, and accept both gaps.

DTLS is offered by passing `transport: :dtls` plus a `dtls_opts` keyword list to `WickCoap.Endpoint.start_link/1`. Those options are forwarded **straight through** to `:ssl` rather than being wrapped in an abstraction of our own — so any cipher suite and any credential format `:ssl` supports works here, and anything it gains in a future OTP release works without a change to WickCoap.

What that yields:

- **PSK (mode 0)** — pass `user_lookup_fun: {&lookup/3, state}` and a PSK cipher suite.
- **X.509 (mode 2)** — pass `certfile` / `keyfile` on the server, `verify: :verify_peer` plus `cacertfile` on the client.
- **RPK (mode 3)** — not available. Consumers needing it must use PSK or X.509.

For the Connection ID gap, mitigate at the application layer rather than pretending the problem is solved: `WickCoap.Endpoint.ping/3` implements the CoAP Ping of [RFC 7252 §4.3](https://www.rfc-editor.org/rfc/rfc7252#section-4.3), which doubles as a NAT keepalive, and an LwM2M Update carrying a fresh peer address refreshes the session record on the far side.

## Consequences

**Good**

- No build toolchain, no NIF, no new crash domain. Consistent with [ADR 0001](0001-hand-written-coap-rather-than-forking.md): the only things we depend on ship with the platform.
- Forwarding options untouched means the full surface of `:ssl` is reachable, including cipher suites we have never tested, without us having to enumerate them.
- Cross-compilation is a non-issue, which matters for the constrained targets this is aimed at.
- If OTP implements either extension, we inherit it.

**Bad**

- **LwM2M Security Mode 3 cannot be offered.** For a library aiming at LwM2M completeness this is a genuine hole, and it is upstream, not ours to close.
- **NAT rebinding breaks sessions.** On cellular this is not an edge case. The Ping mitigation reduces the frequency; it does not eliminate the failure, and a device that sleeps longer than the NAT binding will re-handshake.
- Forwarding `:ssl` options means `:ssl`'s error messages reach the consumer raw, and some are misleading. One is documented in the README because it cost real time: `:psk_identity` must be a charlist on the client, and passing an Elixir binary produces an `{:options, {:psk_identity, ...}}` error that does not say so.

**Neutral**

- If either gap becomes painful enough, the escape hatch is a userspace DTLS stack. That is a large, security-critical undertaking and is explicitly tabled — recorded here so the option is remembered rather than rediscovered.
- Both gaps are documented in the README's Security section, not just here. A consumer choosing a security mode should not have to read the decision log to discover mode 3 is unavailable.

## References

- [RFC 6347 — DTLS 1.2](https://www.rfc-editor.org/rfc/rfc6347)
- [RFC 9146 — DTLS Connection ID](https://www.rfc-editor.org/rfc/rfc9146)
- [RFC 7250 — Raw Public Keys in TLS/DTLS](https://www.rfc-editor.org/rfc/rfc7250)
- [RFC 4279 — Pre-Shared Key ciphersuites](https://www.rfc-editor.org/rfc/rfc4279)
- `test/wick_coap/endpoint_dtls_test.exs` and `endpoint_dtls_x509_test.exs` — runnable examples of both supported modes
