# ADR-0017 — Credit-layer mechanics (Phase E implementation decisions)

**Status:** Accepted (made during implementation, 2026-07-09). Within the ADR-0004/
0014/0015 envelope; parameter defaults flagged to the pre-mainnet economic review.

> **SUPERSEDED FOR CLEAN MAINNET V1 BY ADR-0030.** This ADR remains as historical
> design context. The fresh v1 deployment has no DSRA, no class-level rate field, and no
> legacy unwind selectors.

> **SUPERSEDED IN PART BY ADR-0028 (2026-07-24):** automatic DSRA funding was
> retired. New interest routes `protocol fee → sUSDfr`; `dsraMonths = 0` for every
> launch class. DSRA custody functions remain only to unwind pre-existing escrow.

> **AMENDED 2026-07-24 (per-facility pricing):** annual interest is an explicit
> facility term. `ClaimBridge.originate` takes `interestRateBps`, stores it on that
> facility, and includes it in the 2-of-n `CreditIssued` terms commitment. The
> historical `ClassParams.interestTierBps` field remains in the upgradeable registry
> layout but is not a pricing authority for new originations. Collateral classes set
> risk-policy ceilings (LTV, maturity, concentration, and MTM controls); they do not
> dictate a common coupon for every borrower in the vertical.

> **AMENDED 2026-07-13 (post-campaign + audit R5):**
> - **DSRA fee (F-1):** `serviceFromDSRA` no longer re-charges the protocol fee on a DSRA
>   draw. The escrowed USDfr was already fee'd as gross interest in `_routeInterest`, so
>   the full draw now routes to senior (fee-once-on-gross). Any text below implying the
>   DSRA draw goes through the fee/senior split is superseded.
> - **Curator freeze-on-default (R4-EC2):** `CuratorModule.withdrawFirstLoss` freezes for a
>   class once a facility in it enters default (`declareDefault`/`liquidate` call
>   `freezeOnDefault`, incrementing a per-class counter); governance `liftDefaultFreeze`
>   reopens on workout resolution. `absorbLoss` is never frozen. The guaranteed
>   subordination floor was always locked; the freeze closes the discretionary
>   over-funding withdrawal window.
> - **`fundDSRA` (R5-FD1):** now `CREDIT_ROLE`-gated (was permissionless).

Phase E implements `CuratorModule`, `WaterfallEngine`, and `DefaultManager` against the
Phase A §4 interface specs. Four mechanics were under-specified there; this records how
they were resolved and why.

## 1. Curator first-loss pools: internal pro-rata shares with wipe-out rounds

Each class has one USDfr pool. Curators receive internal (non-transferable) shares;
`absorbLoss` reduces only the pool balance, so a partial absorption dilutes every
curator in the class exactly pro-rata with no iteration (no curator list to loop —
no gas ceiling on curator count). A pool absorbed to zero with shares outstanding
advances a **round**: stale-round shares are worth zero and are lazily cleared on the
holder's next post, so fresh capital is never diluted by dead shares.

Two provable properties (both comment-documented in code and fuzzed in
`CreditInvariants` / unit fuzz):
- **Share price never exceeds 1** (`totalShares >= balance`): only absorption moves
  the ratio, and only down; withdrawals burn ceil-rounded shares. Consequence: a
  zero-share mint is unreachable.
- **Withdrawal rounding favors the pool** (the senior side), never the withdrawer.

**Subordination headroom rule:** `required(class) = min(firstLossTarget, classExposure)`;
only `balance - required` is withdrawable. A fully repaid class frees all capital; live
exposure is protected up to the governance-set target ($10M/class default, ADR-0004).
Alternatives considered: require the full target always (rejected — locks capital with
an empty book); proportional-to-exposure percentage (rejected — a young class would be
under-protected exactly when the anchor commitment matters).

## 2. Waterfall ordering and the legacy DSRA lifecycle

`distribute(tokenId, interest, principal)`:
- **Principal** → `recordPrincipalReturn` + registry exposure decrease (backing
  composition shifts deployed → idle; nothing minted).
