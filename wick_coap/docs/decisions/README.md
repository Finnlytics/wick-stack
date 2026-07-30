# Decision Records

Architecture Decision Records (ADRs) for WickCoap.

The architectural split between Wick (LwM2M primitives) and WickCoap (CoAP wire format and runtime) is documented in [Wick ADR 0004](../../../wick/docs/decisions/0004-wick-coap-as-sibling-library.md). The numbering here starts fresh at 0001 — WickCoap's own decisions, not a continuation of Wick's.

Both libraries live in the same repository ([Wick ADR 0006](../../../wick/docs/decisions/0006-single-repository-for-the-wick-stack.md)) while remaining separate packages, so cross-references between the two logs are relative paths.

## Format

Each ADR is a single Markdown file numbered sequentially. Every record carries:

- **Status** — `Accepted` (current), `Superseded by ADR-N` (replaced), or `Reverted` (rolled back).
- **Context** — what we knew when the decision was made.
- **Decision** — what we chose.
- **Consequences** — what follows from the choice (good and bad).

Don't rewrite history. If a decision turns out to be wrong, write a new ADR that supersedes the old one and update the old one's Status line. Keep the old text intact.

## Index

| # | Title | Status |
|---|-------|--------|
| [0001](0001-hand-written-coap-rather-than-forking.md) | Hand-written CoAP with zero runtime dependencies, rather than forking | Accepted |
| [0002](0002-dtls-via-otp-ssl.md) | DTLS via OTP `:ssl`, accepting two missing extensions | Accepted |
| [0003](0003-observe-relations-keyed-by-path.md) | Server-side Observe relations are keyed by `{peer, uri_path}` | Accepted |
