# ADR-0014 — sGROVE backstop parameters

**Status:** Resolved (launch calibration); final numbers confirmed against Forest Road's
per-vertical loss history in the pre-mainnet economic review (brief Part 11 gate 5).

## Decision
`sGROVE` is the second loss-absorption layer. **Loss order (locked):**

```
curator first-loss ($10M/class) → sGROVE backstop → sUSDfr (depositor) principal
```

Launch calibration (all governance-adjustable):
- **Target size:** 10% of total deployed principal, protocol-wide — a target/floor
  governance steers toward via emissions/fees, not a hard mint cap.
- **Initial seed:** ~$5M Forest Road contribution, growing toward target as the book
  scales.
- **Unbonding:** 21 days for `sGROVE → GROVE` (stakers cannot front-run a known loss).
- **Per-event coverage cap:** ≤50% of staked `sGROVE` drawn per shortfall event,
  preserving residual backstop for subsequent events.
- **Rewards:** `sGROVE` stakers earn a governance-set share of protocol fees (modest
  initial rate) for bearing backstop risk.

## Alternatives
No backstop (depositors take second loss directly); unbounded slashing (one event drains
everything); larger/smaller targets.

## Rationale
Conservative, standard-range values for a young protocol carrying real credit: a real but
bounded backstop that protects depositors without over-promising, with cooldowns/caps that
prevent gaming and preserve coverage across multiple events.

## Consequences
- Cascade ordering is a named invariant — losses never skip or invert a layer
  (CLAUDE.md §1.3).
- The unbonding queue and the per-event cap interact: pending unbonds remain slashable
  until the cooldown completes (else the cooldown is decorative). Encoded in tests.
