# ADR-0002 — Variable-yield pass-through, not a fixed-rate obligation

**Status:** Locked (brief Part 4). Do not reopen without Forest Road input.

## Decision
`sUSDfr` accrues the *actual* performance of the loan book plus reserve yield via a rising
ERC-4626 exchange rate. The protocol never promises, encodes, or implies a fixed return;
Forest Road does not issue a fixed-rate note.

## Alternatives
- Fixed-rate obligation backed by the book (explicitly out of scope — a materially more
  security-like, issuer-credit-dependent instrument).
- Hybrid fixed/floating tranches.

## Rationale
Depositors bear asset performance, faithful to sUSDai. A fixed-rate promise would change
the instrument's character and create an uncovered obligation in underperformance.

## Consequences
- No APR/APY constant exists anywhere in the contracts.
- The frontend/docs present yield as trailing/realized, computed from exchange-rate
  history, and label it variable everywhere (brief §8.6).
- Losses beyond the cascade's junior layers reduce the exchange rate — visibly, via
  events, never silently.
