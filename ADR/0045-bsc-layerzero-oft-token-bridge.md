# ADR-0045: Phase 1 Ethereum↔BSC LayerZero `SUSDfrOFT` token bridge

**Status:** Accepted and deployed on Ethereum and BNB Smart Chain (live November 2026; Phase 1
token bridge only — the standalone BSC credit instance in [ADR-0037](0037-bnb-smart-chain-instance-and-reserve-asset-admission.md)
remains unlaunched).

**Date:** 2026-11-09 (recorded 2026-11-25)

## Context

[ADR-0037](0037-bnb-smart-chain-instance-and-reserve-asset-admission.md) explored a separate,
independently backed credit protocol instance on BNB Smart Chain. Before undertaking multi-chain
credit origination and reserve segregation, Forest Road required a simpler way for `sUSDfr`
holders to hold and use canonical Ethereum-backed `sUSDfr` on BNB Smart Chain.

## Decision

1. **Lockbox-and-OFT token bridge only.** Deploy an immutable-backing Ethereum escrow adapter
   (`SUSDfrOFTAdapter`, `0x90224734d2c75580f074f0e818a997eb2ef824ab`) paired with a LayerZero V2
   OFT representation (`SUSDfrOFT`) on BNB Smart Chain (`0xde6d...1794`).
2. **Single-chain credit solvency preserved.** Every bridged BSC `sUSDfr` token is backed 1:1 by
   canonical `sUSDfr` locked in the Ethereum lockbox; no loans are originated on BSC and no
   additional `USDfr` or `sUSDfr` supply is created.
3. **Leaderboard exclusion.** The Ethereum lockbox address is excluded from personal wallet
   rankings on `/points` so aggregate bridged supply cannot distort individual participation ranks.

## Consequences

- Amends [ADR-0009](0009-ethereum-l1.md) strictly for cross-chain token representation without
  creating a multi-chain credit book.
- Documentation and address tables must clearly distinguish the live Ethereum↔BSC token bridge
  from the separate unlaunched BSC credit protocol (`ADR-0037`).
