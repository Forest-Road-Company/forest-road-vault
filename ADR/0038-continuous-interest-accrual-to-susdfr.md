# ADR-0038: Continuous accrual of earned-but-unreceived interest into the senior exchange rate

**Subsequent owner answers received 2026-09-11:**
[the received directions](../docs/remediation/CONTINUOUS_ACCRUAL_OWNER_DIRECTIONS_2026-09-11.md)
authorize batch engineering for approximately 100 loans, fixed-rate cash initially, and
both configured interest and performance fees on streamed cash and PIK. Earlier cash-only
and no-PIK protocol fee policy is superseded. Implementation has resumed; final integration
and validation remain unfinished. Pending-question passages below are historical.

**Status:** owner-directed implementation in progress. The mechanism below records the
received 2026-09-10/11 directions and replaces the earlier conditional panel status.
It authorizes no broadcast and does not change the live Ethereum deployment. The original
design discussion is retained with its subsequent decisions; implementation and final
validation are still incomplete.

## Decisions received from Forest Road, 2026-09-10

The question was put in three parts after the agent declined to guess a financial mechanic under
operating-rules directive 5.

| # | Question | Answer |
|---|---|---|
| 1 | Smooth recognition of interest **already received** (ADR-0023, built and currently disabled), or credit interest **before** it arrives? | **Credit before arrival.** "I am approving B explicitly." |
| 2 | PIK only, or cash interest too? | **"PIk and cash interest"** — both legs. |
| 3 | Constrain origination to short payment intervals, which would deliver most of the effect with no contract change? | **"no we don't want inflexibility there for origination"** — rejected. Payment intervals stay a commercial choice. |

**The five open questions below were also answered, 2026-09-10, in the same session:**

| # | Question | Answer | What it forces |
|---|---|---|---|
| Q1 | Do accrued cash and accrued PIK enter backing at the same mark, or is the cash receivable haircut? | **Full face.** | Backing grows with accrual at 100%. No haircut term. |
| Q2 | When does accrual stop on a distressed facility? | **At default declaration.** | Not at the past-due mark. Accrual continues through the entire pre-declaration window. |
| Q3 | Is recognised interest reversed, and through the cascade or straight to the senior rate? | **Through the three-layer cascade.** | **Decides the carrier.** See §"What Q3 forces" below. |
| Q4 | Do performance fees crystallise on accrued or only on received income? | **Accrued.** | ADR-0031's HWM fee becomes due on income not yet in hand. |
| Q5 | Enable ADR-0023 vesting alongside? | **No, not on.** | `yieldVestingPeriod` stays zero. No smoothing layer to reconcile. |

### Loss-bearing cash and PIK without changing the contractual basis

Both kinds of earned interest must be reachable by impairment and the native three-layer
cascade. The reserve Book tracks unposted earned claims separately from the native recorded
face, and the lifecycle posts all earned interest before a default or loss. The canonical
loan model distinguishes principal from unpaid interest. Accrued cash interest remains an
interest receivable and never enters the borrower's interest-bearing principal; PIK changes
its frozen interest basis only at a signed capitalization date. Payment reduces the correct
principal and interest components while moving measured USDC into custody. The same income
is not recognized or charged fees twice.

### The combination is sharper than any single answer

Recorded once, factually, because the questions were answered separately:

**Q1 full face + Q2 stop only at default declaration** is the longest accrual window at the highest
mark. Receivable classes carry no on-chain mark during a facility's life and distress arrives on an
attestation cadence, so a borrower who has stopped paying continues to accrue at full face until a
`SERVICER_ROLE` declaration with an attestation quorum lands. **Q4 accrued** means performance fees
crystallise on that income as it is recognised. **Q5 no vesting** removes the delay that would
otherwise hold some of it back from pricing exits. **Q3 cascade** then means the eventual reversal
burns curator first-loss for income that never existed.

