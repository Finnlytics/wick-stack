using System.Text;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Links;

namespace Wick.Lwm2m.Tests.Codecs;

public sealed class PlainTextCodecTests
{
    public static TheoryData<Lwm2mValue, string> Encodings => new()
    {
        { Lwm2mValue.FromInteger(87), "87" },
        { Lwm2mValue.FromInteger(-1), "-1" },
        { Lwm2mValue.FromUnsignedInteger(ulong.MaxValue), "18446744073709551615" },
        { Lwm2mValue.FromFloat(1.5), "1.5" },
        { Lwm2mValue.FromFloat(22.0), "22.0" },
        { Lwm2mValue.FromString("café"), "café" },
        { Lwm2mValue.FromBoolean(true), "1" },
        { Lwm2mValue.FromBoolean(false), "0" },
        { Lwm2mValue.FromTime(1700000000), "1700000000" },
        { Lwm2mValue.FromObjectLink(new ObjectLink(1, 0)), "1:0" },
        { Lwm2mValue.FromOpaque([0xDE, 0xAD, 0xBE, 0xEF]), "3q2+7w==" },
        { Lwm2mValue.FromCoreLink("</3/0>"), "</3/0>" },
    };

    [Theory]
    [MemberData(nameof(Encodings))]
    public void Encodes_and_decodes_each_type(Lwm2mValue value, string text)
    {
        Assert.Equal(text, Encoding.UTF8.GetString(PlainTextCodec.Encode(value)));
        Assert.Equal(value, PlainTextCodec.Decode(Encoding.UTF8.GetBytes(text), value.Type));
    }

    [Fact]
    public void Without_a_type_text_decodes_as_a_string()
    {
        Assert.Equal(Lwm2mValue.FromString("87"), PlainTextCodec.Decode("87"u8, null));
    }

    [Theory]
    [InlineData("12.5", Lwm2mType.Integer)]
    [InlineData("", Lwm2mType.Integer)]
    [InlineData("-1", Lwm2mType.UnsignedInteger)]
    [InlineData("NaN", Lwm2mType.Float)]
    [InlineData("abc", Lwm2mType.Float)]
    [InlineData("2", Lwm2mType.Boolean)]
    [InlineData("true", Lwm2mType.Boolean)]
    [InlineData("1", Lwm2mType.ObjectLink)]
    [InlineData("not base64!", Lwm2mType.Opaque)]
    [InlineData("1700000000.5", Lwm2mType.Time)]
    public void Rejects_text_that_does_not_parse_as_the_type(string text, Lwm2mType type)
    {
        var e = Assert.Throws<Lwm2mException>(() => PlainTextCodec.Decode(Encoding.UTF8.GetBytes(text), type));
        Assert.Equal(Lwm2mErrorCode.MalformedText, e.Code);
    }

    [Fact]
    public void A_value_less_resource_cannot_be_encoded()
    {
        Assert.Equal(Lwm2mErrorCode.UnencodableValue, Assert.Throws<Lwm2mException>(() => PlainTextCodec.Encode(Lwm2mValue.None)).Code);
    }
}

public sealed class OpaqueCodecTests
{
    [Fact]
    public void Is_the_identity_on_bytes()
    {
        Assert.Equal(new byte[] { 0xCA, 0xFE }, OpaqueCodec.Encode(Lwm2mValue.FromOpaque([0xCA, 0xFE])));
        Assert.Equal(Lwm2mValue.FromOpaque([0xCA, 0xFE]), OpaqueCodec.Decode([0xCA, 0xFE]));
        Assert.Empty(OpaqueCodec.Encode(Lwm2mValue.FromOpaque([])));
    }

    [Fact]
    public void Carries_opaque_values_only()
    {
        Assert.Equal(Lwm2mErrorCode.UnencodableValue, Assert.Throws<Lwm2mException>(() => OpaqueCodec.Encode(Lwm2mValue.FromString("x"))).Code);
    }
}

public sealed class CoreLinkFormatTests
{
    [Fact]
    public void Parses_a_registration_payload()
    {
        var links = CoreLinkFormat.Parse("""</>;rt="oma.lwm2m";ct=11543,</1/0>,</3/0>,</5>""");

        Assert.Equal(["/", "/1/0", "/3/0", "/5"], links.Select(l => l.Target));
        Assert.Equal("oma.lwm2m", links[0].Get("rt"));
        Assert.Equal("11543", links[0].Get("ct"));
        Assert.True(links[0].Parameters[0].Quoted);
        Assert.False(links[0].Parameters[1].Quoted);
    }

    [Fact]
    public void Round_trips_byte_for_byte_when_quoting_is_preserved()
    {
        const string text = """</>;rt="oma.lwm2m";ct="60 110 112 11543",</1/0>,</3>;ver=1.1,</3/0>,</3303/0/5700>;pmin=10;pmax=60;gt=25.5;obs""";

        Assert.Equal(text, CoreLinkFormat.Format(CoreLinkFormat.Parse(text)));
    }

    [Fact]
    public void Tolerates_whitespace_between_tokens()
    {
        var links = CoreLinkFormat.Parse(" </1/0> , </3/0> ; rt = \"x\" ");

        Assert.Equal(2, links.Count);
        Assert.Equal("x", links[1].Get("rt"));
    }

    [Fact]
    public void Unescapes_quoted_strings()
    {
        const string text = "</a>;title=\"say \\\"hi\\\" \\\\ bye\"";
        var link = CoreLinkFormat.Parse(text).Single();

        Assert.Equal("say \"hi\" \\ bye", link.Get("title"));
        Assert.Equal(text, link.ToString());
    }

    [Fact]
    public void Quotes_by_name_and_by_content_when_built()
    {
        var link = new Link("/", LinkParam.Of("rt", "oma.lwm2m"), LinkParam.Of("ct", "11543"), LinkParam.Of("x", "a b"), LinkParam.Of("obs", null));

        Assert.Equal("""</>;rt="oma.lwm2m";ct=11543;x="a b";obs""", link.ToString());
    }

    [Fact]
    public void An_empty_document_has_no_links()
    {
        Assert.Empty(CoreLinkFormat.Parse(""));
        Assert.Empty(CoreLinkFormat.Parse("  "));
    }

    [Theory]
    [InlineData("/1/0")]
    [InlineData("</1/0")]
    [InlineData("</1/0>;")]
    [InlineData("</1/0>;rt=\"open")]
    [InlineData("</1/0> </3/0>")]
    [InlineData("</1/0>,")]
    public void Rejects_malformed_documents(string text)
    {
        Assert.Equal(Lwm2mErrorCode.MalformedLinkFormat, Assert.Throws<Lwm2mException>(() => CoreLinkFormat.Parse(text)).Code);
    }

    [Fact]
    public void Exposes_targets_as_paths_where_they_are_paths()
    {
        var links = CoreLinkFormat.Parse("</>,</3/0>");

        Assert.Null(links[0].Path);
        Assert.Equal(Lwm2mPath.Parse("/3/0"), links[1].Path);
    }
}
