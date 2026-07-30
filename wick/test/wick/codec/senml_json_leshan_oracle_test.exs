defmodule Wick.Codec.SenmlJsonLeshanOracleTest do
  @moduledoc """
  Cross-implementation byte-equality test for SenML JSON against Eclipse Leshan 2.0.0-M18.

  Mirror of `Wick.Codec.SenmlCborLeshanOracleTest` for the JSON wire format. Reads the
  fixtures under `test/fixtures/senml_json/`. Run on demand: the Java oracle generates
  `.bin` files, which the Elixir test reads directly. **No JVM is required to run the test.**

  See [`tools/leshan_oracle/README.md`](../../../tools/leshan_oracle/) and ADRs 0002 / 0003.
  """

  use ExUnit.Case, async: true
  @moduletag :oracle

  alias Wick.Codec.SenmlJson
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  @fixtures_dir Path.join(__DIR__, "../../fixtures/senml_json") |> Path.expand()

  for json_path <-
        @fixtures_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(&Path.join(@fixtures_dir, &1)) do
    @json_path json_path
    @stem json_path |> Path.basename() |> Path.rootname(".json")
    @leshan_bin Path.join(@fixtures_dir, "#{@stem}.bin")
    @wick_bin Path.join(@fixtures_dir, "#{@stem}.wick.bin")

    test "#{@stem}: SenML JSON output matches the committed reference" do
      spec = @json_path |> File.read!() |> Jason.decode!()
      pack = build_pack(spec)
      opts = if Map.get(spec, "allow_no_value", false), do: [allow_no_value: true], else: []

      assert {:ok, encoded} = SenmlJson.encode(pack, opts)

      expected_path =
        if File.exists?(@wick_bin), do: @wick_bin, else: @leshan_bin

      expected = File.read!(expected_path)

      assert encoded == expected, """
      Encoder output did not match #{Path.basename(expected_path)}.
      Expected (#{byte_size(expected)} bytes): #{expected}
      Got      (#{byte_size(encoded)} bytes): #{encoded}
      """
    end
  end

  defp build_pack(%{"records" => records}) do
    Pack.new(Enum.map(records, &build_record/1))
  end

  defp build_record(map) do
    %Record{
      base_name: map["base_name"],
      base_time: number_or_nil(map["base_time"]),
      name: map["name"],
      time: number_or_nil(map["time"]),
      number_value: number_or_nil(map["number_value"]),
      string_value: map["string_value"],
      boolean_value: map["boolean_value"],
      opaque_value: opaque_or_nil(map["opaque_value"]),
      object_link_value: map["object_link_value"]
    }
  end

  defp number_or_nil(nil), do: nil
  defp number_or_nil(n) when is_integer(n) or is_float(n), do: n

  defp opaque_or_nil(nil), do: nil
  defp opaque_or_nil(hex) when is_binary(hex), do: Base.decode16!(hex, case: :mixed)
end
