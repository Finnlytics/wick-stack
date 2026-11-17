namespace Wick.Coap.Tests.Codec;

public class BlockOptionTests
{
    [Fact]
    public void Sizes_cover_szx_0_to_6()
    {
        Assert.Equal([16, 32, 64, 128, 256, 512, 1024], Enumerable.Range(0, 7).Select(BlockOption.SizeOf));
        Assert.Throws<ArgumentOutOfRangeException>(() => BlockOption.SizeOf(7));
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(15, 1)]
    [InlineData(16, 2)]
    [InlineData(4095, 2)]
    [InlineData(4096, 3)]
    [InlineData(1_048_575, 3)]
    public void Values_round_trip_in_the_shortest_form(int number, int expectedLength)
    {
        foreach (bool more in new[] { true, false })
        {
            for (int szx = 0; szx <= 6; szx++)
            {
                var block = new BlockOption(number, more, szx);
                var encoded = block.Encode();
                if (number != 0 || more || szx != 0) Assert.Equal(expectedLength, encoded.Length);
                Assert.True(BlockOption.TryDecode(encoded, out var decoded));
                Assert.Equal(block, decoded);
            }
        }
    }

    [Fact]
    public void Encodes_the_rfc_7959_examples()
    {
        Assert.Equal("16", Convert.ToHexString(new BlockOption(1, false, 6).Encode()));
        Assert.Equal("010E", Convert.ToHexString(new BlockOption(16, true, 6).Encode()));
        Assert.Equal("010006", Convert.ToHexString(new BlockOption(4096, false, 6).Encode()));
        Assert.Empty(new BlockOption(0, false, 0).Encode());
    }

    [Fact]
    public void Decodes_special_values()
    {
        Assert.True(BlockOption.TryDecode([], out var empty));
        Assert.Equal(new BlockOption(0, false, 0), empty);
        Assert.True(BlockOption.TryDecode([0x0E], out var first));
        Assert.Equal(new BlockOption(0, true, 6), first);
        Assert.Equal(1024, first.Size);
    }

    [Fact]
    public void Rejects_szx_7_and_values_longer_than_three_bytes()
    {
        Assert.False(BlockOption.TryDecode([0x07], out _));
        Assert.False(BlockOption.TryDecode([0, 0, 0, 0], out _));
    }

    [Fact]
    public void Block_option_numbers_are_the_registered_ones()
    {
        Assert.Equal(27, CoapOptionNumber.Block1);
        Assert.Equal(23, CoapOptionNumber.Block2);
    }
}

public class BlockSenderTests
{
    private static byte[] Bytes(int count, byte fill = (byte)'x') => Enumerable.Repeat(fill, count).ToArray();

    [Fact]
    public void Payload_sizing()
    {
        Assert.Equal(1, new BlockSender(Bytes(2), 6).TotalBlocks);
        Assert.Equal(1024, new BlockSender(Bytes(2), 6).BlockSize);
        Assert.Equal(1, new BlockSender(Bytes(16), 0).TotalBlocks);
        Assert.Equal(2, new BlockSender(Bytes(17), 0).TotalBlocks);
        Assert.Equal(1, new BlockSender(Array.Empty<byte>(), 0).TotalBlocks);
        Assert.Equal(7, new BlockSender(Bytes(100), 0).TotalBlocks);
        Assert.Equal(6, new BlockSender(Bytes(2)).SizeExponent);
    }

    [Fact]
    public void First_block_of_a_multi_block_payload()
    {
        var (chunk, block) = new BlockSender(Bytes(32, (byte)'a'), 0).Current();
        Assert.Equal(Bytes(16, (byte)'a'), chunk.ToArray());
        Assert.Equal(new BlockOption(0, true, 0), block);
    }

    [Fact]
    public void Single_block_payload_has_more_false()
    {
        var (chunk, block) = new BlockSender("hello world"u8.ToArray(), 0).Current();
        Assert.Equal("hello world"u8.ToArray(), chunk.ToArray());
        Assert.False(block.More);
    }

