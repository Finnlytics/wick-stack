namespace Wick.Coap.Tests.Codec;

public class OptionTests
{
    private static string EncodeOptions(params CoapOption[] options)
    {
        var message = new CoapMessage { Type = CoapMessageType.Confirmable, Code = CoapCode.Get };
        message.Options.AddRange(options);
        return Convert.ToHexString(message.Encode().AsSpan(4));
    }

    private static List<CoapOption> DecodeOptions(string hex) =>
        CoapMessage.Decode(Convert.FromHexString("40010000" + hex)).Options;

    [Fact]
    public void Unsigned_zero_encodes_as_an_empty_value()
    {
        var option = CoapOption.FromUInt(14, 0);
        Assert.Equal(0, option.Length);
        Assert.Equal(0u, option.GetUInt());
    }

    [Theory]
    [InlineData(1u, "01")]
    [InlineData(255u, "FF")]
    [InlineData(256u, "0100")]
    [InlineData(65535u, "FFFF")]
    [InlineData(65536u, "010000")]
    [InlineData(0xFFFFFFFFu, "FFFFFFFF")]
    public void Unsigned_values_use_the_fewest_bytes(uint value, string hex)
    {
        Assert.Equal(hex, Convert.ToHexString(CoapOption.FromUInt(0, value).Value.Span));
    }

    [Theory]
    [InlineData(1u)]
    [InlineData(12u)]
    [InlineData(13u)]
    [InlineData(269u)]
    [InlineData(65536u)]
    [InlineData(1_000_000u)]
    public void Unsigned_values_round_trip(uint value) => Assert.Equal(value, CoapOption.FromUInt(0, value).GetUInt());

    [Fact]
    public void Single_options_encode_with_delta_and_length_nibbles()
    {
        Assert.Equal("B27264", EncodeOptions(CoapOption.FromString(11, "rd")));
        Assert.Equal("C170", EncodeOptions(CoapOption.FromUInt(12, 112)));
        Assert.Equal("50", EncodeOptions(new CoapOption(5)));
    }

    [Fact]
    public void Deltas_are_taken_from_the_previous_option()
    {
        Assert.Equal("34686F7374827264", EncodeOptions(CoapOption.FromString(3, "host"), CoapOption.FromString(11, "rd")));
        Assert.Equal("B13301300139", EncodeOptions(CoapOption.FromString(11, "3"), CoapOption.FromString(11, "0"), CoapOption.FromString(11, "9")));
        Assert.Equal("34686F7374827264", EncodeOptions(CoapOption.FromString(11, "rd"), CoapOption.FromString(3, "host")));
    }

    [Fact]
    public void Extended_deltas_and_lengths_use_extension_bytes()
    {
        Assert.Equal("D10078", EncodeOptions(CoapOption.FromString(13, "x")));
        Assert.Equal("E1000178", EncodeOptions(CoapOption.FromString(270, "x")));
        var fifty = new string('x', 50);
        Assert.Equal("0D25" + Convert.ToHexString(System.Text.Encoding.ASCII.GetBytes(fifty)), EncodeOptions(CoapOption.FromString(0, fifty)));
        var long300 = new byte[300];
        Assert.StartsWith("0E001F", EncodeOptions(new CoapOption(0, long300)));
    }

    [Fact]
    public void The_largest_delta_and_length_round_trip()
    {
        var value = new byte[1034];
        var options = DecodeOptions(EncodeOptions(new CoapOption(65000, value)));
        Assert.Single(options);
        Assert.Equal(65000, options[0].Number);
        Assert.Equal(1034, options[0].Length);
    }

    [Fact]
    public void Typical_option_sets_round_trip()
    {
        CoapOption[][] cases =
        [
            [CoapOption.FromString(11, "rd")],
            [CoapOption.FromUInt(12, 112)],
            [CoapOption.FromString(3, "host"), CoapOption.FromString(11, "rd")],
            [CoapOption.FromString(11, "3"), CoapOption.FromString(11, "0"), CoapOption.FromString(11, "9")],
            [CoapOption.FromUInt(6, 0), CoapOption.FromString(11, "rd")],
            [CoapOption.FromString(13, "x")],
            [CoapOption.FromString(270, "x")],
            [CoapOption.FromString(11, new string('p', 50))],
        ];
        foreach (var options in cases)
            Assert.Equal(options.OrderBy(o => o.Number), DecodeOptions(EncodeOptions(options)));
    }

    [Fact]
    public void The_payload_marker_ends_the_options()
    {
        var message = CoapMessage.Decode(Convert.FromHexString("40010000B27264FF010203"));
        Assert.Equal(["rd"], message.UriPath);
        Assert.Equal(new byte[] { 1, 2, 3 }, message.Payload.ToArray());
    }

