namespace Wick.Lwm2m.Tests;

public sealed class PathTests
{
    [Theory]
    [InlineData("/3/0/9", 3, 0, 9, null)]
    [InlineData("3/0", 3, 0, null, null)]
    [InlineData("/65535", 65535, null, null, null)]
    [InlineData("/3/0/6/1", 3, 0, 6, 1)]
    public void Parses_valid_paths(string text, int objectId, int? instance, int? resource, int? resourceInstance)
    {
        var path = Lwm2mPath.Parse(text);

        Assert.Equal(new Lwm2mPath(objectId, instance, resource, resourceInstance), path);
    }

    [Theory]
    [InlineData("")]
    [InlineData("/")]
    [InlineData("/abc")]
    [InlineData("/3/0/9/2/extra")]
    [InlineData("/65536")]
    [InlineData("/3//9")]
    [InlineData("/-1")]
    [InlineData("/3/0/")]
    [InlineData("/+3")]
    public void Rejects_invalid_paths(string text)
    {
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mPath.Parse(text));
        Assert.Equal(Lwm2mErrorCode.InvalidPath, e.Code);
        Assert.False(Lwm2mPath.TryParse(text, out _));
    }

    [Fact]
    public void Formats_with_a_leading_slash()
    {
        Assert.Equal("/3/0/9", new Lwm2mPath(3, 0, 9).ToString());
        Assert.Equal("/3", new Lwm2mPath(3).ToString());
        Assert.Equal("/3/0/9/2", new Lwm2mPath(3, 0, 9, 2).ToString());
    }

    [Fact]
    public void Segments_round_trip()
    {
        var path = new Lwm2mPath(3, 0, 9);

        Assert.Equal(["3", "0", "9"], path.ToSegments());
        Assert.Equal(path, Lwm2mPath.FromSegments(["3", "0", "9"]));
    }

    [Fact]
    public void From_segments_rejects_non_lwm2m_paths()
    {
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => Lwm2mPath.FromSegments([])).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => Lwm2mPath.FromSegments(["rd"])).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => Lwm2mPath.FromSegments(["3", "bs"])).Code);
    }

    [Fact]
    public void Cannot_skip_a_level_or_go_out_of_range()
    {
        Assert.Throws<Lwm2mException>(() => new Lwm2mPath(3, null, 9));
        Assert.Throws<Lwm2mException>(() => new Lwm2mPath(3, 0, null, 1));
        Assert.Throws<Lwm2mException>(() => new Lwm2mPath(70000));
        Assert.Throws<Lwm2mException>(() => new Lwm2mPath(3, -1));
    }

    [Fact]
    public void Depth_and_level_predicates()
    {
        Assert.True(Lwm2mPath.Parse("/3").IsObject);
        Assert.True(Lwm2mPath.Parse("/3/0").IsObjectInstance);
        Assert.True(Lwm2mPath.Parse("/3/0/9").IsResource);
        Assert.True(Lwm2mPath.Parse("/3/0/9/1").IsResourceInstance);
        Assert.Equal(4, Lwm2mPath.Parse("/3/0/9/1").Depth);
    }

    [Fact]
    public void Contains_covers_the_path_and_its_descendants()
    {
        var instance = Lwm2mPath.Parse("/3/0");

        Assert.True(instance.Contains(Lwm2mPath.Parse("/3/0")));
        Assert.True(instance.Contains(Lwm2mPath.Parse("/3/0/9")));
        Assert.True(instance.Contains(Lwm2mPath.Parse("/3/0/6/1")));
        Assert.False(instance.Contains(Lwm2mPath.Parse("/3/1/9")));
        Assert.False(instance.Contains(Lwm2mPath.Parse("/3")));
        Assert.False(instance.Contains(Lwm2mPath.Parse("/4/0")));
    }

    [Fact]
    public void Parent_and_append_are_inverse()
    {
        var path = Lwm2mPath.Parse("/3/0/6/1");

        Assert.Equal(Lwm2mPath.Parse("/3/0/6"), path.Parent);
        Assert.Equal(path, path.Parent!.Append(1));
        Assert.Null(Lwm2mPath.Parse("/3").Parent);
        Assert.Throws<Lwm2mException>(() => path.Append(0));
    }

    [Fact]
    public void Orders_by_component_with_parents_first()
    {
        var paths = new[] { "/3/1", "/3/0/9", "/3", "/3/0", "/1/0" }.Select(Lwm2mPath.Parse).Order().Select(p => p.ToString());

        Assert.Equal(["/1/0", "/3", "/3/0", "/3/0/9", "/3/1"], paths);
    }
}

