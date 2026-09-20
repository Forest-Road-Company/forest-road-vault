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

### 2.1 The role set, and what each one can do if it is captured

Fourteen roles are declared in `Roles.sol`. This table is the threat model's own view of them: not
what each role is for, which the access-control matrix records, but what an attacker holding it
could do. It is generated against the compiled surface by `tools/check-threat-model.mjs`, so a role
added tomorrow reds this document rather than quietly escaping the model.

| Role | Held by | If captured |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | governance timelock | everything below, plus every module setter. The 48h delay is the only brake, so timelock capture is total capture. |
| `UPGRADER_ROLE` | governance timelock | replaces any implementation, which is a superset of every other role. Same brake. |
| `GUARDIAN_ROLE` | guardian multisig | pauses user paths. Cannot touch the cascade. The real damage is LIVENESS: a pause held past one payment interval plus the grace window used to make the whole PIK book markable past due, which is why `DefaultManager.markPastDue` now refuses a PIK facility while the crank is paused. |
| `ATTESTER_ROLE` | m-of-n attester quorum | asserts off-chain facts. THE PRIMARY TRUST ASSUMPTION: a dishonest quorum can originate against a claim that does not exist, declare a default that has not happened, or attest a payment that never arrived. Threshold, EIP-712 domain binding, single-use consumption and expiry bound the blast radius; they do not remove it. |
| `SERVICER_ROLE` | Forest Road ops | records payments and realises losses. A captured servicer can realise a loss that did not occur, but only up to outstanding principal and only with a `LossRealized` attestation it cannot mint itself. |
| `ORIGINATOR_ROLE` | Forest Road ops | originates facilities. Bounded by the attestation gate and by concentration limits, which is why those limits stay a REVERT on the origination path even though capitalisation no longer re-checks them. |
| `CREDIT_ROLE` | protocol modules only | the cross-module primitives: deploy, capitalise, pay, write down, record exposure. **MUST NEVER BE GRANTED TO AN EOA.** An EOA holding it could call `ReserveManager.recordPayment`/`recordPrincipalWritedown` directly and lower `deployedTo` without cash arriving or the cascade running. Several threat-model arguments elsewhere in this document depend on that grant discipline. |
| `CONTROLLER_ROLE` | `MintRedeemController` | the mint/redeem authority over `USDfr`. Capture is equivalent to unbacked issuance. |
| `MINTER_ROLE` | `MintRedeemController` | mints `USDfr`. Same. |
| `LOSS_BURNER_ROLE` | cascade modules | burns `USDfr` during loss absorption. Capture destroys holder balances; it cannot create supply. |
| `FEE_ACCOUNTING_ROLE` | `sUSDfr` fee path | crystallises management and performance fees. Capture dilutes senior holders up to the governed fee bounds, not without limit. |
| `RESERVE_ADMIN_ROLE` | governance | reserve valuation acts, which are deliberately authenticated because a governance write-down leaves `live > recorded` on purpose. |
| `SETTLEMENT_KEEPER_ROLE` | keeper EOA | drives redemption-queue settlement. Capture is a LIVENESS risk only: it cannot change who is owed, and the queue is reconstructable from events. |
| `COMPLIANCE_ADMIN_ROLE` | compliance ops | maintains the `ComplianceRegistry` allowlist. Capture blocks minting for honest users and admits unscreened ones; it moves no value directly. |

### 2.2 Modules not covered by the component sections below

- `AccrualMath`, `AccrualSchedule`, `AccrualBook`, `AccrualCeiling`, `AccrualLoans` and
  `AccrualSegments` — the reserve-owned continuous-interest core. The deployed path now uses the
  fixed-basis math and indexed next-event queue; `AccrualIndex` remains an unused preparatory
  alternative with no authority or external entry point. The active core validates rate, basis,
  year convention and time domains, retains exactly one full-width scheduled event per facility,
  caps the complete signed PIK obligation before admission, and attributes aggregate and
  facility-level accrual from the same frozen basis. Its principal failure modes are arithmetic
  drift, a missed lifecycle checkpoint, scheduling corruption and admitting a future PIK curve
  outside the proved numeric ceiling. Differential histories, schedule invariants and the
  100-facility opening tests cover those properties.
- `ReserveAccrualStorageLib` and `ReserveAccrualViewsLib` — storage-only and constant-time view
  surfaces for that book. They hold no authority. Reads must remain O(1), use the same live
  namespace as mutations, and fail closed while an event boundary or opening migration is due.
