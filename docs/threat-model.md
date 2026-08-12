# Threat Model — Forest Road Vault

**Audience:** external auditors and Forest Road. **Companion docs:** `invariants.md` (the
safety spec), `access-control-matrix.md` (roles), `security-review.md` (the internal
audit campaign — 4 rounds + a post-fix pass). **Posture:** this protocol custodies real
capital against real legal claims; a rushed or under-tested contract is worse than none
(CLAUDE.md Prime Directive 2). The internal review prepares a clean mainnet-v1 candidate
but does not itself authorize production; the human and external gates in §7 control.

---

## 1. Assets at risk

| Asset | Where | Worst-case loss |
|---|---|---|
| Canonical USDC reserve | ReserveManager custody and durable idle ledger | direct theft / mis-routing / unrecognized custody loss |
| Deployed principal | with borrowers (off-chain), tracked on-chain | credit loss (expected, cascaded) |
| `USDfr` backing integrity | supply ≤ backing invariant | silent under-backing → depositor loss |
| `sUSDfr` senior principal | the vault | subordination inversion / silent rate drop |
| Curator first-loss + sGROVE backstop | CuratorModule, SGrove | mis-ordered cascade, front-run withdrawal |
| GROVE supply / fee stream | frTreasury, feeRecipient | mis-routed at deploy |
| Governance control | timelock + roles | privilege escalation → total compromise |

## 2. Actors & trust assumptions

| Actor | Trust level | Notes |
|---|---|---|
| Depositor / staker | untrusted | KYC-gated for mint; holds/transfers open |
| Curator (first-loss) | semi-trusted | approved per class; capital is genuinely subordinated |
| sGROVE staker | untrusted | 21-day unbonding prevents loss-front-running |
| **Attesters (m-of-n)** | **TRUSTED — the protocol's primary trust assumption** | off-chain facts enter via EIP-712 signatures; ADR-0007 / brief Part 11 gate 6. A dishonest quorum can assert false facts. |
| Ops / Servicer (Forest Road) | trusted-but-bounded | single-purpose roles; several actions additionally gated by attestations |
| Governance timelock | trusted root | 48h delay; holds admin + upgrade |
| Guardian | trusted, limited | can pause user paths only, never the cascade |

**Primary trust assumption (state it plainly):** the system is only as honest as its
attester quorum and its servicing keys. The on-chain code enforces *consistency and
ordering*; it cannot verify that an attested off-chain fact (a filed UCC, a received
payment, a declared default) is true. This is the central risk the legal wrapper and the
attestation-trust acceptance (Part 11) exist to manage.

## 3. Trust boundaries

1. **Off-chain ↔ on-chain (attestations).** The highest-value boundary. Mitigations:
   m-of-n threshold (≥2 for every value-bearing launch kind),
   EIP-712 domain binding, single-use consumption for payment/loss authorization, payload
   commitments to exact amounts, expiry + freshness (`asOf`/`maxMarkAge`), nonce replay
   protection, consume-once digests.
2. **External ERC-20 ↔ protocol.** Canonical Ethereum USDC only; exact measured inbound
   receipts, SafeERC20 throughout, and a one-way-downward reconciliation if actual
   custody falls below the durable idle ledger.
3. **Module ↔ module (`CREDIT_ROLE`).** Cross-module primitives callable only by the
   specific sibling module; the cascade legs are non-pausable.
4. **User ↔ vault exit.** ERC-4626 withdraw/redeem is queue-only (epoch FIFO); no instant
   exit can front-run a loss.

## 4. Attack surface & mitigations (by component)

**Token layer (USDfr / MintRedeemController / ReserveManager)**
- *Backing bypass / donation inflation* → every mint is backing-asserted; the configured
  USDC asset is immutable; direct donations do not raise the internal idle ledger.
- *Custody/accounting divergence* → inbound receipts are exact, funding and payment
  transitions are atomic, and reconciliation can only lower recognized backing.
