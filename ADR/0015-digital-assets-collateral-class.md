# ADR-0015 — Digital Assets collateral class (marked-to-market, related-party)

**Status:** Resolved (Forest Road direction, 2026-07-09 — added mid-build). Economic
calibration (LTV/margin numbers) confirmed in the pre-mainnet economic review.

## Decision
Add a **fifth collateral class at launch: Digital Assets** — secured lending to Forest
Road's digital-assets trading subsidiary, financing the desk's trading book. This class
deliberately does **not** reuse the receivable model of the other four classes; it is a
**marked-to-market, volatile-liquid-collateral** class with margin mechanics:

- **Collateral:** a pledged portfolio of liquid crypto assets (eligible-asset list and
  per-asset haircuts governance-set), held under qualified custody / account control.
  Not a receivable; no UCC-foreclosure-and-secondary-sale remedy path.
- **Valuation:** frequent marks via the `AttestationOracle` `Valuation` path (m-of-n ≥ 2
  attesters), with a **freshness rule**: a facility whose latest mark is older than the
  class's `maxMarkAge` cannot draw, and its health checks use the last mark with an added
  staleness haircut. Backing contribution to `backingValue()` always uses conservative,
  haircut marks (ADR-0012).
- **Dynamic LTV / margin machinery** (replaces the single static LTV of receivable
  classes): three thresholds — `initialLtv` (draw ceiling), `marginCallLtv` (breach emits
  `MarginCalled`; short cure window to top up collateral or pay down), `liquidationLtv`
  (breach or cure-window expiry emits `LiquidationInitiated`). Crypto gaps; thresholds are
  set conservatively apart so the cascade is protected before impairment.
- **Remedy path:** margin-call → cure window → **liquidation of pledged collateral**
  (desk/custodian executes; proceeds attested back via `PaymentReceived` and routed
  through the waterfall). Hours-to-days, DeFi-liquidation-like — not months of legal
  enforcement. On-chain, `DefaultManager` gains a fast-path state flow for this class.
- **Related-party facility — disclosed, capped, reviewed:** the borrower is Forest Road's
  own subsidiary while Forest Road is also originator/servicer/anchor curator. Handled by:
  (a) plain disclosure in docs, risk page, and GitBook — never obscured; (b) on-chain
  per-borrower/per-class concentration caps; (c) arm's-length terms as an explicit counsel
  item; (d) a named item in the pre-mainnet economic review.

## Registry impact
`CollateralRegistry.ClassParams` gains a `collateralModel` discriminator
(`Receivable | MarkedToMarket`) and an optional margin-parameter extension
(`initialLtvBps`, `marginCallLtvBps`, `liquidationLtvBps`, `maxMarkAge`) used only by
marked-to-market classes. First-loss defaults extend to the fifth class:
$10M × 5 ≈ **$50M** anchor first-loss at full deployment (ADR-0004 amended).

## Alternatives
- Clone the receivable class and relabel (rejected — the model doesn't fit volatile
  liquid collateral, and pretending it does would misprice the risk).
- Exclude the vertical (rejected by Forest Road).
- On-chain-native collateralization (depositing crypto into the protocol itself) — a
  materially different custody/design surface; out of scope for v1, revisit later.

## Consequences
- ADR-0003 is amended: **five classes at genesis**, four receivable + one marked-to-market.
- Concentration-limit and cascade invariants now span five classes.
- The attestation layer's `Valuation` kind carries real load for this class; its m-of-n
  threshold and freshness rules are load-bearing, not decorative.
