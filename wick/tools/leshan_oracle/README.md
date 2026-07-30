# Leshan Oracle

A small Java program that uses [Eclipse Leshan 2.0.0-M18](https://github.com/eclipse-leshan/leshan/tree/leshan-2.0.0-M18) to encode SenML CBOR fixtures from human-readable JSON specs.

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
```

The program scans the directory for `*.json` input files and writes a sibling `*.bin` for each.

The two modes use different output encoders:

* `cbor` → `SenMLCborPackSerDes.serializeToCbor` (CBOR major type 5 maps with integer/string keys).
* `json` → `SenMLJsonRecordSerDes.jSerialize` + Jackson `ObjectMapper.writeValueAsBytes` (compact JSON).

## Requirements

* JDK 17+
* Maven 3.9+
