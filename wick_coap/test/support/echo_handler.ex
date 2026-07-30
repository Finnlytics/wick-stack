defmodule WickCoap.Test.EchoHandler do
  @moduledoc """
  Test handler that echoes the request payload back as a 2.05 Content response, with
  a special path `/large/<size>` that returns a deterministic payload of the requested
  byte length (used to exercise Block2 fragmentation).
  """

  @behaviour WickCoap.Handler

  alias WickCoap.Handler
  alias WickCoap.Message
  alias WickCoap.Option

  @impl true
  def handle_request(%Message{} = request, _peer, _state) do
    payload =
      case Handler.uri_path(request.options) do
        ["large", size_str] ->
          {size, ""} = Integer.parse(size_str)
          for(i <- 0..(size - 1), into: <<>>, do: <<rem(i, 256)::8>>)

        _ ->
          request.payload
      end

    response = %Message{
      type: :ack,
      code: :content,
      message_id: 0,
      token: <<>>,
      options: [Option.from_uint(12, 0)],
      payload: payload
    }

    {:reply, response}
  end
end