- `ReserveAccrualCreditLib`, `ReserveAccrualLib` and `ReserveAccrualServiceLib` — linked reserve
  lifecycle, materialization and bounded servicing bodies. They execute by delegatecall in the
  `ReserveManager` proxy context; the host retains role, pause and reentrancy checks. A wrong link
  address is therefore equivalent to a reserve implementation compromise, so the deployment
  receipt and live validator bind every link target and runtime hash.
- `ReserveCascadeLib`, `ReserveIncidentLib`, `ReserveMigrationLib`, `ReserveRoundingLib` and
  `ReserveWiringLib` — linked custody cascade, incident, existing-book import, sub-unit correction
  and permanent module-binding bodies. Their critical properties are curator → sGROVE → senior
  order, no partial NAV during migration, preservation of earned fee claims during rounding, and
  immutable identity agreement across every accrual consumer. The `ReserveManager` entry points
  retain the authority and reentrancy guards; none of these libraries is a separately callable
  policy surface.
- `DefaultAccrualLib` and `DefaultBackstopLib` — native past-due/default accrual accounting and
  backstop wiring in the `DefaultManager` context. They must checkpoint before a risk-state
  transition, stop earning at declaration, keep undeclared past-due accrual inside the conservative
  mark, and price curator pools per class before the single shared sGROVE reserve. The host keeps
  servicing/governance admission and the cross-contract reentrancy boundary.
- `BridgeAccrualLib`, `ControllerAccrualLib`, `VaultAccrualLib` and `WaterfallAccrualLib` — linked
  adapters that validate the permanently bound reserve identities and carry accrual coherently
  through origination, mint/redeem, vault NAV/fees and cash/PIK servicing. Each runs in its host
  proxy context and relies on the host's role and reentrancy guard. Cross-module identity drift,
  stale accrual, partial paired delivery and callback re-entry must revert atomically.
- `VaultFeeMath` — the extracted management-fee retention formula used by `sUSDfr`. It owns no
  storage or authority; its risk is rounding or checkpoint-frequency dependence, covered by the
  fee differential and long-time tests.

Section 4 walks the value-moving path. These contracts sit off it and are modelled here so that
"not in section 4" never silently means "not modelled".

- `CollateralRegistry` — class parameters, exposure accounting and the concentration limits. A
  captured `DEFAULT_ADMIN_ROLE` can widen a limit or raise the concentration floor; both are
  timelocked and both are visible as `ConcentrationDrift`/`ConcentrationHealed` events. Note the
  asymmetry introduced 2026-09-10: `recordExposureIncrease` still REVERTS on breach, while
  `recordCapitalizedExposure` reports and does not, because compounding interest is not an
  admission decision and a reverting crank manufactured credit events.
- `ComplianceRegistry` — the KYC allowlist consulted on mint. Read-only to the value path.
- `CommitmentLedger` / `CommitmentLedgerFactory` — per-event remaining principal for the layer-2
  draw, one ledger per manager, created by the factory at `initialize`. Only the owning manager can
  write (`onlyManager`, an inline caller guard rather than a role, which is why the access-control
  suite pins inline guards separately).
- `ConservativeImpairmentMath` — pure arithmetic for the conservative senior mark. No state, no
  privileges; its risk is a wrong formula, not a wrong caller, so it is covered by the invariant
  tier rather than by access control.
- `MtmAtomicExecutor` — the marked-to-market margin path executor. Out of scope for launch classes,
  which are all Receivable.
- `PointsModule` — off-value-path incentive accounting. Cannot move capital.
- `GroveToken` — the governance token. Its risk is governance capture, covered by the timelock rows
  above and by ADR-0026.
- `RecoveryTopUpDistributor` — routes recovered principal back to senior holders. Value-moving but
  post-cascade; the amounts it distributes are already fixed by the cascade that ran before it.
- `DefaultInitLib` / `DefaultLossLib` — delegatecalled bodies extracted from `DefaultManager` on
  2026-09-10 for EIP-170, mirroring the `ReserveCreditLib` pattern. The SAME rule applies and it is
  the whole risk: a library cannot see its caller's modifiers, so `DefaultManager` keeps
  `onlyRole(SERVICER_ROLE)` and `nonReentrant` on `realizeLoss` and nothing may call
  `DefaultLossLib.realizeLoss` from a path that lacks them. The extraction was verbatim; the
  ADR-0012 ordering rule (all burns before the write-down) moved with the body and is restated in
  the library header.

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

