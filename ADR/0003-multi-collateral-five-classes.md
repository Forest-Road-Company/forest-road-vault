# ADR-0003 — Multi-collateral architecture; all FIVE classes live at launch

**Status:** Locked / Resolved (Forest Road). Do not reopen without Forest Road input.
**Amended 2026-07-09 (Forest Road direction):** a fifth class — **Digital Assets** — was
added mid-build. It uses a distinct marked-to-market collateral model, specified in
[ADR-0015](0015-digital-assets-collateral-class.md).

> **UPDATED BY ADR-0030 FOR CLEAN MAINNET V1.** Classes retain risk, maturity,
> concentration, and remedy parameters. Interest is signed per facility; class-level
> interest-tier and DSRA fields do not exist.

## Decision
`CollateralRegistry` parameterizes per-vertical collateral classes — film/TV tax credits,
renewable energy, life sciences, real estate, **and digital assets (ADR-0015)** — each
with its own LTV/margin parameters, max maturity, eligibility,
concentration limits, and default-remedy path.
All five classes are populated at genesis; none is a stub. Four are receivable-backed
(legal-enforcement remedies); the digital-assets class is marked-to-market
(margin-call/liquidation remedies).

## Alternatives
- Single-class v1 (film credits) then progressive addition.
- Hardcoded per-class contracts instead of a parameterized registry.

## Rationale
Diversification across uncorrelated classes is the product's differentiator vs.
single-sector protocols. Forest Road confirmed the full multi-vertical launch, and
directed the addition of the digital-assets class mid-build.

## Consequences
- Heavier launch scope: per-class origination, attestation kinds, and remedy paths are all
  built and tested before mainnet — including the distinct margin/liquidation path.
- Concentration limits (per vertical, per state, per borrower) are enforced on-chain at
  origination and encoded as an invariant (CLAUDE.md §1.3), spanning all five classes.
- The registry schema carries a `collateralModel` discriminator so receivable and
  marked-to-market classes are typed, not special-cased by ID.
