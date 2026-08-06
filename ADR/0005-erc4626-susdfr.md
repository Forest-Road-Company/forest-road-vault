# ADR-0005 — ERC-4626 for sUSDfr

**Status:** Accepted.

## Decision
`sUSDfr` is an ERC-4626 vault over `USDfr` (OpenZeppelin implementation as base). Yield
accrues via the assets/shares exchange rate. Withdrawals are routed through the epoch
redemption queue (ADR-0010) rather than the vault's instant `withdraw`/`redeem` paths,
which are restricted accordingly.

## Alternatives
- Bespoke rebasing token (non-standard, integration-hostile, harder to audit).
- Reward-index (claim-and-distribute) token.

## Rationale
Standard, composable, well-audited; `currentExchangeRate()` (equivalent to
`convertToAssets(10 ** decimals())`) gives the dashboard a clean whole-share
exchange-rate read; matches USD.AI's ratio-accrual model.

## Consequences
- Donation/inflation-attack surface is handled with OZ's decimal-offset defense plus a
  seeded initial deposit in deployment scripts; covered by tests.
- Instant-exit ERC-4626 functions revert with a custom error pointing to the queue.
- Fee-net exchange-rate integrity absent credit loss or a protocol fee becoming due is
  a named invariant (CLAUDE.md §1.3). ADR-0031 conversions simulate pending fee shares,
  so quotes match the checkpointed transaction; crystallization is evented and removes
  no backing asset.
