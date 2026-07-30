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

### Documented

- `WickCoap.Endpoint`'s Observe section now records that server-side relations are keyed by `{peer, uri_path_segments}`, and what that means for a consumer layering LwM2M Composite operations on top: those target the root, so two concurrent Observe-Composite relations from the same peer share a key and the second replaces the first. Single-path Observe and the client side (keyed by `{peer, token}`) are unaffected. Not a code change — the behaviour is unchanged, it was simply undocumented, and Wick gaining Observe-Composite made it reachable.

[Unreleased]: https://github.com/finnlytics/wick_coap/compare/HEAD...HEAD
