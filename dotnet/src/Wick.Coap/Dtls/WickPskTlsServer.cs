using Microsoft.Extensions.Logging;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;

namespace Wick.Coap.Dtls;

/// <summary>The BouncyCastle server peer for one handshake: DTLS 1.2, PSK only, optional Connection ID.</summary>
internal sealed class WickPskTlsServer : PskTlsServer
{
    private readonly DtlsServerTransport _owner;
    private readonly DtlsSession _session;

    public WickPskTlsServer(TlsCrypto crypto, TlsPskIdentityManager identities, DtlsServerTransport owner, DtlsSession session)
        : base(crypto, identities)
    {
        _owner = owner;
        _session = session;
    }

    /// <summary>The negotiated parameters, captured when the handshake completes.</summary>
    public SecurityParameters? CompletedParameters { get; private set; }

    protected override ProtocolVersion[] GetSupportedVersions() => ProtocolVersion.DTLSv12.Only();

    protected override int[] GetSupportedCipherSuites() =>
        TlsUtilities.GetSupportedCipherSuites(Crypto, [.. _owner.Options.CipherSuites]);

    /// <summary>Issues a connection id for records the peer sends us (RFC 9146), or none when disabled.</summary>
    protected override byte[]? GetNewConnectionID() => _owner.Options.ConnectionIdLength > 0 ? _owner.AllocateConnectionId(_session) : null;

    public override int GetHandshakeTimeoutMillis() => (int)_owner.Options.HandshakeTimeout.TotalMilliseconds;

    public override bool RequiresExtendedMasterSecret() => _owner.Options.RequireExtendedMasterSecret;

    public override bool ShouldUseExtendedMasterSecret() => true;

    public override void NotifySecureRenegotiation(bool secureRenegotiation)
    {
        if (!secureRenegotiation && _owner.Options.RequireSecureRenegotiation)
            throw new TlsFatalAlert(AlertDescription.handshake_failure, "Secure renegotiation is required.");
    }

    public override void NotifyHandshakeComplete()
    {
        base.NotifyHandshakeComplete();
        CompletedParameters = m_context.SecurityParameters;
    }

    public override void NotifyAlertRaised(short alertLevel, short alertDescription, string message, Exception cause) =>
        _owner.Logger.LogDebug("DTLS alert raised for {Remote}: {Alert} {Message}", _session.Remote, AlertDescription.GetText(alertDescription), message);

    public override void NotifyAlertReceived(short alertLevel, short alertDescription) =>
        _owner.Logger.LogDebug("DTLS alert received from {Remote}: {Alert}", _session.Remote, AlertDescription.GetText(alertDescription));
}

/// <summary>Bridges BouncyCastle's synchronous PSK lookup to the asynchronous <see cref="IPskStore"/>.</summary>
internal sealed class StorePskIdentityManager(IPskStore store, DtlsServerOptions options, DtlsSession session) : TlsPskIdentityManager
{
    public byte[]? GetHint() => options.PskIdentityHint;

    public byte[]? GetPsk(byte[] identity)
    {
        // This runs on the session's dedicated handshake thread, never on the thread pool, so waiting here is acceptable.
        using var timeout = new CancellationTokenSource(options.PskLookupTimeout);
        byte[]? key;
        try
        {
            key = store.GetKeyAsync(identity, session.RemoteEndPoint, timeout.Token).AsTask().GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        if (key is not null) session.SetPskIdentity((byte[])identity.Clone());
        return key;
    }
}