**Reserve credit path, delegatecalled (ReserveStorageLib / ReserveCreditLib)**
- *Extraction changed behaviour* → `ReserveCreditLib` holds the BODIES of `recordDeployment`,
  `recordFeeCapitalization`, `recordPikCapitalization`, `recordPayment` and
  `recordPrincipalWritedown` verbatim; `ReserveManager` keeps every entry point and every
  `onlyRole`, `nonReentrant` and `whenNotPaused` modifier on it. A library cannot see a caller's
  modifiers, so an unguarded call site would be an unguarded treasury door: nothing may call into
  this library except those five entry points.
- *Storage divergence* → the `ReserveStorage` struct and its single ERC-7201 `$.slot` assignment
  stay declared in `ReserveManager.sol`. The libraries are HANDED the pointer rather than deriving
  it, so exactly one place in the repository knows where the live proxy's storage lives, and both
  storage-layout gates verify unchanged against the committed baselines.
- *Delegatecall context confusion* → these are public library functions reached by delegatecall,
  so `address(this)` is the proxy. That is what keeps `safeTransfer`, `balanceOf(address(this))`
  and the self-deployment guard meaning what they meant inline.
- *Link-time substitution* → public library functions require LINKING, which is new for this
  tree. A wrong or malicious library address at link time is a full compromise of the credit path;
  the deployment manifest must record the library addresses and post-deploy validation must check
  them.
- *Silent proof loss* → `ReserveStorageLib`'s functions are internal deliberately. A library
  calling another library's public function leaves a placeholder that symbolic tooling cannot
  link, and every proof then fails while the suite and size gate stay green.

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
- *Near-total curator-pool wipe makes repost arithmetic unrepresentable (S3-F1)* → fixed in the
  GitHub-equivalent baseline by advancing economically wiped rounds and lazily normalizing the
  share ratio before a new post while preserving residual ownership. The 2026-08-07 two-failure
  heavy receipt and subsequent owner acceptance describe the superseded implementation only; there
  is no active production exception. The pre-import/harness 2026-08-14 configured-heavy candidate
  completed 1,919/0/326 without the panic. The repaired current tree now conclusively passes
  1,921/0/326 at 10,000 fuzz runs and 512 x 256 invariant calls; Oracle is 5/0 with zero reverts and
  captured `PIPE_STATUS=0 0`. Any later source change must preserve a zero-failure result.
- *Facility loss exceeds automated cascade capacity (G3)* → `realizeLoss` intentionally reverts
  atomically before the principal write-down. This moves no funds but leaves face-value accounting
  stale, so every affected value path must remain frozen while governance recapitalizes authorized
  absorbing layers or approves an independently reviewed accounting change, then records the whole
  loss. The manual procedure and rehearsal are mandatory; this accepted recovery policy is not a
  claim that the loss was recorded.
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
  reverts rather than consuming the epoch (R2 A1), and D7 authenticates `closeEpoch` to the
  dedicated settlement keeper. The old permissionless budget-snapshot grief described by R4-EC3
  is therefore remediated; keeper liveness and Safe fallback are the operational residuals.
- *Global mark can halt the queue (G2)* → intentional: global senior impairment is applied to
  the sUSDfr staked base. A sufficiently large book-wide mark can make the head unredeemable. The
  accepted design retains the d04e652 payment-episode protections: monotonic due high-water mark,
  no same-due relief restart, conservative unset-anchor behavior, and a ramp to full weight over
  one redemption cooldown. Monitoring and disclosure remain required.
- *Price changes while a long epoch is being processed (G4)* → intentional between external
  `closeEpoch` calls. A mark revision between chunks changes the later call's live conservative
  price while FIFO order remains intact. This disposition does not assert per-request repricing
  inside one call; monitoring records the transaction/revision boundary and user disclosures avoid
  promising one fixed epoch-wide price.

**Governance / upgrades**
- *Privilege escalation* → flat role-admin graph (no self-grant); `_authorizeUpgrade`
  timelock-gated on all 17 role-based modules, with `FRGovernor` separately gated by
  `onlyGovernance`; impls disable initializers (no uninitialized-impl
  takeover); ERC-7201 namespaced storage with all 17 namespaces re-derived unique; array-element
  structs LAYOUT-FROZEN.
- *Compliance bricks the cascade* → protocol-owned modules are `protocolExempt` so a
  COMPLIANCE_ADMIN block can never freeze settlement/cascade/rewards (audit R3 F1/F2).
