defmodule WickDemoClient do
  @moduledoc """
  Top-level facade for the LwM2M demo client.

  An OTP application that opens an ephemeral UDP socket via `WickCoap.Endpoint` and behaves
  like a real LwM2M 1.2 device:

  * **Registration** — `WickDemoClient.Registrar` drives Register → Update → Deregister.
  * **Device Management** — `WickDemoClient.Device` answers Read, Write, Execute, Discover,
    Create, Delete, Write-Attributes, and the Composite variants against a real
    `Wick.Object.Tree`.
  * **Information Reporting** — Observe relations are held by `WickCoap.Endpoint`;
    `WickDemoClient.Sensor` produces changing values and notifies when the notification
    attributes allow. `WickDemoClient.Uplink` covers Send.
  * **Bootstrap** — `WickDemoClient.Bootstrap` asks a Bootstrap Server to provision the
    device.

  ## Running alongside the demo server

      # Terminal 1
      cd apps/wick_demo_server
      iex -S mix

      # Terminal 2
      cd apps/wick_demo_client
      iex -S mix

  The client logs each protocol step. From the server's IEx, `WickDemoServer.registrations()`
  shows the client, and `WickDemoServer.read(id, "/3303/0/5700")` reads its temperature.

  ## Driving it from IEx

      iex> WickDemoClient.status()
      {:registered, "r0"}

      iex> WickDemoClient.tree() |> Wick.Object.Tree.links() |> Enum.map(& &1.target)
      ["/1/0", "/3/0", "/3303/0"]

      iex> WickDemoClient.tick()          # take a reading, notify observers if due
      :notified

      iex> WickDemoClient.set_temperature(31.5)
      :notified

      iex> WickDemoClient.send_values()   # push the temperature with no prior Observe
      {:ok, %Wick.Response{status: :changed}}

  ## Configuration

  See `config/config.exs`.
  """

  alias Wick.Object.Tree

  @doc "Trigger an immediate Register cycle. Returns `:ok` or `{:error, reason}`."
  defdelegate register, to: WickDemoClient.Registrar

  @doc "Trigger an immediate Update. Returns `:ok` or `{:error, reason}`."
  defdelegate update, to: WickDemoClient.Registrar

  @doc "Tear down the registration; safe to call when not registered."
  defdelegate deregister, to: WickDemoClient.Registrar

  @doc "Current registration status — `:idle` or `{:registered, location_id}`."
  defdelegate status, to: WickDemoClient.Registrar

  @doc "Bound UDP port of the client-side endpoint."
  defdelegate port, to: WickDemoClient.Endpoint

  @doc "The client's current Object tree."
  @spec tree() :: Tree.t()
  defdelegate tree, to: WickDemoClient.Device

  @doc "Take one synthetic sensor reading. `:notified` or `:quiet`."
  defdelegate tick, to: WickDemoClient.Sensor

  @doc "Force the temperature Resource to a value. `:notified` or `:quiet`."
  @spec set_temperature(float()) :: :notified | :quiet
  defdelegate set_temperature(reading), to: WickDemoClient.Sensor, as: :set

  @doc "Push values to the server with a Send uplink (no prior Observe needed)."
  defdelegate send_values(paths \\ [WickDemoClient.Objects.temperature_path()], opts \\ []),
    to: WickDemoClient.Uplink

  @doc "Ask a Bootstrap Server to provision this client."
  defdelegate bootstrap(opts \\ []), to: WickDemoClient.Bootstrap, as: :request

  @doc "True while a bootstrap session is open."
  @spec bootstrapping?() :: boolean()
  defdelegate bootstrapping?, to: WickDemoClient.Device

  @doc """
  Read a path out of the local tree, for poking around in IEx.

      iex> WickDemoClient.read("/3/0/0")
      {:ok, {:string, "Finnlytics"}}
  """
  @spec read(String.t()) :: {:ok, Tree.value()} | :error
  def read(path) when is_binary(path) do
    with {:ok, parsed} <- Wick.Path.parse(path) do
      Tree.fetch(tree(), parsed)
    end
  end
end