Net: the first-redeemer window is at its widest, and curator capital pays for it. ADR-0022's 21-day
cooldown and the conservative redemption NAV are the existing brakes, and the conservative NAV only
engages once a default is *declared*, which Q2 places at the same instant accrual stops.

**This is not a re-litigation of the answers.** It is the consequence chain, recorded so the economic
review sees it in one place. One mitigation is available that contradicts none of the five answers: a
**staleness cap** that suspends accrual when a facility's most recent attested data is older than some
bound. That is not a "stop" in the Q2 sense and does not move the default-declaration trigger; it
bounds how long the protocol will accrue against silence. Offered for decision, not assumed.

The originating request: *"I want all interest (PIK and cash) to accrue to sUSDfr daily, or even
every minute."*

Answer 3 is what makes this a build rather than a parameter. With flexible intervals the accrual
cannot ride on capitalisation frequency, so it has to be computed from the clock.

## Context

### What exists today

- `sUSDfr.totalAssets()` is `held - unvestedYield()` (`sUSDfr.sol:278-282`). Interest enters as a
  lump when it is **received**: `WaterfallEngine.capitalizePik` for PIK, `distribute` for cash.
- **ADR-0023 already smooths received yield.** `unvestedYield()` decays linearly with the clock
  (`sUSDfr.sol:230-241`), so the rate climbs every block while a stream is live. It is **disabled**:
  `Config.DEFAULT_YIELD_VESTING_PERIOD = 0`, passed at `MainnetConfig.sol:92`, the launch default
  having been amended to zero by Forest Road on 2026-07-30. Ceiling `MAX_YIELD_VESTING_PERIOD`
  is 30 days.
- **The management fee already accrues continuously**, per second, with genuine continuous
  compounding via `powWad` (`_managementFeeAssets`, `sUSDfr.sol:1095-1100`).
- The PIK accrual **amount** is already an exact time-proportional computation over
  `plan.dueAt - max(cur.lastAt, cur.fundedAt)`. Only its **recognition** is discrete.

So the protocol already accrues a fee continuously and already smooths received income. What it has
never done is recognise income **before receipt**.

### What this reopens, and it must not be glossed

**ADR-0022 §Y.2 refused exactly this, deliberately and in writing:**

> "**Deposits are unchanged** — they price at today's realized NAV. We deliberately do **not** adopt
> usd.ai's optimistic-deposit NAV (prorating *expected upcoming* yield), because pre-crediting a
> forward return conflicts with **[ADR-0002] variable-yield pass-through (Locked)** and carries
> [risk]."

**ADR-0023 rejected this exact alternative BY NAME**, in its own alternatives list
(`ADR/0023-streamed-senior-yield-vesting.md:79-80`):

> "**Expected-yield per-second accrual.** Rejected because it would recognize income before
> realization and conflict with ADR-0002."

That is a direct prior refusal of the literal request, not merely of the adjacent optimistic-NAV
idea, and it is recorded here because an earlier draft of this ADR missed it. It does not change
Forest Road's authority to reopen the question; it does mean the reopening is of a decision that was
made explicitly rather than by omission, and the economic review should see it that way.

**ADR-0023 restated the same boundary in its body:**

> "Only yield backed by arrived stablecoin and minted through the normal repayment path can be
> streamed. No expected or forecast income is pre-credited."

ADR-0002 is **Locked**, and the operating rules say a Locked decision is not reopened without Forest
Road input. This ADR **is** that input. It is recorded as a reopening rather than as a clarification,
because presenting it as anything else would misrepresent what changed.

### The distinction that makes the decision defensible, and its limit

ADR-0022 refused prorating *expected upcoming repayments*, which is forecasting cash that has not
been earned. That is not identical to what is decided here:

- **PIK interest** genuinely accrues second by second under the loan contract and capitalises into
  an identified claim the protocol holds. Recognising it continuously records income **already
  earned** against an asset that grows with it. This is ordinary accrual accounting and is what a
  credit fund does daily.
