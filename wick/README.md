# Wick

LwM2M protocol primitives for Elixir.

Wick is a library — codecs, Object Model, path resolution, request/response types, registration interface — for building [Lightweight M2M](https://www.openmobilealliance.org/release/LightweightM2M/) servers, clients, and tooling on the BEAM. It deliberately ships **no transport** (no UDP, DTLS, CoAP runtime) and **no running processes**: every module is either pure data or pure functions over data. The consumer service is responsible for transport (the sibling [`wick_coap`](https://github.com/Finnlytics/wick_coap) library), state ownership (Agents / GenServers / a database), and life-cycle policy.

The library is informed by [Eclipse Leshan](https://eclipse.dev/leshan/) — Java's reference LwM2M implementation — and uses Leshan as a test oracle for codec correctness.

## Status

Pre-release, but functionally complete for LwM2M 1.2: **all four interfaces** are implemented in both directions and tested end-to-end over real CoAP/UDP against [`wick_coap`](https://github.com/Finnlytics/wick_coap).

- **Codecs**: SenML CBOR / JSON, Plain Text, Opaque (all bidirectional, oracle-verified against Leshan 2.0.0-M18).
- **Object Model**: DDF XML parser, in-memory Object Registry (definitions) and Object Tree (values).
- **CoRE Link Format** ([RFC 6690](https://www.rfc-editor.org/rfc/rfc6690)) encoder + decoder.
- **Bootstrap Interface** (§6.1): Bootstrap-Request / Write / Delete / Discover / Read / Finish, plus a state machine that enforces the provisioning order.
- **Registration Interface** (§6.2): Register / Update / Deregister with an in-memory store.
- **Device Management Interface** (§6.4): Read / Write / Execute / Discover / Create / Delete / Write-Attributes and the Composite variants.
- **Information Reporting Interface** (§6.5): Observe / Cancel-Observe / Notify / Send, with notification attributes (`pmin`, `pmax`, `gt`, `lt`, `st`) and the [RFC 7641](https://www.rfc-editor.org/rfc/rfc7641) reordering rules.

Every operation has both a `to_wire/1` and a `from_wire/1`, so Wick drives a **client** as readily as a server. `apps/wick_demo_client` and `apps/wick_demo_server` in the parent repository are working examples of each.

Not yet done: LwM2M CBOR and TLV codecs (SenML covers 1.1+ deployments), and the Access Control Object (§6.3.4).

## Architecture

Wick produces `%Wick.Wire{}` — a transport-agnostic request spec — and leaves the transport to the consumer. The bridge is one line, because `Wick.Wire.to_coap_options/1` reduces a request to CoAP option numbers:

```elixir
wire = Wick.Request.to_wire(%Wick.Request.Read{path: path})

options =
  Enum.map(Wick.Wire.to_coap_options(wire), fn {number, value} ->
    WickCoap.Option.new(number, value)
  end)
```

The reverse — a device or gateway receiving a request — is `Wick.Wire.parse/3` followed by `Wick.Request.from_wire/1`. See [ADR 0005](docs/decisions/0005-coap-option-tuples-at-the-wick-boundary.md) for why the boundary sits at option numbers rather than at a CoAP struct.

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP `~> 28`

Pinned in [`.tool-versions`](.tool-versions) for [asdf](https://asdf-vm.com) / [mise](https://mise.jdx.dev) users. Direct Homebrew installs work fine too.

## Installing

```elixir
# In your project's mix.exs while wick is unpublished:
def deps do
  [
    {:wick, path: "../wick"},                 # local path
    # or
    {:wick, github: "finnlytics/wick"},
    # Wick ships no transport. For CoAP/UDP, add the sibling:
    {:wick_coap, github: "finnlytics/wick_coap"}
  ]
end
```

Once published to Hex: `{:wick, "~> 0.1"}`.

## Getting started

Wick is pure functions over pure data, so there is nothing to start and no supervision tree
to wire up. Every operation follows the same shape: build a struct, turn it into a
`Wick.Wire`, hand the wire to a transport.

### A server reading a Resource

```elixir
{:ok, path} = Wick.Path.parse("/3303/0/5700")

wire = Wick.Request.to_wire(%Wick.Request.Read{path: path, accept_content_format: 112})
#=> %Wick.Wire{method: :get, path: ["3303", "0", "5700"], accept: 112}
```

`Wick.Wire.to_coap_options/1` flattens that into CoAP option numbers, which is the whole of
the adapter to `wick_coap`:

```elixir
message = %WickCoap.Message{
  type: :con,
  code: wire.method,
  message_id: 0,
  token: <<>>,
  options: Enum.map(Wick.Wire.to_coap_options(wire), fn {n, v} -> WickCoap.Option.new(n, v) end),
  payload: wire.payload
}

{:ok, reply} = WickCoap.Endpoint.request(endpoint, peer, message)
```

Coming back, convert the reply once and you have an LwM2M response:

```elixir
options = Enum.map(reply.options, &{&1.number, &1.value})

{:ok, wire} = Wick.Wire.Response.parse(WickCoap.Code.encode(reply.code), options, reply.payload)
response = Wick.Response.from_wire(wire)
#=> %Wick.Response{status: :content, content_format: 112, payload: <<...>>}

{:ok, pack} = Wick.Codec.SenmlCbor.decode(response.payload, [])
Wick.Senml.Pack.resolve(pack)
#=> [{"/3303/0/5700", nil, %Wick.Senml.Record{number_value: 22.5}}]
```

### A client answering one

The same functions run in reverse, which is what lets Wick drive a device as well as a
server. `Wick.Request.from_wire/1` works out *which* operation arrived — including the
awkward cases, where a `POST` on a Resource path is an Execute but on an Object Instance it
is a partial-update Write:

```elixir
{:ok, wire} = Wick.Wire.parse(request.code, options, request.payload)
{:ok, request} = Wick.Request.from_wire(wire)

case request do
  %Wick.Request.Read{path: path} -> read_from_my_tree(path)
  %Wick.Request.Write{path: path, payload: body} -> apply_write(path, body)
  %Wick.Request.Execute{path: path, arguments: args} -> invoke(path, args)
end
```

`Wick.Object.Tree` is a ready-made value tree for the device side — Read, Write, Discover,
and Create resolve against it directly:

```elixir
tree = Wick.Object.Tree.from_map(%{
  3 => %{0 => %{0 => {:string, "ACME"}, 9 => {:integer, 87}}},
  3303 => %{0 => %{5700 => {:float, 22.5}}}
})

{:ok, path} = Wick.Path.parse("/3303/0")
Wick.Object.Tree.to_pack(tree, [path])       # a Read response body
Wick.Object.Tree.discover(tree, path)        # a Discover response body
Wick.Object.Tree.links(tree)                 # the Register payload
```

### Deciding when to notify

Observe is the operation with real state behind it. Wick supplies the decision as a pure
function; the caller owns the clock and the per-observation state:

```elixir
attrs = %Wick.Attributes{pmin: 10, pmax: 60, st: 0.5}

# Inside pmin nothing gets through, however large the change.
Wick.Attributes.should_notify?(attrs, %{last_value: 20.0, since_last_ms: 5_000}, 30.0)
#=> false

# Past pmin and past the step threshold.
Wick.Attributes.should_notify?(attrs, %{last_value: 20.0, since_last_ms: 15_000}, 21.0)
#=> true

# Past pmax, so notify even though nothing changed.
Wick.Attributes.should_notify?(attrs, %{last_value: 20.0, since_last_ms: 61_000}, 20.0)
#=> true
```

### Worked examples

Two runnable apps in the parent repository put all of the above together, and they talk to
each other over real UDP:

- **`apps/wick_demo_server`** — a server with a browser UI: registered clients, an Object
  tree browser, Read/Write/Execute/Observe controls, and a live event log.
- **`apps/wick_demo_client`** — a device with an Object tree, a synthetic sensor, and
  attribute-gated notifications.

Wick's own `test/integration/` covers each interface end-to-end over CoAP/UDP and is the
most complete reference for the wire layer.

## Development

```bash
# Install dependencies
mix deps.get

# Run the full check suite — must pass before commit
mix check
# Equivalent to:
#   mix format --check-formatted
#   mix credo --strict
#   mix compile --warnings-as-errors
#   mix test
#   mix dialyzer

# Generate docs
mix docs
```

## Design documents

- [Decision records (ADRs)](docs/decisions/) — every load-bearing technical choice with the *why* behind it.

## License

[Apache 2.0](LICENSE).
