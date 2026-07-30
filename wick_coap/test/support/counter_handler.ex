defmodule WickCoap.Test.CounterHandler do
  @moduledoc """
  Test handler that responds to GET requests on `/counter` with the current value of an
  Agent-held counter. Used by `WickCoap.EndpointTest` to verify the Observe flow:
  the registration response carries the current value, and `notify_observers/3` from
  the test process pushes updates.
  """

  @behaviour WickCoap.Handler

  alias WickCoap.Handler
  alias WickCoap.Message
  alias WickCoap.Option

  @impl true
  def handle_request(%Message{code: :get} = request, _peer, %{counter: agent}) do
    case Handler.uri_path(request.options) do
      ["counter"] ->
        value = Agent.get(agent, & &1)

        response = %Message{
          type: :ack,
          code: :content,
          message_id: 0,
          token: <<>>,
          options: [Option.from_uint(12, 0)],
          payload: Integer.to_string(value)
        }

        {:reply, response}

      _ ->
        {:reply,
         %Message{
           type: :ack,
           code: :not_found,
           message_id: 0,
           token: <<>>,
           options: []
         }}
    end
  end

  def handle_request(_message, _peer, _state) do
    {:reply,
     %Message{
       type: :ack,
       code: :method_not_allowed,
       message_id: 0,
       token: <<>>,
       options: []
     }}
  end
end
