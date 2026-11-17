# Interop tests

These tests run the Eclipse Leshan demo client against `Wick.Coap`'s DTLS server over real
sockets. They are tagged `Category=Interop` and skip themselves when the Java runtime or a jar
is missing, so a plain `dotnet test` stays green without them.

## Environment

| Variable | Meaning |
|---|---|
| `WICK_INTEROP_JAVA` | Path to a `java` executable (Java 17 or later). If unset, `$JAVA_HOME/bin/java` is used. |
| `WICK_INTEROP_LESHAN2_JAR` | Leshan 2.0.0-M18 demo client, `leshan-demo-client-2.0.0-M18-jar-with-dependencies.jar` (Californium 3, supports Connection ID). |
| `WICK_INTEROP_LESHAN1_JAR` | Leshan 1.5.0 demo client jar (Scandium 2.8: no Connection ID, no extended master secret). |

Each Leshan test needs only its own jar.

## Running

```bash
export WICK_INTEROP_JAVA=/path/to/java
export WICK_INTEROP_LESHAN2_JAR=/path/to/leshan-demo-client-2.0.0-M18-jar-with-dependencies.jar
export WICK_INTEROP_LESHAN1_JAR=/path/to/leshan-client-demo-1.5.0.jar
dotnet test dotnet/tests/Wick.Coap.Tests --filter Category=Interop
```

Exclude them with `--filter Category!=Interop`.

## What they check

- Leshan 2.0 with `-cid on`, through a UDP relay the test controls: handshake, register
  (`POST /rd` answered `2.01 Created` with a Location-Path), an update, then the relay moves
  to a new source port and the next update arrives on the same session from the new address.
  A `GET /3/0/0` from the server then reaches the client at its new address.
- Leshan 2.0 restricted to TLS_PSK_WITH_AES_128_CCM_8.
- Leshan 1.5: handshake without Connection ID or extended master secret, register, update and
  a server-initiated read; and the same restricted to CCM_8 and to CBC_SHA256 (with `-oc`, which
  lets Scandium 2 offer CBC).

Californium 3 only offers its recommended suites, which exclude CBC, so CBC is checked against
Leshan 1.5 and the BouncyCastle client in `DtlsTransportTests`.

The demo clients write a Californium properties file into their working directory; the tests
start them in a fresh temporary directory.
