defmodule WickDemoClient.Bootstrap do
  @moduledoc """
  Client side of the Bootstrap interface (LwM2M 1.2 §6.1).

  A real device ships knowing only a Bootstrap Server. It asks to be provisioned, receives a
  Security and a Server Object, and only then registers. The demo client normally skips this —
  `config/config.exs` gives it a Server Object out of the box — but the flow is here so the
  Bootstrap implementation is exercised by something other than tests.

  ## What this function does and does not do

  `request/1` sends the Bootstrap-Request and opens the session. It does **not** wait for
  provisioning to complete: the Deletes and Writes that follow arrive as *inbound* requests,
  handled by `WickDemoClient.Handler` → `WickDemoClient.Device`, and the session closes when
  the server's Bootstrap-Finish is accepted. That asymmetry is inherent to the interface —
  the client opens the conversation and the server drives it.

  Use `WickDemoClient.Device.bootstrapping?/1` to see whether a session is still open.

  ## Ordering

  Opening the session *before* sending the Request matters. A fast Bootstrap Server can have
  its first Bootstrap-Write in flight before the client has finished processing the response
  to its own Request, and a Write that arrives with no session open would be routed to
  `Wick.Request.from_wire/1` — where a write to the Security Object is correctly refused.
  """

  require Logger

  alias Wick.Bootstrap
  alias Wick.Response
  alias WickDemoClient.Coap
  alias WickDemoClient.Device

  @doc """
  Ask a Bootstrap Server to provision this client.

  ## Options

  * `:endpoint` — the `WickCoap.Endpoint` to send from. Defaults to the app's own.
  * `:device` — the `WickDemoClient.Device` to open the session on. Defaults to the app's own.
  * `:peer` — `{ip, port}` of the Bootstrap Server. Defaults to `:bootstrap_server_host` /
    `:bootstrap_server_port` from config.
  * `:endpoint_name` — the `ep` parameter. Defaults to the configured endpoint name.
  * `:preferred_content_format` — the `pct` parameter (LwM2M 1.1+). Defaults to SenML CBOR,
    since that is what `WickDemoClient.Device` decodes.
  """
  @spec request(keyword()) :: {:ok, Response.t()} | {:error, term()}
  def request(opts \\ []) do
    device = Keyword.get(opts, :device, Device)
    endpoint = Keyword.get_lazy(opts, :endpoint, &default_endpoint/0)
    peer = Keyword.get_lazy(opts, :peer, &default_peer/0)

    operation = %Bootstrap.Request{
      endpoint_name: Keyword.get_lazy(opts, :endpoint_name, &default_endpoint_name/0),
      preferred_content_format: Keyword.get(opts, :preferred_content_format, 112)
    }

    # Open the session first — see the module docs on ordering.
    :ok = Device.begin_bootstrap(device)

    case Coap.request(
           endpoint,
           peer,
           Bootstrap.to_wire(operation),
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, response} ->
        Logger.info("BS-REQUEST ep=#{operation.endpoint_name} → #{response.status}")
        {:ok, response}

      {:error, reason} ->
        Logger.warning("BS-REQUEST transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_endpoint, do: WickDemoClient.Endpoint.pid()

  defp default_peer do
    {Application.get_env(:wick_demo_client, :bootstrap_server_host, {127, 0, 0, 1}),
     Application.get_env(:wick_demo_client, :bootstrap_server_port, 5783)}
  end

  defp default_endpoint_name do
    Application.get_env(:wick_demo_client, :endpoint_name, "wick-demo-client")
  end
end