- **Cash interest** is weaker. Between coupon dates it is a **receivable with no capitalised
  claim behind it**. Accruing it is closer to what ADR-0022 refused, and answer 2 includes it.

The decision covers both. The design must not pretend the two are the same asset.

## Decision

1. **Interest earned and not yet received accrues continuously into `sUSDfr`'s exchange rate**, for
   both PIK and cash-pay facilities, independent of payment interval.
2. **Accrual is computed from the clock, not from capitalisation events.** Origination remains free
   to set any payment interval (answer 3).
3. **The computation must be O(1) on the read path.** `totalAssets()` sits on every mint, redeem and
   NAV read. Round ten confirmed as a live medium that a linear walk on an adjacent path
   (`conservativeResiduals()` over `$.eventIds`) becomes a denial surface as the book grows. A
   per-facility loop in `totalAssets()` is ruled out by this ADR, not left to implementation taste.
   The shape is a global accrual index checkpointed on every event that changes a facility's basis,
   rate or accrual status.
4. **Recognition must not double-count.** When interest is finally capitalised (PIK) or received
   (cash), the previously accrued amount converts to realised rather than being recognised a second
   time. The ADR-0031 invariant forbidding a second price jump applies here directly.
5. **An explicit non-accrual policy is mandatory.** Today a past-due mark freezes the PIK crank,
   which is an accidental and partial version of one. The policy must state when accrual stops on a
   distressed facility and what happens to interest already recognised.
6. **The backing invariant is restated, not waived.** `USDfr` supply must remain within backing, and
   backing today is "stablecoin + reserve + deployed principal at conservative marks", which has no
   term for accrued income. Adding one is part of this decision and is the part most likely to be
   got wrong.

## Consequences, including the uncomfortable ones

- **Reversal is real value leaving the senior rate.** If a facility defaults after interest has been
  recognised, that recognition must come out. Whoever redeemed in between kept value that later
  holders funded. ADR-0022's 21-day cooldown narrows that window; it does not close it, and
  continuous accrual widens what sits inside it.
- **Performance fees would crystallise on money not in hand.** ADR-0031's global-HWM performance fee
  currently checkpoints atomically with an arrived payment (ADR-0023 §2). Accruing before receipt
  means fees become economically due on interest that may never arrive. The received direction
  chooses accrual: both configured protocol-interest and performance fees are charged as income
  is earned, with the existing management fee and high-water-mark rules retained.
- **More call sites must checkpoint, and a missed one is silent.** Funding, capitalisation,
  distribution, amendment, past-due marking and clearing, default declaration, loss realisation,
  maturity and repayment all change the accrual rate. An omission does not revert; it drifts. This is
  where the invariant and differential testing has to land.
- **EIP-170 is tight and was measured on 2026-09-11**: Ethereum `ReserveManager` 1,127 B margin
  (tightest anywhere), `SUSDfr` 2,030 B, `DefaultManager` 2,412 B, `WaterfallEngine` 4,470 B; BSC
  `MintRedeemController` 1,265 B, `DefaultManager` 1,391 B. A new index and its checkpoints must fit,
  on both trees.
- **This is a UUPS upgrade to a live mainnet deployment**, not a parameter change, and it changes
  the economics of a token people hold.

## What remains human-owned, and is not closed by this ADR

Recorded factually, without characterising the instruments (operating-rules directive 6):

1. **Counsel's view is owed.** ADR-0022 tied its refusal of pre-credited forward return partly to
   matters reserved for counsel. Reversing that refusal puts the question back in front of them. The
   Part 11 securities opinion gate is unaffected by this ADR and remains outstanding.
2. **Economic review is owed.** ADR-0023 already required published reasoning, window, affected
   market integrations and rollback conditions merely to enable *smoothing of received yield*. This
   is a larger change and inherits that obligation at minimum.
3. **Nothing here authorises deployment.** Production activation remains behind the Part 11 gates.

## Open questions for Forest Road — ALL FIVE ANSWERED 2026-09-10, see the table at the top

