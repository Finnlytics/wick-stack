# ADR 0002 — Oracle pinned to Leshan 2.0.0-M18

**Status:** Accepted
**Date:** 2026-05-07

## Context

The Java oracle — the program that produces reference CBOR bytes for our test fixtures — was initially specified to build against `org.eclipse.leshan:leshan-core:1.5.0`. The reasoning was that 1.x was a stable line whereas 2.x is still milestone-versioned with module-name churn, so an older but settled reference was preferred.

**That reasoning was wrong.** When we checked the Leshan 1.5.0 source out locally for an import-path lookup, we discovered that **Leshan 1.x does not implement SenML at all**:

- `git ls-tree -r leshan-1.5.0` shows zero files matching `SenML` or `senml`.
- The codec packages under `leshan-core/.../node/codec/` are `json`, `opaque`, `text`, `tlv`. The `json` codec is the legacy *LwM2M JSON* format ([OMA LwM2M 1.0 §6.4](https://www.openmobilealliance.org/release/LightweightM2M/V1_0_2-20180209-A/OMA-TS-LightweightM2M-V1_0_2-20180209-A.pdf)), not SenML JSON.
- The same is true on `origin/1.x` — no SenML files were ever added in the 1.x line.

SenML support landed in Leshan 2.x. The 2.x classes we need live at:

- `org.eclipse.leshan.senml.SenMLPack`
- `org.eclipse.leshan.senml.SenMLRecord`
- `org.eclipse.leshan.senml.cbor.upokecenter.SenMLCborPackSerDes`

Available 2.x tags are milestones `M1`–`M18`. `M18` is the latest on Maven Central.

## Decision

The oracle pins to **`org.eclipse.leshan:leshan-lwm2m-core:2.0.0-M18`** (note the artifact ID renamed from `leshan-core` to `leshan-lwm2m-core` in 2.x).

The choice of milestone is "latest available". M18 has been on Maven Central since 2025 and is what the Leshan project uses as the de-facto stable head until 2.0.0 final ships. We accept the milestone-versioning risk because:

1. The oracle is internal tooling, not a runtime dep — its job is to produce reference bytes once per fixture corpus update.
2. We can pin a specific milestone and not move it. Wire-format output is stable across milestones as far as we can tell from release notes.
3. There is no alternative — 1.x doesn't have SenML, period.

## Consequences

**Good**

- The oracle can actually encode SenML CBOR. The original plan could not have been built as written.
- The 2.x API surface (`SenMLPack`, `SenMLRecord`, `SenMLCborPackSerDes`) is what Leshan will likely keep at 2.0.0 GA — minor renames possible but the shape is stable.

**Bad**

- A milestone version is, by definition, not a final release. If a future M-release fixes a bug in the encoder, our committed `.bin` fixtures may be "wrong" relative to the new behaviour. We re-run the oracle and review the diff when we bump.

## Action items

- [x] Update [`tools/leshan_oracle/pom.xml`](../../tools/leshan_oracle/pom.xml) — `leshan-core:1.5.0` → `leshan-lwm2m-core:2.0.0-M18`.
- [x] Update [`tools/leshan_oracle/README.md`](../../tools/leshan_oracle/README.md) to reflect the 2.x rationale.

## References

- [Leshan 2.x release tags](https://github.com/eclipse-leshan/leshan/releases)
- [`tools/leshan_oracle/`](../../tools/leshan_oracle/)
