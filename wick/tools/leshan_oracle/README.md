# Leshan Oracle

A small Java program that uses [Eclipse Leshan 2.0.0-M18](https://github.com/eclipse-leshan/leshan/tree/leshan-2.0.0-M18) to encode fixtures from human-readable JSON specs — SenML CBOR, SenML JSON, and LwM2M TLV.

The output bytes become the **expected output** in Wick's codec tests. Wick's Elixir codec must produce byte-identical output, validating bit-level interop.

## Why Leshan 2.x

Leshan 1.x doesn't implement SenML at all — see [ADR 0002](../../docs/decisions/0002-oracle-pinned-to-leshan-2x.md). The 2.x line added it. M18 is the latest published milestone and is the de-facto stable head of 2.x until 2.0.0 GA.

## When to run

Only when adding or modifying fixtures under [`../../test/fixtures/`](../../test/fixtures/). The generated `.bin` files are committed to the repo. Wick's test suite reads them directly — **no JVM required to run `mix test`.**

## Usage

```bash
# From wick/tools/leshan_oracle
mvn -q clean package

# SenML CBOR fixtures
java -jar target/leshan-oracle.jar cbor ../../test/fixtures/senml_cbor

# SenML JSON fixtures
java -jar target/leshan-oracle.jar json ../../test/fixtures/senml_json

# LwM2M TLV fixtures
java -jar target/leshan-oracle.jar tlv ../../test/fixtures/tlv
```

The program scans the directory for `*.json` input files and writes a sibling `*.bin` for each.

The three modes use different output encoders:

* `cbor` → `SenMLCborPackSerDes.serializeToCbor` (CBOR major type 5 maps with integer/string keys).
* `json` → `SenMLJsonRecordSerDes.jSerialize` + Jackson `ObjectMapper.writeValueAsBytes` (compact JSON).
* `tlv` → `DefaultLwM2mEncoder.encode(node, ContentFormat.TLV, …)`, via [`TlvOracle`](src/main/java/com/finnlytics/wick/oracle/TlvOracle.java).

### The TLV spec format differs

TLV needs two things SenML does not. The payload carries no names, so it only means anything relative to a **request path**; and a TLV value is bare bytes, so an **Object model** is the only thing that says whether four of them are an Integer, a Float or a Time. A TLV fixture therefore declares both, and the Elixir test builds an equivalent `Wick.Object.Registry` from the same declaration — the two implementations are handed identical inputs rather than each supplying its own idea of the model, which is the only way the byte comparison means anything.

```json
{
  "description": "Device Object Instance",
  "path": "/3/0",
  "object_id": 3,
  "resources": [
    {"id": 0, "type": "STRING",  "value": "Open Mobile Alliance"},
    {"id": 9, "type": "INTEGER", "value": 87},
    {"id": 6, "type": "INTEGER", "instances": {"0": 1, "1": 5}}
  ]
}
```

`type` names a Leshan `ResourceModel.Type` constant. An `instances` object makes the Resource multiple-instance; a `value` makes it single. `OPAQUE` values are hex, `OBJLNK` values are `"object:instance"`.

Two representations are deliberately different on each side and must still agree on the wire: Leshan models Time as a `java.util.Date` in milliseconds and divides by 1000 when encoding, where Wick keeps epoch seconds throughout; and Leshan types a CoRE Link Resource as a parsed `Link[]` that it re-serializes, where Wick stores the string as given.

## Requirements

* JDK 17+
* Maven 3.9+