| # | Question | Why it cannot be defaulted |
|---|---|---|
| Q1 | Do accrued cash interest and accrued PIK interest enter backing at the **same** mark, or is the cash receivable haircut? | They are different assets. PIK is capitalised into a claim; cash accrual is unsecured until the coupon lands. |
| Q2 | When does accrual **stop** on a distressed facility: at past-due mark, at default declaration, or on a separate test? | Determines how much phantom yield is recognised before the cascade catches it. |
| Q3 | Is interest already recognised on a defaulting facility **reversed**, and if so does the reversal enter the three-layer cascade or hit the senior rate directly? | Reversal through the cascade protects seniors and burns curator capital for income that never existed. Direct reversal does the opposite. |
| Q4 | Do performance fees crystallise on **accrued** income or only on **received** income? | Charging on accrual pays a fee on money that may never arrive. |
| Q5 | Should ADR-0023 vesting be **enabled** alongside this, or does continuous accrual make it redundant? | They interact: vesting withholds received yield while this recognises unreceived yield. Running both without deciding the interaction is how double-counting gets in. |

## Alternatives considered and rejected by the decision

- **(A) Enable ADR-0023 vesting only.** Available today as a timelocked parameter, already audited,
  no upgrade. Rejected by answer 1: it smooths received yield and does not accrue before receipt.
- **(A′) Vesting plus short origination intervals.** Would have delivered a near-continuous rate with
  no contract change, since `ClaimBridge` places no lower bound on `paymentInterval` beyond non-zero
  (`ClaimBridge.sol:350`). Rejected by answer 3 as an unacceptable constraint on origination.
- **Per-facility loop in `totalAssets()`.** Rejected in §3 above on measured grounds.

## References

- [ADR-0002](0002-variable-yield-pass-through.md) — Locked; reopened in part by this decision.
- [ADR-0022](0022-redemption-cooldown-and-conservative-nav.md) — §Y.2 refusal of pre-credited forward
  return; superseded in part, subject to acceptance of this ADR.
- [ADR-0023](0023-streamed-senior-yield-vesting.md) — the smoothing mechanism that exists and is off.
- [ADR-0031](0031-protocol-level-fees.md) — fee-net views and the no-second-price-jump invariant.
- [ADR-0012](0012-backing-invariant.md) — the invariant this decision restates.
- `docs/remediation/ROUND_TEN_RESULTS_2026-09-11.md` §4 — the measured gas evidence behind §3.

## Implementation mechanism and checkpoint, 2026-09-11

The requested [three-way panel](../docs/remediation/CONTINUOUS_ACCRUAL_DESIGN_PANEL_2026-09-10.md)
is complete. The later owner directions settle its remaining choices: approximately 100
unresolved loans, fixed-rate cash initially and both configured fee types on cash and PIK
as earned. Variable benchmark resets and Thirty/360 conventions are not enabled initially.

The reserve-local Book tracks cumulative recognition, native posting and physical issuance
independently. The contractual planner uses frozen bases, Actual/360 for PIK and Actual/360
or Actual/365 for fixed cash. Maturity or earlier default declaration stops earning. An
indexed event queue bounds chronological work to 32 events per call; admission bounds
aggregate annual work. Dormant zero-income PIK dates can be serviced in constant time.

Constant-time snapshots cap recognition at the next unresolved boundary and expose
freshness. Priced actions require current accounting. A same-transaction reserve permit
converts selected outstanding senior and fee claims into USDfr, with frozen economic
prices and independent physical-delta checks. Fee-rate changes are prospective, and an
old fee recipient's claim is delivered before the destination changes. Earned claims are
not canceled by headroom or an impairment clamp.

