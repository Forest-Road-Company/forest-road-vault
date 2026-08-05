# ADR-0006 — Loan positions as ERC-721 NFTs (`ClaimBridge`)

**Status:** Accepted.

> **UPDATED BY ADR-0030 FOR CLEAN MAINNET V1.** The facility has no DSRA
> reference. It carries complete signed per-facility economics, payment schedule,
> funding recipient, legal reference, and the `Resolved`/`Cancelled` terminal states.

## Decision
Each financed facility is an ERC-721 token carrying: collateral class, principal, LTV,
per-facility contractual interest rate, maturity/amortization data, funding recipient, off-chain
lien/assignment reference, attestation requirements, and a guarded lifecycle state machine
(`Pending → Active → Amortizing → Repaid | Defaulted → Accelerated → Resolved`;
an unfunded pending position may be `Cancelled` and burned).

## Alternatives
- ERC-1155 (positions are unique, not semi-fungible — wrong fit).
- Plain struct registry without tokens (loses the enforceable-claim representation and
  transferability of the position).

## Rationale
Faithful to CALIBER: the NFT is the on-chain representation of a perfected off-chain legal
claim. Discrete tokens give clean per-position events, custody, and enforcement handles.

## Consequences
- Minting is gated on required attestations AND on-chain conditions (the synchronized-mint
  invariant, CLAUDE.md §1.3).
- State transitions are restricted to authorized modules and each emits an event; the
  register must be reconstructable purely from events.
- Transfers of the NFT are restricted (compliance + the SPV legal wrapper define who may
  hold positions).
