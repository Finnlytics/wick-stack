# ADR 0007 — In-memory stores ship as pure data, not processes

**Status:** Accepted
**Date:** 2026-07-30

## Context

Wick's charter says it ships no transport and no running processes: every module is either pure data or pure functions over data, and the consumer owns state and life-cycle policy.

Three pieces of Wick sit awkwardly against that claim, because they are unmistakably *state*:

- `Wick.Registration.Store` — which devices are registered, keyed by location ID.
- `Wick.Observation.Store` — which Observe relations exist, and what each last reported.
- `Wick.Object.Tree` — a client's Resource values.

A protocol library could handle these three ways:

1. **Own them as processes.** Ship a `GenServer` per store, supervised, with a public API. Convenient out of the box.
2. **Define a behaviour and ship no implementation.** Maximum purity: the consumer implements `Wick.Registration.Store` against Postgres, ETS, or whatever, and Wick only specifies the contract.
3. **Ship them as pure immutable data structures** with pure functions, and let the consumer decide what holds them.

Option 1 is what most protocol libraries do, and it is why they are hard to test and hard to embed. It forces a supervision tree on the consumer, makes the store's lifetime the library's business, and turns "what happens when a registration expires" into a policy baked into someone else's process.

Option 2 sounds principled but has a specific cost: it makes Wick unusable without first writing an adapter. Every test, every demo, and every prototype starts with boilerplate. It also means the reference semantics — what *should* happen when a device re-registers under a name that already exists — live in prose rather than code.

`Wick.Registration.Store`'s own module docs promised an ADR on this boundary and referenced "ADR (TBD)", which was never written. This is that ADR.

## Decision

Ship them as **pure data with pure functions** — option 3 — and make the persistence boundary explicit rather than abstract.

Concretely:

- `Store.new/0` returns a struct. Every mutating function takes the struct and returns a new one: `put_new/2` returns `{location_id, store}`, `delete/2` returns a store.
- No process, no clock, no I/O. Where time is needed it is passed in: `Wick.Observation.new/3` takes `:now`, and `Wick.Observation.accept_seq/3` takes `:now`. Where an ID is needed the store allocates it deterministically from a counter.
- The consumer decides what holds the struct. `WickDemoServer.Store` wraps it in a `GenServer` and adds a lifetime reaper; a production deployment would swap that for a Postgres-backed module and keep the same call sites.

No behaviour is defined. A consumer replacing the store does not implement a callback module — it writes its own thing with whatever API suits it. Defining a behaviour would constrain the replacement to Wick's shape, which is the opposite of the intent, and would imply Wick can be configured to use it, which it cannot.

## Consequences

**Good**

- Testable without ceremony. The registration and observation tests are function calls on a struct; there is no process to start, no `async: false`, and no cleanup.
- The reference semantics are executable. "A fresh Register from a known endpoint name replaces the old record" is a line of code in `put_new/2`, not a paragraph a reimplementer has to interpret.
- The consumer's supervision tree stays the consumer's. Wick contributes nothing to it, which is what lets the same library drive a server, a device, and a test with no configuration.
- Time being an argument rather than a call is what makes `Wick.Attributes.should_notify?/3` and the RFC 7641 reordering logic testable at all — a test asserts on `since_last_ms: 61_000` rather than sleeping.

**Bad**

- **These stores are not production storage, and the name invites the assumption that they might be.** They are in-memory, single-node, and hold everything for the lifetime of whatever process owns the struct. Every one says so in its module docs; that is the only guard.
- The consumer must serialise access. A struct threaded through concurrent CoAP exchanges without a process around it will lose writes. `Wick.Registration.Store`'s docs state this, and the demo shows the `GenServer` pattern, but nothing enforces it.
- Swapping in a real store is a rewrite of the wrapper, not a config change. Accepted: the wrapper is small, and the alternative — a behaviour — buys configurability nobody asked for at the cost of constraining the replacement.

**Neutral**

- `Wick.Registration.Server` is the same shape one level up: `handle/2` takes a parsed request and a store and returns `{response, store}`. Pure, no process. The demo server's `GenServer` is 80 lines including the reaper, which is roughly the floor for this pattern and seems a fair price.
- This is the same reasoning as [ADR 0005](0005-coap-option-tuples-at-the-wick-boundary.md), applied to state rather than to transport: Wick describes, the consumer performs.

## References

- [ADR 0001 — Zero runtime dependencies](0001-zero-runtime-dependencies.md) — the same instinct applied to the dependency tree
- [ADR 0003 — Time fields as plain numbers](0003-time-fields-as-plain-numbers.md) — why timestamps are integers a caller supplies
- [ADR 0005 — CoAP option numbers as the Wick/transport boundary](0005-coap-option-tuples-at-the-wick-boundary.md)
- `Wick.Registration.Store`, `Wick.Observation.Store`, `Wick.Object.Tree` — the three structures this governs
- `WickDemoServer.Store` in the demo — the `GenServer` wrapper, with the reaper as an example of consumer-owned life-cycle policy
