# WickDemoServer

A runnable LwM2M 1.2 server built on [Wick](../../wick) (protocol primitives) and [WickCoap](../../wick_coap) (CoAP transport), **with a browser UI** for driving registered devices. Implements **Registration**, **Device Management**, and **Information Reporting** with an in-memory store.

The nearest equivalent is Eclipse's `leshan-demo-server` and its webapp. This one covers the same ground — client list, Object tree browser, per-Resource operations, live notification feed — but as a single self-contained HTML page served by Plug, so `iex -S mix` is the entire toolchain. No Node, no npm, no build step.

It's a *demo*: single-node, in-memory, no persistence, no access control. Useful for:

- Driving a real device by hand and watching the protocol happen.
- Smoke-testing the Wick + WickCoap libraries against a real client ([`wick_demo_client`](../wick_demo_client), Leshan, or a constrained device).
- Reading: the modules are deliberately small so the boundary between *library code* and *application policy* is visible.

## What it implements

| Interface | § | Status |
|---|:-:|---|
| Registration | 6.2 | Register / Update / Deregister, with lifetime reaping |
| Device Management | 6.4 | Read, Write, Execute, Discover, Create, Delete, Write-Attributes, Read-Composite, Write-Composite |
| Information Reporting | 6.5 | Observe, Observe-Composite, Cancel-Observe, Notify ingest, Send ingest |
| Bootstrap | 6.1 | **Not here** — a Bootstrap Server is a separate deployment with different credentials, so it would be its own app. The library side is complete: see `Wick.Bootstrap` and `Wick.Bootstrap.Session`, and [`wick_demo_client`](../wick_demo_client)'s bootstrap test drives it. |

## Running

```bash
cd apps/wick_demo_server
mix deps.get
iex -S mix
```

Two boot log lines:

```
[info] WickDemoServer web UI on http://localhost:8683
[info] WickDemoServer.Endpoint listening on udp:5683 (handler=WickDemoServer.Handler)
```

Open **http://localhost:8683** and point any LwM2M 1.2 client at `coap://127.0.0.1:5683`. The quickest way to have something to look at is the sibling demo client, in a second terminal:

```bash
cd apps/wick_demo_client && iex -S mix
```

Each protocol event also logs a one-line summary:

```
[info] REGISTER ep=device-1 id=r0 lifetime=86400s from=127.0.0.1:54321
[info] READ id=r0 → content
[info] NOTIFY id=r0 seq=3 /3303/0/5700=22.7
[info] DEREGISTER id=r0 from=127.0.0.1:54321
```

## The web UI

Three panes:

- **Clients** — every registration, with its endpoint name, peer address, and a countdown to expiry. Click one to browse it.
- **Object tree** — the Object Instances the client advertised at Register. Expand an Object and each Instance gets **Read**, **Discover**, **Observe**, **Delete**, plus collapsible forms for **Write**, **Execute**, and **Write-Attributes**. Results render inline: SenML bodies become a path/value table with type annotations, link-format becomes a target/attributes table.
- **Event log** — live, over Server-Sent Events. Teal is device-initiated (Notify, Send, Observe established), purple is server-initiated (an outbound Read, Write, Execute).

### Observing something

Notification attributes come first, or the device notifies on every single change:

1. Open **Attributes…** on the Resource and set `pmin 5`, `st 1` — at most one Notification per 5s, and only for changes of a whole degree or more. (Type `clear` in a field to remove that attribute.)
2. Click **Observe**. The button turns solid and the relation appears under **Observations**.
3. Notifications stream into the event log as the client's synthetic sensor drifts.

Observing an **Object Instance** rather than a single Resource works too, and each Notification then carries every Resource in the Instance.

### Why the observation list matters

A Notification carries a payload, a Content-Format, and a sequence number — and **no path**. Nothing in the datagram says which Resource changed. The only thing that makes it interpretable is the server's own record of the Observe that caused it, which is what `WickDemoServer.Observations` holds. Lose it and notifications become undecodable bytes.

### HTTP API

The UI is a client of a plain JSON API, so `curl` works just as well:

```bash
curl localhost:8683/api/registrations

curl -X POST localhost:8683/api/registrations/r0/read \
  -H 'content-type: application/json' -d '{"path":"/3/0/0","accept":0}'

curl -X POST localhost:8683/api/registrations/r0/write \
  -H 'content-type: application/json' \
  -d '{"path":"/3303/0/5700","value":{"type":"float","value":21.5}}'

curl -N localhost:8683/api/events        # live SSE stream
```

Full route list in `WickDemoServer.Web.Router`'s moduledoc. Values carry their LwM2M type explicitly (`{"type":"float","value":21.5}`) because JSON, like SenML, cannot tell an Integer from a Float or a String from an Opaque.

A `4xx` means the *request* was wrong; a `2xx` carrying an LwM2M error status means the *device* said no. A device answering `4.04 Not Found` is a successful exchange with an error result.

## Configuration

All settings live in `config/config.exs` and per-env overrides. Override at runtime via `config :wick_demo_server, KEY: ...`:

| Key                 | Default | Meaning |
|---------------------|---------|---------|
| `:port`             | `5683`  | UDP port. `0` binds an ephemeral port. |
| `:http_port`        | `8683`  | TCP port for the web UI. `nil` runs headless. Not 8080 — that is usually taken locally. |
| `:transport`        | `:udp`  | `:udp` or `:dtls`. DTLS uses PSK only — see below. |
| `:psk_db`           | `%{}`   | `%{identity => secret}` map, both binaries. Required for `:dtls`. |
| `:reaper_interval_ms` | `1000` | How often the store sweeps for expired registrations. |

### DTLS PSK

```elixir
config :wick_demo_server,
  transport: :dtls,
  port: 5684,
  psk_db: %{
    "device-1" => "0123456789abcdef",
    "device-2" => "fedcba9876543210"
  }
```

Identities outside the map are rejected during the DTLS handshake. RFC 9146 Connection ID and RFC 7250 Raw Public Keys are **not** supported because OTP `:ssl` doesn't implement them — see [WickCoap README → Security](../../wick_coap/README.md#security).

## Inspecting state from IEx

```elixir
iex> WickDemoServer.registrations()
[
  %Wick.Registration.Record{
    endpoint_name: "wick-demo-client",
    location_id: "r0",
    lifetime: 60,
    ...
  }
]

iex> WickDemoServer.port()
5683
```

## Driving a device from IEx