BSC's native integration and its curator-then-senior correction are implemented and under
review. Ethereum now has the common components, bridge and controller adapters. Its native
reserve, waterfall, default/risk integration and curator -> sGROVE -> senior correction
remain unfinished, as do proved migration, keeper/deployment wiring and final system
validation. Activation currently refuses existing deployed receivables until migration
is implemented. Current controller evidence is in the
[Ethereum controller checkpoint](../docs/remediation/accrual-panel/ETHEREUM_CONTROLLER_ACCRUAL_VALIDATION_2026-09-11.md).
The BSC risk shortcut is not applicable to Ethereum's shared backstop.

This checkpoint authorizes no deployment, governance execution, signature substitution or
live upgrade. Human-owned release decisions remain separate from this implementation goal.


## Owner decisions implemented, 2026-09-14

The owner directed full contractual PIK recognition and retention of BSC's current custody approach. Any earlier three-times-original-principal recognition limit is superseded. Native funding, authenticated amendments and opening migration reserve the full remaining signed obligation with bounded arithmetic; recognition still uses the contractual frozen basis and capitalization dates. Legacy servicing records full coupons and charges both configured protocol interest and performance fees through a complete paired issuance. Numerical admission limits remain explicit. No storage field or new linked-library name was added.

BSC continues to recognize custody losses through permissionless reconciliation. The interval before observation, and losses hidden by an unreadable asset, remain accepted operational exposure (C1, conditional High); no automatic mint/exit custody observation was introduced. The decision does not change either chain's cascade or authorize a rollout.

The [completion handover](../docs/remediation/FULL_PIK_DECISIONS_COMPLETION_2026-09-14.md) records exact source paths, commits, coverage scope, size margins, regression and mutation results, and pinned local fork tests. No deployment or live change occurred. This dated section supersedes earlier pending PIK implementation choices; earlier checkpoints remain historical.

## Owner decisions, 2026-09-16: three consequences of continuous accrual, ratified

The first executed run of the adversarial fork suite against this ADR's implementation
(`docs/remediation/FORK_ADVERSARIAL_RESULTS_2026-09-15.md`, sections 4, 5 and 11) surfaced
three behaviours that the implementation had adopted without a decision on record. Each was
executed, refuted by three independent lenses, and left red in the suite until decided. Forest
Road decided all three on 2026-09-16 and the tests now pin them
(`docs/remediation/FORK_REGRESSION_FIXES_2026-09-16.md`).

1. **The marked-to-market LTV numerator is the deployed receivable face, including earned but
   unreceived interest.** `ReserveManager.deployedTo` returns principal plus posted and unposted
   accrued interest under continuous accrual; `DefaultManager._ltv` divides it by the mark
   unchanged, so `marginCall`, `clearMarginCall`, `liquidate` and the roleless executor all act
   on the full face. Direction is protective: calls and liquidations fire slightly earlier and a
   cure must cover the accrued coupon (measured drift about 1.8 bps per day at a 400,000 mark
   on a 260,000 principal at 10%). Two items follow, neither a code change: the ADR-0015
   thresholds (6500 / 8000) were calibrated on a principal numerator and are to be reconfirmed
   in the economic review on the full-face basis; and the facility documents must define the
   ratio on outstanding balance including accrued interest, or the on-chain trigger diverges from
   the contract. Recorded in `IDefaultManager.currentLtvBps` and `IReserveManager.deployedTo`.

2. **`DefaultManager.setBackstop` is frozen once the manager is bound to the accrual reserve.**
   The reserve's loss routes are immutable identities configured before activation; the manager's
   copy of the sGROVE route is therefore frozen at binding, and `DefaultAccrualLib.bind` now
   refuses a manager whose backstop differs from the reserve's, closing the activation window in
   which the two could diverge permanently. The cost is a lost route-around: if sGROVE ever
   reverts on `coverShortfall`, `realizeLoss` blocks for any loss whose residual after the curator
   pool is non-zero, and the repair is on the sGROVE side (role re-grant, or an in-place UUPS
   upgrade of the sGROVE proxy by the timelock), not a manager setter. The reserve's custody
   cascade already carried that dependency; the two cascades are now consistent. Runbook
   section 7.5 records the repair path.

