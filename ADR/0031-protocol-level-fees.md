# ADR-0031 — Protocol-level interest, performance, and management fees

**Status:** Locked (Forest Road, 2026-07-29), with the global-HWM round-trip
tradeoff explicitly accepted on 2026-07-30.

## Decision

Mainnet v1 uses three distinct protocol-fee layers:

1. **Interest fee — 10% at launch.** `WaterfallEngine` deducts 1,000 bps from
   realized gross facility interest before the remainder is delivered to `sUSDfr`.
   This is the existing interest fee and remains a timelocked governance parameter.
2. **Performance fee — 10% at launch, prospectively variable from 0% to 20%.**
   `sUSDfr` charges positive performance-fee NAV above a single protocol-wide,
   post-fee high-water mark. Performance-fee NAV is conservative credit NAV with
   temporary curator/sGROVE capital excluded from profit; it is defined precisely
   below. Timelocked governance may change the rate through `setPerformanceFee`.
   The old rate crystallizes before the new rate takes effect, so a change cannot
   reprice past gains. The 2,000-bps v1 ceiling requires an implementation upgrade
   to change.
3. **Management fee — 0% at launch, prospectively variable from 0% to 2% per
   365-day year.** Timelocked governance may change the rate after launch through
   `setManagementFee`. The old rate is accrued before the new rate takes effect, so
   no change applies retroactively. The 200-bps v1 ceiling can be changed only by an
   implementation upgrade. Annual retention is applied geometrically over fractional
   years, so extra permissionless checkpoints do not materially alter the fee when the
   fee base is unchanged.

Performance and management fees are paid by minting new `sUSDfr` shares to the
same protocol `feeRecipient`; no `USDfr` leaves the vault and the backing invariant
is unchanged. Management is calculated first. Performance is then the current
governance rate (10% at launch) applied to profit remaining after the management
fee, so the protocol does not charge performance fees on its own newly minted
management-fee shares.

## Performance-fee basis

The fee is deliberately **protocol-wide, not per investor**:

- redemption pricing continues to use `redemptionTotalAssets() =
  totalAssets() - pendingSeniorImpairment()`, where the impairment is net of
  available curator and sGROVE protection;
- performance fees instead use `totalAssets() - performanceFeeImpairment()`.
  `DefaultManager.performanceFeeImpairment()` is gross live declared/past-due
  impairment before temporary curator or sGROVE capacity is netted. The mandatory
  assessed wrapper may recognize supported recovery, but snapshots the junior-capital
  credit standing when the assessment is published. The interface requires
  `performanceFeeImpairment() >= pendingSeniorImpairment()`;
- the hurdle is one global `highWaterMark`, expressed as marked NAV per whole
  `sUSDfr` token;
- after a profitable crystallization, the high-water mark resets to the post-fee
  marked-NAV rate and is never lowered by investment loss or management-fee
  dilution;
- recovery to a previously charged peak is fee-free; only value above that peak is
  charged again;
- the economically relevant hurdle is asset-denominated. A deposit adds exactly the
  delivered principal. An exit retains the greater of (a) the old hurdle less assets
  paid and (b) the old hurdle multiplied by the remaining effective-supply fraction.
  The asset carry protects stayers in a genuine drawdown; the pro-rata carry applies
  when junior-supported redemption NAV exceeds performance-fee NAV, so the leaver
  cannot transfer its deferred performance-fee liability to stayers. The result is
  converted back to the stored per-share HWM with upward rounding;
- junior-capacity changes never mutate the HWM. They can improve redemption pricing,
  but cannot improve performance-fee NAV because contributed loss protection is not
  investment profit. Their begin/end bracket checkpoints immediately before the
  change and holds the vault fee lock across it;
- valuation-source rewiring and upward rounding dust may ratchet the hurdle upward
  without a fee, so operational accounting changes are not treated as investment
  performance.

This is not personal tax-lot or personal profit accounting. A depositor who enters
while the protocol is below its old high-water mark shares the fee-free recovery
to that mark. If pre-entry gains are hidden below the hurdle by a live performance
impairment and are recognized later above the global hurdle, however, the entrant
shares that later fee even when temporary junior capital made the queued-exit
impairment zero at entry. The staking UI must therefore disclose a live
`feeExchangeRate() < highWaterMark()` state independently of the redemption-impairment
warning. Transfers need no cost-basis storage and do not create a new fee series. A
true per-wallet high-water mark would require non-fungible lots, restricted transfers,
or share classes and was rejected in favor of the scalable global model.

