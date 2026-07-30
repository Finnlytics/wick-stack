# Decision Records

Architecture Decision Records (ADRs) for Wick. Each one documents a single technical decision and the context that motivated it.

## Why we keep these

The library is being built before the team that will own it exists. ADRs capture the *why* behind choices that future contributors will see in the code without context — keeping the rationale searchable rather than scattered across PRs, chat logs, or commit messages.

## Format

Each ADR is a single Markdown file numbered sequentially. Every record carries:

- **Status** — `Accepted` (current), `Superseded by ADR-N` (replaced), or `Reverted` (rolled back).
- **Context** — what we knew when the decision was made.
- **Decision** — what we chose.
- **Consequences** — what follows from the choice (good and bad).

Don't rewrite history. If a decision is wrong, write a new ADR that supersedes the old one and update the old one's Status line. Keep the old text intact.

## Index

| # | Title | Status |
|---|-------|--------|
| [0001](0001-zero-runtime-dependencies.md) | Zero runtime dependencies | Accepted |
| [0002](0002-oracle-pinned-to-leshan-2x.md) | Oracle pinned to Leshan 2.0.0-M18 | Accepted |
| [0003](0003-time-fields-as-plain-numbers.md) | SenML time fields encoded as plain numbers, not CBOR tag 4 | Accepted |
| [0004](0004-wick-coap-as-sibling-library.md) | `wick_coap` as a sibling library, not a Wick module | Accepted |
| [0005](0005-coap-option-tuples-at-the-wick-boundary.md) | CoAP option *numbers* are the Wick/transport boundary | Accepted |
| [0006](0006-single-repository-for-the-wick-stack.md) | One repository for the Wick stack | Accepted |
| [0007](0007-in-memory-stores-as-pure-data.md) | In-memory stores ship as pure data, not processes | Accepted |

WickCoap keeps its own log, numbered separately, at [`../../../wick_coap/docs/decisions/`](../../../wick_coap/docs/decisions/).