3. **Protocol-interest fee on accrued income is deliverable while a senior residual stands.**
   Under the 2026-09-11 direction fees are charged as income is earned and ownership is
   independent of call count, so the fee leg accrues on interest that later defaults and can be
   materialised by anyone through `materializeAccrued(2)` with no reference to
   `pendingSeniorImpairment()`. The ADV-1 per-receipt ceiling (the fee withheld ahead of a
   standing senior residual) therefore applies to the legacy receipt path only, which is the
   path the current mainnet deployment runs and which the legacy unit tests still cover.
   Measured on the fork: 933.33 USDfr delivered and redeemed to USDC against a 957,777.78
   senior residual in the audit's ADV-1 shape; about 7,078 USDfr per 1,000,000 facility over 182
   days of borrower silence at 14%, funded by the cascade when the loss lands, curator first.
   Forest Road accepted this on 2026-09-16 on the ground that the cascade carries the loss in
   either case; the fee is a share of income that was recognised into the senior rate and is
   reversed through the same cascade. A delivery-time ceiling on the fee leg was considered and
   not adopted. ADV-1 was an internal round (`docs/remediation/HANDOVER_2026-08-08.md`) and is
   not described on the public audit register, so no register text needs correcting. What does
   need changing when the accrual upgrade ships is the public overview
   (`frontend/src/content/docs/overview.md`, "the Waterfall fee is 10% of realized gross
   interest"), which is true of the deployed legacy path and false of the continuous path, where
   the fee accrues on recognised interest whether or not it is received. Add it to the upgrade
   checklist; do not change it before the upgrade.


## Owner decision, 2026-09-17: record legacy PIK before declaring default

The owner chose to record completed, unpaid legacy PIK coupons before declaring
an attested default. Posting is mandatory: if a required dependency is paused or
posting fails, the declaration reverts. This is an explicit exception to the old
blanket description that default cannot depend on a paused posting route.

The signed legacy schedule, frozen coupon basis, asset grid and contractual
capitalisation dates remain authoritative. Default records up to 32 payable
completed coupons atomically. A longer backlog can be prepared with bounded,
servicer-only `settleLegacyPikForDefault` calls using the same standing
`DefaultDeclared` evidence. Preparation preserves existing past-due marks and
their relief clocks, increasing marked risk before issuing the corresponding
yield. It asserts no cure. Declaration captures the fully recorded balance.

Both configured fee mechanisms continue to apply through the existing PIK
waterfall. Legacy notes retain their completed-period convention; this decision
does not introduce an additional partial-period coupon. Native continuous accrual
continues to checkpoint earned interest and stop at default under the existing
policy. No rollout or broadcast is authorised by this engineering decision.

Implementation and measured validation are recorded in
[the legacy default handover](../docs/remediation/LEGACY_PIK_DEFAULT_HANDOVER_2026-09-17.md).

## Legacy PIK execution limit, 2026-09-18

The Ethereum automatic and preparation batch limit is **16 completed coupons**.
This supersedes the 32-coupon implementation limit recorded on 2026-09-17. The
contractual compounding schedule is unchanged. The smaller execution batch leaves
headroom under Ethereum's 16,777,216 transaction gas limit, including marked debt
and fee hooks. BSC retains its separate 32-coupon execution limit.

For a longer backlog, the servicer must call `settleLegacyPikForDefault` repeatedly
with a batch of 1–16 on Ethereum (1–32 on BSC), checking `pendingDue` after each
successful transaction, then call `declareDefault`. Evidence must remain valid.
Never raise the transaction gas limit above the chain limit as a workaround. If
WaterfallEngine, ReserveManager, MintRedeemController or USDfr is paused, resolve
that pause before posting; default cannot omit completed legacy interest.

The measured regression scope, conservative call budget and custody-arm changes
are recorded in [the follow-up handover](../docs/remediation/CUSTODY_AND_LEGACY_FOLLOWUP_2026-09-18.md).
