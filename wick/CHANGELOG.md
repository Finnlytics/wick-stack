# Changelog

All notable changes to Wick will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project skeleton.
- Tooling: Credo (strict), Dialyzer, ExDoc, ExCoveralls, StreamData.
- CI: GitHub Actions running format, credo, compile-with-warnings-as-errors, tests, dialyzer.
- Stub modules for `Wick.Path`, `Wick.Value`, `Wick.Codec`, `Wick.Codec.SenmlCbor`, `Wick.Error`.
- `Wick.CoreLink` — RFC 6690 CoRE Link Format encode/decode (`application/link-format`, Content-Format 40).
- `Wick.Registration` — LwM2M 1.2 Client Registration Interface (Register / Update / Deregister). Pure data types plus `to_wire/1`; the server side lives in `Wick.Registration.Server` and uses an in-memory `Wick.Registration.Store`.
- Integration test exercising Wick + WickCoap end-to-end registration round-trip (Register → Update → Deregister) over real CoAP/UDP.
- **`Wick.Wire`** — the canonical transport-agnostic request spec, shared by every interface. Adds `:accept` and `:observe` alongside the fields `Wick.Registration.Wire` carried, and supports the RFC 8132 `:fetch` / `:ipatch` methods the Composite operations need. `to_coap_options/1` flattens a spec to `{option_number, value_bytes}` pairs and `parse/3` reverses it, so a consumer's CoAP adapter is one `map/2` per direction rather than a per-operation translation table — see [ADR 0005](docs/decisions/0005-coap-option-tuples-at-the-wick-boundary.md). `Wick.Wire.Response` is the response counterpart.
- **Device Management interface** (§6.4) — `Wick.Request.to_wire/1` and `from_wire/1` for Read, Write (replace and partial-update), Execute, Discover, Create, Delete, Write-Attributes, Read-Composite, Write-Composite, Observe, Cancel-Observe, and Observe-Composite. `from_wire/1` resolves the operations that share a CoAP method: `Accept: 40` separates Discover from Read, the presence of a Content-Format separates Write from Write-Attributes, and path depth separates Create / partial-update Write / Execute on `POST`.
- `Wick.Response.to_wire/2` and `from_wire/1`, including Location-Path and the Observe sequence number.
- **`Wick.Attributes`** — the §5.1 attributes (`pmin`, `pmax`, `epmin`, `epmax`, `gt`, `lt`, `st`, `dim`, `ssid`, `uri`, `ver`) with Uri-Query and CoRE-Link-param codecs, `merge/2` honouring the `:clear` form, and `should_notify?/3`, a pure evaluator of the §5.1.2 notification decision.
- **`Wick.Request.WriteAttributes`** — the Write-Attributes operation (§6.4.12), previously deferred.
- **Information Reporting interface** (§6.5) — `Wick.Uplink.to_wire/1` and `from_wire/1` for Notify (a `2.05 Content` carrying the Observe option) and Send (`POST /dp`). `Wick.Observation` and `Wick.Observation.Store` record the server-side Observe relations that make an inbound Notification interpretable — a Notify carries no path — with the RFC 7641 §3.4 reordering test in `accept_seq/3`.
- **Bootstrap interface** (§6.1) — `Wick.Bootstrap` with Bootstrap-Request, Write, Delete, Discover, Read, and Finish, plus `to_wire/1` / `from_wire/1`. `from_wire/1` tells Bootstrap-Request from Bootstrap-Finish by the `ep` query parameter, since both are `POST /bs`. `Wick.Bootstrap.Session` is a pure state machine that enforces the provisioning order — it will not emit Bootstrap-Finish while any step is unacknowledged.
- **`Wick.Object.Tree`** — a client's Object *values*, as pure data, complementing `Wick.Object.Registry`'s Object *definitions*. Instance lifecycle, subtree reads, per-path attributes, CoRE Links for Register and Discover, and SenML Pack conversion in both directions.
- `Wick.Codec.for_content_format/1`, `senml_codec/1`, `senml?/1`, and `content_formats/0` — resolve a Content-Format integer to the codec that implements it, which is what a request handler needs when the peer chose the format.
- `Wick.Senml.Pack.resolve/1` (applies the RFC 8428 §4.5 base-prefix rules to yield effective names and times) and `to_paths/1` (the inverse of `from_paths/1`, for reading a Composite request body).
- `Wick.Path.to_segments/1` and `from_segments/1` — conversion to and from CoAP Uri-Path form.
- End-to-end integration tests over real CoAP/UDP for Device Management (every operation against a device backed by `Wick.Object.Tree`), Information Reporting (Observe → Notify → value change → Notify → Cancel-Observe, plus Send), and Bootstrap (a full provisioning session, including Bootstrap-Finish being refused when provisioning is incomplete).

### Changed
- **Breaking:** `Wick.Registration.Wire` is now `Wick.Wire`, and `Wick.Registration.to_wire/1` returns a `%Wick.Wire{}`. Both libraries are pre-release and unpublished on Hex, so this affects only code tracking `main`; the fix is the rename plus dropping any hand-rolled option-building in favour of `Wick.Wire.to_coap_options/1`.
- `Wick.Request.ReadComposite` and `Wick.Request.ObserveComposite` gained a `:content_format` field (defaulting to SenML CBOR, `112`) describing the *request body*, distinct from `:accept_content_format`, which asks for a format on the response. `to_wire/1` now encodes the path list itself rather than leaving it to the caller.

[Unreleased]: https://github.com/finnlytics/wick/compare/HEAD...HEAD
