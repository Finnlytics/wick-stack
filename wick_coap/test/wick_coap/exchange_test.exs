defmodule WickCoap.ExchangeTest do
  use ExUnit.Case, async: true

  alias WickCoap.Exchange
  alias WickCoap.Message
  alias WickCoap.Option

  defp con_request(token \\ <<1, 2>>) do
    %Message{
      type: :con,
      code: :get,
      message_id: 0x1234,
      token: token,
      options: [Option.new(11, "rd")]
    }
  end

  defp non_request do
    %Message{type: :non, code: :post, message_id: 0x0001, token: <<>>}
  end

  describe "start_outbound/1" do
    test "CON message gets a Retransmit state" do
      ex = Exchange.start_outbound(peer: :peer1, message: con_request(), now: 0)

      assert ex.role == :outbound
      assert ex.peer == :peer1
      assert ex.state == :pending
      assert ex.retransmit
      assert ex.retransmit.attempts == 1
    end

    test "NON message has no Retransmit state" do
      ex = Exchange.start_outbound(peer: :peer1, message: non_request(), now: 0)

      assert ex.retransmit == nil
    end

    test "key/1 is {peer, token}" do
      ex = Exchange.start_outbound(peer: :peer1, message: con_request(<<0xAB>>), now: 0)
      assert Exchange.key(ex) == {:peer1, <<0xAB>>}
    end
  end

  describe "start_inbound/2" do
    test "marks the role as :inbound" do
      ex = Exchange.start_inbound(:peer1, con_request())
      assert ex.role == :inbound
      assert ex.state == :pending
    end
  end

  describe "match_response/2" do
    test "matching tokens completes the exchange" do
      ex = Exchange.start_outbound(peer: :peer1, message: con_request(), now: 0)

      response = %Message{
        type: :ack,
        code: :content,
        message_id: 0x1234,
        token: <<1, 2>>
      }

      assert {:matched, ex} = Exchange.match_response(ex, response)
      assert ex.state == :completed
      assert ex.response == response
    end

    test "mismatched tokens do not complete the exchange" do
      ex = Exchange.start_outbound(peer: :peer1, message: con_request(<<1, 2>>), now: 0)

      wrong_response = %Message{
        type: :ack,
        code: :content,
        message_id: 0x9999,
        token: <<9, 9>>
      }

      assert {:no_match, ex} = Exchange.match_response(ex, wrong_response)
      assert ex.state == :pending
      assert ex.response == nil
    end
  end

  describe "ack/1" do
    test "moves CON to :acked and stops retransmission" do
      ex = Exchange.start_outbound(peer: :peer1, message: con_request(), now: 0)
      ex = Exchange.ack(ex)

      assert ex.state == :acked
      assert ex.retransmit == nil
    end
  end

  describe "expire/1 + lifecycle predicates" do
    test "pending? and finished? track state" do
      ex = Exchange.start_outbound(peer: :peer1, message: con_request(), now: 0)
      assert Exchange.pending?(ex)
      refute Exchange.finished?(ex)

      ex = Exchange.expire(ex)
      refute Exchange.pending?(ex)
      assert Exchange.finished?(ex)
      assert ex.state == :expired
    end
  end
end
