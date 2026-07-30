# Changelog

All notable changes to WickCoap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial scaffold mirroring the Wick conventions — Credo strict, Dialyzer, ExDoc, ExCoveralls, StreamData.
- `WickCoap.Code` — bidirectional mapping between CoAP method/response codes and atoms.
- `WickCoap.Option` — option list with delta-length encoding per RFC 7252 §3.1.
- `WickCoap.Message` — message struct with `encode/1` and `decode/1`.
- `WickCoap.Endpoint` — GenServer runtime with retransmit, dedup, Block-wise (RFC 7959 Block1+Block2), Observe (RFC 7641 server+client).
- DTLS transport — `transport: :dtls`, plus `connect/3` for outbound peers. PSK and X.509 supported; RFC 9146 (Connection ID) and RFC 7250 (RPK) are blocked upstream in OTP `:ssl` — see README.
- `WickCoap.Endpoint.ping/3` — CoAP Ping (RFC 7252 §4.3) for application-layer liveness / NAT keepalive.

### Documentation

- `WickCoap.Endpoint`'s Observe section now records that server-side relations are keyed by `{peer, uri_path_segments}`, and what that means for a consumer layering LwM2M Composite operations on top: those target the root, so two concurrent Observe-Composite relations from the same peer share a key and the second replaces the first. Single-path Observe and the client side (keyed by `{peer, token}`) are unaffected. Not a code change — the behaviour is unchanged, it was simply undocumented, and Wick gaining Observe-Composite made it reachable.
- **The decision log now exists.** It previously held only an index, which said "empty — first decision will land with the first non-trivial choice", while three such choices had already been made:
  - [ADR 0001](docs/decisions/0001-hand-written-coap-rather-than-forking.md) — hand-written CoAP with zero runtime dependencies, and why this was not forked from `gen_coap` or the EMQX fork.
  - [ADR 0002](docs/decisions/0002-dtls-via-otp-ssl.md) — DTLS via OTP `:ssl`, and the consequences of RFC 9146 and RFC 7250 being unavailable: no LwM2M Security Mode 3, and NAT rebinding breaking sessions.
  - [ADR 0003](docs/decisions/0003-observe-relations-keyed-by-path.md) — why Observe relations stay keyed by path despite the Composite collision, and the workaround.
- The decision records are published with the docs, and every module is now grouped on HexDocs by the RFC it implements.
- A getting-started guide: a client, a server via `WickCoap.Handler`, both sides of Observe, and DTLS. Every sample was executed against the library, including a live Observe round-trip.
- Source links now carry the repository subdirectory, so "source" on HexDocs resolves. Both libraries share one repository — see [Wick ADR 0006](../wick/docs/decisions/0006-single-repository-for-the-wick-stack.md).

[Unreleased]: https://github.com/Finnlytics/wick-stack/compare/HEAD...HEAD
