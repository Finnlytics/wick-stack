# ADR 0003 — Server-side Observe relations are keyed by `{peer, uri_path}`

**Status:** Accepted
**Date:** 2026-07-28

## Context

[RFC 7641](https://www.rfc-editor.org/rfc/rfc7641) lets a client register interest in a resource; the server then sends a notification whenever that resource changes. The server must remember, per observer: which peer, which resource, which token to echo, and what sequence number comes next.

`WickCoap.Endpoint` stores those relations in a map. The question is what to key it by, and there are two candidates:

- **`{peer, uri_path_segments}`** — the resource being observed. Natural for CoAP, where a resource *is* its path, and it makes the obvious API possible: `notify_observers(endpoint, ["temperature"], template)` — "this resource changed, tell whoever cares".
- **`{peer, token}`** — the exchange. This is what the *client* side uses, because a client tracks its own subscriptions by the token it issued.

Path-keying was chosen and has been in place since the runtime landed. Then Wick gained the LwM2M 1.1+ Composite operations, and a consequence surfaced.

LwM2M's `Observe-Composite` observes several paths at once. Its wire form is a `FETCH` to the **root**, with the paths carried in the request *body* as a SenML payload — not in the URI. So every Observe-Composite from a given peer has the same Uri-Path: none. They all key to `{peer, []}`, and a second one silently replaces the first.

This is not hypothetical. It was found by building a demo UI whose Observe button naturally targets an Object Instance, and it is the second-order effect of a decision made in a library that, by design, knows nothing about LwM2M.

## Decision

Keep `{peer, uri_path_segments}`. Document the limitation precisely, in the module docs and the README, and provide the workaround.

The reasoning:

1. **Path-keying is correct for CoAP.** WickCoap is a generic CoAP library ([ADR 0001](0001-hand-written-coap-rather-than-forking.md)). In CoAP, two observations on the same resource from the same peer *are* the same relation. The collision only looks wrong through an LwM2M lens, where the paths live in a payload the transport is not entitled to parse.
2. **Token-keying would change `notify_observers/3`'s contract.** The whole point of that function is "this path changed" — a caller that has to supply tokens has to track relations itself, which is the thing the Endpoint is doing on its behalf. Keying by token while keeping a path-based API means maintaining a second index and deciding what to do when they disagree.
3. **There is a clean workaround at the right layer.** A consumer that needs several concurrent Composite observations per device can track relations itself and push with `send_async/3`. Wick ships `Wick.Observation.Store` for exactly this, because the LwM2M layer *does* know how to interpret those paths.
4. **Single-path Observe is unaffected**, and so is the client side, which keys subscriptions by `{peer, token}`. The limitation is confined to a 1.1+ operation used by a minority of deployments.

Fixing it properly — keying server-side relations by token as well, and reworking the notification API around that — is deferred, not rejected.

## Consequences

**Good**

- `notify_observers/3` keeps the API that makes it useful: a path and a payload.
- No LwM2M knowledge leaks into a library that must not have any. Interpreting a FETCH body is the application protocol's job.
- The limitation is written down in three places — module docs, README, and here — so it is a decision rather than a trap. A consumer hitting it finds the workaround immediately.

**Bad**

- **Two concurrent Observe-Composite relations from one peer collide**, and the second wins with no error. That is a silent failure mode, which is the worst kind, and only documentation prevents it from being a bug report.
- A consumer needing that capability has to reimplement relation tracking, duplicating logic the Endpoint already has for the single-path case.
- The decision is likely to be revisited. Recording it as Accepted rather than deferred-indefinitely reflects that this is the right call *now*, at pre-release, with a documented escape hatch.

**Neutral**

- Block-wise transfer state uses the same `{peer, uri_path_segments}` keying and has the same theoretical exposure. It has not been reached in practice, because a Composite request body large enough to need Block1 is rare, but it is the same shape of problem and would be fixed by the same change.

## References

- [RFC 7641 §4.1](https://www.rfc-editor.org/rfc/rfc7641#section-4.1) — the list of observers a server maintains
- [RFC 8132](https://www.rfc-editor.org/rfc/rfc8132) — FETCH, the method LwM2M's Composite operations use
- `WickCoap.Endpoint` — the Observe section of the module docs states the limitation and the workaround
- `Wick.Observation.Store` — the LwM2M-side relation registry a consumer can use instead
