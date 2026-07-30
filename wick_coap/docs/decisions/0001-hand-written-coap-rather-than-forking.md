# ADR 0001 — Hand-written CoAP with zero runtime dependencies, rather than forking

**Status:** Accepted
**Date:** 2026-05-10

## Context

WickCoap exists because there is no maintained, general-purpose CoAP library for the BEAM. Before writing one, the alternatives were:

- **[`gen_coap`](https://github.com/gotthardp/gen_coap)** — the original Erlang CoAP library. Dormant: no substantive commits in years, no Block-wise support in the form we need, and an Erlang API that would need an Elixir facade anyway.
- **The EMQX fork of `gen_coap`** — actively used, but LwM2M-specific and pinned to LwM2M 1.0.2. Its CoAP layer has LwM2M assumptions threaded through it, and its representation of LwM2M is an opinionated MQTT-bridge mapping. Taking it would mean either living inside that mapping or unpicking it.
- **A binding to a C library** (libcoap) via NIF or port — introduces a build toolchain, a crash domain outside the BEAM's supervision guarantees, and cross-compilation problems for the constrained targets this is ultimately aimed at.
- **Write it.** CoAP's wire format is genuinely small: a 4-byte fixed header, delta-encoded options, and a payload. [RFC 7252](https://www.rfc-editor.org/rfc/rfc7252) is ~100 pages including rationale and examples; the encoding itself is a handful of pages.

Wick had already taken the same decision for LwM2M's wire formats — see [Wick ADR 0001](../../../wick/docs/decisions/0001-zero-runtime-dependencies.md) — so the question was whether the reasoning carries over to a transport protocol with a runtime, not just codecs.

## Decision

Write CoAP from the RFCs, with **zero runtime dependencies**.

Every dependency in `mix.exs` is `only: [:dev, :test]`. A consumer of `wick_coap` pulls in `wick_coap` and nothing else. Binary parsing uses Erlang bitstring patterns; timers use `Process.send_after/3`; the socket is `:gen_udp`; DTLS is OTP `:ssl`. All of it is either the standard library or the language.

The scope is deliberately *generic CoAP*. WickCoap has no dependency on Wick and no knowledge of LwM2M — that separation is [Wick ADR 0004](../../../wick/docs/decisions/0004-wick-coap-as-sibling-library.md), and it is what makes this library worth taking on its own.

## Consequences

**Good**

- Nothing to audit, pin, or wait on. For a library likely to run on constrained gateways, a dependency-free tarball is a feature in itself.
- The implementation matches the RFC section by section, so a reviewer with the spec open can check it. Module docs cite the section they implement.
- No LwM2M assumptions to unpick, which is exactly the cost the EMQX fork would have imposed.
- Bitstring pattern matching is the right tool for this. The message decoder is close to a transcription of RFC 7252 §3.

**Bad**

- Everything is ours to get right: retransmission timing, deduplication windows, Block-wise state machines, Observe sequence arithmetic. Mitigated by testing each against the RFC's own stated behaviour, and by 169 tests including property tests over the wire format.
- No community battle-testing. `gen_coap` has seen production traffic we have not. The end-to-end LwM2M exercise in Wick is the closest substitute so far.
- Features arrive when we write them. Multicast is absent; see [ADR 0003](0003-observe-relations-keyed-by-path.md) for a keying limitation we chose to document rather than fix.

**Neutral**

- OTP `:ssl` for DTLS is a dependency in the sense that matters (we depend on its behaviour), but it ships with Erlang and adds nothing to the dependency tree. Its limits are real and are recorded separately in [ADR 0002](0002-dtls-via-otp-ssl.md).

## References

- [RFC 7252 — The Constrained Application Protocol](https://www.rfc-editor.org/rfc/rfc7252)
- [RFC 7959 — Block-Wise Transfers in CoAP](https://www.rfc-editor.org/rfc/rfc7959)
- [RFC 7641 — Observing Resources in CoAP](https://www.rfc-editor.org/rfc/rfc7641)
- [RFC 8132 — PATCH and FETCH Methods for CoAP](https://www.rfc-editor.org/rfc/rfc8132)
- [Wick ADR 0001 — Zero runtime dependencies](../../../wick/docs/decisions/0001-zero-runtime-dependencies.md)
- [Eclipse Californium](https://eclipse.dev/californium/) — the architectural precedent: a standalone CoAP library with LwM2M layered on top
