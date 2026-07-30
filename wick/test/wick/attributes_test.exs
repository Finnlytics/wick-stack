defmodule Wick.AttributesTest do
  use ExUnit.Case, async: true

  doctest Wick.Attributes

  alias Wick.Attributes

  describe "to_query/1" do
    test "emits attributes in table order, not struct order" do
      attrs = %Attributes{st: 1, pmin: 10, gt: 25, pmax: 60, lt: 5}

      assert Attributes.to_query(attrs) == [
               {"pmin", 10},
               {"pmax", 60},
               {"gt", 25},
               {"lt", 5},
               {"st", 1}
             ]
    end

    test "keeps a zero value — pmin=0 is meaningful" do
      assert Attributes.to_query(%Attributes{pmin: 0}) == [{"pmin", 0}]
    end

    test "a nil field is omitted, a :clear field becomes a bare flag" do
      assert Attributes.to_query(%Attributes{pmin: nil, pmax: :clear}) == [{"pmax", nil}]
    end

    test "includes property attributes when set" do
      attrs = %Attributes{dim: 3, ver: "1.1", ssid: 101, uri: "coap://example.org"}

      assert Attributes.to_query(attrs) == [
               {"dim", 3},
               {"ssid", 101},
               {"uri", "coap://example.org"},
               {"ver", "1.1"}
             ]
    end
  end

  describe "from_query/1" do
    test "parses integers and floats into their natural types" do
      assert {:ok, attrs} =
               Attributes.from_query([{"pmin", "10"}, {"gt", "22.5"}, {"st", "1"}])

      assert attrs.pmin == 10
      assert attrs.gt == 22.5
      assert attrs.st == 1
    end

    test "a bare parameter decodes to :clear, distinct from absent" do
      assert {:ok, attrs} = Attributes.from_query([{"pmin", nil}])

      assert attrs.pmin == :clear
      assert attrs.pmax == nil
    end

    test "accepts already-numeric values" do
      assert {:ok, attrs} = Attributes.from_query([{"pmin", 10}, {"gt", 22.5}])

      assert {attrs.pmin, attrs.gt} == {10, 22.5}
    end

    test "ignores query parameters that are not attributes" do
      assert {:ok, attrs} = Attributes.from_query([{"ep", "device-1"}, {"lt", "5"}])

      assert attrs.lt == 5
      assert attrs.ssid == nil
    end

    test "rejects an integer attribute given a float" do
      assert {:error, err} = Attributes.from_query([{"pmin", "10.5"}])
      assert err.code == :invalid_attribute
      assert err.meta == %{attribute: "pmin", value: "10.5"}
    end

    test "rejects a numeric attribute given a non-number" do
      assert {:error, err} = Attributes.from_query([{"gt", "warm"}])
      assert err.code == :invalid_attribute
    end

    test "rejects trailing garbage after a number" do
      assert {:error, _err} = Attributes.from_query([{"pmax", "60s"}])
    end

    test "stops at the first bad attribute" do
      assert {:error, err} = Attributes.from_query([{"pmin", "bad"}, {"pmax", "also bad"}])
      assert err.meta.attribute == "pmin"
    end
  end

  describe "to_query/1 and from_query/1 round-trip" do
    test "a full notification set survives" do
      original = %Attributes{pmin: 10, pmax: 60, epmin: 1, epmax: 30, gt: 25.5, lt: 5.5, st: 2}

      assert {:ok, decoded} = original |> Attributes.to_query() |> Attributes.from_query()
      assert decoded == original
    end

    test "clears survive as clears" do
      original = %Attributes{pmin: :clear, gt: :clear}

      assert {:ok, decoded} = original |> Attributes.to_query() |> Attributes.from_query()
      assert decoded == original
    end
  end

  describe "link params" do
    test "round-trip through CoRE Link Format params" do
      original = %Attributes{pmin: 10, pmax: 60, gt: 22.5, dim: 3}

      assert {:ok, decoded} =
               original |> Attributes.to_link_params() |> Attributes.from_link_params()

      assert decoded == original
    end

    test "drops :clear, which has no meaning in a Discover response" do
      assert Attributes.to_link_params(%Attributes{pmin: :clear, pmax: 60}) == %{"pmax" => "60"}
    end

    test "ignores non-attribute link params" do
      assert {:ok, attrs} =
               Attributes.from_link_params(%{"obs" => "", "rt" => "oma.lwm2m", "pmin" => "1"})

      assert attrs.pmin == 1
    end
  end

  describe "merge/2" do
    test "nil leaves the current value alone" do
      current = %Attributes{pmin: 10, pmax: 60}

      assert Attributes.merge(current, %Attributes{}) == current
    end

    test ":clear removes and a value replaces" do
      current = %Attributes{pmin: 10, pmax: 60, gt: 1}
      incoming = %Attributes{pmin: 30, pmax: :clear}

      assert Attributes.merge(current, incoming) == %Attributes{pmin: 30, pmax: nil, gt: 1}
    end

    test "zero replaces rather than being treated as absent" do
      assert Attributes.merge(%Attributes{pmin: 10}, %Attributes{pmin: 0}).pmin == 0
    end
  end

  describe "should_notify?/3 — first notification" do
    test "always notifies when nothing has been sent yet" do
      state = %{last_value: nil, since_last_ms: nil}

      assert Attributes.should_notify?(%Attributes{}, state, 20)
      assert Attributes.should_notify?(%Attributes{pmin: 3600}, state, 20)
    end
  end

  describe "should_notify?/3 — pmin" do
    test "blocks everything until pmin has elapsed" do
      attrs = %Attributes{pmin: 10, pmax: 20, st: 1}

      refute Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 9_999}, 100)
    end

    test "releases exactly at pmin" do
      attrs = %Attributes{pmin: 10}

      assert Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 10_000}, 21)
    end

    test "pmin: 0 blocks nothing" do
      attrs = %Attributes{pmin: 0}

      assert Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 0}, 21)
    end
  end

  describe "should_notify?/3 — pmax" do
    test "notifies on an unchanged value once pmax elapses" do
      attrs = %Attributes{pmax: 60}

      assert Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 60_000}, 20)
    end

    test "does not notify on an unchanged value before pmax" do
      attrs = %Attributes{pmax: 60}

      refute Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 59_999}, 20)
    end

    test "pmin wins over pmax when they conflict" do
      # A nonsensical but legal pair: pmin longer than pmax. pmin is the hard floor.
      attrs = %Attributes{pmin: 30, pmax: 10}

      refute Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 20_000}, 20)
    end
  end

  describe "should_notify?/3 — step" do
    test "fires only once the change reaches st" do
      attrs = %Attributes{st: 5}
      state = %{last_value: 20, since_last_ms: 1_000}

      refute Attributes.should_notify?(attrs, state, 24)
      assert Attributes.should_notify?(attrs, state, 25)
    end

    test "is direction-agnostic" do
      attrs = %Attributes{st: 5}
      state = %{last_value: 20, since_last_ms: 1_000}

      assert Attributes.should_notify?(attrs, state, 15)
      assert Attributes.should_notify?(attrs, state, 25)
    end
  end

  describe "should_notify?/3 — thresholds" do
    test "gt fires on crossing, not on staying above" do
      attrs = %Attributes{gt: 25}

      assert Attributes.should_notify?(attrs, %{last_value: 24, since_last_ms: 1_000}, 26)
      refute Attributes.should_notify?(attrs, %{last_value: 26, since_last_ms: 1_000}, 30)
    end

    test "gt fires on crossing back down" do
      attrs = %Attributes{gt: 25}

      assert Attributes.should_notify?(attrs, %{last_value: 26, since_last_ms: 1_000}, 24)
    end

    test "lt fires on crossing below" do
      attrs = %Attributes{lt: 5}

      assert Attributes.should_notify?(attrs, %{last_value: 6, since_last_ms: 1_000}, 4)
      refute Attributes.should_notify?(attrs, %{last_value: 4, since_last_ms: 1_000}, 3)
    end

    test "gt and lt together form a band, either edge fires" do
      attrs = %Attributes{gt: 25, lt: 5}
      state = fn last -> %{last_value: last, since_last_ms: 1_000} end

      assert Attributes.should_notify?(attrs, state.(10), 30)
      assert Attributes.should_notify?(attrs, state.(10), 1)
      refute Attributes.should_notify?(attrs, state.(10), 20)
    end
  end

  describe "should_notify?/3 — no band attributes" do
    test "any change notifies" do
      state = %{last_value: 20, since_last_ms: 1_000}

      assert Attributes.should_notify?(%Attributes{}, state, 21)
      refute Attributes.should_notify?(%Attributes{}, state, 20)
    end

    test "a band attribute suppresses plain changes" do
      state = %{last_value: 20, since_last_ms: 1_000}

      refute Attributes.should_notify?(%Attributes{st: 5}, state, 21)
    end

    test "works for non-numeric values" do
      state = %{last_value: "on", since_last_ms: 1_000}

      assert Attributes.should_notify?(%Attributes{}, state, "off")
      refute Attributes.should_notify?(%Attributes{}, state, "on")
    end

    test "a numeric band never fires for non-numeric values" do
      state = %{last_value: "on", since_last_ms: 1_000}

      refute Attributes.should_notify?(%Attributes{st: 1}, state, "off")
    end
  end

  describe "field classification" do
    test "every table field belongs to exactly one class" do
      fields = Attributes.notification_fields() ++ Attributes.property_fields()
      struct_fields = %Attributes{} |> Map.from_struct() |> Map.keys()

      assert Enum.sort(fields) == Enum.sort(struct_fields)
    end
  end

  describe "empty?/1" do
    test "a :clear is not empty — it is an instruction" do
      refute Attributes.empty?(%Attributes{pmin: :clear})
    end

    test "a zero is not empty" do
      refute Attributes.empty?(%Attributes{pmax: 0})
    end
  end
end
