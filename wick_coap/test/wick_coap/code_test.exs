defmodule WickCoap.CodeTest do
  use ExUnit.Case, async: true

  alias WickCoap.Code

  doctest Code

  describe "encode/1 — registered codes" do
    test "methods (0.xx)" do
      assert Code.encode(:empty) == 0x00
      assert Code.encode(:get) == 0x01
      assert Code.encode(:post) == 0x02
      assert Code.encode(:put) == 0x03
      assert Code.encode(:delete) == 0x04
      assert Code.encode(:fetch) == 0x05
      assert Code.encode(:patch) == 0x06
      assert Code.encode(:ipatch) == 0x07
    end

    test "success responses (2.xx)" do
      assert Code.encode(:created) == 0x41
      assert Code.encode(:deleted) == 0x42
      assert Code.encode(:valid) == 0x43
      assert Code.encode(:changed) == 0x44
      assert Code.encode(:content) == 0x45
      assert Code.encode(:continue) == 0x5F
    end

    test "client error responses (4.xx)" do
      assert Code.encode(:bad_request) == 0x80
      assert Code.encode(:not_found) == 0x84
      assert Code.encode(:unsupported_content_format) == 0x8F
    end

    test "server error responses (5.xx)" do
      assert Code.encode(:internal_server_error) == 0xA0
      assert Code.encode(:service_unavailable) == 0xA3
    end
  end

  describe "encode/1 — tuple form for unregistered codes" do
    test "encodes {class, detail} via the bit-packing rule" do
      assert Code.encode({2, 5}) == 0x45
      assert Code.encode({4, 4}) == 0x84
      assert Code.encode({5, 0}) == 0xA0
    end
  end

  describe "decode/1" do
    test "round-trips every registered atom" do
      for atom <- [
            :empty,
            :get,
            :post,
            :put,
            :delete,
            :fetch,
            :patch,
            :ipatch,
            :created,
            :deleted,
            :valid,
            :changed,
            :content,
            :continue,
            :bad_request,
            :unauthorized,
            :bad_option,
            :forbidden,
            :not_found,
            :method_not_allowed,
            :not_acceptable,
            :request_entity_incomplete,
            :precondition_failed,
            :request_entity_too_large,
            :unsupported_content_format,
            :internal_server_error,
            :not_implemented,
            :bad_gateway,
            :service_unavailable,
            :gateway_timeout,
            :proxying_not_supported
          ] do
        assert Code.decode(Code.encode(atom)) == atom
      end
    end

    test "returns {class, detail} for unrecognised bytes" do
      # 4.25 is not registered
      assert Code.decode(0x99) == {4, 25}
      # 7.31 (max class, max detail)
      assert Code.decode(0xFF) == {7, 31}
    end
  end

  describe "class/1" do
    test "atoms" do
      assert Code.class(:get) == 0
      assert Code.class(:content) == 2
      assert Code.class(:not_found) == 4
      assert Code.class(:internal_server_error) == 5
    end

    test "raw byte" do
      assert Code.class(0x45) == 2
      assert Code.class(0xA0) == 5
    end

    test "{class, detail} tuple" do
      assert Code.class({4, 4}) == 4
    end

    test "{:method, name} convenience tuple" do
      assert Code.class({:method, :get}) == 0
    end

    test "{:response, class, detail} convenience tuple" do
      assert Code.class({:response, 2, 5}) == 2
    end
  end

  describe "method?/1, success?/1, error?/1" do
    test "method?/1 — true for 0.xx" do
      assert Code.method?(:get)
      assert Code.method?(:post)
      assert Code.method?(:fetch)
      refute Code.method?(:content)
      refute Code.method?(:empty)
    end

    test "success?/1 — true for 2.xx" do
      assert Code.success?(:content)
      assert Code.success?(:changed)
      refute Code.success?(:not_found)
      refute Code.success?(:get)
    end

    test "error?/1 — true for 4.xx and 5.xx" do
      assert Code.error?(:not_found)
      assert Code.error?(:internal_server_error)
      refute Code.error?(:content)
      refute Code.error?(:get)
    end
  end
end