- *Queued operation cannot be vetoed after a successful vote (G1c)* → intentional finality.
  Mainnet v1 has no proposal guardian or separate post-queue cancellation principal. The ordinary
  operational Guardian can pause selected user paths but cannot cancel governance. The two-day
  Timelock is not represented as notice that the 21-day exit can outrun; monitoring, disclosure and
  participation before queueing are the controls.
- *Pointer-only Timelock replacement orphans governance/module authority* → closed for v1:
  `FRGovernor.updateTimelock` retains `onlyGovernance` and always reverts with
  `Governor_TimelockMigrationDisabled`. Operators must not schedule the disabled selector. Any
  future migration requires a separately reviewed Governor upgrade and an atomic role-transfer/
  validation ceremony through the current Timelock; the inherited pointer-only path is not treated
  as a migration mechanism.
- *A fresh production deployment overwrites or is confused with the disposable-v4 receipt* → the
  production path is namespaced as `DeployMainnetProduction`, `ValidateMainnetProduction` and
  `MainnetProductionConfigReceipt`, and it exclusively uses
  `contracts/deployments/1-production-v1.json`. Completed-v4 runtime/broadcast/authorization and
  `deployments/1.json` records are immutable and never accepted by the production validator; the
  shared base script source remains part of the current delta. The frontend principal-set
  reconstruction includes the distinct nonzero <!-- tm-check:ignore-start describes the DEPLOYMENT MANIFEST of this tree, not its src/ symbols -->`queueKeeper`<!-- tm-check:ignore-end -->; any zero/substituted keeper or stale
  static authorization fails closed. Current default, focused and forced cold receipt/validator
  compilation pass; the configured-heavy explicit-exit receipt and clean local source freeze also
  pass. The frozen identities are `contracts/src` tree
  `9714bd1dc5b8b2175576d88ba907f21453e65b6a` and `contracts/script` tree
  `92669e22b5d4f6200b90905b8a78af240153311d`. No production tag or production-v1 manifest exists;
  pinned CI/format/Slither, mandatory RPC-backed tests, formal independent external delta review and fresh
  authorization remain gates.
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

Flagged in the audit campaign. This table mixes accepted policy/counsel risks with historically
remediated code defects such as S3-F1 and D7; each row's disposition controls. Full remediation
detail is in `security-review.md`.

