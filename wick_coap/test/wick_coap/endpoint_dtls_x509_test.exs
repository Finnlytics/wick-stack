defmodule WickCoap.EndpointDtlsX509Test do
  @moduledoc """
  End-to-end DTLS test using X.509 server certificates instead of PSK.

  Self-signed cert + key pair are generated once per test run via `openssl` and written
  to `tmp/`. The endpoint plumbs them straight through to OTP `:ssl`, so the test is
  really a proof that our `:dtls_opts` pass-through doesn't interfere with the standard
  OTP TLS-PKI flow.

  We skip rather than fail if openssl is unavailable on the host — the rest of the
  suite still runs.
  """

  use ExUnit.Case, async: false

  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option
  alias WickCoap.Test.EchoHandler

  @tmp_dir Path.expand("../../tmp/dtls_x509", __DIR__)

  setup_all do
    if System.find_executable("openssl") do
      File.mkdir_p!(@tmp_dir)
      cert_path = Path.join(@tmp_dir, "server.crt")
      key_path = Path.join(@tmp_dir, "server.key")

      if not File.exists?(cert_path) or not File.exists?(key_path) do
        :ok = generate_self_signed(cert_path, key_path)
      end

      {:ok, cert_path: cert_path, key_path: key_path}
    else
      {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip], do: {:ok, skip: true}, else: :ok
  end

  defp generate_self_signed(cert_path, key_path) do
    # Step 1: generate raw EC private key. Output includes an EC PARAMETERS block plus
    # the EC PRIVATE KEY; OTP's keyfile parser trips on the leading EC PARAMETERS block
    # and reports a misleading `:wrong_password`, so we strip it after generation.
    with {_, 0} <-
           System.cmd(
             "openssl",
             ~w(ecparam -genkey -name prime256v1 -out #{key_path}),
             stderr_to_stdout: true
           ),
         :ok <- strip_ec_params(key_path),
         {_, 0} <-
           System.cmd(
             "openssl",
             ~w(req -new -x509 -key #{key_path} -out #{cert_path}
                -days 7 -subj /CN=wick-coap-test),
             stderr_to_stdout: true
           ) do
      :ok
    else
      {out, code} when is_integer(code) -> {:error, {code, out}}
      other -> {:error, other}
    end
  end

  defp strip_ec_params(path) do
    contents = File.read!(path)

    case Regex.run(
           ~r/-----BEGIN EC PRIVATE KEY-----.*-----END EC PRIVATE KEY-----/s,
           contents
         ) do
      [block] ->
        File.write!(path, block <> "\n")
        :ok

      nil ->
        {:error, :no_ec_private_key_block}
    end
  end

  describe "DTLS with X.509 server cert + client verify-none" do
    @tag :x509
    test "client sends CoAP GET, server replies with 2.05 Content", ctx do
      if ctx[:skip] do
        IO.puts("skipping: openssl not found on host")
        :ok
      else
        server_opts = [
          certfile: ctx.cert_path,
          keyfile: ctx.key_path,
          versions: [:"dtlsv1.2"]
        ]

        {:ok, server} =
          Endpoint.start_link(
            handler: EchoHandler,
            transport: :dtls,
            dtls_opts: server_opts
          )

        server_port = Endpoint.port(server)
        peer = {{127, 0, 0, 1}, server_port}

        client_opts = [
          verify: :verify_none,
          versions: [:"dtlsv1.2"]
        ]

        {:ok, client} =
          Endpoint.start_link(
            transport: :dtls,
            dtls_opts: client_opts
          )

        assert :ok = Endpoint.connect(client, peer, [])

        request = %Message{
          type: :con,
          code: :get,
          message_id: 0,
          token: <<>>,
          options: [Option.new(11, "hello")],
          payload: "x509"
        }

        assert {:ok, response} = Endpoint.request(client, peer, request, timeout: 5_000)
        assert response.code == :content
        assert response.payload == "x509"

        Endpoint.stop(client)
        Endpoint.stop(server)
      end
    end
  end
end
