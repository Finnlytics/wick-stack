defmodule Wick.Bootstrap.Session do
  @moduledoc """
  The bootstrap provisioning sequence, as a pure state machine.

  Bootstrap is the one LwM2M interface with a genuine multi-step protocol: a client asks to
  be bootstrapped, the server then pushes an ordered plan of Deletes and Writes, and only
  when every step has been acknowledged does it send Bootstrap-Finish. Get the order wrong
  — Finish before the Writes land, or a Write after Finish — and the device ends up
  unprovisioned or, worse, provisioned with half a Server Account.

  No process and no clock of its own: the caller drives it and owns the transport. Same
  contract as `Wick.Registration.Store`.

  ## States

      :awaiting_request  --request/2-->  :provisioning
                                              |
                                     pop/1, ack/1 per step
                                              |
                                          all acked
                                              |
                                       --finish/1-->  :finished
                                              |
                                        --fail/2-->   :failed

  `fail/2` is terminal from any state: a failed step means the plan cannot be trusted, so
  there is no resuming — the server drops the session and the client falls back to whatever
  configuration it had.

  ## Usage

      plan = [
        %Wick.Bootstrap.Delete{},
        %Wick.Bootstrap.Write{path: security, content_format: 112, payload: creds},
        %Wick.Bootstrap.Write{path: server, content_format: 112, payload: account}
      ]

      session = Wick.Bootstrap.Session.new(plan)
      {:ok, session} = Wick.Bootstrap.Session.request(session, request)

      # Then, driven by the transport:
      case Wick.Bootstrap.Session.pop(session) do
        {:ok, operation, session} -> send_and_await(operation); Session.ack(session)
        :done -> {:ok, finish, session} = Session.finish(session); send(finish)
      end

  ## Examples

      iex> session = Wick.Bootstrap.Session.new([%Wick.Bootstrap.Delete{}])
      iex> session.state
      :awaiting_request
      iex> request = %Wick.Bootstrap.Request{endpoint_name: "device-1"}
      iex> {:ok, session} = Wick.Bootstrap.Session.request(session, request)
      iex> {session.state, session.endpoint_name}
      {:provisioning, "device-1"}
      iex> {:ok, %Wick.Bootstrap.Delete{}, session} = Wick.Bootstrap.Session.pop(session)
      iex> {:ok, session} = Wick.Bootstrap.Session.ack(session)
      iex> Wick.Bootstrap.Session.pop(session)
      :done
      iex> {:ok, %Wick.Bootstrap.Finish{}, session} = Wick.Bootstrap.Session.finish(session)
      iex> session.state
      :finished
  """

  alias Wick.Bootstrap
  alias Wick.Error

  @typedoc "Where the session has got to."
  @type state :: :awaiting_request | :provisioning | :finished | :failed

  @typedoc """
  An operation the server pushes during provisioning. `Request` and `Finish` are not valid
  plan steps: the first opens the session and the second closes it.
  """
  @type operation :: Bootstrap.Write.t() | Bootstrap.Delete.t() | Bootstrap.Discover.t()

  @typedoc "A bootstrap session."
  @type t :: %__MODULE__{
          state: state(),
          endpoint_name: String.t() | nil,
          preferred_content_format: non_neg_integer() | nil,
          pending: [operation()],
          in_flight: operation() | nil,
          applied: [operation()],
          failure: Error.t() | nil
        }

  defstruct state: :awaiting_request,
            endpoint_name: nil,
            preferred_content_format: nil,
            pending: [],
            in_flight: nil,
            applied: [],
            failure: nil

  @doc """
  Build a session with the provisioning plan the server intends to push, in order.

  Raises `ArgumentError` if the plan contains a `Request` or a `Finish` — those bracket the
  session rather than belonging to it, and including one would send Finish twice.
  """
  @spec new([operation()]) :: t()
  def new(plan \\ []) when is_list(plan) do
    Enum.each(plan, &validate_step!/1)
    %__MODULE__{pending: plan}
  end

  @doc """
  Accept a client's Bootstrap-Request and move to `:provisioning`.

  Returns `{:error, %Wick.Error{code: :invalid_session_state}}` if the session has already
  started — a second Bootstrap-Request means a new session, not a continuation.

  ## Examples

      iex> session = Wick.Bootstrap.Session.new()
      iex> request = %Wick.Bootstrap.Request{endpoint_name: "d1", preferred_content_format: 110}
      iex> {:ok, session} = Wick.Bootstrap.Session.request(session, request)
      iex> session.preferred_content_format
      110
      iex> {:error, err} = Wick.Bootstrap.Session.request(session, request)
      iex> err.code
      :invalid_session_state
  """
  @spec request(t(), Bootstrap.Request.t()) :: {:ok, t()} | {:error, Error.t()}
  def request(%__MODULE__{state: :awaiting_request} = session, %Bootstrap.Request{} = request) do
    {:ok,
     %{
       session
       | state: :provisioning,
         endpoint_name: request.endpoint_name,
         preferred_content_format: request.preferred_content_format
     }}
  end

  def request(%__MODULE__{} = session, %Bootstrap.Request{}) do
    {:error, wrong_state(session, :awaiting_request, "Bootstrap-Request")}
  end

  @doc """
  Take the next operation to send. Returns `:done` when the plan is exhausted, or
  `{:error, _}` if the session is not provisioning.

  The operation is held as `in_flight` until `ack/1` or `fail/2`, so a session cannot skip a
  step whose response never arrived.

  ## Examples

      iex> session = Wick.Bootstrap.Session.new([%Wick.Bootstrap.Delete{}])
      iex> {:ok, session} = Wick.Bootstrap.Session.request(
      ...>   session, %Wick.Bootstrap.Request{endpoint_name: "d1"}
      ...> )
      iex> {:ok, _operation, session} = Wick.Bootstrap.Session.pop(session)
      iex> {:error, err} = Wick.Bootstrap.Session.pop(session)
      iex> err.code
      :operation_in_flight
  """
  @spec pop(t()) :: {:ok, operation(), t()} | :done | {:error, Error.t()}
  def pop(%__MODULE__{state: :provisioning, in_flight: nil, pending: []}), do: :done

  def pop(%__MODULE__{state: :provisioning, in_flight: nil, pending: [next | rest]} = session) do
    {:ok, next, %{session | pending: rest, in_flight: next}}
  end

  def pop(%__MODULE__{state: :provisioning} = session) do
    {:error,
     Error.new(
       :operation_in_flight,
       "the previous operation has not been acknowledged; call ack/1 or fail/2 first",
       in_flight: session.in_flight
     )}
  end

  def pop(%__MODULE__{} = session) do
    {:error, wrong_state(session, :provisioning, "pop")}
  end

  @doc """
  Record that the in-flight operation succeeded.

  Returns `{:error, %Wick.Error{code: :no_operation_in_flight}}` if nothing is outstanding.
  """
  @spec ack(t()) :: {:ok, t()} | {:error, Error.t()}
  def ack(%__MODULE__{state: :provisioning, in_flight: nil}) do
    {:error, Error.new(:no_operation_in_flight, "there is no outstanding operation to acknowledge")}
  end

  def ack(%__MODULE__{state: :provisioning} = session) do
    {:ok, %{session | in_flight: nil, applied: session.applied ++ [session.in_flight]}}
  end

  def ack(%__MODULE__{} = session) do
    {:error, wrong_state(session, :provisioning, "ack")}
  end

  @doc """
  Abandon the session. Terminal from any state — a failed step invalidates the whole plan,
  so there is nothing to resume.

  ## Examples

      iex> session = Wick.Bootstrap.Session.new()
      iex> session = Wick.Bootstrap.Session.fail(session, Wick.Error.new(:timeout, "no response"))
      iex> {session.state, session.failure.code}
      {:failed, :timeout}
  """
  @spec fail(t(), Error.t()) :: t()
  def fail(%__MODULE__{} = session, %Error{} = reason) do
    %{session | state: :failed, failure: reason}
  end

  @doc """
  Produce the Bootstrap-Finish that closes the session, and mark it `:finished`.

  Refuses while any step is still pending or in flight — sending Finish early is exactly the
  bug this module exists to prevent.

  ## Examples

      iex> session = Wick.Bootstrap.Session.new([%Wick.Bootstrap.Delete{}])
      iex> {:ok, session} = Wick.Bootstrap.Session.request(
      ...>   session, %Wick.Bootstrap.Request{endpoint_name: "d1"}
      ...> )
      iex> {:error, err} = Wick.Bootstrap.Session.finish(session)
      iex> err.code
      :plan_incomplete
  """
  @spec finish(t()) :: {:ok, Bootstrap.Finish.t(), t()} | {:error, Error.t()}
  def finish(%__MODULE__{state: :provisioning, pending: [], in_flight: nil} = session) do
    {:ok, %Bootstrap.Finish{}, %{session | state: :finished}}
  end

  def finish(%__MODULE__{state: :provisioning} = session) do
    {:error,
     Error.new(
       :plan_incomplete,
       "#{remaining(session)} operation(s) still outstanding; Bootstrap-Finish would leave " <>
         "the client partially provisioned",
       remaining: remaining(session)
     )}
  end

  def finish(%__MODULE__{} = session) do
    {:error, wrong_state(session, :provisioning, "finish")}
  end

  @doc """
  True once the session has reached a terminal state, successfully or not.

  ## Examples

      iex> Wick.Bootstrap.Session.done?(Wick.Bootstrap.Session.new())
      false

      iex> session = Wick.Bootstrap.Session.fail(
      ...>   Wick.Bootstrap.Session.new(), Wick.Error.new(:timeout, "gone")
      ...> )
      iex> Wick.Bootstrap.Session.done?(session)
      true
  """
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{state: state}), do: state in [:finished, :failed]

  @doc """
  How many operations are still outstanding — pending plus any in flight.

  ## Examples

      iex> Wick.Bootstrap.Session.remaining(Wick.Bootstrap.Session.new([%Wick.Bootstrap.Delete{}]))
      1
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = session) do
    length(session.pending) + if(session.in_flight, do: 1, else: 0)
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp validate_step!(%Bootstrap.Request{}), do: reject_step!("Bootstrap-Request", "opens")
  defp validate_step!(%Bootstrap.Finish{}), do: reject_step!("Bootstrap-Finish", "closes")
  defp validate_step!(%Bootstrap.Write{}), do: :ok
  defp validate_step!(%Bootstrap.Delete{}), do: :ok
  defp validate_step!(%Bootstrap.Discover{}), do: :ok
  defp validate_step!(%Bootstrap.Read{}), do: :ok

  defp validate_step!(other) do
    raise ArgumentError, "not a Bootstrap operation: #{inspect(other)}"
  end

  @spec reject_step!(String.t(), String.t()) :: no_return()
  defp reject_step!(name, verb) do
    raise ArgumentError,
          "#{name} #{verb} a session and cannot be a plan step; " <>
            "use request/2 and finish/1 instead"
  end

  defp wrong_state(%__MODULE__{state: state}, expected, operation) do
    Error.new(
      :invalid_session_state,
      "#{operation} requires state #{inspect(expected)}, session is #{inspect(state)}",
      state: state,
      expected: expected
    )
  end
end
