namespace Wick.Coap.Tests.Codec;

public class MessageCodecTests
{
    private static CoapMessage Decode(string hex) => CoapMessage.Decode(Convert.FromHexString(hex));

    private static CoapDecodeError ErrorOf(params byte[] bytes)
    {
        Assert.False(CoapMessageCodec.TryDecode(bytes, out _, out var error));
        return error;
    }

    [Fact]
    public void Encodes_a_confirmable_get_with_one_uri_path()
    {
        var message = new CoapMessage { Type = CoapMessageType.Confirmable, Code = CoapCode.Get, MessageId = 0x1234, Token = [0xCA, 0xFE] };
        message.AddOption(CoapOption.FromString(CoapOptionNumber.UriPath, "rd"));
        Assert.Equal("42011234CAFEB27264", Convert.ToHexString(message.Encode()));
    }

    [Fact]
    public void Encodes_a_piggybacked_content_response_with_payload()
    {
        var message = new CoapMessage { Type = CoapMessageType.Acknowledgement, Code = CoapCode.Content, MessageId = 0x1234, Token = [0xCA, 0xFE], Payload = new byte[] { 1, 2, 3 } };
        message.AddOption(CoapOption.FromUInt(CoapOptionNumber.ContentFormat, 112));
        Assert.Equal("62451234CAFEC170FF010203", Convert.ToHexString(message.Encode()));
    }

    [Fact]
    public void Encodes_an_empty_token_as_tkl_zero()
    {
        var message = new CoapMessage { Type = CoapMessageType.NonConfirmable, Code = CoapCode.Empty, MessageId = 1 };
        Assert.Equal("50000001", Convert.ToHexString(message.Encode()));
    }

    [Fact]
    public void Rejects_tokens_longer_than_eight_bytes()
    {
        var message = new CoapMessage();
        Assert.Throws<ArgumentException>(() => message.Token = new byte[9]);
    }

    // RFC 7252 appendix A, figure 16: a basic GET and its piggybacked response.
    [Fact]
    public void Round_trips_the_rfc_7252_appendix_a_get_example()
    {
        var request = CoapMessage.CreateRequest(CoapCode.Get, "/temperature");
        request.MessageId = 0x7d34;
        Assert.Equal("40017D34BB74656D7065726174757265", Convert.ToHexString(request.Encode()));

        var response = Decode("60457D34FF32322E332043");
        Assert.Equal(CoapMessageType.Acknowledgement, response.Type);
        Assert.Equal(CoapCode.Content, response.Code);
        Assert.Equal(0x7d34, response.MessageId);
        Assert.Equal("22.3 C", response.PayloadAsString());
    }

    [Fact]
    public void Decodes_the_textbook_get()
    {
        var message = Decode("42011234CAFEB27264");
        Assert.Equal(CoapMessageType.Confirmable, message.Type);
        Assert.Equal(CoapCode.Get, message.Code);
        Assert.Equal(0x1234, message.MessageId);
        Assert.Equal(new byte[] { 0xCA, 0xFE }, message.Token);
        Assert.Equal([new CoapOption(11, "rd"u8.ToArray())], message.Options);
        Assert.True(message.Payload.IsEmpty);
    }

    [Fact]
    public void Decodes_options_and_payload()
    {
        var message = Decode("62451234CAFEC170FF010203");
        Assert.Equal(CoapMessageType.Acknowledgement, message.Type);
        Assert.Equal(CoapCode.Content, message.Code);
        Assert.Equal(112, message.ContentFormat);
        Assert.Equal(new byte[] { 1, 2, 3 }, message.Payload.ToArray());
    }

    [Fact]
    public void Decodes_a_four_byte_empty_message()
    {
        var message = Decode("40000007");
        Assert.Equal(CoapMessageType.Confirmable, message.Type);
        Assert.True(message.IsEmpty);
        Assert.Equal(7, message.MessageId);
        Assert.Empty(message.Token);
        Assert.Empty(message.Options);
    }

    [Fact]
    public void Decodes_unregistered_codes_as_class_and_detail()
    {
        var message = Decode("40990001");
        Assert.Equal(4, message.Code.Class);
        Assert.Equal(25, message.Code.Detail);
    }

    public static TheoryData<string> RoundTripCases => new()
    {
        "42011234CAFEB27264",
        "40450042C170FFDEADBEEF",
        "5804FFFF0102030405060708B13301300139",
        "70000001",
        "4105050 0ABC170D1 0A14".Replace(" ", ""),
    };