## Crystallization and ordering

`accrueFees()` is permissionless. It is also called before every operation that can
change ownership, exit pricing, realized yield, or a directly managed impairment:

- vault deposit, mint, queue admission, queue settlement, withdraw, and redeem;
- waterfall repayment distribution, before new senior yield is delivered;
- default declaration, past-due marking/cure, liquidation, and realized loss;
- curator first-loss posts/withdrawals, sGROVE coverage funding/cap changes, and
  DefaultManager backstop replacement, using a checkpoint-plus-lock fee-neutral
  bracket. The bracket never derives accounting from a free-running NAV re-read;
- performance-fee, management-fee, fee-recipient, impairment-source, and
  yield-vesting changes.

Every positive senior-interest delivery also ends with a second explicit checkpoint
after `notifyYield` closes the delivery lock. With the zero-period launch policy this
is the checkpoint that crystallizes the newly realized performance fee in the same
repayment transaction. If governance later enables optional vesting, the post-delivery
checkpoint charges only fee amounts already economically due; future streamed release
remains available to later permissionless checkpoints.

The sole exception is `clearUnreadableImpairmentSource()`, a timelocked recovery path
for a source whose fixed-budget `pendingSeniorImpairment()` or
`performanceFeeImpairment()` read fails, returns malformed data, or violates the required
`performanceFeeImpairment >= pendingSeniorImpairment` ordering. Each selector gets a
200,000-gas probe and the transaction must retain a separate 150,000-gas recovery reserve,
so under-gassing cannot make a healthy source appear broken. A source readable through
both selectors cannot use that path. Recovery clears only to zero, never installs a
replacement, skips the impossible old-source checkpoint, and ratchets the resulting NAV
increase into the HWM fee-free. Normal source changes validate both selectors on the
replacement and remain checkpointed. This emergency ratchet permanently waives any
performance fee embedded in the lifted mark; that under-collection is an explicit
incident-response trade-off, not an ordinary source-update path.

The vault's upgrade-safe reentrancy guard covers the complete deposit/exit and fee
checkpoint frames, including the underlying USDfr transfer before deposit shares are
minted. Independent fee/share-update locks preserve a specific fail-open rejection if
the points callback tries to checkpoint during a transient ERC-20 share mint, burn, or
transfer. HWM effects are committed before a fee-share mint reaches that callback.
For yield delivery, `WaterfallEngine` first acquires a persistent lock in the vault,
then mints both interest legs; `notifyYield` consumes that same lock after the vault
delivery, and the engine immediately calls `accrueFees`. The engine's own
`nonReentrant` state is not treated as protection for a different contract. If a
faulty or compromised trusted module ever commits a begin call without its paired end,
timelocked governance can call `clearStaleFeeOperation`; the recovery is evented and
does not change NAV or the HWM. Ordinary share transfers do not checkpoint because
they change neither NAV nor supply.

Fees are economically continuous but crystallized lazily at these checkpoints.
Once fee shares have been minted there is no clawback. Permissionless
crystallization prevents an administrator or exiting holder from indefinitely
choosing whether a due fee is recognized.

All ERC-4626 conversion and exit previews simulate the shares that would be minted
if fees were checkpointed at the current timestamp. `currentExchangeRate()` is
therefore fee-net even before a state-changing checkpoint, and the later share mint
must not create a second price jump. `feeExchangeRate()` is the separate
performance-fee NAV rate used to test the HWM; it excludes temporary junior-capital
credit even when that credit improves the exit price. With a non-zero management fee,
the fee-net rate can decline predictably with elapsed time even before the
crystallization event; the current rate, cap, last checkpoint, and eventual mint are
all public.

## Worked examples

With no management fee and no loss:

- if marked NAV rises from 1.00 to 1.20 above the applicable global hurdle, the
  10% fee on 0.20 of profit leaves existing holders with 1.18 per original share;
- if the applicable global hurdle and starting NAV are 0.50 and NAV rises to 0.60,
  the fee is 0.01 and existing holders retain 0.59. If the protocol-wide high-water
  mark is still above 0.60, however, that recovery is fee-free.

