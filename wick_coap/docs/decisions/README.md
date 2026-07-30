# Decision Records

Architecture Decision Records (ADRs) for WickCoap.

The architectural split between Wick (LwM2M primitives) and WickCoap (CoAP wire format and runtime) is documented in [Wick ADR 0004](https://github.com/Finnlytics/wick/blob/main/docs/decisions/0004-wick-coap-as-sibling-library.md). The numbering here starts fresh at 0001 — WickCoap's own decisions, not a continuation of Wick's.

## Format

Each ADR is a single Markdown file numbered sequentially. Every record carries:

- **Status** — `Accepted` (current), `Superseded by ADR-N` (replaced), or `Reverted` (rolled back).
- **Context** — what we knew when the decision was made.
- **Decision** — what we chose.
- **Consequences** — what follows from the choice (good and bad).

## Index

*(empty — first decision will land with the first non-trivial choice)*
