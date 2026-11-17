using System.Diagnostics;
using Xunit.Abstractions;
using System.Text;
using Wick.Coap.Dtls;
using Wick.Coap.Tests.Support;

namespace Wick.Coap.Tests.Interop;

/// <summary>
/// Runs a test only when the Java runtime and the jar named by <paramref name="jarVariable"/>
/// are available. See the README in this folder for the environment variables.
/// </summary>
public sealed class InteropFactAttribute : FactAttribute
{
    public InteropFactAttribute(string jarVariable)
    {
        if (LeshanClient.FindJava() is null) Skip = $"No Java runtime: set {LeshanClient.JavaVariable} or JAVA_HOME.";
        else if (LeshanClient.FindJar(jarVariable) is null) Skip = $"Set {jarVariable} to the Leshan demo client jar to run this test.";
    }
}

/// <summary>A Leshan demo client process.</summary>
public sealed class LeshanClient : IDisposable
{
    public const string JavaVariable = "WICK_INTEROP_JAVA";
    public const string Leshan2Variable = "WICK_INTEROP_LESHAN2_JAR";
    public const string Leshan1Variable = "WICK_INTEROP_LESHAN1_JAR";

    private readonly Process _process;
    private readonly string _workingDirectory;
    private readonly StringBuilder _output = new();

