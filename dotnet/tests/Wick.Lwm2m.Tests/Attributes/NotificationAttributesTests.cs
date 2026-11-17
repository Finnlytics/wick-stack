using Wick.Lwm2m.Attributes;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Tests.Attributes;

public sealed class NotificationAttributesTests
{
    private static IReadOnlyList<QueryParameter> Query(params string[] parameters) => parameters.Select(QueryParameter.Parse).ToList();

    [Fact]
    public void Emits_attributes_in_a_fixed_order()
    {
        var attributes = new NotificationAttributes { St = 0.5m, Gt = 25, Pmax = 60, Pmin = 10, Epmax = 30 };

        Assert.Equal(["pmin=10", "pmax=60", "epmax=30", "gt=25", "st=0.5"], attributes.ToQuery().Select(q => q.ToString()));
    }

    [Fact]
    public void Keeps_zero_and_writes_clear_as_a_bare_name()
    {
        var attributes = new NotificationAttributes { Pmin = 0, Pmax = AttributeValue<long>.Cleared };

        Assert.Equal(["pmin=0", "pmax"], attributes.ToQuery().Select(q => q.ToString()));
    }

    [Fact]
    public void Thresholds_are_written_without_exponent_or_trailing_zeros()
    {
        var attributes = new NotificationAttributes { Gt = 25.500m, Lt = -0.000001m };

        Assert.Equal(["gt=25.5", "lt=-0.000001"], attributes.ToQuery().Select(q => q.ToString()));
    }

    [Fact]
    public void Parses_integers_decimals_and_clears()
    {
        var attributes = NotificationAttributes.FromQuery(Query("pmin=10", "gt=22.5", "lt=-3", "pmax", "unknown=x"));

        Assert.Equal(10, attributes.Pmin.Value);
        Assert.Equal(22.5m, attributes.Gt.Value);
        Assert.Equal(-3m, attributes.Lt.Value);
        Assert.Equal(AttributeState.Cleared, attributes.Pmax.State);
        Assert.Equal(AttributeState.Absent, attributes.St.State);
    }

    [Theory]
    [InlineData("pmin=soon")]
    [InlineData("pmin=1.5")]
    [InlineData("pmin=-1")]
    [InlineData("pmin=10x")]
    [InlineData("gt=1e3")]
    [InlineData("gt=")]
    [InlineData("gt=-")]
    [InlineData("gt=1-2")]
    public void Rejects_malformed_values(string parameter)
    {
        Assert.Equal(Lwm2mErrorCode.InvalidAttribute, Assert.Throws<Lwm2mException>(() => NotificationAttributes.FromQuery(Query(parameter))).Code);
    }

    [Fact]
    public void Rejects_a_repeated_attribute()
    {
        Assert.Throws<Lwm2mException>(() => NotificationAttributes.FromQuery(Query("pmin=1", "pmin=2")));
    }

    [Fact]
    public void A_full_set_survives_the_query_round_trip()
    {
        var attributes = new NotificationAttributes { Pmin = 10, Pmax = 60, Gt = 30, Lt = 10, St = 2.5m, Epmin = 1, Epmax = 5 };

        Assert.Equal(attributes, NotificationAttributes.FromQuery(attributes.ToQuery()));

        var clears = new NotificationAttributes { Pmin = AttributeValue<long>.Cleared, Gt = AttributeValue<decimal>.Cleared };
        Assert.Equal(clears, NotificationAttributes.FromQuery(clears.ToQuery()));
    }

    [Fact]
    public void Link_params_carry_property_attributes_and_drop_clears()
    {
        var attributes = new NotificationAttributes { Dim = 3, Ver = "1.1", Pmin = 10, Gt = 22.5m, Pmax = AttributeValue<long>.Cleared };

        var parameters = attributes.ToLinkParams();
        var back = NotificationAttributes.FromLinkParams(parameters.Append(LinkParam.Of("obs", null)).Append(LinkParam.Of("rt", "x")));

        Assert.Equal("</3/0/6>;dim=3;ver=1.1;pmin=10;gt=22.5", new Link("/3/0/6", parameters).ToString());
        Assert.Equal(attributes with { Pmax = AttributeValue<long>.Absent }, back);
    }

    [Fact]
    public void Merge_leaves_absent_clears_cleared_and_replaces_set()
    {
        var current = new NotificationAttributes { Pmin = 10, Pmax = 60 };

        var merged = current.Merge(new NotificationAttributes { Pmax = AttributeValue<long>.Cleared, Gt = 25, Pmin = 0 });

        Assert.Equal(new NotificationAttributes { Pmin = 0, Gt = 25 }, merged);
    }

    [Theory]
    [InlineData("pmin=60", "pmax=10")]
    [InlineData("epmin=6", "epmax=5")]
    [InlineData("lt=30", "gt=10")]
    [InlineData("lt=10", "gt=10")]
    [InlineData("lt=10", "gt=20", "st=5")]
    [InlineData("st=-1")]
    public void Validate_enforces_the_section_5_1_rules(params string[] parameters)
    {
        var attributes = NotificationAttributes.FromQuery(Query(parameters));

        Assert.Equal(Lwm2mErrorCode.InvalidAttribute, Assert.Throws<Lwm2mException>(attributes.Validate).Code);
    }

    [Fact]
    public void Validate_accepts_a_consistent_set()
    {
        NotificationAttributes.FromQuery(Query("pmin=10", "pmax=60", "lt=10", "gt=30", "st=4.9")).Validate(Lwm2mPath.Parse("/3303/0/5700"));
    }

    [Fact]
    public void Thresholds_attach_to_resources_only()
    {
        var attributes = new NotificationAttributes { Gt = 1 };

        Assert.Throws<Lwm2mException>(() => attributes.Validate(Lwm2mPath.Parse("/3303/0")));
        attributes.Validate(Lwm2mPath.Parse("/3303/0/5700"));
        attributes.Validate(Lwm2mPath.Parse("/3303/0/5700/1"));
    }

    [Fact]
    public void Clear_and_zero_are_not_empty()
    {
        Assert.True(new NotificationAttributes().IsEmpty);
        Assert.False(new NotificationAttributes { Pmin = AttributeValue<long>.Cleared }.IsEmpty);
        Assert.False(new NotificationAttributes { Pmin = 0 }.IsEmpty);
    }
}
