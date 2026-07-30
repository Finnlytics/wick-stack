defmodule WickCoap.EndpointDtlsTest do
  use ExUnit.Case, async: false

  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option
  alias WickCoap.Test.EchoHandler

  @psk "0123456789abcdef"
  @psk_identity ~c"device-1"

  defp psk_cipher do
    %{mac: :aead, cipher: :aes_128_ccm_8, key_exchange: :psk, prf: :default_prf}
  end

  def psk_lookup(:psk, _identity, _user_state), do: {:ok, @psk}

  defp dtls_opts do
    [
      ciphers: [psk_cipher()],
      user_lookup_fun: {&__MODULE__.psk_lookup/3, []}
    ]
  end

  describe "DTLS PSK end-to-end" do
    test "client sends CoAP GET over DTLS, server replies with 2.05 Content" do
      {:ok, server} =
        Endpoint.start_link(
          handler: EchoHandler,
          transport: :dtls,
          dtls_opts: dtls_opts()
        )

      server_port = Endpoint.port(server)
      peer = {{127, 0, 0, 1}, server_port}

      {:ok, client} =
        Endpoint.start_link(
          transport: :dtls,
          dtls_opts: dtls_opts()
        )

      assert :ok = Endpoint.connect(client, peer, psk_identity: @psk_identity)

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "hello")],
        payload: "secure"
      }

      assert {:ok, response} = Endpoint.request(client, peer, request, timeout: 5_000)
      assert response.code == :content
      assert response.payload == "secure"

      Endpoint.stop(client)
      Endpoint.stop(server)
    end

    test "request to an unconnected peer fails fast" do
      {:ok, client} =
        Endpoint.start_link(
          transport: :dtls,
          dtls_opts: dtls_opts()
        )

      request = %Message{
        type: :non,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [],
        payload: ""
      }

      # No connect/3 first → send_raw returns {:error, :not_connected} immediately.
      # request/4 surfaces that as a timeout because nothing comes back.
      result = Endpoint.request(client, {{127, 0, 0, 1}, 1}, request, timeout: 200)
      assert match?({:error, _}, result)

      Endpoint.stop(client)
    end
  end
end
