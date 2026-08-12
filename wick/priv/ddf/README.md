# Bundled Object definitions

DDF (Data Definition Format) XML for the LwM2M Objects Wick ships. `Wick.Object.Registry.standard/0`
parses these **at compile time** and embeds the result in the BEAM, so there is no runtime file
IO and the catalogue survives a release that strips `priv`.

## Provenance

Every file here is vendored **unmodified** from the [OMNA LwM2M Registry](https://github.com/OpenMobileAlliance/lwm2m-registry),
the Open Mobile Alliance's authoritative registry of Object definitions. Each file carries OMA's
own `FILE INFORMATION` header naming the source Permanent Document and its copyright terms — the
files are self-attributing, which is why they are committed verbatim rather than reformatted or
stripped.

The definitions are OMA's, not Wick's. Wick's Apache 2.0 licence covers the code that reads them.

## What is here

| Object | Name | Why it is bundled |
|-------:|------|-------------------|
| 0 | LWM2M Security | Server URIs, security mode, credentials. The protocol bootstraps through it. |
| 1 | LwM2M Server | Short Server ID, lifetime, binding, the registration executables. |
| 2 | LwM2M Access Control | Per-server rights; needed for any multi-server deployment. |
| 3 | Device | Manufacturer, model, error codes, Current Time. The most-read Object there is. |
| 4 | Connectivity Monitoring | Radio signal, link quality, IP addresses. |
| 5 | Firmware Update | The update state machine. |
| 6 | Location | Latitude, longitude, altitude, timestamp. |
| 7 | Connectivity Statistics | Byte and packet counters. |
| 21 | LWM2M OSCORE | OSCORE security contexts. |
| 3303 | Temperature | A representative IPSO Object, and what the demos report. |

This is the set the *protocol* depends on plus one sensor, not the whole OMNA registry — which
runs to hundreds of Objects, most of them vendor-specific. For anything else, drop the DDF
somewhere of your own and use `Wick.Object.Registry.load_from_dir/1`, or merge it into the
standard registry with `Wick.Object.Registry.register/2`.

## Why a model is not optional

TLV and LwM2M CBOR are not self-describing. Four bytes of TLV value could be an Integer, a Float
or a Time, and the only thing that says which is the Object definition. `Wick.Codec.Tlv` therefore
takes a `:model`, and without one it falls back to `:opaque` rather than guessing:

```elixir
{:ok, pack} = Wick.Codec.Tlv.decode(payload, path: path, model: Wick.Object.Registry.standard())
```

## Re-syncing from upstream

The files track the `prod` branch of the OMNA registry, which holds the latest published version
of each Object. To refresh:

```bash
cd wick/priv/ddf
for id in 0 1 2 3 4 5 6 7 21 3303; do
  curl -fsS -o "$id.xml" "https://raw.githubusercontent.com/OpenMobileAlliance/lwm2m-registry/prod/$id.xml"
done
```

Then confirm nothing regressed:

```bash
cd wick && mix test
```

`test/wick/object/registry_test.exs` asserts every bundled Object parses, and
`test/wick/model_test.exs` asserts every type the catalogue declares is one the value layer
understands — so a new type appearing upstream fails the build rather than silently resolving to
something no codec matches.

Object *versions* are not yet part of lookup. These are the latest published version of each
Object, and a device advertising an older one currently resolves against the newer definition.
Version-aware lookup is tracked separately.
