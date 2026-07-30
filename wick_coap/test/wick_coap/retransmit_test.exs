defmodule WickCoap.RetransmitTest do
  use ExUnit.Case, async: true

  alias WickCoap.Retransmit

  doctest Retransmit

  describe "new/1" do
    test "starts at attempt 1 with the next deadline ahead of `now`" do
      r = Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0)
      assert r.attempts == 1
      assert r.next_at >= 1000
    end

    test "respects ack_random_factor jitter" do
      # With factor 2.0, initial interval is in [1000, 2000)
      for _ <- 1..30 do
        r = Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 2.0)
        assert r.interval >= 1000
        assert r.interval <= 2000
      end
    end
  end

  describe "next_step/2 — :wait branch" do
    test "before the deadline, no action" do
      r = Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0)
      assert :wait = Retransmit.next_step(r, 500)
    end
  end

  describe "next_step/2 — :retransmit branch" do
    test "doubles the interval on each retransmit" do
      r = Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0)
      assert {:retransmit, r2} = Retransmit.next_step(r, 1000)
      assert r2.attempts == 2
      assert r2.interval == 2000
      assert r2.next_at == 1000 + 2000

      assert {:retransmit, r3} = Retransmit.next_step(r2, 3000)
      assert r3.attempts == 3
      assert r3.interval == 4000
    end
  end

  describe "next_step/2 — :expire branch" do
    test "after MAX_RETRANSMIT, expires" do
      r = Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0, max_retransmit: 1)

      # First retransmit OK
      assert {:retransmit, r} = Retransmit.next_step(r, 1000)
      assert r.attempts == 2

      # Second time the deadline is reached, we've used our one retransmit; expire
      assert {:expire, _} = Retransmit.next_step(r, 100_000)
    end

    test "MAX_RETRANSMIT=4 (RFC default) gives 5 total transmits before expiring" do
      r = Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0)

      # Attempt 1 = initial send (when struct is built). Then 4 retransmits.
      r =
        Enum.reduce(1..4, r, fn _, r ->
          {:retransmit, r} = Retransmit.next_step(r, r.next_at)
          r
        end)

      assert r.attempts == 5
      assert {:expire, _} = Retransmit.next_step(r, r.next_at)
    end
  end
end