    [Fact]
    public void Last_partial_block_returns_the_remaining_bytes()
    {
        var sender = new BlockSender(Bytes(20), 0);
        Assert.True(sender.Advance());
        var (chunk, block) = sender.Current();
        Assert.Equal(4, chunk.Length);
        Assert.Equal(new BlockOption(1, false, 0), block);
    }

    [Fact]
    public void Advance_walks_every_block_then_stops()
    {
        var sender = new BlockSender(Bytes(100), 0);
        int steps = 0;
        while (sender.Advance()) steps++;
        Assert.Equal(6, steps);
        Assert.Equal(6, sender.Number);
        Assert.False(sender.More);
    }

    [Fact]
    public void A_smaller_peer_size_renumbers_from_the_end_of_the_sent_block()
    {
        // RFC 7959 section 2.5, figure 4: 128-byte block 0 acknowledged as 0/1/32, next block is 4/1/32.
        var sender = new BlockSender(Bytes(300), 3);
        Assert.True(sender.AdvanceAfter(new BlockOption(0, true, 1)));
        Assert.Equal(1, sender.SizeExponent);
        Assert.Equal(4, sender.Number);
        Assert.Equal(128, sender.Current().Block.Offset);
    }
}

public class BlockReceiverTests
{
    private static byte[] Bytes(int count, byte fill) => Enumerable.Repeat(fill, count).ToArray();

    [Fact]
    public void A_single_block_transfer_completes_at_once()
    {
        var receiver = new BlockReceiver();
        Assert.Equal(BlockReceiveStatus.Complete, receiver.Add(new BlockOption(0, false, 0), "hello"u8));
        Assert.Equal("hello"u8.ToArray(), receiver.Body.ToArray());
    }

    [Fact]
    public void In_order_blocks_assemble()
    {
        var receiver = new BlockReceiver();
        Assert.Equal(BlockReceiveStatus.Continue, receiver.Add(new BlockOption(0, true, 0), Bytes(16, (byte)'a')));
        Assert.Equal(BlockReceiveStatus.Continue, receiver.Add(new BlockOption(1, true, 0), Bytes(16, (byte)'b')));
        Assert.Equal(BlockReceiveStatus.Complete, receiver.Add(new BlockOption(2, false, 0), "tail"u8));
        Assert.Equal([.. Bytes(16, (byte)'a'), .. Bytes(16, (byte)'b'), .. "tail"u8.ToArray()], receiver.Body.ToArray());
    }

    [Fact]
    public void Out_of_order_blocks_are_refused()
    {
        // The Elixir receiver tolerated this; RFC 7959 section 2.3 lets a server insist on order, and this one does.
        var receiver = new BlockReceiver();
        Assert.Equal(BlockReceiveStatus.OutOfOrder, receiver.Add(new BlockOption(2, false, 0), "tail"u8));
        Assert.False(receiver.IsComplete);
    }

    [Fact]
    public void A_repeated_block_is_a_duplicate()
    {
        var receiver = new BlockReceiver();
        receiver.Add(new BlockOption(0, true, 0), Bytes(16, 1));
        Assert.Equal(BlockReceiveStatus.Duplicate, receiver.Add(new BlockOption(0, true, 0), Bytes(16, 1)));
        Assert.Equal(16, receiver.Length);
    }

    [Fact]
    public void A_change_of_size_that_breaks_the_offset_is_refused()
    {
        var receiver = new BlockReceiver();
        receiver.Add(new BlockOption(0, true, 0), Bytes(16, (byte)'a'));
        Assert.Equal(BlockReceiveStatus.OutOfOrder, receiver.Add(new BlockOption(1, false, 6), "tail"u8));
    }

    [Fact]
    public void A_smaller_size_that_continues_at_the_right_offset_is_accepted()
    {
        var receiver = new BlockReceiver();
        receiver.Add(new BlockOption(0, true, 2), Bytes(64, (byte)'a'));
        Assert.Equal(BlockReceiveStatus.Complete, receiver.Add(new BlockOption(4, false, 0), "end"u8));
        Assert.Equal(67, receiver.Length);
    }