For a facility earning 20% gross interest on 1,000:

| Leg | Amount |
|---|---:|
| Gross facility interest | 200 |
| 10% interest fee | 20 |
| Senior yield delivered to `sUSDfr` | 180 |
| 10% performance fee on that 180 of profit | 18 |
| Net incremental depositor NAV, before management fee | 162 (16.2%) |

At launch the senior receipt enters marked NAV immediately and the performance fee is
minted in the same repayment transaction. If governance later enables optional
vesting, the fee arises only as that already-realized receipt enters marked NAV. It is
never charged on expected or unreceived facility income.

## Accepted global-HWM composition tradeoff

A single pooled scalar cannot simultaneously guarantee all three of the following for
freely transferable shares: basis-additive entry, pro-rata basis removal on exit, and
an exactly HWM-neutral exit/redeposit round trip when an entrant or leaver transacts
above the pooled performance-fee basis.

Forest Road chose the holder-protective rule already specified above and, on
2026-07-30, explicitly accepted the resulting protocol-revenue residual:

- no launch exit-equalization fee or personal tax-lot system is added;
- an incumbent who serves the 21-day queue cooldown, exits during a junior-covered
  deferral, and redeposits the proceeds can raise the pooled hurdle and reduce the
  protocol's later performance fee;
- the direction is under-collection by the protocol, not an overcharge to remaining
  holders; the per-share HWM cannot fall across the exit;
- the behavior is pinned in
  `test_acceptedGlobalHwmRoundTripUndercollectsButCannotOverchargeHolders`;
- monitoring should quantify deferred profit and material queue/redeposit activity.
  If lost revenue becomes material, the economic decision must be reopened as an
  equalization-credit, lot, share-class, or exit-fee design—not patched by weakening
  the holder-protection invariant.

## Accepted fee-share denomination tradeoff

The performance fee is MEASURED on the gross performance base (realized assets less the
gross declared/past-due mark, junior capital excluded) but the settling share mint is
SIZED on the conservative redemption base (realized assets less the junior-netted mark).
Those shares then dilute the realized base that `currentExchangeRate()` reports. Three
bases; the mint sits on the middle one.

Neither denomination is correct in both terminal branches, which is why this is a policy
choice rather than a defect to patch. Sizing on the redemption base is exactly right if
the mark later REALIZES as a senior loss, and over-collects if the mark CURES. Sizing on
the realized base is exactly right on a cure and under-collects on a realization.

Forest Road, on 2026-07-30, chose to retain redemption-base sizing and accept the
residual. **The bound recorded at acceptance was wrong and was corrected on 2026-07-30
after an independent review round; the corrected statement follows.** The economic choice
is unchanged — the error was in the characterisation of when and how far the effect bites,
not in the decision itself.

### The general condition

Write `a` for the realized base plus one, `r` for the redemption base plus one, `f` for the
performance rate, `Delta_a` for the realized-asset gain across the step, and `d` for the
deferred profit released by it. The reported rate falls when

    Delta_a * (r - f*d)  <  a * f * d

A single crystallization lowers the rate by exactly
`feeAssets / (redemptionTotalAssets() + 1)`, bounded by `f` because
`_performanceFeeTotalAssets() <= redemptionTotalAssets()` is enforced.

Two families satisfy that inequality. The originally recorded bound described only the
first:

- **Payment-driven.** A repayment moves realized assets and deferred profit together, so
  `Delta_a = d = y` and the condition collapses to `r < f*a` together with
  `y < (f*a - r)/(1 - f)`. This needs a deep mark AND a small payment; large legs raise the
  rate normally. Worst case over all payment sizes is 0.92% at a redemption base of 5% of
  realized assets, and 8.18% at a 99.9% markdown — **both figures at the 1,000-bps launch
  rate.** They are NOT fee-rate independent, as originally written: at the
  `MAX_PERFORMANCE_FEE_BPS` ceiling of 2,000 bps the same two states give **5.56%** and
  **17.5%**. Governance can reach that ceiling through `setPerformanceFee` with no
  implementation upgrade, which sextuples the accepted worst case without re-acceptance.
