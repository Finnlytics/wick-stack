# WickDemoClient

A runnable LwM2M 1.2 **client** built on [Wick](../../wick) + [WickCoap](../../wick_coap). Counterpart to [`apps/wick_demo_server`](../wick_demo_server) — together they prove the Wick stack works end-to-end over real CoAP/UDP.

This is the first piece of code that *uses* Wick the way a real device would, and a stepping stone for the firmware that will eventually run on the nRF54L15.

## What it implements

| Interface | § | Status |
|---|:-:|---|
| Registration | 6.2 | Register / Update / Deregister, with automatic re-registration on `4.04` |
| Device Management | 6.4 | Answers Read, Write, Execute, Discover, Create, Delete, Write-Attributes, and the Composite variants against a real `Wick.Object.Tree` |
| Information Reporting | 6.5 | Serves Observe / Observe-Composite, emits Notify when the notification attributes allow, and pushes Send uplinks |
| Bootstrap | 6.1 | Sends Bootstrap-Request and applies inbound Write / Delete / Discover / Read / Finish |

## Object inventory

| Object | Name | Why it's here |
|--------|------|---------------|
| `1` | Server | A registered client must have a Server Account, and it's what a Bootstrap-Write provisions |
| `3` | Device | Mandatory for every LwM2M client (§C.3). Includes an Execute-only Reboot Resource |
| `3303` | IPSO Temperature | Something that *changes* — the point of Observe. Driven by `WickDemoClient.Sensor` |

Values are stored as `{type, value}` tuples (`{:float, 22.5}`, `{:string, "Cel"}`) because SenML can't tell an Integer from a Float, or a String from an Opaque. See `Wick.Object.Tree`.

## Running alongside the demo server

```bash
# Terminal 1 — server on UDP 5683, web UI on 8683
cd apps/wick_demo_server
iex -S mix
# [info] WickDemoServer web UI on http://localhost:8683
# [info] WickDemoServer.Endpoint listening on udp:5683 (handler=WickDemoServer.Handler)

# Terminal 2 — client connects to localhost:5683
cd apps/wick_demo_client
iex -S mix
# [info] WickDemoClient.Endpoint bound on UDP/<ephemeral> (handler=WickDemoClient.Handler)
# [info] REGISTER ok ep=wick-demo-client → id=r0 (lifetime=60s)
```

Then open **http://localhost:8683** — the server's UI lists this client, browses its Object tree, and drives Read / Write / Execute / Observe against it, with notifications streaming live as the sensor drifts. That is the easiest way to see the stack work; the IEx recipes below do the same thing by hand.

From the **server's** IEx, drive the device:

```elixir
iex> [reg] = WickDemoServer.registrations()
iex> WickDemoServer.read(reg.location_id, "/3/0/0", accept: 0)
{:ok, %Wick.Response{status: :content, payload: "Finnlytics"}}

iex> WickDemoServer.write_attributes(reg.location_id, "/3303/0/5700",
...>   %Wick.Attributes{pmin: 5, st: 1.0})
iex> {:ok, handle} = WickDemoServer.observe(reg.location_id, "/3303/0/5700")
# ... Notifications arrive as the sensor drifts past the step threshold ...
iex> WickDemoServer.readings() |> hd()
```

From the **client's** IEx, inspect and drive the device side:

```elixir
iex> WickDemoClient.status()
{:registered, "r0"}

iex> WickDemoClient.read("/3/0/0")
{:ok, {:string, "Finnlytics"}}

iex> WickDemoClient.tree() |> Wick.Object.Tree.links() |> Enum.map(& &1.target)
["/1/0", "/3/0", "/3303/0"]

iex> WickDemoClient.tick()              # one sensor reading; notifies if attributes allow
:notified

iex> WickDemoClient.set_temperature(31.5)
:notified

iex> WickDemoClient.send_values()       # Send uplink — no prior Observe needed
{:ok, %Wick.Response{status: :changed}}
```

## The sensor, and why notifications are not one-per-change

`WickDemoClient.Sensor` takes a reading every `:sensor_interval_ms`, drifting by a small random step. Each reading goes to `WickDemoClient.Device`, which asks `Wick.Attributes.should_notify?/3` whether a Notification is actually due given what the server wrote:

- `pmin` is a hard floor on notification rate — nothing gets through inside it, however large the change.
- `pmax` forces a Notification even when nothing changed.
- `st` (step) suppresses changes smaller than the threshold.
- `gt` / `lt` fire on *crossing* a threshold, not on staying past it.

Setting any of `st`, `gt`, or `lt` means "only tell me about these changes" — plain value changes stop notifying. That's why `tick/0` returns `:notified` or `:quiet`.

The division of labour: the *decision* is Wick's (a pure function), the *dispatch* is WickCoap's (`notify_observers/3` owns the relations and sequence numbers), and the Sensor contributes only the clock.