    [Fact]
    public void A_short_non_final_block_is_refused_but_a_short_final_one_is_fine()
    {
        Assert.Equal(BlockReceiveStatus.WrongSize, new BlockReceiver().Add(new BlockOption(0, true, 0), "short"u8));
        Assert.Equal(BlockReceiveStatus.Complete, new BlockReceiver().Add(new BlockOption(0, false, 0), "short"u8));
    }

    [Fact]
    public void The_body_is_capped()
    {
        var receiver = new BlockReceiver(maxBodySize: 40);
        receiver.Add(new BlockOption(0, true, 0), Bytes(16, 1));
        receiver.Add(new BlockOption(1, true, 0), Bytes(16, 1));
        Assert.Equal(BlockReceiveStatus.TooLarge, receiver.Add(new BlockOption(2, true, 0), Bytes(16, 1)));
    }
}

public class ObserveSequenceTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Next_wraps_at_two_to_the_24()
    {
        Assert.Equal(1u, ObserveSequence.Next(0));
        Assert.Equal(0u, ObserveSequence.Next(0xFFFFFF));
    }

    [Theory]
    [InlineData(5u, 3u, true)]
    [InlineData(3u, 5u, false)]
    [InlineData(5u, 5u, false)]
    [InlineData(0u, 0xFFFFFFu, true)]          // wrap-around
    [InlineData(0xFFFFFFu, 0u, false)]
    [InlineData(0x800001u, 1u, false)]        // more than 2^23 ahead counts as older
    [InlineData(0x7FFFFFu, 1u, true)]
    public void Newer_follows_rfc_7641_section_3_4(uint arrived, uint last, bool newer) =>
        Assert.Equal(newer, ObserveSequence.IsNewer(arrived, last));

    [Fact]
    public void Anything_is_newer_than_nothing() => Assert.True(ObserveSequence.IsNewer(7, null));

    [Fact]
    public void After_128_seconds_any_value_is_newer()
    {
        Assert.False(ObserveSequence.IsNewer(3, T0 + TimeSpan.FromSeconds(100), 5, T0));
        Assert.True(ObserveSequence.IsNewer(3, T0 + TimeSpan.FromSeconds(129), 5, T0));
    }
}

public class RetransmissionTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly CoapTransmissionParameters Fixed = new() { AckTimeout = TimeSpan.FromSeconds(1), AckRandomFactor = 1.0 };

    [Fact]
    public void Starts_with_one_transmission_and_the_deadline_ahead()
    {
        var state = new RetransmissionState(Fixed, T0, new Random(1));
        Assert.Equal(1, state.Transmissions);
        Assert.Equal(T0 + TimeSpan.FromSeconds(1), state.NextDeadline);
    }

    [Fact]
    public void The_initial_timeout_is_randomised_within_the_factor()
    {
        var random = new Random(42);
        var parameters = Fixed with { AckRandomFactor = 2.0 };
        for (int i = 0; i < 50; i++)
        {
            var interval = new RetransmissionState(parameters, T0, random).Interval;
            Assert.InRange(interval, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2));
        }
    }

    [Fact]
    public void Waits_before_the_deadline()
    {
        var state = new RetransmissionState(Fixed, T0, new Random(1));
        Assert.Equal(RetransmissionAction.Wait, state.Next(T0 + TimeSpan.FromMilliseconds(500)));
    }

    [Fact]
    public void Doubles_the_interval_on_each_retransmission()
    {
        var state = new RetransmissionState(Fixed, T0, new Random(1));
        Assert.Equal(RetransmissionAction.Retransmit, state.Next(T0 + TimeSpan.FromSeconds(1)));
        Assert.Equal(2, state.Transmissions);
        Assert.Equal(TimeSpan.FromSeconds(2), state.Interval);
        Assert.Equal(T0 + TimeSpan.FromSeconds(3), state.NextDeadline);
        Assert.Equal(RetransmissionAction.Retransmit, state.Next(T0 + TimeSpan.FromSeconds(3)));
        Assert.Equal(TimeSpan.FromSeconds(4), state.Interval);
    }

    [Fact]
    public void Max_retransmit_4_gives_five_transmissions_then_gives_up()
    {
        var state = new RetransmissionState(Fixed, T0, new Random(1));
        for (int i = 0; i < 4; i++) Assert.Equal(RetransmissionAction.Retransmit, state.Next(state.NextDeadline));
        Assert.Equal(5, state.Transmissions);
        Assert.Equal(RetransmissionAction.GiveUp, state.Next(state.NextDeadline));
    }

    [Fact]
    public void Derived_times_match_rfc_7252_section_4_8_2()
    {
        var defaults = new CoapTransmissionParameters();
        Assert.Equal(TimeSpan.FromSeconds(45), defaults.MaxTransmitSpan);
        Assert.Equal(TimeSpan.FromSeconds(93), defaults.MaxTransmitWait);
        Assert.Equal(TimeSpan.FromSeconds(202), defaults.MaxRtt);
        Assert.Equal(TimeSpan.FromSeconds(247), defaults.ExchangeLifetime);
        Assert.Equal(TimeSpan.FromSeconds(145), defaults.NonLifetime);
    }
}

