# ADR-0043: Morpho Blue USDC/sUSDfr market and immutable exit-value oracle

**Status:** Accepted and deployed on Ethereum mainnet (Oracle and market deployed October 2026;
lending, borrowing and Treasury supply active on `/markets`; audited `ee9b228a` liquidation-bot
update rolled out and live-verified on 25 November 2026 — `FRV-NEW-02` retained Open in external
audit register pending independent confirmation).

**Date:** 2026-10-21 (recorded 2026-11-25)

## Context

Holders of `sUSDfr` face a 21-day redemption cooldown and a daily FIFO liquidity budget in
`RedemptionQueue` (ADR-0018, ADR-0022). Rather than introducing instant exits that could force
fire sales or invert the loss cascade, Forest Road integrated an isolated Morpho Blue market
lending canonical USDC against `sUSDfr` collateral at an 86% LLTV with the adaptive curve IRM.

## Decision

1. **Immutable, roleless exit-value oracle (`SUSDfrExitValueOracle`).** The market prices
   `sUSDfr` using the *minimum* of the vault's live queue exit value (`previewRedeem`, net of
   declared senior impairment after curator and `sGROVE` capacity) and the backing floor
   (realized NAV × recognized backing / supply) — never their product (which would double-count
   a declared, reserve-marked loss).
2. **Fail-closed custody & source posture.** The oracle reverts whenever a custody shortfall is
   open, a custody-loss arm awaits ratification, the vault's impairment source is cleared, or a
   referenced read fails, preventing borrows and liquidations against mispriced collateral.
3. **Bounded liquidation bot.** An off-chain liquidation bot operating under an AWS KMS
   policy-restricted signer (see [ADR-0046](0046-aws-kms-policy-signers-for-keepers.md)) enforces
   strict per-liquidation and UTC-daily USDC caps, simulates every transaction, checks oracle
   liveness and sweeps seized `sUSDfr` to the Treasury Safe.
4. **Server-evaluated UI launch switches.** The `/markets` interface gates lending, borrowing and
   Treasury supply through server-evaluated switches (`/api/morpho/launch`) and five-minute quote
   expiry ([ADR-0041](0041-morpho-quote-issuance-and-expiry.md)).

## Consequences

- `sUSDfr` holders gain a venue for USDC liquidity without weakening `RedemptionQueue` protections.
- Because a Morpho market's oracle is fixed at creation and reads ~10 upgradeable protocol modules,
  every core protocol upgrade must re-run the oracle fork verification suite before execution.
- A discrete declared default step can exceed the 86% LLTV liquidation buffer; market parameters
  and borrower disclosures state this explicitly.
