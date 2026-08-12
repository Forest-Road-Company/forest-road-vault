# ADR-0014 — sGROVE backstop parameters

**Status:** Resolved (launch calibration); final numbers confirmed against Forest Road's
per-vertical loss history in the pre-mainnet economic review (brief Part 11 gate 5).
The per-event coverage-cap element is **superseded by ADR-0035**; the other parameters and locked
loss order remain in force.

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
- **Per-event coverage cap (superseded by ADR-0035):** the historical decision limited a shortfall
  event to 50%. The current mechanism has no event ceiling or snapshot: one event can exhaust the
  live USDfr coverage reserve, after which senior principal absorbs all subsequent loss until that
  reserve is replenished.
- **Rewards:** `sGROVE` stakers earn a governance-set share of protocol fees (modest
  initial rate) for bearing backstop risk.

## Alternatives
No backstop (depositors take second loss directly); unbounded slashing (one event drains
everything); larger/smaller targets.

## Rationale
The calibration was selected for a young protocol carrying real credit. ADR-0035 later reversed
the cap because fractional event limits produce order-dependent geometric decay rather than fair
multi-event allocation. The funded reserve remains finite and must not be represented as insurance.

## Consequences
- Cascade ordering is a named invariant — losses never skip or invert a layer
  (CLAUDE.md §1.3).
- The unbonding queue remains an exit, voting and obligation delay. Staked GROVE is not slashed;
  the separately funded USDfr reserve supplies layer two under ADR-0021/0035.
