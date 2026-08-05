# ADR-0010 — Epoch FIFO redemption queue (QEV analog)

**Status:** Accepted.

## Decision
`sUSDfr` redemptions enter an epoch-based FIFO queue. At each epoch close, available
`USDfr` liquidity is distributed to queued requests strictly in order. Queue parameters
(epoch length, per-epoch liquidity policy) are governance-set; the design leaves room for
per-class parameters given the blended multi-maturity book (brief Difference 4).

## Alternatives
- Instant redemption (impossible against an illiquid amortizing book — a bank-run design).
- Auction/market-clearing (USD.AI's fuller QEV) — more capital-efficient, materially more
  complex; a v2 evolution path.

## Rationale
FIFO is the simplest honest v1: predictable, fair, easy to reason about and to prove
invariants over (never over-distribute; FIFO ordering holds; no double-claim —
CLAUDE.md §1.3).

## Consequences
- The frontend must always present redemption as queued with an estimated fill — never
  instant (brief §8.3).
- Shares are escrowed on request (a queued redeemer stops earning on queued shares only
  per the final spec — decided at implementation and documented).
- Value of a queued request is fixed or floating per spec decision at implementation;
  either way it is explicit, evented, and tested.