| Ref | Sev | Risk | Disposition |
|---|---|---|---|
| F3 | Med (counsel) | `sUSDfr` transfers bypass compliance — a sanctioned wallet can hold the staked instrument. | **Intentional** (Forest Road: "no transfer gating in DeFi"). The `protocolExempt` plumbing is in place if counsel later requires gating. |
| F4 | Low | Value stranded by a post-fill jurisdiction block has no governed recovery path. | Accepted (may be intended for sanctions). |
| R4-EC3 | Historical Low | Redemption-queue budget-snapshot timing griefing (no extraction). | **Fixed by D7:** `closeEpoch` is keeper-authenticated. Production still requires keeper activation, health and Safe-fallback rehearsal. |
| Deploy | Info | Testnet `KEEP_OPS_ADMIN=true` leaves the ops EOA as `DEFAULT_ADMIN`; testnet attester keys derive from one secret. | **Production MUST** run `KEEP_OPS_ADMIN=false` with genuinely-separated attester signers. |
| R5-EC1 | Low | An sGROVE reward slice streamed while `totalStaked == 0` is stranded with no governance sweep; a dominant staker can weaponize it to burn a funder's routed rewards (no attacker profit; custody invariant intact). | **Recommended:** a governance <!-- tm-check:ignore-start describes a RECOMMENDED primitive NOT YET BUILT on this tree; modelled ahead of integration so it cannot land unmodelled -->`sweepStrandedRewards()`<!-- tm-check:ignore-end --> (ADR-0021 economic decision, Forest Road). |
| R5-OR1 | Info | (a) `PaymentReceived` is one record slot per facility — a second attested payment overwrites the first before distribution (liveness). (b) Oracle `pause()` blocks only new submissions; the guardian must ALSO pause `DefaultManager`/`ClaimBridge` to freeze the margin/mint path (two-switch coordination). | Ops notes; no code change. |
| R5-I1 | Info | `liftDefaultFreeze` is per-class, not tokenId-bound — a governance double-lift could reopen the R4-EC2 window (inside the trusted-timelock boundary). | Governance-ops discipline; consider tokenId-binding lifts. |
| R5-TEST | Med (rigor) | Historical test-strength gap: the stateful cascade invariant used an uncapped mock while the audit-era production backstop was capped; the backing invariant was self-referential with no config-transition fuzz. | R6 fixed the backing half. ADR-0035 later made the production reserve intentionally uncapped per event; current production-backed cascade suites still bind the live shared-reserve behavior. |
| S3-F1 | Historical Medium liveness | Near-total curator-pool residuals made later repost share arithmetic overflow. | **Fixed; current exact-heavy green.** Repaired tree passes 1,921/0/326 at 512 x 256 with captured Forge exit and no recurrence. Earlier acceptance is history only; reopen on any panic. |
| G1c | Governance policy | No post-queue veto and the 21-day holder exit cannot outrun the two-day Timelock. | **Intentional.** No proposal guardian; disclose queued finality and monitor proposal lifecycle. |
| G2 | Economic/liveness policy | Global senior impairment can make the sUSDfr queue head unredeemable. | **Intentional with d04e652 safeguards retained.** Reopen if the payment-episode high-watermark/ramp/fail-safe rules change. |
| G3 | Incident liveness/accounting | An over-capacity `realizeLoss` reverts, leaving face-value accounting until remediation. | **Accepted manual frozen-protocol remedy.** Mandatory rehearsal; no value path reopens until recapitalization/upgrade and successful on-chain recognition. |
| G4 | Queue pricing policy | A mark revision between settlement calls can make later chunks use a different price. | **Intentional live inter-call pricing.** Preserve FIFO and transaction/revision monitoring; no claim of intra-call repricing. |
| PROD-V1-FLOW | Deployment identity / operator integrity | A replacement could overwrite the v4 receipt, validate the wrong manifest, or omit <!-- tm-check:ignore-start describes the DEPLOYMENT MANIFEST of this tree, not its src/ symbols -->`queueKeeper`<!-- tm-check:ignore-end --> from frontend receipt reconstruction. | **Implemented; current default/heavy/focused/cold-build and clean local source-freeze evidence green.** Dedicated production script/validator/receipt names and `1-production-v1.json`; completed-v4 records/manifest immutable while shared base source remains in scope; zero/substituted keeper rejected. No production tag/manifest exists; pinned CI/RPC/Slither, formal review and regenerated authorization remain open. |
| GOV-TL-V1 | Governance liveness / authority integrity | Inherited `updateTimelock` changes only the Governor pointer and could orphan roles on the old Timelock. | **Fixed for v1; focused/current default/heavy evidence green.** Endpoint is governance-only and terminally reverts; future migration requires an independently reviewed Governor upgrade plus atomic role transfer. |
| **R7-SM1** | Low | A facility `originate`d then never funded sits in `Pending` forever (only exit is `Pending→Active` via `fund`); its class/borrower/state concentration exposure is stranded, keeping `CuratorModule._requiredFirstLoss` inflated and curator first-loss headroom locked. **Conservative direction** — only shrinks future capacity, never permits over-concentration; value conservation intact. | **Governance-recoverable WITHOUT an upgrade** (timelock `grantRole(CREDIT_ROLE)` → `recordExposureDecrease`). Proper fix: a future governed `cancel/expire` transition out of `Pending`. Not a redeploy blocker. |
| ADR27-VAL1 | High (governance trust) | A malicious or unsupported `AssessedImpairmentSource.setAssessment` can reduce the queue haircut to zero while a real senior loss remains likely, allowing early redeemers to shift that loss to stayers. | Timelock-only; amount can never exceed the zero-recovery base, expires after at most 30 days, commits to a published evidence hash, and automatically fails back to zero recovery. It is also bound to `DefaultManager`'s monotonic revision and to the live **risk-state** hash, so every new default/past-due/recovery/realization or curator first-loss change invalidates it immediately. **sGROVE backstop capacity is deliberately excluded from that hash and compared directionally instead (RC-01 era fix for FRV-FS-04): a capacity DECREASE invalidates, a capacity INCREASE does not.** An increase can only make a published assessment more conservative, whereas an exact-match rule let anyone void a depositor-favourable assessment with a dust `fundCoverage` donation, since that entry point is permissionless. Independent valuation-policy and monitoring sign-off remain mainnet gates. |
| ADR31-EQ1 | Medium (economic) | A single global HWM is not a depositor tax lot: someone entering during a drawdown shares fee-free recovery to the old protocol peak and may share a later fee on pre-entry gains deferred by performance impairment, even while junior support makes queued-exit impairment zero. There is no clawback of crystallized fees after a later loss. | Deliberate scalable design; the Stake surface independently warns whenever `feeExchangeRate() < highWaterMark()`, monitor both values, and obtain economic/legal acceptance. Per-investor lots/share classes are a future redesign, not a parameter change. |
| ADR31-EQ2 | Medium (economic under-collection, accepted 2026-07-30) | After serving the 21-day queue cooldown, an incumbent can exit and redeposit during a junior-covered fee deferral. Basis-additive entry plus the holder-protective pro-rata exit law can then reduce the protocol's later performance fee even though assets return. | Forest Road explicitly accepted this direction and declined a launch exit-equalization fee. The per-share HWM cannot fall across the exit, so the residual under-collects protocol revenue rather than charging stayers on non-profit. A composed production-wired regression pins the behavior; monitor material round trips and reopen only as a lot/equalization/share-class economic redesign. |
| ADR31-VAL1 | Medium (governance/economic) | Professional assessment timing can alter performance-fee NAV between lazy checkpoints; direct USDfr donations are fee-bearing gain. | Timelocked/evidenced assessment policy, permissionless checkpoints, junior-credit snapshotting, event monitoring, and external audit. The v2 deployment contains this surface but remains closed pending operational acceptance. |
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
- **Canonical Ethereum USDC** — the only launch reserve token. Earlier frozen/baseline candidates
  and the fresh v2 deployment have pinned-mainnet evidence against the real six-decimal proxy,
  including mint/redeem, funding, repayment, queue settlement and custody accounting. RPC-backed
  fork checks are release evidence and must be rerun serially after any source, deployment or
  provider change; an offline skip is never counted as a pass.