- *Reentrancy via token callbacks* → `nonReentrant` + CEI on all value moves.

**Attestation / origination (AttestationOracle / ClaimBridge)**
- *Single-attester forgery* → high-value kinds floored at m-of-n ≥ 2 (`setThreshold`
  cannot lower them — audit R3 SM-2); deployed masks include CreditIssued (SM-1).
- *Mint without conditions* → `originate` requires the full class mask satisfied for the
  exact new tokenId; escrow release conditioned off-chain on the NFT.
- *Replay* → consume-once digests, nonces, expiry.

**Credit / waterfall (WaterfallEngine)**
- *Fabricated or redirected repayment* → `distribute` spends a single-use
  `PaymentReceived` attestation committing to payment id, facility, USDC, payer, exact
  cash amount, interest, principal, and next due date, then pulls that exact receipt.
- *Value non-conservation* → two-leg cash split by construction:
  `interest == protocol fee + sUSDfr`; mainnet v1 has no DSRA state or path.
  ADR-0031's later performance/management fees mint vault shares and remove no
  backing asset, so they cannot break this equation.
- *Funding redirection* → the funding recipient is part of the signed facility terms;
  the servicer supplies only the facility id and exact USDC amount.

**Vault fees (sUSDfr, ADR-0031)**
- *Double charging / loss-recovery fee* → performance launches at 10% (governance-
  variable up to a hard 20% v1 cap) of performance-fee NAV profit above a
  post-fee global high-water mark. A rate change crystallizes the old rate first;
  investment losses and management-fee dilution never lower the hurdle. Deposits and
  exits carry it through the holder-protective asset/pro-rata max law in ADR-0031.
  Junior-capacity changes never mutate it; the fee impairment is measured before
  temporary curator/sGROVE capacity is netted, so contributed protection cannot become
  chargeable profit.
- *Fee timing around entry, exit, or loss* → deposits/mints, queue admission and
  settlement, vault exits, distributions, default/past-due/loss/liquidation transitions,
  and relevant setters checkpoint the prior period first. Curator/sGROVE capacity writers
  use a checkpointed fee-neutral lock bracket with no free-running NAV re-read.
  `accrueFees` is permissionless. Every positive interest delivery also checkpoints
  after `notifyYield`, so zero-period launch performance crystallizes in the repayment
  transaction.
- *Backing or liquidity extraction* → management/performance fees mint `sUSDfr`
  shares to the recipient; no USDfr leaves the vault. ERC-4626 views simulate due
  shares before mutation, and crystallization is explicit through
  `ManagementFeeAccrued` / `PerformanceFeeAccrued`.
- *Excessive or retroactive management fee* → launches at zero; governance can set only
  0–200 bps per 365-day year; the old rate accrues before a change takes effect.
- *Fee-recipient brick or split routing* → a new vault recipient must already be
  `protocolExempt`, including at vault initialization. Rotation writes the valid
  replacement before accruing, so a blocked/non-exempt old recipient cannot brick the
  recovery call and pending shares mint to the replacement. Deployment validation pins
  the Waterfall and vault recipients to one manifest address; later changes must be an
  atomic timelock batch and monitored.
- *Callback crystallizes transient asset/share state* → the vault-wide reentrancy guard
  spans the underlying USDfr transfer and the later share mint/burn; independent fee and
  share-update locks cover fee-share minting and preserve fail-open rejection through the
  points hook. Fee HWM effects are written before the optional callback. Waterfall yield
  delivery additionally acquires a persistent lock in the vault before either token leg
  is minted, `notifyYield` consumes it after delivery, and Waterfall then checkpoints.
  The Waterfall's own guard is not relied upon cross-contract. Timelocked governance has
  an evented stale-lock recovery if a faulty trusted module commits only the begin call.
  Regression tests attack the underlying-token,
  share-token, and mint-to-notify windows.
