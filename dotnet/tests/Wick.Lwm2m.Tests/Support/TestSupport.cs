using System.Text.Json;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Tests.Support;

/// <summary>Locates the Leshan oracle fixtures shared with the Elixir library.</summary>
internal static class Fixtures
{
    private static readonly Lazy<string> Root = new(FindRoot);

    public static string Directory(string format) => Path.Combine(Root.Value, format);

    public static IEnumerable<string> Stems(string format) =>
        System.IO.Directory.GetFiles(Directory(format), "*.json")
            .Select(Path.GetFileNameWithoutExtension)
            .OfType<string>()
            .Order(StringComparer.Ordinal);

    public static JsonElement Spec(string format, string stem) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(Directory(format), stem + ".json"))).RootElement.Clone();

    public static byte[] Bytes(string format, string fileName) => File.ReadAllBytes(Path.Combine(Directory(format), fileName));

    public static bool Exists(string format, string fileName) => File.Exists(Path.Combine(Directory(format), fileName));

    public static TheoryData<string> TheoryStems(string format)
    {
        var data = new TheoryData<string>();
        foreach (var stem in Stems(format))
        {
            data.Add(stem);
        }

        return data;
    }

    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "wick", "test", "fixtures");
            if (System.IO.Directory.Exists(candidate))
            {
                return candidate;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException("could not find wick/test/fixtures above the test assembly");
    }
}

/// <summary>Builds SenML packs from the oracle's JSON fixture specs.</summary>
internal static class SenmlFixture
{
    public static SenmlPack Pack(JsonElement spec) =>
        new(spec.GetProperty("records").EnumerateArray().Select(Record));

    public static bool AllowNoValue(JsonElement spec) =>
        spec.TryGetProperty("allow_no_value", out var flag) && flag.GetBoolean();

    private static SenmlRecord Record(JsonElement r) => new()
    {
        BaseName = Text(r, "base_name"),
        BaseTime = Number(r, "base_time"),
        Name = Text(r, "name"),
        Time = Number(r, "time"),
        NumberValue = Number(r, "number_value"),
        StringValue = Text(r, "string_value"),
        BooleanValue = r.TryGetProperty("boolean_value", out var b) ? b.GetBoolean() : null,
        OpaqueValue = Text(r, "opaque_value") is { } hex ? (ReadOnlyMemory<byte>?)Convert.FromHexString(hex) : null,
        ObjectLinkValue = Text(r, "object_link_value"),
    };

    private static string? Text(JsonElement r, string key) => r.TryGetProperty(key, out var v) ? v.GetString() : null;

    private static SenmlNumber? Number(JsonElement r, string key)
    {
        if (!r.TryGetProperty(key, out var v))
        {
            return null;
        }

        var raw = v.GetRawText();
        return raw.IndexOfAny(['.', 'e', 'E']) >= 0 ? SenmlNumber.FromFloat(v.GetDouble()) : (SenmlNumber)v.GetInt64();
    }
}

/// <summary>A clock the test moves by hand.</summary>
internal sealed class ManualTimeProvider(DateTimeOffset start) : TimeProvider
{
    private DateTimeOffset _now = start;

    public override DateTimeOffset GetUtcNow() => _now;

    public void Advance(TimeSpan by) => _now += by;
}

internal static class Hex
{
    public static byte[] Bytes(string hex) => Convert.FromHexString(hex.Replace(" ", string.Empty, StringComparison.Ordinal));

    public static string Of(ReadOnlySpan<byte> bytes) => Convert.ToHexString(bytes);

    public static string Of(ReadOnlyMemory<byte> bytes) => Convert.ToHexString(bytes.Span);
}
