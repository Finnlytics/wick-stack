defmodule Wick.Senml.PackTest do
  use ExUnit.Case, async: true

  alias Wick.Codec.SenmlCbor
  alias Wick.Codec.SenmlJson
  alias Wick.Path
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  doctest Pack

  describe "new/1" do
    test "wraps an empty list" do
      assert %Pack{records: []} = Pack.new([])
    end

    test "wraps a list of records preserving order" do
      r1 = %Record{name: "/3/0/9", number_value: 87}
      r2 = %Record{name: "/3/0/0", string_value: "Open Mobile Alliance"}

      pack = Pack.new([r1, r2])

      assert pack.records == [r1, r2]
    end
  end

  describe "struct construction" do
    test "requires :records key" do
      assert_raise ArgumentError, fn ->
        struct!(Pack, [])
      end
    end

    test "accepts an explicit empty list" do
      assert %Pack{records: []} = %Pack{records: []}
    end
  end

  describe "from_paths/1 — Read-Composite payload construction" do
    test "produces one record per path with name set and no value field" do
      {:ok, p1} = Path.parse("/3/0/9")
      {:ok, p2} = Path.parse("/3303/0/5700")

      pack = Pack.from_paths([p1, p2])

      assert Enum.map(pack.records, & &1.name) == ["/3/0/9", "/3303/0/5700"]
      assert Enum.all?(pack.records, &(Record.value_type(&1) == :none))
    end

    test "an empty path list yields an empty pack" do
      assert %Pack{records: []} = Pack.from_paths([])
    end

    test "the resulting pack encodes cleanly via SenML CBOR with allow_no_value: true" do
      {:ok, p} = Path.parse("/3/0/9")
      pack = Pack.from_paths([p])

      assert {:ok, _bytes} = SenmlCbor.encode(pack, allow_no_value: true)
    end

    test "the resulting pack also encodes cleanly via SenML JSON" do
      {:ok, p1} = Path.parse("/3/0/9")
      {:ok, p2} = Path.parse("/3303/0/5700")
      pack = Pack.from_paths([p1, p2])

      assert {:ok, ~s|[{"n":"/3/0/9"},{"n":"/3303/0/5700"}]|} =
               SenmlJson.encode(pack, allow_no_value: true)
    end
  end

  describe "resolve/1" do
    test "an empty pack resolves to an empty list" do
      assert Pack.resolve(Pack.new([])) == []
    end

    test "base_name carries forward until overridden" do
      pack =
        Pack.new([
          %Record{base_name: "/3/0/", name: "0", string_value: "OMA"},
          %Record{name: "1", string_value: "model"},
          %Record{base_name: "/3303/0/", name: "5700", number_value: 22.5},
          %Record{name: "5701", string_value: "Cel"}
        ])

      assert Enum.map(Pack.resolve(pack), fn {name, _t, _r} -> name end) ==
               ["/3/0/0", "/3/0/1", "/3303/0/5700", "/3303/0/5701"]
    end

    test "a record with a full name and no base resolves to itself" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])

      assert [{"/3/0/9", nil, _record}] = Pack.resolve(pack)
    end

    test "base_time is added to per-record time and carries forward" do
      pack =
        Pack.new([
          %Record{base_time: 1_700_000_000, name: "/1/0/1", time: 5, number_value: 1},
          %Record{name: "/1/0/2", time: 10, number_value: 2},
          %Record{name: "/1/0/3", number_value: 3}
        ])

      assert Enum.map(Pack.resolve(pack), fn {_n, time, _r} -> time end) ==
               [1_700_000_005, 1_700_000_010, 1_700_000_000]
    end

    test "no time anywhere resolves to nil, not zero" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])

      assert [{_name, nil, _record}] = Pack.resolve(pack)
    end

    test "a per-record time with no base_time stands alone" do
      pack = Pack.new([%Record{name: "/3/0/9", time: 42, number_value: 87}])

      assert [{_name, 42, _record}] = Pack.resolve(pack)
    end

    test "carries the original record through untouched" do
      record = %Record{base_name: "/3/0/", name: "9", number_value: 87}

      assert [{"/3/0/9", _time, ^record}] = Pack.resolve(Pack.new([record]))
    end
  end

  describe "to_paths/1" do
    test "is the inverse of from_paths/1" do
      {:ok, p1} = Path.parse("/3/0/9")
      {:ok, p2} = Path.parse("/3303/0/5700")
      {:ok, p3} = Path.parse("/1")
      original = [p1, p2, p3]

      assert {:ok, ^original} = original |> Pack.from_paths() |> Pack.to_paths()
    end

    test "an empty pack yields an empty path list" do
      assert Pack.to_paths(Pack.new([])) == {:ok, []}
    end

    test "resolves base_name before parsing" do
      pack = Pack.new([%Record{base_name: "/3303/0/", name: "5700"}])

      assert {:ok, [path]} = Pack.to_paths(pack)
      assert Path.format(path) == "/3303/0/5700"
    end

    test "ignores values — a pack of readings still yields its paths" do
      pack =
        Pack.new([
          %Record{name: "/3303/0/5700", number_value: 22.5},
          %Record{name: "/3303/0/5701", string_value: "Cel"}
        ])

      assert {:ok, paths} = Pack.to_paths(pack)
      assert Enum.map(paths, &Path.format/1) == ["/3303/0/5700", "/3303/0/5701"]
    end

    test "a record with no name at all is an error" do
      assert {:error, err} = Pack.to_paths(Pack.new([%Record{number_value: 1}]))
      assert err.code == :missing_name
    end

    test "a name that is not an LwM2M path is an error" do
      assert {:error, err} = Pack.to_paths(Pack.new([%Record{name: "/3/0/temperature"}]))
      assert err.code == :invalid_path
    end

    test "stops at the first bad record" do
      pack = Pack.new([%Record{name: "/3/0/9"}, %Record{name: "/bad"}, %Record{name: "/6/0"}])

      assert {:error, %{code: :invalid_path}} = Pack.to_paths(pack)
    end

    test "round-trips through the SenML CBOR wire form" do
      {:ok, p1} = Path.parse("/3/0/9")
      {:ok, p2} = Path.parse("/6/0/0")

      assert {:ok, encoded} = SenmlCbor.encode(Pack.from_paths([p1, p2]), allow_no_value: true)
      assert {:ok, pack} = SenmlCbor.decode(IO.iodata_to_binary(encoded), [])
      assert {:ok, [^p1, ^p2]} = Pack.to_paths(pack)
    end
  end
end