    [Theory]
    [InlineData("0B")]       // length 11, no value bytes
    [InlineData("B272")]     // length 2, one byte present
    [InlineData("D0")]       // missing one-byte delta extension
    [InlineData("E000")]     // missing second byte of a two-byte extension
    public void Truncated_options_are_rejected(string hex)
    {
        Assert.False(CoapMessageCodec.TryDecode(Convert.FromHexString("40010000" + hex), out _, out var error));
        Assert.Equal(CoapDecodeError.TruncatedOption, error);
    }

    [Fact]
    public void Option_classes_follow_the_number()
    {
        Assert.True(CoapOptionNumber.IsCritical(CoapOptionNumber.UriPath));
        Assert.False(CoapOptionNumber.IsCritical(CoapOptionNumber.ContentFormat));
        Assert.True(CoapOptionNumber.IsUnsafe(CoapOptionNumber.UriPath));
        Assert.False(CoapOptionNumber.IsUnsafe(CoapOptionNumber.ETag));
    }
}

public class CodeTests
{
    [Theory]
    [InlineData(0x00, "0.00")]
    [InlineData(0x01, "0.01")]
    [InlineData(0x05, "0.05")]
    [InlineData(0x45, "2.05")]
    [InlineData(0x5F, "2.31")]
    [InlineData(0x84, "4.04")]
    [InlineData(0x8F, "4.15")]
    [InlineData(0xA0, "5.00")]
    [InlineData(0xFF, "7.31")]
    public void Codes_format_as_class_dot_detail(byte value, string text) => Assert.Equal(text, new CoapCode(value).ToString());

    [Fact]
    public void Registered_codes_have_the_rfc_values()
    {
        Assert.Equal(0x01, CoapCode.Get.Value);
        Assert.Equal(0x02, CoapCode.Post.Value);
        Assert.Equal(0x03, CoapCode.Put.Value);
        Assert.Equal(0x04, CoapCode.Delete.Value);
        Assert.Equal(0x05, CoapCode.Fetch.Value);
        Assert.Equal(0x06, CoapCode.Patch.Value);
        Assert.Equal(0x07, CoapCode.IPatch.Value);
        Assert.Equal(0x41, CoapCode.Created.Value);
        Assert.Equal(0x42, CoapCode.Deleted.Value);
        Assert.Equal(0x43, CoapCode.Valid.Value);
        Assert.Equal(0x44, CoapCode.Changed.Value);
        Assert.Equal(0x45, CoapCode.Content.Value);
        Assert.Equal(0x5F, CoapCode.Continue.Value);
        Assert.Equal(0x80, CoapCode.BadRequest.Value);
        Assert.Equal(0x82, CoapCode.BadOption.Value);
        Assert.Equal(0x84, CoapCode.NotFound.Value);
        Assert.Equal(0x88, CoapCode.RequestEntityIncomplete.Value);
        Assert.Equal(0x8D, CoapCode.RequestEntityTooLarge.Value);
        Assert.Equal(0x8F, CoapCode.UnsupportedContentFormat.Value);
        Assert.Equal(0xA0, CoapCode.InternalServerError.Value);
        Assert.Equal(0xA3, CoapCode.ServiceUnavailable.Value);
        Assert.Equal(0xA5, CoapCode.ProxyingNotSupported.Value);
    }

    [Fact]
    public void Class_and_detail_construct_the_byte()
    {
        Assert.Equal(CoapCode.Content, new CoapCode(2, 5));
        Assert.Equal(CoapCode.NotFound, new CoapCode(4, 4));
        Assert.Equal(CoapCode.InternalServerError, new CoapCode(5, 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => new CoapCode(8, 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => new CoapCode(2, 32));
    }

    [Fact]
    public void Predicates_classify_codes()
    {
        Assert.True(CoapCode.Get.IsRequest);
        Assert.True(CoapCode.Fetch.IsRequest);
        Assert.False(CoapCode.Empty.IsRequest);
        Assert.False(CoapCode.Content.IsRequest);
        Assert.True(CoapCode.Content.IsSuccess);
        Assert.True(CoapCode.Changed.IsSuccess);
        Assert.False(CoapCode.NotFound.IsSuccess);
        Assert.True(CoapCode.NotFound.IsError);
        Assert.True(CoapCode.InternalServerError.IsError);
        Assert.False(CoapCode.Content.IsError);
        Assert.True(new CoapCode(1, 0).IsReserved);
        Assert.True(new CoapCode(6, 0).IsReserved);
        Assert.True(new CoapCode(7, 31).IsReserved);
        Assert.False(CoapCode.Content.IsReserved);
    }
}
