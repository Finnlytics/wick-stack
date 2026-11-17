using System.Globalization;
using System.Text;

namespace Wick.Lwm2m.Codecs.Internal;

/// <summary>
/// Formats a double the way Java's <c>Double.toString</c> does, which is what Eclipse Leshan
/// emits in SenML JSON and plain text.
/// </summary>
/// <remarks>
/// The digits are the shortest that round-trip, which .NET's <c>"R"</c> format already gives.
/// Only the layout differs: Java uses plain decimal notation with at least one fractional digit
/// for magnitudes from 10^-3 up to but not including 10^7 (<c>22.0</c>, <c>0.001</c>), and
/// <c>d.dddE±n</c> outside that range (<c>1.0E7</c>, <c>1.0E-4</c>).
/// </remarks>
internal static class JavaDouble
{
    public static string Format(double value)
    {
        if (double.IsNaN(value))
        {
            return "NaN";
        }

        if (double.IsPositiveInfinity(value))
        {
            return "Infinity";
        }

        if (double.IsNegativeInfinity(value))
        {
            return "-Infinity";
        }

        if (value == 0)
        {
            return double.IsNegative(value) ? "-0.0" : "0.0";
        }

        var (digits, exponent) = Decompose(Math.Abs(value));
        var builder = new StringBuilder();
        if (value < 0)
        {
            builder.Append('-');
        }

        var magnitude = Math.Abs(value);
        if (magnitude is >= 1e-3 and < 1e7)
        {
            if (exponent >= 0)
            {
                var integerDigits = exponent + 1;
                if (digits.Length <= integerDigits)
                {
                    builder.Append(digits).Append('0', integerDigits - digits.Length).Append(".0");
                }
                else
                {
                    builder.Append(digits, 0, integerDigits).Append('.').Append(digits, integerDigits, digits.Length - integerDigits);
                }
            }
            else
            {
                builder.Append("0.").Append('0', -exponent - 1).Append(digits);
            }
        }
        else
        {
            builder.Append(digits[0]).Append('.');
            builder.Append(digits.Length > 1 ? digits[1..] : "0");
            builder.Append('E').Append(exponent.ToString(CultureInfo.InvariantCulture));
        }

        return builder.ToString();
    }

    // Splits a positive finite double into its shortest round-trip significant digits and the
    // decimal exponent of the first digit, so value = d.ddd * 10^exponent.
    private static (string Digits, int Exponent) Decompose(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        int exponentOffset = 0;
        var e = text.IndexOfAny(['E', 'e']);
        if (e >= 0)
        {
            exponentOffset = int.Parse(text.AsSpan(e + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            text = text[..e];
        }

        var point = text.IndexOf('.');
        var integerPart = point >= 0 ? text[..point] : text;
        var fractionPart = point >= 0 ? text[(point + 1)..] : string.Empty;
        var all = integerPart + fractionPart;

        int leadingZeros = 0;
        while (leadingZeros < all.Length - 1 && all[leadingZeros] == '0')
        {
            leadingZeros++;
        }

        var digits = all[leadingZeros..].TrimEnd('0');
        if (digits.Length == 0)
        {
            digits = "0";
        }

        int exponent = integerPart.Length - 1 - leadingZeros + exponentOffset;
        return (digits, exponent);
    }
}
