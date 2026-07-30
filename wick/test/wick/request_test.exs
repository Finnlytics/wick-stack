defmodule Wick.RequestTest do
  use ExUnit.Case, async: true

  alias Wick.Path
  alias Wick.Request

  describe "Wick.Request.Read" do
    test "requires :path; accept_content_format defaults to nil" do
      {:ok, p} = Path.parse("/3/0/9")
      req = %Request.Read{path: p}

      assert req.path == p
      assert req.accept_content_format == nil
    end

    test "accepts an explicit accept_content_format" do
      {:ok, p} = Path.parse("/3/0/9")
      req = %Request.Read{path: p, accept_content_format: 112}
      assert req.accept_content_format == 112
    end

    test "missing :path raises at construction" do
      assert_raise ArgumentError, fn -> struct!(Request.Read, []) end
    end
  end

  describe "Wick.Request.Write" do
    setup do
      {:ok, path} = Path.parse("/3/0/9")
      %{path: path}
    end

    test "requires :path, :content_format, :payload — :mode defaults to :replace", %{
      path: path
    } do
      req = %Request.Write{path: path, content_format: 112, payload: <<1, 2, 3>>}

      assert req.mode == :replace
      assert req.content_format == 112
      assert req.payload == <<1, 2, 3>>
    end

    test "accepts :mode = :partial_update", %{path: path} do
      req = %Request.Write{
        path: path,
        content_format: 112,
        payload: <<>>,
        mode: :partial_update
      }

      assert req.mode == :partial_update
    end

    test "missing required keys raise", %{path: path} do
      assert_raise ArgumentError, fn ->
        struct!(Request.Write, path: path, content_format: 112)
      end

      assert_raise ArgumentError, fn -> struct!(Request.Write, []) end
    end
  end

  describe "Wick.Request.Execute" do
    test "requires :path; arguments default to nil" do
      {:ok, p} = Path.parse("/3/0/4")
      req = %Request.Execute{path: p}

      assert req.path == p
      assert req.arguments == nil
    end

    test "accepts an arguments string" do
      {:ok, p} = Path.parse("/3/0/4")
      req = %Request.Execute{path: p, arguments: "0='delay'"}
      assert req.arguments == "0='delay'"
    end
  end

  describe "Wick.Request.Discover" do
    test "requires :path" do
      {:ok, p} = Path.parse("/3")
      req = %Request.Discover{path: p}
      assert req.path == p
    end
  end

  describe "Wick.Request.Create" do
    test "requires :path, :content_format, :payload" do
      {:ok, p} = Path.parse("/3")
      req = %Request.Create{path: p, content_format: 112, payload: <<>>}
      assert req.content_format == 112
    end

    test "missing required keys raise" do
      assert_raise ArgumentError, fn -> struct!(Request.Create, []) end
    end
  end

  describe "Wick.Request.Delete" do
    test "requires :path" do
      {:ok, p} = Path.parse("/3/0")
      req = %Request.Delete{path: p}
      assert req.path == p
    end
  end

  describe "Wick.Request.ReadComposite" do
    test "carries a list of paths and an optional accept content format" do
      {:ok, p1} = Path.parse("/3/0/9")
      {:ok, p2} = Path.parse("/3303/0/5700")

      req = %Request.ReadComposite{paths: [p1, p2], accept_content_format: 112}

      assert req.paths == [p1, p2]
      assert req.accept_content_format == 112
    end

    test "accept_content_format defaults to nil" do
      {:ok, p1} = Path.parse("/3/0/9")
      req = %Request.ReadComposite{paths: [p1]}
      assert req.accept_content_format == nil
    end

    test "an empty path list is valid (consumer responsibility, not Wick's)" do
      req = %Request.ReadComposite{paths: []}
      assert req.paths == []
    end

    test "missing :paths raises at construction" do
      assert_raise ArgumentError, fn -> struct!(Request.ReadComposite, []) end
    end
  end

  describe "Wick.Request.WriteComposite" do
    test "requires :content_format and :payload" do
      req = %Request.WriteComposite{content_format: 112, payload: <<0x80>>}
      assert req.content_format == 112
      assert req.payload == <<0x80>>
    end

    test "missing required keys raise" do
      assert_raise ArgumentError, fn -> struct!(Request.WriteComposite, []) end

      assert_raise ArgumentError, fn ->
        struct!(Request.WriteComposite, content_format: 112)
      end
    end

    test "deliberately has no :mode field — Write-Composite is always partial update" do
      req = %Request.WriteComposite{content_format: 112, payload: <<>>}
      refute Map.has_key?(req, :mode)
    end
  end

  describe "Wick.Request.Observe" do
    test "carries a path and an optional accept content format" do
      {:ok, p} = Path.parse("/3303/0/5700")
      req = %Request.Observe{path: p, accept_content_format: 112}

      assert req.path == p
      assert req.accept_content_format == 112
    end

    test "accept_content_format defaults to nil" do
      {:ok, p} = Path.parse("/3303/0/5700")
      req = %Request.Observe{path: p}
      assert req.accept_content_format == nil
    end

    test "missing :path raises" do
      assert_raise ArgumentError, fn -> struct!(Request.Observe, []) end
    end
  end

  describe "Wick.Request.CancelObserve" do
    test "requires :path" do
      {:ok, p} = Path.parse("/3303/0/5700")
      req = %Request.CancelObserve{path: p}
      assert req.path == p
    end

    test "missing :path raises" do
      assert_raise ArgumentError, fn -> struct!(Request.CancelObserve, []) end
    end
  end

  describe "Wick.Request.ObserveComposite" do
    test "carries a list of paths" do
      {:ok, p1} = Path.parse("/3/0/9")
      {:ok, p2} = Path.parse("/6/0/0")

      req = %Request.ObserveComposite{paths: [p1, p2], accept_content_format: 112}

      assert length(req.paths) == 2
      assert req.accept_content_format == 112
    end

    test "missing :paths raises" do
      assert_raise ArgumentError, fn -> struct!(Request.ObserveComposite, []) end
    end
  end

  describe "pattern matching across request types" do
    test "structs are distinguishable" do
      {:ok, path} = Path.parse("/3/0/9")

      requests = [
        %Request.Read{path: path},
        %Request.Write{path: path, content_format: 0, payload: ""},
        %Request.Execute{path: path},
        %Request.Discover{path: path},
        %Request.Create{path: path, content_format: 0, payload: ""},
        %Request.Delete{path: path},
        %Request.ReadComposite{paths: [path]},
        %Request.WriteComposite{content_format: 112, payload: <<>>},
        %Request.Observe{path: path},
        %Request.CancelObserve{path: path},
        %Request.ObserveComposite{paths: [path]}
      ]

      tags =
        Enum.map(requests, fn
          %Request.Read{} -> :read
          %Request.Write{} -> :write
          %Request.Execute{} -> :execute
          %Request.Discover{} -> :discover
          %Request.Create{} -> :create
          %Request.Delete{} -> :delete
          %Request.ReadComposite{} -> :read_composite
          %Request.WriteComposite{} -> :write_composite
          %Request.Observe{} -> :observe
          %Request.CancelObserve{} -> :cancel_observe
          %Request.ObserveComposite{} -> :observe_composite
        end)

      assert tags == [
               :read,
               :write,
               :execute,
               :discover,
               :create,
               :delete,
               :read_composite,
               :write_composite,
               :observe,
               :cancel_observe,
               :observe_composite
             ]
    end
  end
end
