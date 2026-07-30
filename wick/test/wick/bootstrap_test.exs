defmodule Wick.BootstrapTest do
  use ExUnit.Case, async: true

  doctest Wick.Bootstrap
  doctest Wick.Bootstrap.Session

  alias Wick.Bootstrap
  alias Wick.Bootstrap.Session
  alias Wick.Error
  alias Wick.Path
  alias Wick.Wire

  defp path!(string) do
    {:ok, path} = Path.parse(string)
    path
  end

  defp round_trip(operation) do
    wire = Bootstrap.to_wire(operation)
    {:ok, parsed} = Wire.parse(wire.method, Wire.to_coap_options(wire), wire.payload)
    Bootstrap.from_wire(parsed)
  end

  describe "Bootstrap-Request" do
    test "is a POST to /bs carrying ep" do
      wire = Bootstrap.to_wire(%Bootstrap.Request{endpoint_name: "device-1"})

      assert wire.method == :post
      assert wire.path == ["bs"]
      assert Wire.to_coap_options(wire) == [{11, "bs"}, {15, "ep=device-1"}]
    end

    test "carries pct when a preferred format is set" do
      request = %Bootstrap.Request{endpoint_name: "d1", preferred_content_format: 110}

      assert Bootstrap.to_wire(request).query == [{"ep", "d1"}, {"pct", 110}]
    end

    test "round-trips with and without pct" do
      bare = %Bootstrap.Request{endpoint_name: "device-1"}
      with_pct = %Bootstrap.Request{endpoint_name: "device-1", preferred_content_format: 112}

      assert {:ok, ^bare} = round_trip(bare)
      assert {:ok, ^with_pct} = round_trip(with_pct)
    end

    test "an ep with no value is rejected rather than read as a Finish" do
      {:ok, wire} = Wire.parse(:post, [{11, "bs"}, {15, "ep"}], "")

      assert {:error, err} = Bootstrap.from_wire(wire)
      assert err.code == :missing_endpoint_name
    end

    test "an empty ep value is rejected" do
      {:ok, wire} = Wire.parse(:post, [{11, "bs"}, {15, "ep="}], "")

      assert {:error, %{code: :missing_endpoint_name}} = Bootstrap.from_wire(wire)
    end

    test "a non-numeric pct is rejected" do
      {:ok, wire} = Wire.parse(:post, [{11, "bs"}, {15, "ep=d1"}, {15, "pct=senml"}], "")

      assert {:error, err} = Bootstrap.from_wire(wire)
      assert err.code == :invalid_content_format
      assert err.meta == %{value: "senml"}
    end

    test "endpoint names with awkward characters survive the query round-trip" do
      for name <- ["urn:imei:352656100000000", "device.with.dots", "device-1_A"] do
        request = %Bootstrap.Request{endpoint_name: name}

        assert {:ok, ^request} = round_trip(request)
      end
    end
  end

  describe "Bootstrap-Finish" do
    test "is a bare POST to /bs" do
      wire = Bootstrap.to_wire(%Bootstrap.Finish{})

      assert Wire.to_coap_options(wire) == [{11, "bs"}]
      assert wire.payload == ""
    end

    test "round-trips, and is distinguished from Request by the absence of ep" do
      assert {:ok, %Bootstrap.Finish{}} = round_trip(%Bootstrap.Finish{})
    end

    test "a POST outside /bs is not a bootstrap operation" do
      {:ok, wire} = Wire.parse(:post, [{11, "rd"}], "")

      assert {:error, err} = Bootstrap.from_wire(wire)
      assert err.code == :unsupported_operation
      assert err.meta == %{path: ["rd"]}
    end
  end

  describe "Bootstrap-Write" do
    test "is a PUT with a body, and may target the Security Object" do
      write = %Bootstrap.Write{path: path!("/0/0"), content_format: 112, payload: <<0x80>>}
      wire = Bootstrap.to_wire(write)

      assert wire.method == :put
      assert wire.path == ["0", "0"]
      assert wire.content_format == 112
    end

    test "round-trips at Object, Instance, and Resource level" do
      for string <- ["/0", "/0/0", "/0/0/1"] do
        write = %Bootstrap.Write{path: path!(string), content_format: 112, payload: <<0x80>>}

        assert {:ok, ^write} = round_trip(write)
      end
    end

    test "a PUT with no Content-Format is rejected" do
      {:ok, wire} = Wire.parse(:put, [{11, "0"}, {11, "0"}], "")

      assert {:error, err} = Bootstrap.from_wire(wire)
      assert err.code == :unsupported_operation
      assert err.message =~ "Content-Format"
    end
  end

  describe "Bootstrap-Delete" do
    test "the root form is a DELETE with an empty path" do
      wire = Bootstrap.to_wire(%Bootstrap.Delete{})

      assert wire.method == :delete
      assert wire.path == []
      assert Wire.to_coap_options(wire) == []
    end

    test "root and targeted forms both round-trip" do
      root = %Bootstrap.Delete{}
      targeted = %Bootstrap.Delete{path: path!("/1/0")}

      assert {:ok, ^root} = round_trip(root)
      assert {:ok, ^targeted} = round_trip(targeted)
    end
  end

  describe "Bootstrap-Discover" do
    test "asks for link-format, at the root or at an Object" do
      assert Bootstrap.to_wire(%Bootstrap.Discover{}).accept == 40
      assert Bootstrap.to_wire(%Bootstrap.Discover{path: path!("/1")}).path == ["1"]
    end

    test "root and targeted forms both round-trip" do
      root = %Bootstrap.Discover{}
      targeted = %Bootstrap.Discover{path: path!("/1")}

      assert {:ok, ^root} = round_trip(root)
      assert {:ok, ^targeted} = round_trip(targeted)
    end
  end

  describe "Bootstrap-Read" do
    test "is a GET without link-format Accept" do
      read = %Bootstrap.Read{path: path!("/1/0"), accept_content_format: 112}
      wire = Bootstrap.to_wire(read)

      assert wire.method == :get
      assert wire.accept == 112
    end

    test "round-trips with and without Accept" do
      bare = %Bootstrap.Read{path: path!("/1")}
      with_accept = %Bootstrap.Read{path: path!("/1/0"), accept_content_format: 112}

      assert {:ok, ^bare} = round_trip(bare)
      assert {:ok, ^with_accept} = round_trip(with_accept)
    end

    test "a Read asking for link-format is read back as a Discover" do
      # Inherent to the wire encoding, exactly as with Read/Discover in Device Management.
      read = %Bootstrap.Read{path: path!("/1"), accept_content_format: 40}

      assert {:ok, %Bootstrap.Discover{}} = round_trip(read)
    end

    test "a GET at the root with no Accept has no path to read" do
      {:ok, wire} = Wire.parse(:get, [], "")

      assert {:error, %{code: :invalid_path}} = Bootstrap.from_wire(wire)
    end
  end

  describe "from_wire/1 — unsupported methods" do
    test "the interface defines no FETCH or iPATCH" do
      for method <- [:fetch, :ipatch] do
        {:ok, wire} = Wire.parse(method, [{12, <<112>>}], "")

        assert {:error, err} = Bootstrap.from_wire(wire)
        assert err.code == :unsupported_operation
        assert err.meta == %{method: method}
      end
    end
  end

  describe "Session — happy path" do
    test "drives a full plan then finishes" do
      plan = [
        %Bootstrap.Delete{},
        %Bootstrap.Write{path: path!("/0/0"), content_format: 112, payload: <<0x81>>},
        %Bootstrap.Write{path: path!("/1/0"), content_format: 112, payload: <<0x82>>}
      ]

      session = Session.new(plan)
      assert Session.remaining(session) == 3

      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})
      assert session.state == :provisioning

      session =
        Enum.reduce(plan, session, fn expected, acc ->
          assert {:ok, ^expected, acc} = Session.pop(acc)
          assert {:ok, acc} = Session.ack(acc)
          acc
        end)

      assert Session.pop(session) == :done
      assert Session.remaining(session) == 0
      assert session.applied == plan

      assert {:ok, %Bootstrap.Finish{}, session} = Session.finish(session)
      assert session.state == :finished
      assert Session.done?(session)
    end

    test "an empty plan can finish immediately" do
      session = Session.new()
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})

      assert Session.pop(session) == :done
      assert {:ok, %Bootstrap.Finish{}, _session} = Session.finish(session)
    end

    test "carries the client's preferred Content-Format through for the plan to honour" do
      session = Session.new()

      {:ok, session} =
        Session.request(session, %Bootstrap.Request{
          endpoint_name: "d1",
          preferred_content_format: 110
        })

      assert session.preferred_content_format == 110
    end
  end

  describe "Session — ordering guarantees" do
    test "pop/1 refuses to hand out a second operation while one is in flight" do
      session = Session.new([%Bootstrap.Delete{}, %Bootstrap.Delete{}])
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})

      assert {:ok, _op, session} = Session.pop(session)
      assert {:error, err} = Session.pop(session)
      assert err.code == :operation_in_flight
    end

    test "finish/1 refuses while operations are pending" do
      session = Session.new([%Bootstrap.Delete{}])
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})

      assert {:error, err} = Session.finish(session)
      assert err.code == :plan_incomplete
      assert err.meta == %{remaining: 1}
    end

    test "finish/1 refuses while an operation is in flight" do
      session = Session.new([%Bootstrap.Delete{}])
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})
      {:ok, _op, session} = Session.pop(session)

      assert {:error, %{code: :plan_incomplete, meta: %{remaining: 1}}} = Session.finish(session)
    end

    test "ack/1 with nothing outstanding is an error" do
      session = Session.new([%Bootstrap.Delete{}])
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})

      assert {:error, err} = Session.ack(session)
      assert err.code == :no_operation_in_flight
    end

    test "applied preserves plan order" do
      plan = [
        %Bootstrap.Delete{path: path!("/1/0")},
        %Bootstrap.Delete{path: path!("/1/1")},
        %Bootstrap.Delete{path: path!("/1/2")}
      ]

      session = Session.new(plan)
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})

      session =
        Enum.reduce(plan, session, fn _step, acc ->
          {:ok, _op, acc} = Session.pop(acc)
          {:ok, acc} = Session.ack(acc)
          acc
        end)

      assert session.applied == plan
    end
  end

  describe "Session — state guards" do
    test "operations before a Bootstrap-Request are refused" do
      session = Session.new([%Bootstrap.Delete{}])

      assert {:error, %{code: :invalid_session_state}} = Session.pop(session)
      assert {:error, %{code: :invalid_session_state}} = Session.ack(session)
      assert {:error, %{code: :invalid_session_state}} = Session.finish(session)
    end

    test "a second Bootstrap-Request on a live session is refused" do
      session = Session.new()
      request = %Bootstrap.Request{endpoint_name: "d1"}

      {:ok, session} = Session.request(session, request)

      assert {:error, err} = Session.request(session, request)
      assert err.code == :invalid_session_state
      assert err.meta == %{state: :provisioning, expected: :awaiting_request}
    end

    test "nothing proceeds after finish" do
      session = Session.new()
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})
      {:ok, _finish, session} = Session.finish(session)

      assert {:error, %{code: :invalid_session_state}} = Session.pop(session)
      assert {:error, %{code: :invalid_session_state}} = Session.finish(session)
    end

    test "fail/2 is terminal from any state" do
      reason = Error.new(:timeout, "client stopped responding")

      for session <- [Session.new(), started_session(), finished_session()] do
        failed = Session.fail(session, reason)

        assert failed.state == :failed
        assert failed.failure == reason
        assert Session.done?(failed)
        assert {:error, %{code: :invalid_session_state}} = Session.pop(failed)
        assert {:error, %{code: :invalid_session_state}} = Session.finish(failed)
      end
    end
  end

  describe "Session — plan validation" do
    test "rejects Request and Finish as plan steps" do
      assert_raise ArgumentError, ~r/opens a session/, fn ->
        Session.new([%Bootstrap.Request{endpoint_name: "d1"}])
      end

      assert_raise ArgumentError, ~r/closes a session/, fn ->
        Session.new([%Bootstrap.Finish{}])
      end
    end

    test "rejects anything that is not a Bootstrap operation" do
      assert_raise ArgumentError, ~r/not a Bootstrap operation/, fn ->
        Session.new([%Wick.Request.Delete{path: path!("/1/0")}])
      end
    end

    test "accepts Write, Delete, Discover, and Read" do
      plan = [
        %Bootstrap.Write{path: path!("/0/0"), content_format: 112, payload: <<0x80>>},
        %Bootstrap.Delete{},
        %Bootstrap.Discover{},
        %Bootstrap.Read{path: path!("/1")}
      ]

      assert %Session{pending: ^plan} = Session.new(plan)
    end
  end

  defp started_session do
    session = Session.new([%Bootstrap.Delete{}])
    {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})
    session
  end

  defp finished_session do
    session = Session.new()
    {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "d1"})
    {:ok, _finish, session} = Session.finish(session)
    session
  end
end
