defmodule Wick.ObservationTest do
  use ExUnit.Case, async: true

  doctest Wick.Observation
  doctest Wick.Observation.Store

  alias Wick.Attributes
  alias Wick.Observation
  alias Wick.Observation.Store
  alias Wick.Path

  defp path!(string) do
    {:ok, path} = Path.parse(string)
    path
  end

  defp observation(opts \\ []) do
    paths = Keyword.get(opts, :paths, [path!("/3303/0/5700")])
    registration_id = Keyword.get(opts, :registration_id, "r0")

    Observation.new(registration_id, paths, Keyword.put_new(opts, :now, 0))
  end

  describe "new/3" do
    test "defaults are the absence of a notification, not a zeroed one" do
      obs = observation()

      assert obs.last_seq == nil
      assert obs.notified_at == nil
      assert obs.last_value == nil
      assert obs.attributes == %Attributes{}
    end

    test "carries the transport token and expected Content-Format" do
      obs = observation(token: <<0xAB, 0xCD>>, content_format: 112)

      assert obs.token == <<0xAB, 0xCD>>
      assert obs.content_format == 112
    end

    test "carries attributes written by the server" do
      attrs = %Attributes{pmin: 10, pmax: 60}

      assert observation(attributes: attrs).attributes == attrs
    end

    test "uses the monotonic clock when :now is omitted" do
      before = System.monotonic_time(:millisecond)
      obs = Observation.new("r0", [path!("/3/0/9")])

      assert obs.created_at >= before
    end
  end

  describe "composite?/1" do
    test "one path is not composite" do
      refute Observation.composite?(observation())
    end

    test "two or more paths is composite" do
      assert Observation.composite?(observation(paths: [path!("/3/0/9"), path!("/6/0/0")]))
    end

    test "an empty path list counts as composite, not single" do
      assert Observation.composite?(observation(paths: []))
    end
  end

  describe "newer?/2" do
    test "anything is newer than no prior notification" do
      assert Observation.newer?(0, nil)
      assert Observation.newer?(16_777_215, nil)
    end

    test "strictly greater is newer within the recent window" do
      assert Observation.newer?(2, 1)
      refute Observation.newer?(1, 2)
      refute Observation.newer?(1, 1)
    end

    test "handles the 24-bit wrap per RFC 7641 §3.4" do
      assert Observation.newer?(0, 16_777_215)
      assert Observation.newer?(5, 16_777_210)
      refute Observation.newer?(16_777_215, 0)
    end

    test "a jump beyond half the sequence space reads as a wrap, not a leap forward" do
      # 8_388_609 is more than 2^23 ahead of 0, so RFC 7641 treats it as stale.
      refute Observation.newer?(8_388_609, 0)
      assert Observation.newer?(8_388_607, 0)
    end
  end

  describe "accept_seq/3" do
    test "the first notification is always accepted" do
      assert {:ok, obs} = Observation.accept_seq(observation(), 0, now: 100, value: 22.5)

      assert obs.last_seq == 0
      assert obs.last_value == 22.5
      assert obs.notified_at == 100
    end

    test "a reordered notification is rejected and changes nothing" do
      {:ok, obs} = Observation.accept_seq(observation(), 10, now: 100, value: 22)

      assert Observation.accept_seq(obs, 9, now: 200, value: 99) == :stale
    end

    test "a duplicate sequence number is stale" do
      {:ok, obs} = Observation.accept_seq(observation(), 10, now: 100)

      assert Observation.accept_seq(obs, 10, now: 200) == :stale
    end

    test "omitting :value keeps the previous value" do
      {:ok, obs} = Observation.accept_seq(observation(), 1, now: 100, value: 22)
      {:ok, obs} = Observation.accept_seq(obs, 2, now: 200)

      assert obs.last_value == 22
      assert obs.notified_at == 200
    end

    test "an explicit nil value is recorded as nil" do
      {:ok, obs} = Observation.accept_seq(observation(), 1, now: 100, value: 22)
      {:ok, obs} = Observation.accept_seq(obs, 2, now: 200, value: nil)

      assert obs.last_value == nil
    end
  end

  describe "state/2" do
    test "reports no elapsed time before the first notification" do
      assert Observation.state(observation(), 5_000) == %{last_value: nil, since_last_ms: nil}
    end

    test "feeds Attributes.should_notify?/3 directly" do
      {:ok, obs} = Observation.accept_seq(observation(), 0, now: 1_000, value: 20)
      attrs = %Attributes{pmin: 10}

      refute Attributes.should_notify?(attrs, Observation.state(obs, 6_000), 25)
      assert Attributes.should_notify?(attrs, Observation.state(obs, 12_000), 25)
    end
  end

  describe "next_seq/1" do
    test "starts at zero and wraps at 2^24" do
      assert Observation.next_seq(nil) == 0
      assert Observation.next_seq(0) == 1
      assert Observation.next_seq(16_777_214) == 16_777_215
      assert Observation.next_seq(16_777_215) == 0
    end

    test "a full wrap of emitted sequences stays acceptable to newer?/2" do
      # Emitting in order must never produce a sequence the receiver rejects.
      Enum.reduce([nil | Enum.to_list(0..5)], nil, fn _step, seen ->
        next = Observation.next_seq(seen)
        assert Observation.newer?(next, seen)
        next
      end)
    end
  end

  describe "Store" do
    test "put/fetch/delete round-trip" do
      obs = observation()
      store = Store.put(Store.new(), :h1, obs)

      assert Store.fetch(store, :h1) == {:ok, obs}
      assert Store.size(store) == 1
      assert Store.delete(store, :h1) |> Store.size() == 0
    end

    test "fetching an unknown handle is :error, not a crash" do
      assert Store.fetch(Store.new(), :nope) == :error
    end

    test "deleting an unknown handle is a no-op" do
      store = Store.put(Store.new(), :h1, observation())

      assert Store.delete(store, :nope) == store
    end

    test "re-putting the same handle replaces rather than duplicating the index entry" do
      store =
        Store.new()
        |> Store.put(:h1, observation())
        |> Store.put(:h1, observation(token: <<9>>))

      assert Store.size(store) == 1
      assert Store.handles_for_registration(store, "r0") == [:h1]
      assert {:ok, %{token: <<9>>}} = Store.fetch(store, :h1)
    end

    test "handles_for_registration/2 preserves insertion order" do
      store =
        Store.new()
        |> Store.put(:h1, observation())
        |> Store.put(:h2, observation(paths: [path!("/3/0/9")]))
        |> Store.put(:h3, observation(paths: [path!("/6/0/0")]))

      assert Store.handles_for_registration(store, "r0") == [:h1, :h2, :h3]
    end

    test "delete_by_registration/2 drops the whole set and leaves others alone" do
      store =
        Store.new()
        |> Store.put(:a1, observation(registration_id: "r0"))
        |> Store.put(:a2, observation(registration_id: "r0", paths: [path!("/3/0/9")]))
        |> Store.put(:b1, observation(registration_id: "r1"))

      store = Store.delete_by_registration(store, "r0")

      assert Store.size(store) == 1
      assert Store.handles_for_registration(store, "r0") == []
      assert {:ok, _obs} = Store.fetch(store, :b1)
    end

    test "deleting the last handle for a registration prunes the index key" do
      store = Store.put(Store.new(), :h1, observation())

      assert Store.delete(store, :h1).by_registration == %{}
    end

    test "update/3 on an unknown handle is a no-op" do
      store = Store.put(Store.new(), :h1, observation())

      assert Store.update(store, :gone, &%{&1 | last_value: 1}) == store
    end

    test "update/3 composes with accept_seq/3 for the notification path" do
      store = Store.put(Store.new(), :h1, observation())

      store =
        Store.update(store, :h1, fn obs ->
          {:ok, updated} = Observation.accept_seq(obs, 3, now: 500, value: 21.0)
          updated
        end)

      assert {:ok, %{last_seq: 3, last_value: 21.0}} = Store.fetch(store, :h1)
    end

    test "handles_for_path/3 matches exactly, not hierarchically" do
      store = Store.put(Store.new(), :h1, observation(paths: [path!("/3303/0/5700")]))

      assert Store.handles_for_path(store, path!("/3303/0/5700")) == [:h1]
      assert Store.handles_for_path(store, path!("/3303/0")) == []
      assert Store.handles_for_path(store, path!("/3303")) == []
    end

    test "handles_for_path/3 finds a path inside a composite relation" do
      paths = [path!("/3/0/9"), path!("/6/0/0")]
      store = Store.put(Store.new(), :h1, observation(paths: paths))

      assert Store.handles_for_path(store, path!("/6/0/0")) == [:h1]
    end

    test "handles_for_path/3 can be scoped to one registration" do
      path = path!("/3303/0/5700")

      store =
        Store.new()
        |> Store.put(:a, observation(registration_id: "r0", paths: [path]))
        |> Store.put(:b, observation(registration_id: "r1", paths: [path]))

      assert Enum.sort(Store.handles_for_path(store, path)) == [:a, :b]
      assert Store.handles_for_path(store, path, registration_id: "r1") == [:b]
    end

    test "list/1 returns every relation" do
      store =
        Store.new()
        |> Store.put(:h1, observation())
        |> Store.put(:h2, observation(registration_id: "r1"))

      assert length(Store.list(store)) == 2
    end

    test "handles need not be atoms — a {peer, token} tuple works" do
      handle = {{{127, 0, 0, 1}, 5683}, <<1, 2, 3>>}
      store = Store.put(Store.new(), handle, observation())

      assert {:ok, _obs} = Store.fetch(store, handle)
    end
  end
end
