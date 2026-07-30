# WickCoap

CoAP ([RFC 7252](https://www.rfc-editor.org/rfc/rfc7252)) wire format and runtime for Elixir.

WickCoap is the BEAM equivalent of [Eclipse Californium](https://eclipse.dev/californium/) — a generic CoAP library that knows nothing about the application protocol layered on top. It is the transport sibling of [Wick](https://github.com/Finnlytics/wick), which provides LwM2M protocol primitives. The two are independent; WickCoap can be used standalone for any CoAP application.

## Status

Pre-release. The wire format, runtime (retransmission, deduplication), Block-wise transfer (RFC 7959), Observe (RFC 7641), and DTLS over OTP `:ssl` are all in place. See [Security](#security) for what's possible and what is blocked upstream in OTP.

The library carries the full LwM2M 1.2 surface in [Wick](https://github.com/Finnlytics/wick) — all four interfaces, both directions — which is the closest thing to a real-world exercise it has had.

Two known gaps, both deferred rather than overlooked:

- **Multicast** is not implemented.
- **Server-side Observe relations are keyed by `{peer, uri_path_segments}`.** Correct for CoAP, where a resource is its path, but it means two concurrent observations on the *same* path from one peer share a relation. That is reachable from LwM2M's Composite operations, which target the root — see the Observe section of `WickCoap.Endpoint`'s docs for the detail and the workaround.

## Why this exists

There is currently a gap in the BEAM ecosystem for production CoAP. [`gen_coap`](https://github.com/gotthardp/gen_coap) is dormant; the EMQX fork is LwM2M-specific and tracks LwM2M 1.0.2 only. WickCoap fills that gap with a hand-written implementation that ships zero runtime dependencies and matches the RFC verbatim.

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP `~> 28`

## Installing

```elixir
# In your project's mix.exs while wick_coap is unpublished:
def deps do
  [
    {:wick_coap, path: "../wick_coap"}
    # or
    {:wick_coap, github: "finnlytics/wick_coap"}
  ]
end
```

## Getting started

WickCoap knows nothing about LwM2M — it is a generic CoAP library, and everything below works
for any CoAP application.

### A client

```elixir
{:ok, endpoint} = WickCoap.Endpoint.start_link([])   # ephemeral UDP port

request = %WickCoap.Message{
  type: :con,
  code: :get,
  message_id: 0,        # allocated by the Endpoint
  token: <<>>,          # allocated by the Endpoint
  options: [WickCoap.Option.new(11, "time")],
  payload: ""
}

{:ok, response} = WickCoap.Endpoint.request(endpoint, {{127, 0, 0, 1}, 5683}, request)
response.code    #=> :content
```

Retransmission (RFC 7252 §4.8) and Block2 reassembly (RFC 7959) are handled for you: a
multi-block response arrives as one logical reply however many datagrams it took.

### A server

Implement `WickCoap.Handler` and pass it in:

```elixir
defmodule TimeHandler do
  @behaviour WickCoap.Handler

  @impl true
  def handle_request(%WickCoap.Message{code: :get} = request, _peer, _state) do
    payload =
      case WickCoap.Handler.uri_path(request.options) do
        ["time"] -> DateTime.utc_now() |> DateTime.to_iso8601()
        _other -> "?"
      end

    {:reply,
     %WickCoap.Message{
       type: :ack,
       code: :content,
       message_id: request.message_id,
       token: request.token,
       options: [WickCoap.Option.from_uint(12, 0)],
       payload: payload
     }}
  end
end

{:ok, server} = WickCoap.Endpoint.start_link(port: 5683, handler: TimeHandler)
```

A response larger than the block size is fragmented via Block2 automatically — the handler
returns one response and stays oblivious.

### Observe

Server-side relations are managed for you. An inbound `GET` carrying `Observe: 0` registers a
relation and the sequence number is grafted onto whatever the handler returns; pushing an
update is one call:

```elixir
WickCoap.Endpoint.notify_observers(server, ["time"], %WickCoap.Message{
  type: :non,
  code: :content,
  message_id: 0,
  token: <<>>,
  options: [WickCoap.Option.from_uint(12, 0)],
  payload: "tick"
})
```

As a client, `observe/4` turns a request into a long-lived subscription. Notifications arrive
as `{:wick_coap_notification, handle, message}`, already filtered for RFC 7641 §3.4
reordering:

```elixir
{:ok, handle, initial} = WickCoap.Endpoint.observe(endpoint, peer, request)

receive do
  {:wick_coap_notification, ^handle, message} -> message.payload
end

WickCoap.Endpoint.cancel_observation(endpoint, handle)
```

### DTLS

Pass `transport: :dtls` plus `dtls_opts`, which go straight to OTP `:ssl`. See
[Security](#security) for what is and is not possible.

```elixir
{:ok, server} = WickCoap.Endpoint.start_link(
  port: 5684,
  handler: TimeHandler,
  transport: :dtls,
  dtls_opts: [
    ciphers: [%{mac: :aead, cipher: :aes_128_ccm_8, key_exchange: :psk, prf: :default_prf}],
    user_lookup_fun: {&MyPsk.lookup/3, %{"device-1" => "0123456789abcdef"}}
  ]
)
```

Outbound DTLS connections are made explicitly with `connect/3` before the first `request/4`.

## Development

```bash
mix deps.get
mix check
```

## Security

DTLS is offered by passing `transport: :dtls` plus a `dtls_opts` keyword list to `Endpoint.start_link/1`. Options are forwarded straight to OTP `:ssl`, so any cipher suite and credential format `:ssl` supports works here.

**Supported:**

- **PSK (RFC 4279).** Pass `user_lookup_fun: {&lookup/3, state}` and a PSK cipher suite (e.g. `TLS_PSK_WITH_AES_128_CCM_8`). Note that `:psk_identity` must be a charlist on the client side — Elixir binaries trigger a misleading `{:options, {:psk_identity, ...}}` error from OTP because the option goes through `get_opt_list/4`.
- **X.509.** Pass `certfile` / `keyfile` (or in-memory equivalents) on the server, and `verify: :verify_peer` plus `cacertfile` on the client. See `test/wick_coap/endpoint_dtls_x509_test.exs` for a runnable example.

**Not available — blocked upstream in OTP `:ssl`:**

- **RFC 9146 — DTLS Connection ID.** No support in OTP 28. Without CID, NAT rebinding breaks the underlying DTLS connection. We mitigate at the application layer: clients can use `Endpoint.ping/3` (RFC 7252 §4.3) as a NAT-keepalive, and an LwM2M Update with a fresh peer address can refresh the session record once the registration interface lands.
- **RFC 7250 — Raw Public Keys.** OTP `ssl_handshake.hrl` explicitly marks the extension as `Not supported`. That rules out **LwM2M Security Mode 3 (RPK)**; the other two modes (PSK / X.509) work normally.

Both gaps are tracked. If the constraint becomes painful, swap OTP `:ssl` for a userspace DTLS stack (significant scope; tabled for now).

## Decisions

- The architectural split between Wick and WickCoap is documented in [Wick ADR 0004](https://github.com/Finnlytics/wick/blob/main/docs/decisions/0004-wick-coap-as-sibling-library.md).
- Future WickCoap-specific decisions live in [docs/decisions/](docs/decisions/).

## License

[Apache 2.0](LICENSE).
