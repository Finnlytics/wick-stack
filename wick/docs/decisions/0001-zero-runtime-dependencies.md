# ADR 0001 — Zero runtime dependencies

**Status:** Accepted
**Date:** 2026-05-06

## Context

We need to encode and decode SenML CBOR (and, eventually, SenML JSON, LwM2M CBOR, and other LwM2M wire formats) bit-identically against an established reference implementation (Eclipse Leshan). The default approach would be to depend on an existing Elixir CBOR library and let it handle the wire format.

We empirically evaluated [`cbor`](https://hex.pm/packages/cbor) v1.0.2 (the most established Elixir CBOR library, MIT-licensed, ~520 lines, fork of the unmaintained `excbor`). Findings:

- **Integer encoding** is correct and shortest-form per RFC 8949 §3.1.
- **Float encoding** always emits 64-bit doubles (`fb` prefix), even when the value fits exactly in float16 or float32. Leshan's [`com.upokecenter.cbor`](https://github.com/peteroupc/CBOR-Java) uses shortest-form per RFC 8949 §4.2.1.
- **Map ordering** iterates Elixir's internal hash order. Leshan emits map keys in field-declaration order (`bn, bt, n, t, value`). Neither matches the other.
- **No deterministic-encoding mode** is exposed in the library API.

A library-based path requires either monkey-patching the float and map behaviours, or constructing CBOR maps ourselves with explicit ordering — at which point we're using the library only for its primitive heads, which are themselves trivial.

CBOR for the LwM2M subset uses major types 0/1/2/3/4/5/7 with definite-length items, no tags, no bignums, no streaming. The full encoder fits in ~100 lines; decoder ~150.

## Decision

Wick has zero runtime dependencies. Every wire format we ship is hand-written against the relevant RFC.

The tooling deps in `mix.exs` (`credo`, `dialyxir`, `ex_doc`, `excoveralls`, `stream_data`, `jason`) are dev/test only — they do not appear in `mix.exs`'s `package[:files]` and do not ship with the runtime artefact.

`Decimal` is also rejected. Leshan uses `BigDecimal` for time/value fields because Java's `Number` doesn't preserve int-vs-decimal-vs-float at the type level. Elixir's `integer() | float()` does.

## Consequences

**Good**

- Bit-identical CBOR output is achievable. We control every byte.
- No supply-chain drift; no dependency upgrades dragging behaviour with them.
- The code that produces wire bytes is small, self-contained, and auditable.
- Consumers' dependency graphs aren't polluted by a transitive choice we made.

**Bad**

- Wick owns ~250 lines of CBOR code (~100 encoder, ~150 decoder when implemented). If a CBOR-level bug surfaces, it's on us to fix.
- We cannot benefit from upstream improvements to the `cbor` library.

**Neutral**

- The internal `Wick.Cbor` module is `@moduledoc false`. It's not part of the public API today; promoting it later (e.g., for a public CBOR type if Wick grows beyond LwM2M) is a non-breaking change.

## References

- [`Wick.Cbor`](../../lib/wick/cbor.ex)
- [RFC 8949 — Concise Binary Object Representation](https://www.rfc-editor.org/rfc/rfc8949)
- Empirical evaluation captured in commit history (the `cbor` dep was added, tested, removed).
