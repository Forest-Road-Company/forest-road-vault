# ADR-0009 — Chain: Ethereum L1, single-chain at launch

**Status:** Deployed on Ethereum L1 (V2 live since September 2026, block 26,006,832). Amended in
part by [ADR-0045](0045-bsc-layerzero-oft-token-bridge.md) (Phase 1 Ethereum↔BSC LayerZero
`SUSDfrOFT` token bridge, live November 2026); the separate BSC credit instance in
[ADR-0037](0037-bnb-smart-chain-instance-and-reserve-asset-admission.md) remains unlaunched.

## Decision
Ethereum L1 only for v1. Build and QA targets are local Anvil and Sepolia testnet.
Fail-closed production preparation and validation are in scope. Forest Road owner
direction dated 2026-07-29 permits a qualified human operator to make a disposable,
pre-audit Ethereum-mainnet deployment for controlled testing through
`docs/MAINNET_LAUNCH_RUNBOOK.md`. It may use only controlled wallets and an approved test
budget, and it may not accept third-party capital or represent a real facility or legal
claim. Audit remediation is expected; production therefore requires a fresh post-audit
deployment with a new authorization receipt and addresses. Coding agents may not
broadcast or move real value.

## Alternatives
- L2 (Arbitrum/Base) — cheaper, but thinner institutional custody support.
- Multi-chain — adds a cross-chain messaging surface to secure, unjustified in v1.

## Rationale
Deepest RWA/institutional-custody support and liquidity; no bridge risk; matches an
institutional credit product. Gas costs are acceptable for a protocol whose transactions
are infrequent and large. Multi-chain/L2 is a possible later expansion.
