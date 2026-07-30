defmodule WickCoap.DedupTest do
  use ExUnit.Case, async: true

  alias WickCoap.Dedup

  doctest Dedup

  describe "observe/3" do
    test "first observation of a Message ID is :fresh" do
      d = Dedup.new()
      assert {:fresh, _} = Dedup.observe(d, 1234, 0)
    end

    test "second observation within the lifetime is :duplicate" do
      d = Dedup.new(lifetime_ms: 10_000)
      {:fresh, d} = Dedup.observe(d, 1234, 0)
      assert {:duplicate, _} = Dedup.observe(d, 1234, 5_000)
    end

    test "observation past the lifetime is :fresh again (window pruned)" do
      d = Dedup.new(lifetime_ms: 1_000)
      {:fresh, d} = Dedup.observe(d, 1234, 0)
      assert {:fresh, _} = Dedup.observe(d, 1234, 2_000)
    end

    test "different Message IDs do not collide" do
      d = Dedup.new()
      {:fresh, d} = Dedup.observe(d, 1, 0)
      assert {:fresh, _} = Dedup.observe(d, 2, 0)
    end
  end

  describe "size/1" do
    test "tracks the number of remembered Message IDs" do
      d = Dedup.new(lifetime_ms: 10_000)
      assert Dedup.size(d) == 0

      {:fresh, d} = Dedup.observe(d, 1, 0)
      {:fresh, d} = Dedup.observe(d, 2, 0)
      assert Dedup.size(d) == 2
    end

    test "shrinks after a sweep evicts old entries" do
      d = Dedup.new(lifetime_ms: 1_000)
      {:fresh, d} = Dedup.observe(d, 1, 0)
      {:fresh, d} = Dedup.observe(d, 2, 0)
      assert Dedup.size(d) == 2

      # Force a sweep by observing well past lifetime
      {:fresh, d} = Dedup.observe(d, 3, 5_000)
      assert Dedup.size(d) == 1
    end
  end
end
