# ADR-0001 — Identified-per-asset collateral, not a discretionary blind pool

**Status:** Locked (brief Part 4). Do not reopen without Forest Road input.

## Decision
Every deployed dollar maps to an *identified*, tokenized, lien-perfected position: a
`ClaimBridge` ERC-721 facility with an off-chain reference (UCC filing, SPV series,
escrow) and required attestations. Deployment control is exercised at the underwriting
level (which facilities Forest Road originates), never as ongoing manager discretion over
a pooled balance.

## Alternatives
- Discretionary blind pool (manager deploys pooled capital at will).
- Hybrid (identified core + discretionary sleeve).

## Rationale
Faithful to USD.AI's per-asset CALIBER model; backing is verifiable position-by-position
on-chain; materially cleaner transparency and regulatory posture than a blind pool.

## Consequences
- No contract may move reserve capital into lending except against a specific, already
  originated facility NFT.
- The transparency dashboard can (and must) reconcile backing per position.
- `MintRedeemController.backingValue()` sums identified positions at conservative marks
  plus reserves — never a manager-asserted NAV.
