# ADR 0005 — CoAP option *numbers* are the Wick/transport boundary

**Status:** Accepted
**Date:** 2026-07-28

## Context

[ADR 0004](0004-wick-coap-as-sibling-library.md) put CoAP in a sibling library and left Wick with no runtime dependency on it. That was the right split, but it left a question unanswered: *how* does a consumer turn a Wick request into a CoAP message?

Until the Device Management interface landed, only `Wick.Registration` needed an answer, and it gave a partial one — a `%Wick.Registration.Wire{}` struct carrying `method`, `path`, `query`, `payload`, and `content_format`. Turning that into a `%WickCoap.Message{}` was the consumer's problem, and each consumer solved it separately:

- `wick`'s own registration integration test had a `send_wire/3` helper.
- `apps/wick_demo_client`'s Registrar had a near-identical one.
- `apps/wick_demo_server`'s test had a third.

Each was about twenty lines, each hard-coded the option numbers 8, 11, 12, and 15 as bare integers, and each had to know that Content-Format is a uint option while Uri-Path is a string option. Three copies of the same knowledge is two too many, and Device Management would have added Accept (17) and Observe (6) to every copy.

The obvious fixes were both wrong:

- **Wick depends on `wick_coap`.** Discards ADR 0004 for convenience. A CoAP dependency in an LwM2M primitives library also makes Wick unusable over any other transport, and LwM2M 1.2 explicitly allows others (SMS, and LwM2M 1.2 §5.3 anticipates more).
- **`wick_coap` depends on Wick.** Worse: it makes a generic CoAP library carry LwM2M's Object Model, which is precisely what ADR 0004 was avoiding, and it is the mistake the EMQX `gen_coap` fork made.

A third option — a `wick_coap_adapter` bridge library — would have honoured the split, but three libraries and three release cycles is a lot of ceremony for what turns out to be a `map/2`.

## Decision

Wick draws the boundary at CoAP **option numbers**, not at CoAP types.

`Wick.Wire` (promoted from `Wick.Registration.Wire`, now shared by `Wick.Request`, `Wick.Response`, `Wick.Uplink`, and `Wick.Bootstrap`) exposes:

```elixir
@spec to_coap_options(t()) :: [{non_neg_integer(), binary()}]
```

It returns `{option_number, value_bytes}` pairs, sorted ascending, with uint options already encoded in CoAP's shortest form (`Wick.Wire.encode_uint/1`). `Wick.Wire.parse/3` goes the other way. The numbers themselves are named — `Wick.Wire.uri_path_option/0` and friends — so consumers never hard-code `11`.

That reduces the adapter to one line per direction:

```elixir
options = Enum.map(Wick.Wire.to_coap_options(wire), fn {n, v} -> WickCoap.Option.new(n, v) end)
```

Wick still has zero runtime dependencies. It knows the *numbers* from the CoAP option registry, which are protocol constants LwM2M itself specifies (§8), not a library's types.

ADR 0004's "Neutral" section already anticipated this: *"Wick exposes those raw integers and the gateway/binding layer translates. We can add convenience helpers later without breaking the contract."* This is that helper.

## Consequences

**Good**

- One translation per consumer instead of one per operation. `WickDemoClient.Coap` and `WickDemoServer.Coap` are ~40 lines each and cover Registration, Device Management, Information Reporting, and Bootstrap between them.
- The awkward encoding details live in Wick, tested once: that `Observe: 0` is the *empty* binary rather than `<<0>>`, that repeated Uri-Path options must keep their relative order, that an absent Content-Format is different from `0`.
- Still transport-agnostic in principle. A non-CoAP binding ignores `to_coap_options/1` and reads the `%Wick.Wire{}` fields directly.
- `Wick.Wire.parse/3` gives the receiving side — a device, or a gateway inspecting traffic — the same leverage the sending side has. `Wick.Request.from_wire/1` is what makes a Wick-based *client* possible at all.

**Bad**

- Wick now encodes knowledge of six CoAP option numbers. If a future LwM2M version reassigns one, Wick changes too. Judged very unlikely: these are IANA-registered and LwM2M pins them.
- The name `to_coap_options/1` mentions a protocol Wick claims not to know about. Accepted as honest: pretending otherwise would mean a vaguer name for the same thing.

**Neutral**

- `Wick.Registration.Wire` was renamed to `Wick.Wire`, a breaking change for anyone tracking `main`. Both libraries are pre-release and unpublished on Hex, so the blast radius is this repository. Noted in the CHANGELOG.
- The two demo apps each hold their own copy of the adapter rather than sharing one. They are separate Mix projects with separate dependency sets; at forty lines the duplication costs less than a fourth library would.

## References

- [ADR 0001 — Zero runtime dependencies](0001-zero-runtime-dependencies.md)
- [ADR 0004 — `wick_coap` as a sibling library](0004-wick-coap-as-sibling-library.md)
- [RFC 7252 §5.10 — Option Definitions](https://www.rfc-editor.org/rfc/rfc7252#section-5.10)
- [RFC 7252 §3.2 — Option Value Formats](https://www.rfc-editor.org/rfc/rfc7252#section-3.2) — the shortest-form uint rule
- [RFC 7641 §2 — The Observe Option](https://www.rfc-editor.org/rfc/rfc7641#section-2)
