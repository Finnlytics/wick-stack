# ADR 0004 — `wick_coap` as a sibling library, not a Wick module

**Status:** Accepted
**Date:** 2026-05-10

## Context

Wick's scope from the start excluded transport: no UDP listener, no DTLS session manager, no Registration store as a process — anything CoAP, DTLS, or UDP would belong in a transport library that consumes Wick.

That separation was deferred until the protocol primitives layer was complete. With Wick functionally complete for LwM2M 1.1 (every codec bidirectional, full request/response/uplink type set, DDF parser, Object Registry), the next foundation stone is CoAP.

CoAP is a generic IETF protocol ([RFC 7252](https://www.rfc-editor.org/rfc/rfc7252)). Many things use CoAP — IoT devices, edge gateways, lightweight web services — most without LwM2M on top. The wire format is independent of LwM2M's Object Model.

Eclipse uses the same architecture: **Californium** is a standalone CoAP library; Leshan layers LwM2M on top via its `leshan-tl-cf-*` binding modules. Leshan does not vendor or wrap CoAP semantics into its core protocol library.

## Decision

CoAP wire format and (eventually) runtime live in a **new sibling library [`wick_coap`](https://github.com/Finnlytics/wick_coap)**. It is its own Mix project, its own Hex package shape, its own decision log.

`wick_coap` has **no runtime dependency on Wick.** Pure CoAP — generic, reusable for non-LwM2M applications. The LwM2M-specific binding (e.g. mapping CoAP `2.05 Content` to `Wick.Status.content`) lives in either Wick itself or a future gateway service that depends on both.

## Consequences

**Good**

- Clean separation. Anyone wanting CoAP-without-LwM2M can take `wick_coap` standalone — there is currently a gap in the BEAM ecosystem (`gen_coap` is dormant; the EMQX fork is LwM2M-specific).
- Wick stays focused on LwM2M protocol primitives. No CoAP knowledge bleeds in.
- Two smaller, more comprehensible libraries beat one bigger one — for both reviewers and consumers.

**Bad**

- Two libraries to version, publish, and CI. We accept this.
- Conventions need to stay in sync. The new library copies Wick's tooling stack (Credo, Dialyzer, ExDoc, ExCoveralls, StreamData, GitHub Actions) verbatim. ADR 0001 (zero runtime deps) applies — the same reasoning carries over.

**Neutral**

- The boundary between "protocol primitives" and "transport" is not perfectly crisp at the LwM2M layer (e.g., the `accept_content_format` field on `Wick.Request.Read` is a CoAP Content-Format integer). For the foreseeable future, Wick exposes those raw integers and the gateway/binding layer translates. We can add convenience helpers later without breaking the contract.

## Sequenced milestones

1. **`wick_coap` — CoAP message wire format (encode/decode)** — current milestone. Mirror of Wick's "encode-first, decode-second" approach: get the wire bytes right, then add the runtime (retransmission, deduplication, block-wise reassembly, observe relations).
2. **`wick_coap` runtime** — retransmit/dedup state machines, block-wise transfer engine, observe relation tracking. A later milestone.
3. **Demo server + demo client** — minimal end-to-end LwM2M exchange. Wires Wick + wick_coap + OTP `:ssl` (DTLS) + an in-memory ETS-backed registration store. Confirms the libraries work together; doubles as reference implementation for downstream consumers.

## References

- [Eclipse Californium](https://eclipse.dev/californium/) — the architectural precedent (CoAP-only library; Leshan layers LwM2M on top)
- [RFC 7252 — CoAP](https://www.rfc-editor.org/rfc/rfc7252)
- [RFC 7641 — Observe](https://www.rfc-editor.org/rfc/rfc7641)
- [RFC 7959 — Block-wise Transfers](https://www.rfc-editor.org/rfc/rfc7959)
