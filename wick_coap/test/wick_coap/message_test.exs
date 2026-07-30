defmodule WickCoap.MessageTest do
  use ExUnit.Case, async: true

  alias WickCoap.Error
  alias WickCoap.Message
  alias WickCoap.Option

  doctest Message

  describe "encode/1 — full request with single Uri-Path" do
    # Builds the message used in the moduledoc example: CON GET with token CAFE,
    # MID 0x1234, Uri-Path "rd". This is a CoAP-spec textbook case (RFC 7252 §A.1).
    test "produces the expected wire bytes" do
      msg = %Message{
        type: :con,
        code: :get,
        message_id: 0x1234,
        token: <<0xCA, 0xFE>>,
        options: [Option.new(11, "rd")]
      }

      assert {:ok, bytes} = Message.encode(msg)
      assert Base.encode16(bytes) == "42011234CAFEB27264"
    end
  end

  describe "encode/1 — response with payload" do
    test "produces the expected wire bytes for ACK 2.05 Content + payload" do
      msg = %Message{
        type: :ack,
        code: :content,
        message_id: 0x1234,
        token: <<0xCA, 0xFE>>,
        options: [Option.from_uint(12, 112)],
        payload: <<0x01, 0x02, 0x03>>
      }

      assert {:ok, bytes} = Message.encode(msg)
      # 62 (ACK + TKL=2) | 45 (2.05) | 1234 (MID) | CAFE (token) |
      # C1 (delta=12, len=1) | 70 (112) | FF (payload marker) | 01 02 03 (payload)
      assert Base.encode16(bytes) == "62451234CAFEC170FF010203"
    end
  end

  describe "encode/1 — empty token" do
    test "TKL nibble is 0 and no token bytes are emitted" do
      msg = %Message{type: :non, code: :empty, message_id: 0x0001}
      assert {:ok, <<0x50, 0x00, 0x00, 0x01>>} = Message.encode(msg)
    end
  end

  describe "encode/1 — error paths" do
    test "rejects tokens longer than 8 bytes" do
      msg = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<0::72>>
      }

      assert {:error, %Error{code: :invalid_token, meta: %{length: 9}}} = Message.encode(msg)
    end
  end

  describe "decode/1 — happy paths" do
    test "decodes the textbook GET /rd example" do
      bytes = <<0x42, 0x01, 0x12, 0x34, 0xCA, 0xFE, 0xB2, ?r, ?d>>
      assert {:ok, msg, <<>>} = Message.decode(bytes)

      assert msg.type == :con
      assert msg.code == :get
      assert msg.message_id == 0x1234
      assert msg.token == <<0xCA, 0xFE>>
      assert msg.options == [%Option{number: 11, value: "rd"}]
      assert msg.payload == <<>>
    end

    test "decodes a response that carries options + payload" do
      bytes = <<0x62, 0x45, 0x12, 0x34, 0xCA, 0xFE, 0xC1, 112, 0xFF, 1, 2, 3>>
      assert {:ok, msg, <<>>} = Message.decode(bytes)

      assert msg.type == :ack
      assert msg.code == :content
      assert msg.options == [%Option{number: 12, value: <<112>>}]
      assert msg.payload == <<1, 2, 3>>
    end

    test "decodes a 4-byte empty header" do
      bytes = <<0x40, 0x00, 0x00, 0x07>>
      assert {:ok, msg, <<>>} = Message.decode(bytes)

      assert msg.type == :con
      assert msg.code == :empty
      assert msg.message_id == 7
      assert msg.token == <<>>
      assert msg.options == []
      assert msg.payload == <<>>
    end

    test "decodes unrecognised codes as {class, detail} tuples" do
      # 4.25 (= 0x99) isn't a registered CoAP code
      bytes = <<0x40, 0x99, 0x00, 0x01>>
      assert {:ok, msg, <<>>} = Message.decode(bytes)
      assert msg.code == {4, 25}
    end
  end

  describe "encode/decode round-trip" do
    test "every well-formed message round-trips identically" do
      cases = [
        # CON GET /rd
        %Message{
          type: :con,
          code: :get,
          message_id: 0x1234,
          token: <<0xCA, 0xFE>>,
          options: [Option.new(11, "rd")]
        },
        # ACK 2.05 Content with payload
        %Message{
          type: :ack,
          code: :content,
          message_id: 0x0042,
          token: <<>>,
          options: [Option.from_uint(12, 112)],
          payload: <<0xDE, 0xAD, 0xBE, 0xEF>>
        },
        # NON DELETE /3/0/9
        %Message{
          type: :non,
          code: :delete,
          message_id: 0xFFFF,
          token: <<1, 2, 3, 4, 5, 6, 7, 8>>,
          options: [
            Option.new(11, "3"),
            Option.new(11, "0"),
            Option.new(11, "9")
          ]
        },
        # RST empty
        %Message{type: :rst, code: :empty, message_id: 0x0001},
        # CON FETCH with Block2 — options sorted because round-trip canonicalises order
        %Message{
          type: :con,
          code: :fetch,
          message_id: 0x0500,
          token: <<0xAB>>,
          options: [Option.from_uint(12, 112), Option.from_uint(23, 0x14)]
        }
      ]

      for msg <- cases do
        assert {:ok, bytes} = Message.encode(msg)
        assert {:ok, ^msg, <<>>} = Message.decode(bytes)
      end
    end

    test "encoding canonicalises option order — out-of-order in produces sorted out" do
      msg = %Message{
        type: :con,
        code: :get,
        message_id: 0x0001,
        options: [Option.new(11, "z"), Option.new(3, "a")]
      }

      assert {:ok, bytes} = Message.encode(msg)
      assert {:ok, decoded, <<>>} = Message.decode(bytes)
      assert Enum.map(decoded.options, & &1.number) == [3, 11]
    end
  end

  describe "decode/1 — error paths" do
    test "rejects empty input" do
      assert {:error, %Error{code: :malformed_message}} = Message.decode(<<>>)
    end

    test "rejects truncated header (< 4 bytes)" do
      assert {:error, %Error{code: :malformed_message}} = Message.decode(<<0x40>>)
      assert {:error, %Error{code: :malformed_message}} = Message.decode(<<0x40, 0x00>>)
    end

    test "rejects unsupported version" do
      # Top 2 bits = 00 (v0) or 10 (v2) or 11 (v3)
      assert {:error, %Error{code: :malformed_message, meta: %{version: 0}}} =
               Message.decode(<<0x00, 0x00, 0x00, 0x00>>)

      assert {:error, %Error{code: :malformed_message, meta: %{version: 2}}} =
               Message.decode(<<0x80, 0x00, 0x00, 0x00>>)
    end

    test "rejects reserved TKL values 9..15" do
      # TKL=9: 0100_1001 = 0x49
      assert {:error, %Error{code: :malformed_message, meta: %{tkl: 9}}} =
               Message.decode(<<0x49, 0x00, 0x00, 0x00>>)

      # TKL=15: 0100_1111 = 0x4F
      assert {:error, %Error{code: :malformed_message, meta: %{tkl: 15}}} =
               Message.decode(<<0x4F, 0x00, 0x00, 0x00>>)
    end

    test "rejects truncated token field" do
      # Header says TKL=4 but only 2 bytes follow
      assert {:error, %Error{code: :malformed_message, meta: %{tkl: 4}}} =
               Message.decode(<<0x44, 0x00, 0x00, 0x00, 0xAA, 0xBB>>)
    end

    test "propagates malformed-option errors" do
      # CON GET, no token, then a single 0x0F byte (option with length nibble 15 → reserved)
      assert {:error, %Error{code: :malformed_option}} =
               Message.decode(<<0x40, 0x01, 0x00, 0x00, 0x0F>>)
    end
  end
end