    [Theory]
    [MemberData(nameof(RoundTripCases))]
    public void Every_well_formed_message_round_trips(string hex)
    {
        var bytes = Convert.FromHexString(hex);
        Assert.Equal(hex, Convert.ToHexString(CoapMessage.Decode(bytes).Encode()));
    }

    [Fact]
    public void Encoding_sorts_options_and_keeps_repeated_ones_in_order()
    {
        var message = new CoapMessage { Code = CoapCode.Get, MessageId = 1 };
        message.AddOption(CoapOption.FromString(CoapOptionNumber.UriPath, "z"));
        message.AddOption(CoapOption.FromString(CoapOptionNumber.UriHost, "a"));
        message.AddOption(CoapOption.FromString(CoapOptionNumber.UriPath, "y"));
        var decoded = CoapMessage.Decode(message.Encode());
        Assert.Equal([3, 11, 11], decoded.Options.Select(o => o.Number));
        Assert.Equal(["z", "y"], decoded.UriPath);
    }

    [Fact]
    public void Rejects_empty_input_and_a_truncated_header()
    {
        Assert.Equal(CoapDecodeError.TruncatedHeader, ErrorOf());
        Assert.Equal(CoapDecodeError.TruncatedHeader, ErrorOf(0x40));
        Assert.Equal(CoapDecodeError.TruncatedHeader, ErrorOf(0x40, 0x00));
    }

    [Fact]
    public void Rejects_unsupported_versions()
    {
        Assert.Equal(CoapDecodeError.UnsupportedVersion, ErrorOf(0x00, 0x00, 0x00, 0x00));
        Assert.Equal(CoapDecodeError.UnsupportedVersion, ErrorOf(0x80, 0x00, 0x00, 0x00));
    }

    [Fact]
    public void Rejects_reserved_token_lengths()
    {
        Assert.Equal(CoapDecodeError.ReservedTokenLength, ErrorOf(0x49, 0x01, 0x00, 0x00));
        Assert.Equal(CoapDecodeError.ReservedTokenLength, ErrorOf(0x4F, 0x01, 0x00, 0x00));
    }

    [Fact]
    public void Rejects_a_truncated_token()
    {
        Assert.Equal(CoapDecodeError.TruncatedToken, ErrorOf(0x44, 0x01, 0x00, 0x00, 0xAA, 0xBB));
    }

    [Fact]
    public void Rejects_a_reserved_option_nibble()
    {
        Assert.Equal(CoapDecodeError.ReservedOptionNibble, ErrorOf(0x40, 0x01, 0x00, 0x00, 0x0F));
        Assert.Equal(CoapDecodeError.ReservedOptionNibble, ErrorOf(0x40, 0x01, 0x00, 0x00, 0xF0));
    }

    [Fact]
    public void Rejects_a_payload_marker_without_payload()
    {
        Assert.Equal(CoapDecodeError.EmptyPayloadAfterMarker, ErrorOf(0x40, 0x01, 0x00, 0x00, 0xFF));
    }

    [Fact]
    public void Rejects_an_empty_message_with_a_token_or_trailing_bytes()
    {
        Assert.Equal(CoapDecodeError.MalformedEmptyMessage, ErrorOf(0x41, 0x00, 0x00, 0x00, 0x01));
        Assert.Equal(CoapDecodeError.MalformedEmptyMessage, ErrorOf(0x40, 0x00, 0x00, 0x00, 0xFF, 0x01));
    }

    [Fact]
    public void Rejects_an_option_number_beyond_65535()
    {
        // Two options with a 2-byte delta extension of 0xFFFF each: 65804 + 65804.
        Assert.Equal(CoapDecodeError.OptionNumberOutOfRange, ErrorOf(0x40, 0x01, 0x00, 0x00, 0xE0, 0xFF, 0xFF, 0xE0, 0xFF, 0xFF));
    }

    [Fact]
    public void Header_can_be_read_from_a_malformed_message()
    {
        Assert.True(CoapMessageCodec.TryReadHeader([0x40, 0x01, 0x12, 0x34, 0x0F], out var type, out var id));
        Assert.Equal(CoapMessageType.Confirmable, type);
        Assert.Equal(0x1234, id);
    }

    [Fact]
    public void Path_and_query_helpers_round_trip()
    {
        var request = CoapMessage.CreateRequest(CoapCode.Post, "/rd").AddUriQuery("ep=device1").AddUriQuery("lt=300");
        var decoded = CoapMessage.Decode(request.Encode());
        Assert.Equal("/rd", decoded.UriPathString);
        Assert.Equal(["ep=device1", "lt=300"], decoded.UriQuery);
    }
}
