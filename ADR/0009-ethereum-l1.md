# ADR-0009 — Chain: Ethereum L1, single-chain at launch

**Status:** Resolved; disposable mainnet test deployment authorized, production gated
(Forest Road, amended 2026-07-29).

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
