using System.Collections.Immutable;
using System.Text;

namespace Wick.Lwm2m.DeviceManagement;

/// <summary>One Execute argument: a digit and an optional quoted value, as in <c>0='abc'</c>.</summary>
/// <param name="Digit">The argument number, 0 to 9.</param>
/// <param name="Value">The value, or <see langword="null"/> for a bare argument such as <c>1</c>.</param>
public sealed record ExecuteArgument(int Digit, string? Value);

/// <summary>
/// The Execute argument list of OMA LwM2M 1.2 §5.4.3: <c>arg *("," arg)</c>, where each argument
/// is a digit optionally followed by <c>='value'</c>. The value may hold printable ASCII other than
/// space, the double and single quote, and the backslash.
/// </summary>
public static class ExecuteArguments
{
    /// <summary>Formats arguments as the Execute payload text.</summary>
    /// <param name="arguments">The arguments.</param>
    /// <returns>The text, such as <c>0='abc',1</c>.</returns>
    /// <exception cref="ArgumentException">A digit is out of range or a value contains a quote or control character.</exception>
    public static string Format(IEnumerable<ExecuteArgument> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var builder = new StringBuilder();
        foreach (var argument in arguments)
        {
            if (argument.Digit is < 0 or > 9)
            {
                throw new ArgumentException($"an Execute argument number is 0 to 9, not {argument.Digit}", nameof(arguments));
            }

            if (argument.Value is { } value && !value.All(IsArgChar))
            {
                throw new ArgumentException("an Execute argument value may only hold printable ASCII other than space, quotes and backslash", nameof(arguments));
            }

            if (builder.Length > 0)
            {
                builder.Append(',');
            }

            builder.Append((char)('0' + argument.Digit));
            if (argument.Value is not null)
            {
                builder.Append("='").Append(argument.Value).Append('\'');
            }
        }

        return builder.ToString();
    }

    /// <summary>Parses Execute payload text.</summary>
    /// <param name="text">The text. Empty means no arguments.</param>
    /// <returns>The arguments, in order.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MalformedText"/> when the text does not follow the grammar.</exception>
    public static IReadOnlyList<ExecuteArgument> Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var arguments = ImmutableArray.CreateBuilder<ExecuteArgument>();
        int i = 0;
        while (i < text.Length)
        {
            if (!char.IsAsciiDigit(text[i]))
            {
                throw Malformed($"expected an argument digit at offset {i}");
            }

            int digit = text[i++] - '0';
            string? value = null;
            if (i < text.Length && text[i] == '=')
            {
                if (i + 1 >= text.Length || text[i + 1] != '\'')
                {
                    throw Malformed($"expected a quoted value at offset {i + 1}");
                }

                var close = text.IndexOf('\'', i + 2);
                if (close < 0)
                {
                    throw Malformed("unterminated argument value");
                }

                value = text[(i + 2)..close];
                if (!value.All(IsArgChar))
                {
                    throw Malformed("an argument value holds a character outside the argchar set");
                }

                i = close + 1;
            }

            arguments.Add(new ExecuteArgument(digit, value));
            if (i < text.Length)
            {
                if (text[i] != ',' || i + 1 == text.Length)
                {
                    throw Malformed($"expected ',' and another argument at offset {i}");
                }

                i++;
            }
        }

        return arguments.ToImmutable();
    }

    // argchar in §5.4.3: %x21 / %x23-26 / %x28-5B / %x5D-7E, so printable ASCII without space,
    // double quote, single quote or backslash.
    private static bool IsArgChar(char c) => c is '!' or (>= '#' and <= '&') or (>= '(' and <= '[') or (>= ']' and <= '~');

    private static Lwm2mException Malformed(string message) => new(Lwm2mErrorCode.MalformedText, message);
}