### Notifying at every level

A change to `/3303/0/5700` is also a change to `/3303/0` and to `/3303`, and LwM2M lets a server Observe at any of those levels. `WickCoap.Endpoint` keys relations by exact URI path, so the Sensor notifies each ancestor in turn — otherwise a server that observed the Object Instance, which is the natural thing to ask for, would silently receive nothing. Each level gets its own payload, because an Instance-level Notify must carry the Instance's Resources rather than just the one that moved.

## Bootstrap

The client is pre-provisioned with a Server Object, so it never needs to bootstrap on boot. To exercise the flow against a Bootstrap Server:

```elixir
iex> WickDemoClient.bootstrap()
iex> WickDemoClient.bootstrapping?()
true
```

`request/1` opens the session and sends Bootstrap-Request; it does **not** wait for provisioning. The Deletes and Writes that follow arrive as *inbound* requests, and the session closes when the server's Bootstrap-Finish is accepted — which the client refuses unless it now holds a usable Security and Server Object pair.

### Why the session flag matters

A Bootstrap-Write and a Device Management Write are **the same bytes on the wire**. The only thing that distinguishes them is whether a bootstrap session is open: a Bootstrap-Write may target the Security Object and create Instances, a DM Write may not. So `WickDemoClient.Device` routes on the flag — through `Wick.Bootstrap.from_wire/1` while bootstrapping, `Wick.Request.from_wire/1` otherwise. `test/bootstrap_test.exs` asserts both halves: the same request accepted during a session and refused after it.

## Configuration

`config/config.exs`:

| Key | Default | Meaning |
|-----------------|--------------------------|---------|
| `:server_host` | `{127, 0, 0, 1}` | LwM2M server IP. |
| `:server_port` | `5683` | LwM2M server UDP port. |
| `:endpoint_name`| `"wick-demo-client"` | Globally-unique device identity. |
| `:lifetime` | `60` | Registration lifetime (seconds). Updates fire at `lifetime * 0.8`. Also seeds `/1/0/1`. |
| `:autostart` | `true` | Register on app boot. Tests set this to `false`. |
| `:transport` | `:udp` | Plain UDP only for v1. |
| `:sensor_interval_ms` | `10_000` | How often the synthetic sensor reads. `nil` keeps it idle — tests use this so readings are driven explicitly rather than by wall-clock time. |
| `:bootstrap_server_host` / `:bootstrap_server_port` | `{127,0,0,1}` / `5783` | Only used by `WickDemoClient.bootstrap/1`. |

## What's NOT here

| Feature | Where it'll land |
|---|---|
| DTLS PSK | Turn on `transport: :dtls` and pass `dtls_opts` with `psk_identity` + `user_lookup_fun` |
| Queue Mode (§6.2.1 `Q`) | Needs a sleep/wake cycle; the server side would need to hold requests |
| Access Control (Object 2) | Wick library; §6.3.4 is unimplemented |
| Firmware Update (Object 5) | Needs Block1 upload plus real state machine semantics |

## Architecture

```
WickDemoClient.Application         (:rest_for_one — order matters)
  ├─ Device      # owns the Wick.Object.Tree; answers DM + Bootstrap operations
  ├─ Endpoint    # the WickCoap socket, with Handler installed
  ├─ Registrar   # Register / Update / Deregister state machine
  └─ Sensor      # synthetic readings → Device → notify_observers

Outbound:  Wick.*.to_wire ──▶ Coap.to_message ──▶ WickCoap.Endpoint ──▶ UDP
Inbound:   UDP ──▶ WickCoap.Endpoint ──▶ Handler ──▶ Coap.to_request_wire
             ──▶ Wick.Request.from_wire (or Wick.Bootstrap.from_wire)
             ──▶ Device.dispatch ──▶ Wick.Response ──▶ Coap.reply
```

`Device` sits on one interesting boundary: by the time a request reaches it, Wick has already decided *which operation this is* — including the awkward cases, like a `POST` on a Resource path being an Execute while on an Object Instance it's a partial-update Write. What's left is genuinely the device's business: whether a path exists, whether the operation is permitted on it, which Content-Format to answer in, and what Execute actually *does*.

Everything under `WickDemoClient.*` is application policy plus a ~40-line `Coap` adapter. The protocol work is all in `Wick.*` / `WickCoap.*`.

## Tests

```bash
mix test
```

- `test/wick_demo_client_test.exs` — registration lifecycle, including recovery when the server has reaped the record.
- `test/device_management_test.exs` — the demo server driving this client over real UDP: every DM operation, the Observe → Notify → Cancel loop, attribute gating, and Send.
- `test/bootstrap_test.exs` — a full provisioning session, plus the Bootstrap-Write / DM-Write permission split.
