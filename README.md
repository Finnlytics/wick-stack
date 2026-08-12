# Wick Stack

LwM2M and CoAP for the BEAM — two libraries and two runnable demos, in one repository.

There is currently a gap in the Elixir ecosystem for either protocol. [`gen_coap`](https://github.com/gotthardp/gen_coap) is dormant; the EMQX fork is LwM2M-specific and tracks LwM2M 1.0.2 only. This stack targets **LwM2M 1.2** and implements all four of its interfaces in both directions, so it drives a client as readily as a server.

## What's here

| Project | Package | What it is |
|---|---|---|
| [`wick/`](wick) | `wick` | LwM2M protocol primitives — codecs, Object Model, paths, requests, responses, the four interfaces. No transport, no processes. |
| [`wick_coap/`](wick_coap) | `wick_coap` | CoAP ([RFC 7252](https://www.rfc-editor.org/rfc/rfc7252)) wire format and runtime. Generic: knows nothing about LwM2M. |
| [`demo/wick_demo_server/`](demo/wick_demo_server) | — | A working LwM2M server **with a browser UI** for driving devices. |
| [`demo/wick_demo_client/`](demo/wick_demo_client) | — | A working LwM2M device with an Object tree and a synthetic sensor. |

The two libraries are published as separate Hex packages and are usable independently. `wick_coap` in particular is worth taking on its own if you want CoAP without LwM2M.

## Interface coverage

| Interface | § | Status |
|---|:-:|---|
| Bootstrap | 6.1 | Request / Write / Delete / Discover / Read / Finish, plus a session state machine that enforces provisioning order |
| Registration | 6.2 | Register / Update / Deregister, with an in-memory store and lifetime reaping |
| Device Management | 6.4 | Read, Write, Execute, Discover, Create, Delete, Write-Attributes, and the Composite variants |
| Information Reporting | 6.5 | Observe, Observe-Composite, Cancel-Observe, Notify, Send, with notification attributes and RFC 7641 reordering |

Codecs: SenML CBOR and JSON, Plain Text, Opaque — all bidirectional and verified against Eclipse Leshan as a test oracle. Not yet done: LwM2M CBOR and TLV (SenML covers 1.1+ deployments), and Access Control (Object 2, §6.3.4).

## Try it

```bash
./run-demo.sh
```

That builds both demos, starts the server (CoAP on 5683, web UI on 8683) and a device that registers with it, streams both logs into the one terminal, and opens the UI. Ctrl-C stops both — the device deregisters on the way out. `--server-only` leaves the CoAP port free for Leshan or a real device; `--help` lists the rest.

The page opens on a four-step guide: pick the device, Read it, Write to it, then set notification attributes and Observe it with notifications streaming in live.

Both nodes run named, so the IEx recipes in the demo READMEs are still a `--remsh` away — the exact command is printed at startup.

By hand instead, two terminals:

```bash
cd demo/wick_demo_server && mix deps.get && iex -S mix
cd demo/wick_demo_client && mix deps.get && iex -S mix
```

> The UI has no authentication and can Write and Execute against every registered device, so it binds to loopback only. Override with `config :wick_demo_server, http_ip: {0, 0, 0, 0}` if you want it reachable — and put something authenticating in front of it.

## Why one repository

The two libraries are deliberately separate *packages* — [Wick ADR 0004](wick/docs/decisions/0004-wick-coap-as-sibling-library.md) explains why CoAP does not belong inside an LwM2M library. They are not separate *repositories*, because changes routinely span both: adding Observe-Composite to Wick is what surfaced a relation-keying limitation in WickCoap. With one repository, `wick` resolves `wick_coap` through a relative path and CI tests a cross-library change as a single commit. See [ADR 0006](wick/docs/decisions/0006-single-repository-for-the-wick-stack.md).

## Layout

```
wick/                    the LwM2M library    → hex: wick
wick_coap/               the CoAP library     → hex: wick_coap
demo/wick_demo_server/   server + web UI
demo/wick_demo_client/   device
.github/workflows/ci.yml one workflow, one job per project
```

Path dependencies are relative and resolve within the tree: `wick` → `../wick_coap`, the demos → `../../wick`.

## Development

Each project is an ordinary Mix project. From its own directory:

```bash
mix deps.get
mix check        # libraries: format, credo --strict, warnings-as-errors, test, dialyzer
mix test
```

Or across everything:

```bash
for d in wick wick_coap demo/wick_demo_server demo/wick_demo_client; do (cd $d && mix test); done
```

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP `~> 28`

Pinned per project in `.tool-versions` for [asdf](https://asdf-vm.com) / [mise](https://mise.jdx.dev).

## Decisions

Load-bearing technical choices are recorded as ADRs, with the *why* behind each. Each library keeps its own log, numbered separately, and both are published with the library's docs.

**[`wick/docs/decisions/`](wick/docs/decisions/)**

| # | Title |
|---|-------|
| [0001](wick/docs/decisions/0001-zero-runtime-dependencies.md) | Zero runtime dependencies |
| [0002](wick/docs/decisions/0002-oracle-pinned-to-leshan-2x.md) | Oracle pinned to Leshan 2.0.0-M18 |
| [0003](wick/docs/decisions/0003-time-fields-as-plain-numbers.md) | SenML time fields as plain numbers |
| [0004](wick/docs/decisions/0004-wick-coap-as-sibling-library.md) | `wick_coap` as a sibling library |
| [0005](wick/docs/decisions/0005-coap-option-tuples-at-the-wick-boundary.md) | CoAP option numbers as the transport boundary |
| [0006](wick/docs/decisions/0006-single-repository-for-the-wick-stack.md) | One repository for the Wick stack |
| [0007](wick/docs/decisions/0007-in-memory-stores-as-pure-data.md) | In-memory stores as pure data, not processes |

**[`wick_coap/docs/decisions/`](wick_coap/docs/decisions/)**

| # | Title |
|---|-------|
| [0001](wick_coap/docs/decisions/0001-hand-written-coap-rather-than-forking.md) | Hand-written CoAP, rather than forking |
| [0002](wick_coap/docs/decisions/0002-dtls-via-otp-ssl.md) | DTLS via OTP `:ssl`, accepting two missing extensions |
| [0003](wick_coap/docs/decisions/0003-observe-relations-keyed-by-path.md) | Observe relations keyed by `{peer, uri_path}` |

If you read only two: [Wick 0004](wick/docs/decisions/0004-wick-coap-as-sibling-library.md) explains why there are two libraries, and [Wick 0005](wick/docs/decisions/0005-coap-option-tuples-at-the-wick-boundary.md) explains how they meet without depending on each other.

## License

[Apache 2.0](wick/LICENSE).