- **Mark release, which is the dominant family.** `_performanceFeeTotalAssets()` subtracts
  a PRINCIPAL pool that shrinks with no vault cash — a repayment's principal leg books to
  the ReserveManager, never to the vault. A cure therefore has `Delta_a = 0` with `d > 0`,
  and at `Delta_a = 0` the inequality holds for **every** `r`, including `r = a`. There is
  no depth precondition at all. The fall is `f*d/r`, bounded by `f`. Every release path
  checkpoints BEFORE the release and never after (`clearPastDue`, `realizeLoss`, and the
  `distribute` lifecycle hooks), and the high-water mark is never ratcheted down by a mark,
  so yield earned under the mark accrues fee-free and crystallizes in one step on release.
  This is instantiated at **5.00% with `r/a = 100%`** by the repository's own passing
  `test_acceptedGlobalHwmRoundTripUndercollectsButCannotOverchargeHolders`.

### What is accepted, and how it is monitored

- both families are accepted; the economic choice is retained;
- the behaviour is pinned, with controls, in
  `contracts/test/audit/R14_01-FeeShareMintBasis.t.sol` (payment-driven) and
  `contracts/test/integration/FeeStackFlow.t.sol` (mark release). These are
  characterization tests of accepted behaviour: if the denomination is ever changed they
  must be inverted, not deleted;
- **monitoring must alert on any release of `performanceFeeImpairment()` — a cure,
  resolution, recovery or realized loss — and quantify the fee crystallized against it.**
  The originally recorded trigger, "alert when the redemption base falls below
  `performanceFeeBps` of the realized base", is the necessary condition for the
  payment-driven family ONLY. It is blind to mark release, which is unconditional in `r`
  and is where the larger fall occurs, so it must not be relied on alone;
- monitoring must treat any `setPerformanceFee` increase as re-opening this acceptance,
  because the accepted magnitudes are stated at 1,000 bps and scale with the rate.

If either family produces a materially larger fall in production than the figures above,
the economic decision must be reopened as a denomination choice — not patched by loosening
the rate-integrity invariant.

**Open assurance item, recorded rather than fixed.** Tightening
`invariant_exchangeRate_neverFallsWithoutLossOrFee` so its performance-fee slack applies
only inside the accepted regime was attempted on 2026-07-30 and NOT shipped. Two gates were
tried — the payment-driven necessary condition `r < f*a`, and the weaker "a mark is live at
all" — and both turned the campaign red against a baseline green at 256 runs / 32,768 calls.

The review round that corrected the bound above also explains that failure, and corrects a
second error in the original note. The flat `1 - performanceFeeBps` slack is **tight for a
single checkpoint, not loose** — the single-checkpoint fall is exactly
`feeAssets / (redemptionTotalAssets() + 1)`. What it absorbs is the compounding of several
checkpoints inside one ghost-floor epoch. And the "a mark is live" gate fails for a reason
worth recording: on a full cure `performanceFeeImpairment()` reads ZERO at the moment the
invariant evaluates, so the evidence the gate depends on is destroyed by the very
transition that produced the fall. A correct in-code bound must be anchored to a value
captured BEFORE the release, not read afterwards.

Until that work is done the invariant cannot be relied on to detect this class, and the
mark-release alert above is the operative control, not the test suite.


## Governance and operational requirements

- `feeRecipient` must remain protocol-exempt in `ComplianceRegistry`; otherwise
  future fee-share mints could be blocked. Fresh initialization enforces the exemption.
  A recipient rotation validates and installs the replacement before checkpointing, so a
  blocked/non-exempt old recipient cannot brick recovery; any fee pending at rotation
  mints to the replacement.
- `WaterfallEngine.feeRecipient` and `sUSDfr.feeRecipient` are separate storage
  values because they receive different token legs. Governance must change them in
  one timelock batch and monitoring must alert on any mismatch. Deployment
  validation pins both to the manifest value.
- `DefaultManager.setBackstop` requires ERC-165 support for the complete
  `ICascadeBackstop` surface and probes `coverageCapacity()` with bounded gas. A
  readable outgoing backstop is checkpointed
  before rotation, so elapsed management fees use the outgoing redemption NAV. Only an
  unreadable outgoing backstop takes the effects-first repair path; in that incident
  case the elapsed management fee necessarily uses the incoming NAV. Performance-fee
  NAV is independent of backstop capacity. Treat the fallback path during a live
  impairment as an incident/governance valuation event.