- **Interest** → protocol fee on gross (10% at launch,
  `Config.DEFAULT_PROTOCOL_FEE_BPS`) → every remaining unit to the sUSDfr vault
  (senior). Vault-level performance and management fees are separate and governed by
  ADR-0031.
- Conservation holds by construction and is asserted per fuzzed call against an
  independent model: `interest == fee + toVault`. The historical `dsraTopUp` event
  field remains ABI-compatible and is always zero.
- Lifecycle: first partial principal → Amortizing; outstanding hitting zero → Repaid.

**Legacy DSRA out-paths (wiring-gap closure):** with the Phase C test-era EOA grants revoked,
no production module could ever draw or refund DSRA (CREDIT_ROLE holds those paths).
Two tightly-scoped servicer functions close it, true to the DSRA's purpose:
- `serviceFromDSRA(tokenId, amount)` — debt service in disruption: routes the escrowed
  USDfr in full to senior with **no mint and no second protocol fee** (that USDfr was
  backed and fee-paid when originally created). Callable while performing or defaulted.
- `refundDSRA(tokenId, to)` — retained for upgrade-safe closeout compatibility. ADR-0028
  requires `to == sUSDfr`, and the closeout uses the vault's configured yield-recognition
  policy (instant at launch; optional smoothing if governance enables it).

**Funding lives in the waterfall** (`fund`): single-shot, exact-principal deployment
(normalized stable == originated principal), Pending → Active. Deployment is
distribution's inverse; giving it the same module keeps the treasury's CREDIT_ROLE
surface to two contracts.

## 3. Cascade execution order and the backstop contract

`realizeLoss` executes: layer-1 `curator.absorbLoss` → layer-2
`backstop.coverShortfall(residual)` → **all burns** (`burnLoss`) → the write-down →
exposure decrease, in ONE transaction. Burns run BEFORE `recordPrincipalWritedown` so
the ADR-0012 assertion inside every `burnLoss` sees supply falling against still-whole
backing; the write-down then drops backing by exactly what supply already fell.

`ICascadeBackstop.coverShortfall` (Phase H implements; Phase E mocks) must transfer
exactly `covered <= amount` USDfr to the caller within the call. DefaultManager
**enforces** this with a balance-delta check and reverts
(`DefaultManager_BackstopContractViolated`) on any misbehavior — the cascade's layer 2
is verified, not trusted. (Slither's `reentrancy-balance` hit on this pattern is the
enforcement working as designed: trusted governance-wired callee + `nonReentrant`.)

A loss exceeding curator + backstop + the vault's entire assets reverts loudly
(`DefaultManager_LossExceedsAbsorptionCapacity`) rather than silently impairing
unstaked USDfr — beyond-design-capacity insolvency is a governance decision, not an
accounting default.

## 4. Marked-to-market fast path details (ADR-0015 refinements)

- **Freshness asymmetry (protocol-protective):** protective triggers (`marginCall`,
  `liquidate`) accept the latest mark at any age; **curing** a margin call requires a
  fresh mark within the class `maxMarkAge`. A desk cannot escape a margin call on
  stale evidence, and withheld marks cannot block protective action.
- **Triggers are permissionless** — the attested mark is the entire evidence; the
  protocol only checks thresholds. Liquidation fires on hard breach
  (`ltv >= liquidationLtv`) or on cure expiry *still in margin-call breach* (a
  recovered LTV survives expiry).
- **Cure window:** per-class, default `Config.DEFAULT_MARGIN_CURE_WINDOW = 1 day`
  (ADR-0015 "hours-to-days"; economic-review item).
- **Pause policy:** only the permissionless triggers are guardian-pausable (the lever
  if marks are suspect). `declareDefault` / `accelerate` / `realizeLoss` /
  `absorbLoss` are deliberately never pausable — suppressing loss recognition is not
  an emergency remedy.

## Roles

New `SERVICER_ROLE` (funding, distribution, DSRA service/refund, default declaration,
loss realization) — Forest Road servicing keys until Phase G binds these paths to
attested facts; the role then gates who may *execute* an attested action, not what is
true. CREDIT_ROLE grants: WaterfallEngine + DefaultManager on treasury/controller/
registry/bridge; DefaultManager on CuratorModule (`absorbLoss`).