- *Mandatory-streaming complexity* → launch vesting is zero. Realized interest enters
  NAV immediately and Pendle compatibility does not depend on a stream. The capped
  non-zero branch remains tested as an optional governance policy.
- *Assessment timing / donation classification* → fees use the live professional
  conservative mark. A timelocked assessment change between checkpoints can defer or
  expose feeable gain; direct USDfr donations are indistinguishable from gain. These
  are valuation/governance trust assumptions, not permissionless extraction paths.

**Cascade / default (DefaultManager / CuratorModule / SGrove)**
- *Layer skip / inversion* → fixed sequence with strict `received == covered` equality;
  write-down paired atomically with burns; non-pausable.
- *Curator front-runs a loss* → `withdrawFirstLoss` frozen once a facility in the class
  defaults, until governance lifts it (audit R4-EC2). The guaranteed `target` floor is
  locked regardless.
- *sGROVE exit timing* → 21-day unbonding delays exit. NOTE (audit L-6, corrected 2026-07-22):
  staked GROVE principal is **never slashed** — the backstop absorbs losses from its funded
  coverage reserve, not by slashing stakers — so the unbond is an exit/voting/obligation delay,
  NOT protection of slashable staker principal (do not represent it as the latter externally).
- *Backstop exhaustion / report ordering* → ADR-0035 intentionally gives each reported shortfall
  access to the whole live USDfr reserve. One event can drain layer two completely; senior
  principal absorbs 100% of later loss until replenishment. Report order therefore allocates the
  shared protection, an owner-accepted economic consequence that must remain explicit externally.
