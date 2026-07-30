# ADR 0003 — SenML time fields encoded as plain numbers, not CBOR tag 4

**Status:** Accepted
**Date:** 2026-05-07

## Context

While bringing up the Leshan oracle (see [ADR 0002](0002-oracle-pinned-to-leshan-2x.md)), 10 of 12 fixtures matched byte-for-byte between Wick's encoder and Leshan 2.0.0-M18. The two divergences were:

1. **Map key ordering** — Leshan emits canonical CBOR order ([RFC 8949 §4.2.1](https://www.rfc-editor.org/rfc/rfc8949#section-4.2.1)); Wick was emitting field-declaration order. **Fixed.** Wick now sorts canonically.
2. **Time-field encoding** — Leshan emits `base_time = 1700000000` as a tagged decimal fraction:

   ```
   22                       key -3 (bt)
   c4 82 00 1a 6553f100     tag(4) [exponent=0, mantissa=1700000000]
   ```

   Wick emits the same value as a plain CBOR uint32:

   ```
   22                       key -3 (bt)
   1a 6553f100              uint32(1700000000)
   ```

   The Leshan emission is 3 bytes longer.

The divergence comes from Leshan storing time as Java `BigDecimal`. The `com.upokecenter.cbor` library encodes `BigDecimal` as CBOR tag 4 (decimal fraction) regardless of whether the value is whole-numbered. There is no flag to disable this; it's a property of upokecenter's `CBORObject.FromObject(BigDecimal)` dispatch.

[RFC 8428 (SenML)](https://www.rfc-editor.org/rfc/rfc8428) is silent on the wire-level CBOR representation of time. Both forms are valid SenML CBOR. [LwM2M 1.2 §6.4 / §7.4](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf) inherits SenML's flexibility — neither prescribes the encoding.

[RFC 8949 §4.2.1 Core Deterministic Encoding](https://www.rfc-editor.org/rfc/rfc8949#section-4.2.1) implies preferred-serialization principles that argue *against* tagged decimals when a plain integer would suffice: the deterministic encoding is the shortest representation that preserves the value.

Leshan's decoder explicitly accepts both forms — see [`SenMLCborPackSerDes.deserializeNumberValue`](https://github.com/eclipse-leshan/leshan/blob/master/leshan-lwm2m-core/src/main/java/org/eclipse/leshan/senml/cbor/upokecenter/SenMLCborPackSerDes.java) which has cases for `Integer` / `Long` / `EDecimal` (`EDecimal` being upokecenter's CBOR tag 4 type).

## Decision

Wick emits SenML time fields (`time`, `base_time`) as plain CBOR integers when the value is integral, and as plain CBOR floats (shortest IEEE 754 width) when the value is fractional.

Wick does not emit CBOR tag 4 (decimal fraction) for time fields. It accepts tag 4 on **decode** (when implemented), since LwM2M peers running Leshan will produce it.

This means the byte-equality oracle test treats fixture **09** (a fixture that exercises `base_time`) as **expected to differ from Leshan's output**. The oracle test infrastructure marks such fixtures with a `wick_diverges` flag and verifies the *known* difference (Wick 21 bytes, Leshan 24 bytes; the time-field encoding is the only mismatch).

## Consequences

**Good**

- Wick's output is shorter and more deterministic per RFC 8949 §4.2.1 preferred serialization. Whole-numbered times don't get padded with 3 unnecessary tag-overhead bytes.
- Wick's emission matches what most non-Java LwM2M stacks (Anjay, Wakaama, Zephyr's LwM2M client) are likely to produce, since none of them use Java BigDecimal in their data model.
- The decoder will need to accept tag 4 anyway (Leshan-emitting peers will send it), so on the wire we round-trip cleanly with Leshan even though our emission differs.

**Bad**

- We are not byte-identical with Leshan when time fields are present. Any system that canonicalises SenML CBOR for hashing or signing needs to be explicit about which encoder produced the payload, since a Wick-emitted payload and a Leshan-emitted payload of the same logical content will hash differently. Mixed-stack fleets need to agree on a canonical form.
- Future contributors will see this divergence and may attempt to "fix" it by adding tag 4 emission. The encoder code carries a comment pointing to this ADR.

**Neutral**

- One open variant: when Wick is given a `Decimal` (e.g. via a future API extension), what should it emit? Plain CBOR float (lossy for some decimals like 0.1) or CBOR tag 4 (exact, but adds 3+ bytes)? Wick's current `Wick.Senml.Record.t()` uses `integer() | float() | nil` for time, no Decimal — so this question doesn't bite yet. Revisit if/when we accept `Decimal`.

## Action items

- [x] Update [`Wick.Codec.SenmlCbor`](../../lib/wick/codec/senml_cbor.ex) `@moduledoc` to call out the divergence.
- [x] Mark fixture `09_base_name_plus_base_time` as a known-divergence case in the Leshan oracle test.

## References

- [RFC 8949 — CBOR](https://www.rfc-editor.org/rfc/rfc8949) (especially §3.4.4 tag 4 decimal fraction, §4.2.1 deterministic encoding)
- [RFC 8428 — SenML](https://www.rfc-editor.org/rfc/rfc8428)
- [Leshan 2.x `SenMLCborPackSerDes.serializeToCbor`](https://github.com/eclipse-leshan/leshan/blob/master/leshan-lwm2m-core/src/main/java/org/eclipse/leshan/senml/cbor/upokecenter/SenMLCborPackSerDes.java)
- [`com.upokecenter.cbor` BigDecimal handling](https://github.com/peteroupc/CBOR-Java)
- Empirical comparison: [`test/fixtures/senml_cbor/09_base_name_plus_base_time.{json,bin}`](../../test/fixtures/senml_cbor/) and Wick's encoder output for the same input.
