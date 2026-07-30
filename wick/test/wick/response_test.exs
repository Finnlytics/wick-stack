defmodule Wick.ResponseTest do
  use ExUnit.Case, async: true

  alias Wick.Path
  alias Wick.Response

  doctest Response

  describe "content/2" do
    test "builds a 2.05 Content response carrying a payload" do
      r = Response.content(112, <<0xDE, 0xAD>>)

      assert r.status == :content
      assert r.content_format == 112
      assert r.payload == <<0xDE, 0xAD>>
      assert r.location_path == nil
    end

    test "rejects negative content-format" do
      assert_raise FunctionClauseError, fn -> Response.content(-1, <<>>) end
    end
  end

  describe "changed/0 and deleted/0" do
    test "no payload, no content-format" do
      assert %Response{status: :changed, content_format: nil, payload: nil} = Response.changed()
      assert %Response{status: :deleted, content_format: nil, payload: nil} = Response.deleted()
    end
  end

  describe "created/1" do
    test "carries the new instance's location path" do
      {:ok, location} = Path.parse("/3/0")
      r = Response.created(location)

      assert r.status == :created
      assert r.location_path == location
    end
  end

  describe "error/2" do
    test "builds a status-only error response" do
      r = Response.error(:not_found)

      assert r.status == :not_found
      assert r.payload == nil
    end

    test "attaches an optional diagnostic payload" do
      r = Response.error(:bad_request, "missing required field")

      assert r.status == :bad_request
      assert r.payload == "missing required field"
    end

    test "raises if status is not in the error class" do
      assert_raise ArgumentError, fn -> Response.error(:content) end
      assert_raise ArgumentError, fn -> Response.error(:changed) end
    end
  end

  describe "success?/1 and error?/1" do
    test "success responses report success?, not error?" do
      r = Response.changed()
      assert Response.success?(r)
      refute Response.error?(r)
    end

    test "error responses report error?, not success?" do
      r = Response.error(:not_found)
      refute Response.success?(r)
      assert Response.error?(r)
    end
  end
end