Every operation takes the `location_id` from the registration — see [Reaching a device](#reaching-a-device) for why that, and not an IP address, is the handle.

```elixir
iex> [reg] = WickDemoServer.registrations()
iex> id = reg.location_id

# Read. `accept: 0` asks for text/plain, which is easier to eyeball than SenML CBOR.
iex> {:ok, response} = WickDemoServer.read(id, "/3/0/0", accept: 0)
iex> response.payload
"Finnlytics"

# Write. Values are {type, value} tuples — SenML can't tell an Integer from a Float.
iex> WickDemoServer.write(id, "/3303/0/5700", {:float, 21.5})
{:ok, %Wick.Response{status: :changed}}

# Execute, Discover, Create, Delete.
iex> WickDemoServer.execute(id, "/3/0/4")                       # Reboot
iex> WickDemoServer.discover(id, "/3303/0")
iex> WickDemoServer.create(id, "/3303", %{5700 => {:float, 5.0}})
iex> WickDemoServer.delete(id, "/3303/1")

# Composite operations — several paths in one exchange.
iex> WickDemoServer.read_composite(id, ["/3/0/0", "/3303/0/5700"])
iex> WickDemoServer.write_composite(id, %{"/3/0/15" => {:string, "+02:00"}})
```

## Observing a device

Notification attributes come first, or the device notifies on every change:

```elixir
# At most one Notification per 5s, and only for changes of a degree or more.
iex> WickDemoServer.write_attributes(id, "/3303/0/5700",
...>   %Wick.Attributes{pmin: 5, pmax: 300, st: 1.0})

iex> {:ok, handle} = WickDemoServer.observe(id, "/3303/0/5700")

# ... the device's sensor drifts, and Notifications arrive ...
iex> WickDemoServer.readings() |> hd()
%{source: :notify, observe_seq: 3, readings: [{"/3303/0/5700", 22.7}], at: 1234}

iex> WickDemoServer.observations()
[%Wick.Observation{registration_id: "r0", paths: [...], last_value: 22.7, ...}]

iex> WickDemoServer.cancel_observe(id, "/3303/0/5700", handle)
```

`WickDemoServer.readings/0` also collects `Send` uplinks (`source: :send`), which arrive with no prior Observe.

### Why observations must be stored

A Notification carries a payload, a Content-Format, and a sequence number — and **no path**. Nothing in the datagram says which Resource changed. The only thing that makes it interpretable is the server's own record of the Observe that caused it, which is why `WickDemoServer.Observations` exists and why relations are stored the moment `observe/3` returns.

LwM2M ties observations to the registration (§6.2), so they are dropped when a device deregisters or its lifetime expires.

## Reaching a device

Every Device Management call is keyed by `location_id` rather than by address, because a device is typically behind NAT or a carrier gateway and has no address the server can dial. The only reachable address is the source of the device's own Register, which `Wick.Registration.Record` carries as `peer`. It is also why a registration expiring makes a device *unreachable* rather than merely stale.

## Status — what's NOT here yet

| Feature | Where it'll land |
|---|---|
| Bootstrap Server | A separate app — different credentials, different trust position. `Wick.Bootstrap` is ready. |
| Access Control (Object 2) | Wick library; §6.3.4 is unimplemented, so every server has full rights |
| Persistent storage | Outside scope — swap `WickDemoServer.Store` for a Postgres-backed module |
| Queue Mode (§6.2.1 `Q`) | Requires holding requests for a sleeping device; the store would need a per-device queue |
| Authentication on the web UI | There is none. The UI can Write and Execute against every registered device, so bind it to localhost and don't expose it. |
| A CoAP message tracer | Leshan's demo shows raw CoAP frames; here the event log is at the LwM2M level |

## Architecture

```
                ┌─────────────────────────────────────────────────┐
  Device ─UDP──▶│ WickCoap.Endpoint                               │
                │   ├─ requests ──▶ Handler                       │
                │   │                 ├─ /rd* ──▶ Store           │
                │   │                 │           ↓               │
                │   │                 │   Wick.Registration       │
                │   │                 └─ /dp  ──▶ Observations    │
                │   │                             (Uplink.Send)   │
                │   └─ notifications ──▶ Observations             │
                │        matched by token, never dispatched to    │
                │        the handler — a Notify is a *response*   │
                │                          │                      │
  Device ◀─UDP──┤ Client                   │ Events (pub/sub)     │
                │   Wick.Request.to_wire   │      │               │
                │        ↓                 ↓      ↓               │
                │       Coap ──▶ Endpoint  Web.Router             │
                └──────────────────────────────┬──────────────────┘
                                               │ JSON + SSE
  Browser ─────────────────────────────────────┘
```

The `Events` bus is what keeps the protocol code unaware of the web layer: `Store`,
`Observations`, and `Client` publish; with no subscribers `publish/2` is a no-op, so the
IEx-only path costs exactly what it did before the UI existed.

```
lib/wick_demo_server/
  application.ex     supervision tree (Events → Store → Observations → Endpoint → Bandit)
  endpoint.ex        the WickCoap.Endpoint, UDP or DTLS
  handler.ex         inbound: /rd* registration, /dp Send uplinks
  store.ex           registrations + the lifetime reaper
  observations.ex    Observe relations, notification ingest, the reading log
  client.ex          outbound: every DM and Information Reporting operation
  coap.ex            the ~40-line Wick.Wire ↔ WickCoap adapter
  events.ex          pub/sub over Registry, so the web layer can watch without coupling
  web/router.ex      JSON API + the SSE stream
  web/api.ex         JSON serialisation
  web/ui.ex          the page: markup, CSS, and JS in one string
```

Everything in `WickDemoServer.*` is *application* code. Everything under `Wick.*` and `WickCoap.*` is *library* code that survives unchanged into production.

## Tests

```bash
mix test
```

`test/web_test.exs` drives the router through `Plug.Test` — routing, parameter validation, and the 4xx-vs-LwM2M-error distinction. `test/wick_demo_server_test.exs` covers registration over real UDP. The full server-drives-device path lives in [`wick_demo_client`](../wick_demo_client)'s `test/device_management_test.exs`.