- A legacy proxy whose HWM slot is zero seeds the fee-free baseline from
  `totalAssets()`, not either impairment-reduced NAV. This prevents an in-place
  upgrade during a live pending or gross impairment from charging pre-upgrade value
  when the mark later cures, while a realized loss still lands below the hurdle.
- Dual-NAV upgrades have an executable dependency order:
  `DefaultManager` first, then `AssessedImpairmentSource`, then `sUSDfr`. The wrapper
  refuses to upgrade unless its base exposes the complete revisioned source surface,
  and the vault refuses unless its installed wrapper exposes both impairment views.
  Execute the sequence atomically through one timelock batch.
- Monitoring must index `ManagementFeeAccrued`, `PerformanceFeeAccrued`,
  `HighWaterMarkAdjusted`, `PerformanceFeeSet`, `ManagementFeeSet`, and
  `VaultFeeRecipientSet`, and `FeeOperationEmergencyCleared`, and read the current
  rates and hard caps, high-water mark, last accrual timestamp, and both recipients.
- Direct `USDfr` donations are indistinguishable from economic gain and may be
  performance-fee-bearing at the next checkpoint.
- A professional assessed-recovery update can move both redemption NAV and
  performance-fee NAV between checkpoints. The performance-fee view adds the
  junior-capital credit snapshotted at publication to the submitted assessed senior
  impairment, so later capacity changes cannot manufacture profit. Because the
  assessment is a trusted timelocked valuation input, its timing and evidence policy
  remain part of the governance/valuation trust model and must be monitored.
- Monitoring must alert on `ImpairmentSourceEmergencyCleared` and
  `ImpairmentSourceUpdated(0)`. After an emergency clear, governance must investigate
  the failed source, quantify and disclose the permanently waived fee on the lifted
  mark, and wire a validated replacement through the normal setter before resuming
  production operations.

## Alternatives considered

- **Per-investor high-water marks.** More exact for individual entry prices, but
  incompatible with freely fungible/transferrable ERC-20 shares without lots,
  equalization credits, or separate share classes. Considerably larger accounting,
  integration, and audit surface.
- **Charge performance on each deposit/withdrawal only.** Allows timing games,
  misses inactive accounts, and makes transfer treatment ambiguous.
- **Deduct another percentage directly from each facility rate.** Scalable for an
  originator/revenue share, but it is a fee on gross loan interest rather than a
  fee on protocol investor performance and cannot respect losses or a high-water
  mark.
- **Transfer underlying assets to the fee recipient.** Reduces vault backing and
  available liquidity. Share minting preserves custody and expresses both fees as
  transparent dilution.

## Consequences and assurance

- `currentExchangeRate()` can now fall without a credit loss in TWO cases, not one. The
  first is a management fee becoming economically due. The second, narrower case is the
  accepted denomination tradeoff above: inside the deep-mark regime a positive repayment
  can lower the reported rate, bounded as stated there. Fee-net views simulate both
  dilutions continuously; the later `ManagementFeeAccrued`/`PerformanceFeeAccrued` share
  mint records rather than repeats them. Monotonicity therefore excludes credit losses,
  due protocol fees, and that bounded denomination residual.
  Note the scoping: the under-collection claim in the global-HWM round-trip acceptance is
  specific to that mechanic and is not a general statement that the fee stack can never
  over-collect. The denomination residual runs the other way on a cure.
- Four external review rounds successively closed the impaired-flow, capacity-write,
  recipient-rotation, delivery-window, dual-NAV, and exit-carry defects. The final
  composition review found no High issue and no §1.3 invariant break. Its remaining
  global-HWM round-trip item is the explicitly accepted under-collection policy above;
  the legacy seed, backstop test, upgrade ordering, UI dust warning, and size gate are
  remediated in the 2026-07-30 follow-up.
- This change invalidates all earlier deployment artifact hashes, configuration
  receipts, audit scope statements, and launch approvals tied to the prior code.
  It may be exercised only in the authorized disposable pre-audit mainnet test.
  Production remains blocked on external audit, remediation, a fresh source freeze,
  fresh approvals, and a fresh mainnet deployment.