public class DeduplicatorTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void First_sighting_is_new_and_the_second_a_duplicate()
    {
        var dedup = new Deduplicator<int>(TimeSpan.FromSeconds(10));
        Assert.Equal(DeduplicationResult.New, dedup.Check(1234, T0, out _));
        Assert.Equal(DeduplicationResult.Duplicate, dedup.Check(1234, T0 + TimeSpan.FromSeconds(5), out _));
    }

    [Fact]
    public void Entries_expire_after_the_lifetime()
    {
        var dedup = new Deduplicator<int>(TimeSpan.FromSeconds(1));
        dedup.Check(1234, T0, out _);
        Assert.Equal(DeduplicationResult.New, dedup.Check(1234, T0 + TimeSpan.FromSeconds(2), out _));
    }

    [Fact]
    public void Different_ids_do_not_collide()
    {
        var dedup = new Deduplicator<int>(TimeSpan.FromSeconds(10));
        dedup.Check(1, T0, out _);
        Assert.Equal(DeduplicationResult.New, dedup.Check(2, T0, out _));
        Assert.Equal(2, dedup.Count);
    }

    [Fact]
    public void A_sweep_shrinks_the_window()
    {
        var dedup = new Deduplicator<int>(TimeSpan.FromSeconds(1));
        dedup.Check(1, T0, out _);
        dedup.Check(2, T0, out _);
        dedup.Check(3, T0 + TimeSpan.FromSeconds(5), out _);
        Assert.Equal(1, dedup.Count);
    }

    [Fact]
    public void The_cached_reply_comes_back_on_a_duplicate()
    {
        var dedup = new Deduplicator<int>(TimeSpan.FromSeconds(10));
        dedup.Check(7, T0, out _);
        Assert.True(dedup.SetReply(7, [1, 2, 3]));
        dedup.Check(7, T0, out var reply);
        Assert.Equal(new byte[] { 1, 2, 3 }, reply);
    }

    [Fact]
    public void Capacity_drops_the_oldest_entry()
    {
        var dedup = new Deduplicator<int>(TimeSpan.FromMinutes(10), capacity: 3);
        for (int i = 0; i < 5; i++) dedup.Check(i, T0 + TimeSpan.FromSeconds(i), out _);
        Assert.Equal(3, dedup.Count);
        Assert.False(dedup.Contains(0));
        Assert.False(dedup.Contains(1));
        Assert.True(dedup.Contains(4));
    }
}

public class MessageIdAndTokenTests
{
    [Fact]
    public void Ids_advance_and_wrap()
    {
        var ids = new MessageIdAllocator(0xFFFE);
        Assert.Equal(0xFFFE, ids.Next());
        Assert.Equal(0xFFFF, ids.Next());
        Assert.Equal(0, ids.Next());
        Assert.Equal(1, ids.Next());
    }

    [Fact]
    public void Tokens_have_the_requested_length()
    {
        Assert.Equal(8, TokenGenerator.Create().Length);
        Assert.Equal(2, TokenGenerator.Create(2).Length);
        Assert.Empty(TokenGenerator.Create(0));
        Assert.Throws<ArgumentOutOfRangeException>(() => TokenGenerator.Create(9));
    }
}
