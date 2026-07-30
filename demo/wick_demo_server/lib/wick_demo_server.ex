defmodule WickDemoServer do
  @moduledoc """
  Top-level facade for the LwM2M demo server.

  An OTP application that boots a registration store, an observation registry, and a
  `WickCoap.Endpoint` running `WickDemoServer.Handler`. It now implements three of the four
  LwM2M interfaces:

  * **Registration** (§6.2) — devices `POST /rd?ep=…`; records are reaped when their lifetime
    elapses without an Update.
  * **Device Management** (§6.4) — `WickDemoServer.Client` issues Read, Write, Execute,
    Discover, Create, Delete, Write-Attributes, and the Composite variants against any
    registered device.
  * **Information Reporting** (§6.5) — Observe / Cancel-Observe, with relations tracked in
    `WickDemoServer.Observations` so inbound Notifications can be correlated back to the paths
    that produced them. `Send` uplinks (`POST /dp`) are ingested too.

  Bootstrap (§6.1) is deliberately not here: a Bootstrap Server is a separate deployment with
  different credentials and a different trust position, so it would be its own app rather than
  a mode of this one. The library side is complete — see `Wick.Bootstrap` and
  `Wick.Bootstrap.Session`.

  This is a *demo*, not a production stack — single-node, in-memory, no persistence, no access
  control. Production deployments wrap the same `Wick.*` cores in their own process tree with a
  durable store. The boundary is `Wick.Registration.Store` and `Wick.Observation.Store`; every
  other piece is reusable as-is.

  ## Running

      iex --sname demo -S mix

  Bound port is logged at boot. Point an LwM2M client at `coap://127.0.0.1:5683`.

  ## Driving it from IEx

      iex> [reg] = WickDemoServer.registrations()
      iex> reg.endpoint_name
      "wick-demo-client"

      iex> {:ok, response} = WickDemoServer.read(reg.location_id, "/3/0/0", accept: 0)
      iex> response.payload
      "Finnlytics"

      # Ask for a Notification at most every 5s, and only for changes of 1 degree or more.
      iex> WickDemoServer.write_attributes(reg.location_id, "/3303/0/5700",
      ...>   %Wick.Attributes{pmin: 5, st: 1.0})

      iex> {:ok, handle} = WickDemoServer.observe(reg.location_id, "/3303/0/5700")
      # ... the device notifies as the value drifts ...
      iex> WickDemoServer.readings() |> hd()
      %{source: :notify, readings: [{"/3303/0/5700", 22.7}], observe_seq: 3, ...}

      iex> WickDemoServer.cancel_observe(reg.location_id, "/3303/0/5700", handle)
  """

  alias WickDemoServer.Client
  alias WickDemoServer.Observations

  @doc "Return the running endpoint's bound UDP port. Useful in tests."
  defdelegate port(), to: WickDemoServer.Endpoint, as: :port

  @doc "Return the running registration store pid."
  defdelegate store(), to: WickDemoServer.Store, as: :pid

  @doc "List the currently-registered endpoints."
  defdelegate registrations(), to: WickDemoServer.Store, as: :list

  # ── Device Management ──────────────────────────────────────────────────────

  @doc "Read a path on a registered device. See `WickDemoServer.Client.read/3`."
  defdelegate read(location_id, path, opts \\ []), to: Client

  @doc "Write a `{type, value}` to a path. See `WickDemoServer.Client.write/4`."
  defdelegate write(location_id, path, value, opts \\ []), to: Client

  @doc "Invoke an Executable Resource. See `WickDemoServer.Client.execute/4`."
  defdelegate execute(location_id, path, arguments \\ nil, opts \\ []), to: Client

  @doc "Enumerate Resources at a path. See `WickDemoServer.Client.discover/3`."
  defdelegate discover(location_id, path, opts \\ []), to: Client

  @doc "Create an Object Instance. See `WickDemoServer.Client.create/4`."
  defdelegate create(location_id, path, resources, opts \\ []), to: Client

  @doc "Delete an Object Instance. See `WickDemoServer.Client.delete/3`."
  defdelegate delete(location_id, path, opts \\ []), to: Client

  @doc "Set notification attributes. See `WickDemoServer.Client.write_attributes/4`."
  defdelegate write_attributes(location_id, path, attributes, opts \\ []), to: Client

  @doc "Read several paths at once. See `WickDemoServer.Client.read_composite/3`."
  defdelegate read_composite(location_id, paths, opts \\ []), to: Client

  @doc "Write several paths at once. See `WickDemoServer.Client.write_composite/3`."
  defdelegate write_composite(location_id, values, opts \\ []), to: Client

  # ── Information Reporting ──────────────────────────────────────────────────

  @doc "Observe a path. See `WickDemoServer.Client.observe/3`."
  defdelegate observe(location_id, path, opts \\ []), to: Client

  @doc "Observe several paths under one relation. See `WickDemoServer.Client.observe_composite/3`."
  defdelegate observe_composite(location_id, paths, opts \\ []), to: Client

  @doc "Tear down an observation. See `WickDemoServer.Client.cancel_observe/4`."
  defdelegate cancel_observe(location_id, path, handle, opts \\ []), to: Client

  @doc "Every Observe relation the server currently holds."
  defdelegate observations(), to: Observations, as: :list

  @doc """
  Values received from devices, newest first — one entry per Notification or Send.

  Demo instrumentation; a real server would write these to a time-series store.
  """
  defdelegate readings(), to: Observations, as: :readings
end