- *Sanctions-immune fee wallet (`protocolExempt`)* → accepted (liveness-critical inbound); counsel
  to revisit a sweep-sink / leg-split before third-party capital (OWNER_DECISIONS #5).
- *Reward sandwich (deposit-before-harvest)* → rewards **stream** over a duration; a
  mid-stream notify cannot lower the rate (audit R4-EC1 + M-1). Pendle-compatible.

**Liquidity (RedemptionQueue)**
- *Over-distribution / double-claim* → budget-bounded FIFO; `assetsClaimable` zeroed
  before transfer; settled assets remain claimable during a guardian pause; dust rejected.
- *Permissionless DoS on the exit* → a zero-distribution settlement with requests queued
  reverts rather than consuming the epoch (R2 A1). (Residual: budget-snapshot timing
  griefing, R4-EC3, documented.)

**Governance / upgrades**
- *Privilege escalation* → flat role-admin graph (no self-grant); `_authorizeUpgrade`
  timelock-gated on all 17 role-based modules, with `FRGovernor` separately gated by
  `onlyGovernance`; impls disable initializers (no uninitialized-impl
  takeover); ERC-7201 namespaced storage with all 14 slots re-derived unique; array-element
  structs LAYOUT-FROZEN.
- *Compliance bricks the cascade* → protocol-owned modules are `protocolExempt` so a
  COMPLIANCE_ADMIN block can never freeze settlement/cascade/rewards (audit R3 F1/F2).
- *Guardian freezes the electorate* (**NEW, ADR-0026/L-02**) → `SGrove.stake` and
  `requestUnstake` are `whenNotPaused`, so post-L-02 a guardian pause no longer merely freezes
  staking: it freezes the **composition of the sGROVE electorate**. Nobody can stake in to gain
  votes, nobody can unbond out to remove them, and a pause timed just before a proposal snapshot
  locks in the current vote distribution. Mitigations, deliberate: `delegate`/`delegateBySig` are
  **not** pausable (a pausable `delegate` would be a stronger censorship lever), all vote reads
  are unpausable so the Governor never stalls, and the quorum denominator is GROVE-sourced so a
  pause cannot move the bar. Accepted; the guardian is already trusted to pause the redemption
  exit path, which is a strictly larger power.
- *Retained admin becomes retroactive vote authority* (**NEW, ADR-0026/L-02**) → sGROVE now
  reports historical voting power, and `DEFAULT_ADMIN_ROLE` administers `UPGRADER_ROLE`. While
  the owner's deliberate `KEEP_OPS_ADMIN` posture holds, that EOA can self-grant `UPGRADER` on
  `SGrove` and ship an implementation writing **retroactive votes at any past timepoint**,
  defeating any proposal to remove it — so the key is structurally unremovable by governance.
  This does not reopen the owner's decision; it records that L-02 widened its blast radius.
  `Validate.s.sol` prints it in the RETAINED PRIVILEGE block. Closed by `Handover.s.sol`.
- *A broken vote source bricks `propose`* (**NEW, ADR-0026/L-02**) → `GroveVotesAggregator` does
  **not** `try/catch` either leg, so a governance-authored bad `SGrove` upgrade would revert
  `propose`/`castVote` while `state`/`queue`/`execute` keep working off the GROVE-only quorum
  path. Accepted as a contested choice, on the grounds that the pre-L-02 design already accepts
  exactly this for GROVE (whose `getPastVotes` the Governor has always called unwrapped) and that
  the fail-open alternative introduces a gas-griefing attack on `castVoteBySig`. Flagged for the
  pre-mainnet audit; see ADR-0026.

## 5. Residual risks & accepted items

Flagged in the audit campaign; each is a governance / counsel / policy decision, not a
code defect. Full remediations in `security-review.md`.

| Ref | Sev | Risk | Disposition |
|---|---|---|---|
| F3 | Med (counsel) | `sUSDfr` transfers bypass compliance — a sanctioned wallet can hold the staked instrument. | **Intentional** (Forest Road: "no transfer gating in DeFi"). The `protocolExempt` plumbing is in place if counsel later requires gating. |
| F4 | Low | Value stranded by a post-fill jurisdiction block has no governed recovery path. | Accepted (may be intended for sanctions). |
| R4-EC3 | Low | Redemption-queue budget-snapshot timing griefing (no extraction). | Not fixed; a keeper-gated close would remove it. |
| Deploy | Info | Testnet `KEEP_OPS_ADMIN=true` leaves the ops EOA as `DEFAULT_ADMIN`; testnet attester keys derive from one secret. | **Production MUST** run `KEEP_OPS_ADMIN=false` with genuinely-separated attester signers. |
| R5-EC1 | Low | An sGROVE reward slice streamed while `totalStaked == 0` is stranded with no governance sweep; a dominant staker can weaponize it to burn a funder's routed rewards (no attacker profit; custody invariant intact). | **Recommended:** a governance `sweepStrandedRewards()` (ADR-0021 economic decision → Forest Road). |
| R5-OR1 | Info | (a) `PaymentReceived` is one record slot per facility — a second attested payment overwrites the first before distribution (liveness). (b) Oracle `pause()` blocks only new submissions; the guardian must ALSO pause `DefaultManager`/`ClaimBridge` to freeze the margin/mint path (two-switch coordination). | Ops notes; no code change. |
| R5-I1 | Info | `liftDefaultFreeze` is per-class, not tokenId-bound — a governance double-lift could reopen the R4-EC2 window (inside the trusted-timelock boundary). | Governance-ops discipline; consider tokenId-binding lifts. |
| R5-TEST | Med (rigor) | Historical test-strength gap: the stateful cascade invariant used an uncapped mock while the audit-era production backstop was capped; the backing invariant was self-referential with no config-transition fuzz. | R6 fixed the backing half. ADR-0035 later made the production reserve intentionally uncapped per event; current production-backed cascade suites still bind the live shared-reserve behavior. |
| **R7-SM1** | Low | A facility `originate`d then never funded sits in `Pending` forever (only exit is `Pending→Active` via `fund`); its class/borrower/state concentration exposure is stranded, keeping `CuratorModule._requiredFirstLoss` inflated and curator first-loss headroom locked. **Conservative direction** — only shrinks future capacity, never permits over-concentration; value conservation intact. | **Governance-recoverable WITHOUT an upgrade** (timelock `grantRole(CREDIT_ROLE)` → `recordExposureDecrease`). Proper fix: a future governed `cancel/expire` transition out of `Pending`. Not a redeploy blocker. |
| ADR27-VAL1 | High (governance trust) | A malicious or unsupported `AssessedImpairmentSource.setAssessment` can reduce the queue haircut to zero while a real senior loss remains likely, allowing early redeemers to shift that loss to stayers. | Timelock-only; amount can never exceed the zero-recovery base, expires after at most 30 days, commits to a published evidence hash, and automatically fails back to zero recovery. It is also bound to `DefaultManager`'s monotonic revision and to the live **risk-state** hash, so every new default/past-due/recovery/realization or curator first-loss change invalidates it immediately. **sGROVE backstop capacity is deliberately excluded from that hash and compared directionally instead (RC-01 era fix for FRV-FS-04): a capacity DECREASE invalidates, a capacity INCREASE does not.** An increase can only make a published assessment more conservative, whereas an exact-match rule let anyone void a depositor-favourable assessment with a dust `fundCoverage` donation, since that entry point is permissionless. Independent valuation-policy and monitoring sign-off remain mainnet gates. |
| ADR31-EQ1 | Medium (economic) | A single global HWM is not a depositor tax lot: someone entering during a drawdown shares fee-free recovery to the old protocol peak and may share a later fee on pre-entry gains deferred by performance impairment, even while junior support makes queued-exit impairment zero. There is no clawback of crystallized fees after a later loss. | Deliberate scalable design; the Stake surface independently warns whenever `feeExchangeRate() < highWaterMark()`, monitor both values, and obtain economic/legal acceptance. Per-investor lots/share classes are a future redesign, not a parameter change. |
| ADR31-EQ2 | Medium (economic under-collection, accepted 2026-07-30) | After serving the 21-day queue cooldown, an incumbent can exit and redeposit during a junior-covered fee deferral. Basis-additive entry plus the holder-protective pro-rata exit law can then reduce the protocol's later performance fee even though assets return. | Forest Road explicitly accepted this direction and declined a launch exit-equalization fee. The per-share HWM cannot fall across the exit, so the residual under-collects protocol revenue rather than charging stayers on non-profit. A composed production-wired regression pins the behavior; monitor material round trips and reopen only as a lot/equalization/share-class economic redesign. |
| ADR31-VAL1 | Medium (governance/economic) | Professional assessment timing can alter performance-fee NAV between lazy checkpoints; direct USDfr donations are fee-bearing gain. | Timelocked/evidenced assessment policy, permissionless checkpoints, junior-credit snapshotting, event monitoring, and external audit. This newly added accounting surface is not production-approved. |
| ADR31-LIVE1 | High (liveness, remediated) | A reverting, malformed, or semantically inconsistent impairment source can make every fee checkpoint fail and therefore block deposits, queue operations, repayments, and default transitions; checkpointing through that same source also prevents the normal setter from clearing it. | Non-zero replacements are validated through both impairment views and their required ordering before wiring. The normal path remains fail-loud and checkpointed. A separate timelocked recovery function can only clear the current source after a fixed-budget ABI/ordering probe fails, enforces a separate recovery-gas reserve so under-gassing cannot fake failure, emits failure evidence, and HWM-ratchets any lifted NAV fee-free. A valid source cannot use the bypass. Regressions cover reverting, short-return, performance-only malformed, and `performance < redemption` sources. |
| ADR31-REC1 | Low (economic under-collection, accepted emergency trade-off) | Clearing an unreadable impairment source lifts marked NAV and ratchets that lift fee-free. Any performance fee embedded in the live impairment/recovery gap is permanently waived. | Recovery is timelock-only, can only clear a source that fails a fixed-budget ABI-shape probe, emits failure evidence, and is an incident path rather than ordinary valuation governance. Monitoring must quantify the waived fee and production must remain paused until a validated source is restored. Regressions cover both reverting and successful-but-malformed current sources. |
| ADR31-EXIT1 | High (economic, remediated; delta review pending) | Carrying an asset hurdle out solely at junior-supported redemption NAV lets a leaver shed deferred performance-fee exposure onto stayers when redemption NAV exceeds performance-fee NAV. | Exits retain `max(asset carry, pro-rata carry)`. A production-wired queue regression cures the impairment and value-asserts that only stayers' proportional deferred profit is charged; the dual-NAV stateful campaign independently derives the same law from pre-flow state. |
| ADR31-BACKSTOP1 | Low (governance/economic, residual limited to broken outgoing contract) | A backstop rotation must value elapsed management fees on the outgoing NAV without letting an unreadable outgoing contract block its own replacement. | `setBackstop` validates the incoming ABI and bounded-gas probes the outgoing backstop. Readable rotations checkpoint before the write; only an unreadable outgoing contract uses effects-first repair and therefore the incoming NAV. Monitoring must treat that fallback during live impairment as an incident. Regressions cover outgoing-NAV fee value, malformed candidates, and broken-old replacement. |
| ADR31-UPGRADE1 | Medium (liveness, remediated) | Upgrading `sUSDfr` before the assessed wrapper/base expose the new dual-NAV selectors can freeze vault views and queue settlement. | Execute one timelock batch in dependency order: `DefaultManager` → `AssessedImpairmentSource` → `sUSDfr`. The wrapper and vault now enforce their respective dependency edge during UUPS authorization; reverse-order unit tests revert. |

## 6. External dependencies

- **OpenZeppelin 5.4.0** (upgradeable) — AccessControl, ERC-4626, ERC-721, UUPS,
  ReentrancyGuard, Pausable, Governor, Timelock. Audited stack; not hand-rolled.
- **Solady `FixedPointMathLib`** — pinned source dependency used only for fractional-year
  management-fee retention. Its approximate `powWad` makes fee accrual materially
  checkpoint-frequency neutral on an unchanged NAV; approximation/rounding and long-time
  bounds are explicit external-audit scope.
- **Canonical Ethereum USDC** — the only launch reserve token. The clean candidate is
  fork-tested against its real six-decimal proxy at a pinned mainnet block, including
  mint/redeem, funding, repayment, queue settlement, and custody accounting.
- **The attester infrastructure** — off-chain; the trust root (see §2).

## 7. Production assurance gates (Part 11 — human-owned)

External security audit · securities-law opinion · executed legal wrapper · economic
review · attestation-trust acceptance. The internal campaign includes pinned canonical-USDC
fork tests and a Halmos proof of the modeled cascade conservation/ordering arithmetic.
Those results support but do not replace the independent reviews, controlled deployment
ceremony, monitoring, incident response, and ongoing governance obligations.

Forest Road's 2026-07-29 owner decision permits a disposable pre-audit mainnet deployment
for controlled testing only. It is closed to third-party capital and real legal claims,
uses only controlled test wallets and an approved test budget, and is not a production
release. External audit remediation is expected; production requires a fresh deployment
and every gate above.

The round-4 ADR-0031 review found no High issue and confirmed the holder-harming exit
defect closed. Forest Road accepted the remaining protocol-under-collection tradeoff.
The follow-up working tree seeds legacy zero-HWM upgrades from `totalAssets()`, enforces
dual-NAV upgrade order, validates the complete backstop interface, fixes the UI dust
trigger, gates EIP-170 size in CI, and launches with zero yield vesting plus an atomic
post-interest checkpoint. Exact-source independent review and fresh receipts remain
required; prior hashes and approvals do not cover this source.

*Living document — update as the surface, mitigations, or accepted risks change.*