- **The attester infrastructure** — off-chain; the trust root (see §2).

## 7. Production assurance gates (Part 11 — human-owned)

External security audit · securities-law opinion · executed legal wrapper · economic
review · attestation-trust acceptance. The internal campaign includes historical/baseline pinned
canonical-USDC fork tests and a Halmos proof of the modeled cascade conservation/ordering
arithmetic. Existing results support but do not replace a current exact-source rerun, independent
reviews, controlled deployment ceremony, monitoring, incident response, and ongoing governance
obligations.

The coverage receipt and its hard source-function denominator must be regenerated for the exact
release source. `--allow-failure` is only an LCOV-emission mechanism; ordinary default/heavy
profiles own correctness and every coverage-only failure must still be reviewed explicitly.

The fresh Ethereum v2 address set deployed on 2026-09-18 remains closed to user operations while
live-address qualification runs. Corrovera satisfies Forest Road's independent source-review gate;
that review and this internal evidence do not authorize third-party capital. Opening the system is
a separate human governance and operational decision after every gate above is reviewed.

The round-4 ADR-0031 review found no High issue and confirmed the holder-harming exit
defect closed. Forest Road accepted the remaining protocol-under-collection tradeoff.
The reviewed contract tree deployed for v2 is bound by the deployment manifest, implementation and
library runtime hashes, and the post-handover fork pin. It enables continuous accrual from genesis,
enforces dual-NAV dependency order, validates the complete backstop interface, gates EIP-170 size,
and launches with zero yield vesting plus an atomic post-interest checkpoint. Any contract change
invalidates that identity evidence and requires new bytecode, review and deployment receipts.

*Living document — update as the surface, mitigations, or accepted risks change.*


## Continuous-accrual delivery module, updated 2026-09-18

USDfr now has an explicitly bound reserve permit path for delivering already recognized
senior and protocol-fee claims. One-time token/controller/vault identity checks, monotone
nonces and consumed per-leg authorization constrain the paused mint exception. Compliance
and points still execute; other token mutations are excluded during the batch. The first
points hook retains a second-leg allowance when both claims are delivered. The reserve
host supplies coherent prices, consumes only the selected virtual obligations, and proves actual
supply/recipient deltas. The token cannot independently prove that economic book, so reserve,
controller, vault, waterfall, default and registry identities are permanently cross-bound.

The host integration is complete on the fresh v2 deployment: fixed-rate cash and PIK interest
accrue continuously from frozen contractual bases, both protocol and performance fees crystallize
as income is earned, PIK compounds only on its signed schedule, and earning stops at default or
maturity. Every basis/rate/status transition checkpoints first. Opening migration remains an
upgrade-only path and deliberately fails closed until its signed roster is complete. System-level
evidence therefore combines the exact deployed-block lifecycle suite, differential histories,
stateful invariants, function coverage, static analysis and serialized RPC-backed fork tests;
isolated token tests alone are insufficient.