public sealed class ValueTests
{
    [Fact]
    public void Values_compare_by_type_and_content()
    {
        Assert.Equal(Lwm2mValue.FromInteger(42), Lwm2mValue.FromInteger(42));
        Assert.NotEqual(Lwm2mValue.FromInteger(42), Lwm2mValue.FromTime(42));
        Assert.NotEqual(Lwm2mValue.FromString("x"), Lwm2mValue.FromCoreLink("x"));
        Assert.Equal(Lwm2mValue.FromOpaque([1, 2]), Lwm2mValue.FromOpaque([1, 2]));
        Assert.Equal(Lwm2mValue.FromOpaque([1, 2]).GetHashCode(), Lwm2mValue.FromOpaque([1, 2]).GetHashCode());
        Assert.NotEqual(Lwm2mValue.FromOpaque([1, 2]), Lwm2mValue.FromOpaque([1, 3]));
    }

    [Fact]
    public void Opaque_bytes_are_copied_in()
    {
        var bytes = new byte[] { 1, 2 };
        var value = Lwm2mValue.FromOpaque(bytes);
        bytes[0] = 9;

        Assert.Equal(1, value.AsOpaque().Span[0]);
    }

    [Fact]
    public void Accessors_refuse_the_wrong_type()
    {
        Assert.Throws<InvalidOperationException>(() => Lwm2mValue.FromString("x").AsInteger());
        Assert.Throws<InvalidOperationException>(() => Lwm2mValue.FromTime(1).AsInteger());
    }

    [Fact]
    public void Time_converts_to_and_from_date_time_offset()
    {
        var at = new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero);

        Assert.Equal(1_700_000_000, Lwm2mValue.FromTime(at).AsTime());
        Assert.Equal(at, Lwm2mValue.FromTime(1_700_000_000).AsDateTimeOffset());
    }

    [Fact]
    public void Object_links_parse_and_format()
    {
        Assert.Equal(new ObjectLink(1, 0), ObjectLink.Parse("1:0"));
        Assert.Equal("65535:65535", ObjectLink.Null.ToString());
        Assert.True(ObjectLink.Parse("65535:65535").IsNull);
        Assert.Throws<Lwm2mException>(() => ObjectLink.Parse("1"));
        Assert.Throws<Lwm2mException>(() => ObjectLink.Parse("1:x"));
        Assert.Throws<Lwm2mException>(() => ObjectLink.Parse("65536:0"));
    }
}

public sealed class NodeTests
{
    [Fact]
    public void Nodes_compare_by_content()
    {
        static Lwm2mObjectInstance Make() => new(0,
            new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87)),
            new Lwm2mMultipleResource(6, Lwm2mType.Integer, new Lwm2mResourceInstance(0, Lwm2mValue.FromInteger(1))));

        Assert.Equal(Make(), Make());
        Assert.Equal(Make().GetHashCode(), Make().GetHashCode());
        Assert.NotEqual(Make(), new Lwm2mObjectInstance(0, new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(88))));
    }

    [Fact]
    public void Children_are_ordered_by_id()
    {
        var instance = new Lwm2mObjectInstance(0,
            new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(1)),
            new Lwm2mSingleResource(0, Lwm2mValue.FromString("a")));

        Assert.Equal([0, 9], instance.Resources.Keys);
    }

    [Fact]
    public void Duplicate_ids_are_refused()
    {
        Assert.Throws<ArgumentException>(() => new Lwm2mObjectInstance(0,
            new Lwm2mSingleResource(1, Lwm2mValue.FromInteger(1)),
            new Lwm2mSingleResource(1, Lwm2mValue.FromInteger(2))));
    }

    [Fact]
    public void A_multiple_resource_holds_one_type()
    {
        Assert.Throws<ArgumentException>(() => new Lwm2mMultipleResource(6, Lwm2mType.Integer,
            new Lwm2mResourceInstance(0, Lwm2mValue.FromString("x"))));
    }
}