    private LeshanClient(Process process, string workingDirectory)
    {
        _process = process;
        _workingDirectory = workingDirectory;
        process.OutputDataReceived += (_, e) => { lock (_output) _output.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { lock (_output) _output.AppendLine(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    public string Output
    {
        get { lock (_output) return _output.ToString(); }
    }

    public static string? FindJava()
    {
        var explicitPath = Environment.GetEnvironmentVariable(JavaVariable);
        if (!string.IsNullOrEmpty(explicitPath)) return File.Exists(explicitPath) ? explicitPath : null;
        var javaHome = Environment.GetEnvironmentVariable("JAVA_HOME");
        if (string.IsNullOrEmpty(javaHome)) return null;
        var candidate = Path.Combine(javaHome, "bin", OperatingSystem.IsWindows() ? "java.exe" : "java");
        return File.Exists(candidate) ? candidate : null;
    }

    public static string? FindJar(string variable)
    {
        var path = Environment.GetEnvironmentVariable(variable);
        return !string.IsNullOrEmpty(path) && File.Exists(path) ? path : null;
    }

    public static LeshanClient Start(string jarVariable, params string[] arguments)
    {
        // The demo clients write a Californium properties file to the working directory, so give them a scratch one.
        var workingDirectory = Directory.CreateTempSubdirectory("wick-interop-").FullName;
        var start = new ProcessStartInfo(FindJava()!)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            WorkingDirectory = workingDirectory,
        };
        start.ArgumentList.Add("-jar");
        start.ArgumentList.Add(FindJar(jarVariable)!);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return new LeshanClient(Process.Start(start)!, workingDirectory);
    }

    public void Dispose()
    {
        try
        {
            if (!_process.HasExited) _process.Kill(entireProcessTree: true);
            _process.WaitForExit(5000);
        }
        catch (InvalidOperationException) { }
        _process.Dispose();
        try { Directory.Delete(_workingDirectory, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

[Trait("Category", "Interop")]
public class LeshanInteropTests(ITestOutputHelper output)
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(40);
    private static readonly string PskHex = Convert.ToHexString(RegistrationServer.Key);

    [InteropFact(LeshanClient.Leshan2Variable)]
    public async Task Leshan_2_registers_updates_and_survives_a_source_port_change_with_a_connection_id()
    {
        await using var server = await RegistrationServer.StartAsync(new DtlsServerOptions { ConnectionIdLength = 6 });
        using var relay = new UdpRelay(server.LocalEndPoint);
        using var client = LeshanClient.Start(LeshanClient.Leshan2Variable,
            "-u", $"coaps://127.0.0.1:{relay.ListenEndPoint.Port}", "-n", "wick-interop-2",
            "-i", RegistrationServer.Identity, "-p", PskHex, "-cid", "on", "-l", "60", "-cp", "5");
        try
        {
            var registration = await server.WaitForAsync("register", 1, Timeout);
            Assert.Equal(RegistrationServer.Identity, registration.Identity);
            Assert.Contains("ep=wick-interop-2", registration.Request.UriQuery);
            var session = Assert.IsType<DtlsSession>(registration.Peer);
            Assert.NotNull(session.ConnectionId);
            Assert.Equal(relay.UpstreamEndPoint, session.RemoteEndPoint);
            output.WriteLine($"Leshan 2: suite 0x{session.Security!.CipherSuite:X4}, extended master secret {session.Security.ExtendedMasterSecret}, cid {Convert.ToHexString(session.ConnectionId!)}");

            var firstUpdate = await server.WaitForAsync("update", 1, Timeout);
            Assert.Same(session, firstUpdate.Peer);

            var before = relay.UpstreamEndPoint;
            relay.Rebind();
            var after = relay.UpstreamEndPoint;
            int updatesBefore = server.Events.Count(e => e.Kind == "update");
            var moved = await server.WaitForAsync("update", updatesBefore + 1, Timeout);
            Assert.Same(session, moved.Peer);
            Assert.Equal(after, moved.Address);
            Assert.Equal(after, session.RemoteEndPoint);
            Assert.NotEqual(before, after);
            Assert.Single(server.Transport.GetSessions());
            Assert.Equal(1, server.Events.Count(e => e.Kind == "register"));

            // The downlink reaches the device at its new address.
            var read = await server.Endpoint.SendAsync(session, CoapMessage.CreateRequest(CoapCode.Get, "/3/0/0")).WaitAsync(Timeout);
            Assert.Equal(CoapCode.Content, read.Code);
            output.WriteLine($"Leshan 2: moved {before} -> {after}; GET /3/0/0 answered {read.Code} '{read.PayloadAsString()}'");
        }
        finally
        {
            output.WriteLine(client.Output);
        }
    }

    [InteropFact(LeshanClient.Leshan1Variable)]
    public async Task Leshan_1_completes_a_handshake_on_ccm_8_and_cbc()
    {
        foreach (var suite in new[] { Org.BouncyCastle.Tls.CipherSuite.TLS_PSK_WITH_AES_128_CCM_8, Org.BouncyCastle.Tls.CipherSuite.TLS_PSK_WITH_AES_128_CBC_SHA256 })
        {
            await using var server = await RegistrationServer.StartAsync(new DtlsServerOptions { CipherSuites = [suite] });
            // -oc lets Scandium 2 offer the CBC suites it treats as old.
            using var client = LeshanClient.Start(LeshanClient.Leshan1Variable,
                "-u", $"127.0.0.1:{server.LocalEndPoint.Port}", "-n", "wick-interop-1-suite",
                "-i", RegistrationServer.Identity, "-p", PskHex, "-l", "60", "-cp", "5", "-oc");
            try
            {
                var registration = await server.WaitForAsync("register", 1, Timeout);
                Assert.Equal(suite, registration.Peer.Security!.CipherSuite);
                await server.WaitForAsync("update", 1, Timeout);
            }
            finally
            {
                output.WriteLine(client.Output);
            }
        }
    }

    [InteropFact(LeshanClient.Leshan2Variable)]
    public async Task Leshan_2_completes_a_handshake_on_ccm_8()
    {
        // Californium 3 only offers its recommended suites, which exclude CBC; CBC is covered against Leshan 1.
        var options = new DtlsServerOptions { CipherSuites = [Org.BouncyCastle.Tls.CipherSuite.TLS_PSK_WITH_AES_128_CCM_8] };
        await using var server = await RegistrationServer.StartAsync(options);
        using var client = LeshanClient.Start(LeshanClient.Leshan2Variable,
            "-u", $"coaps://127.0.0.1:{server.LocalEndPoint.Port}", "-n", "wick-interop-2-ccm8",
            "-i", RegistrationServer.Identity, "-p", PskHex, "-cid", "on", "-l", "60", "-cp", "5");
        try
        {
            var registration = await server.WaitForAsync("register", 1, Timeout);
            Assert.Equal(Org.BouncyCastle.Tls.CipherSuite.TLS_PSK_WITH_AES_128_CCM_8, registration.Peer.Security!.CipherSuite);
            Assert.NotNull(registration.Peer.Security.ConnectionId);
            await server.WaitForAsync("update", 1, Timeout);
        }
        finally
        {
            output.WriteLine(client.Output);
        }
    }

    [InteropFact(LeshanClient.Leshan1Variable)]
    public async Task Leshan_1_registers_and_updates_without_connection_id_or_extended_master_secret()
    {
        await using var server = await RegistrationServer.StartAsync(new DtlsServerOptions { ConnectionIdLength = 6 });
        using var client = LeshanClient.Start(LeshanClient.Leshan1Variable,
            // Leshan 1.x takes host:port and picks coaps itself when a PSK is given.
            "-u", $"127.0.0.1:{server.LocalEndPoint.Port}", "-n", "wick-interop-1",
            "-i", RegistrationServer.Identity, "-p", PskHex, "-l", "60", "-cp", "5");
        try
        {
            var registration = await server.WaitForAsync("register", 1, Timeout);
            Assert.Equal(RegistrationServer.Identity, registration.Identity);
            Assert.Contains("ep=wick-interop-1", registration.Request.UriQuery);
            var session = Assert.IsType<DtlsSession>(registration.Peer);
            Assert.False(session.Security!.ExtendedMasterSecret);
            Assert.Null(session.Security.ConnectionId);
            output.WriteLine($"Leshan 1: suite 0x{session.Security.CipherSuite:X4}, extended master secret {session.Security.ExtendedMasterSecret}");

            var update = await server.WaitForAsync("update", 1, Timeout);
            Assert.Same(session, update.Peer);
            var read = await server.Endpoint.SendAsync(session, CoapMessage.CreateRequest(CoapCode.Get, "/3/0/0")).WaitAsync(Timeout);
            Assert.Equal(CoapCode.Content, read.Code);
        }
        finally
        {
            output.WriteLine(client.Output);
        }
    }
}
