# ADR-0012 — On-chain backing-invariant enforcement

**Status:** Accepted.

> **UPDATED BY ADR-0030 FOR CLEAN MAINNET V1.** Backing is accounted canonical USDC
> plus outstanding deployed principal. Reserve instruments and a generic stable registry
> are not part of the fresh v1 deployment.

## Decision
`MintRedeemController` enforces, as a hard on-chain check on every supply-affecting
operation:

```
USDfr.totalSupply() <= backingValue()
```

where clean-v1 `backingValue()` = accounted idle USDC + outstanding deployed principal.
Direct token donations do not create backing; custody reconciliation may only mark the
idle ledger down. Violation reverts with a custom error. The
invariant is additionally encoded as a stateful fuzz test held across all reachable
states (CLAUDE.md §1.3) and is a candidate for symbolic checking (§1.5).

## Alternatives
- Soft/off-chain accounting with monitoring (silent divergence risk — rejected).

## Rationale
The peg's integrity is foundational; an unbacked synthetic dollar is the one failure mode
that destroys everything else. Enforcement belongs in the state machine, not a dashboard.

## Consequences
- Marked-to-market valuations govern funding and remedy/LTV actions; they do not inflate
  the USDfr backing ledger. See ADR-0030.
- Loss events must write down backing *and* flow through the cascade in the same
  transaction so the invariant cannot be transiently violated.
