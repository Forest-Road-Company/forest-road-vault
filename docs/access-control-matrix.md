# Access-Control Matrix — Forest Road Vault

**Audience:** external auditors. Derived 1:1 from `src/libraries/Roles.sol`,
`script/Deploy.s.sol` (grants), and `script/Validate.s.sol` (which asserts the live
topology — positive AND negative holdings — after every deploy). All roles are admin'd by
`DEFAULT_ADMIN_ROLE`; there is **no `_setRoleAdmin` override anywhere**, so no role can
grant itself (no escalation loop).

> **Production vs testnet.** In production, `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` are
> held **only** by the governance timelock (`KEEP_OPS_ADMIN=false`). On the current Sepolia
> testnet, the ops EOA additionally retains `DEFAULT_ADMIN_ROLE` for QA convenience
> (`KEEP_OPS_ADMIN=true`) — the single largest live privilege, flagged in the manifest and
> Validate. The prod-shaped deploy MUST run with `KEEP_OPS_ADMIN=false`.

## Roles and holders

| Role | Held by (prod) | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (0x00) | Governance **timelock** | Admin of all roles (grant/revoke); every parameter setter. |
| `UPGRADER_ROLE` | Governance **timelock** | `_authorizeUpgrade` on the clean deployment's role-gated UUPS modules, including `AssessedImpairmentSource`. `RecoveryTopUpDistributor` is not deployed. `FRGovernor` authorizes upgrades through `onlyGovernance`; `GroveVotesAggregator` remains immutable and role-less. **Post ADR-0026 this role also controls a vote source**: an `SGrove` upgrade can rewrite historical voting power. |
| `GUARDIAN_ROLE` | Guardian | Pause/unpause **user paths only** — never the cascade. |
| `MINTER_ROLE` | MintRedeemController | Mint USDfr (on `USDfr`). |
| `CONTROLLER_ROLE` | MintRedeemController | `ReserveManager.depositUSDC` / `releaseUSDC` (primary mint/redeem custody). |
| `CREDIT_ROLE` | WaterfallEngine, DefaultManager, ClaimBridge | The **trusted internal-module** role — the only caller of cross-module credit value/state primitives. Never held by an EOA. |
| `ORIGINATOR_ROLE` | Ops (Forest Road) | `ClaimBridge.originate`. |
| `SERVICER_ROLE` | Ops (Forest Road) | Facility servicing: fund, distribute, declareDefault, accelerate, realizeLoss, and clearPastDue. Value-bearing facts are separately attestation-bound. |
| `ATTESTER_ROLE` | The m-of-n attester keys | Authorized EIP-712 signers; the oracle verifies `attest()` bundles against these holders. |
| `RESERVE_ADMIN_ROLE` | Governance timelock | Recognize a conservative idle-USDC custody write-down. It cannot add an asset or increase backing. |
| `COMPLIANCE_ADMIN_ROLE` | Ops / compliance | KYC allow-list and jurisdiction blocklist. No identity mapping exists on chain. |

## Role × privileged-function matrix

### Governance-only (`DEFAULT_ADMIN_ROLE` = timelock)
Every economic / safety parameter. A compromised holder is the top of the threat model —
hence the timelock + (prod) no-EOA rule.

| Contract | Functions |
|---|---|
| CollateralRegistry | `setClass`, `setBorrowerLimit`, **`setBorrowerLimitOverride`**, **`clearBorrowerLimitOverride`**, `setStateLimit`, `setComplianceModule`, `setConcentrationFloor` |
| ComplianceRegistry | `setProtocolExempt` |
| ClaimBridge | `setRequiredMintAttestations` (audit R7: the ONLY ClaimBridge governance setter — the oracle is wired once at `initialize` and is immutable thereafter; `setRedemptionQueue`/`setPointsModule` live on sUSDfr, `setAttestationOracle` on ReserveManager — corrected below) |
| sUSDfr | `setRedemptionQueue`, `setPointsModule`, **`setImpairmentSource`** (ADR-0022 Option Y — validates and wires both impairment views; zero = exits price at realized NAV), **`clearUnreadableImpairmentSource`** (recovery-only clear after a bounded source read demonstrably fails; cannot replace a readable source), **`clearStaleFeeOperation`** (evented recovery of a lock left by a faulty trusted module), **`setYieldVestingPeriod`** (ADR-0023 — optional senior-yield smoothing, capped at `MAX_YIELD_VESTING_PERIOD`; launch default zero = instant recognition), **`setPerformanceFee`** (ADR-0031 — prospective global-HWM rate, 0–2,000 bps; old rate crystallizes first), **`setManagementFee`** (ADR-0031 — prospective annual rate, 0–200 bps; old rate crystallizes first), **`setFeeRecipient`** (replacement must already be protocol-exempt; it is installed before the checkpoint so a blocked old recipient cannot prevent recovery and any pending shares mint to the replacement) |
| ReserveManager | no generic asset or reserve-instrument setters; `RESERVE_ADMIN_ROLE` is limited to `writeDownIdleUSDC` |
| USDfr | `setComplianceModule` |
| CuratorModule | `setCuratorApproved`, `setFirstLossTarget`, **`liftDefaultFreeze`** (audit R4-EC2) |
| AttestationOracle | `setThreshold` (floored ≥2 for high-value kinds), `revoke` |
| RedemptionQueue | `setEpochDuration` (the ADR-0022 settlement HEARTBEAT, not the hold), `setEpochLiquidityBps`, **`setRedeemCooldown`** (ADR-0022 Option X — the forced per-request holding period; applies uniformly to in-flight requests, so a lengthening is bounded by the timelock delay), `setMinRedemptionValue` |
| WaterfallEngine | `setProtocolFee`, `setOriginationFee`, `setFeeRecipient`, **`setDefaultManager`** (ADR-0022 — wires the clean-resolve impairment hook; zero disables it) |
| DefaultManager | `setRemedyRef`, `setCureWindow`, **`setGraceWindow`** (H-5 — per-class past-due grace, capped at `DEFAULT_REDEEM_COOLDOWN`), `setBackstop` |
| AssessedImpairmentSource | `setAssessment`, `clearAssessment`, `setBaseSource` (ADR-0027 — time-limited professional senior-loss mark; assessment can only lower the live zero-recovery base and is invalidated by any revision/state-hash change) |
| SGrove | `setUnbondingPeriod`, `setPerEventCap`, **`setRewardsDuration`** (audit R4-EC1) |
| PointsModule | `setRate`, `setUSDfrMultiplier`, `setCuratorMultiplier`, `setCuratorModule` |

### Operational roles (Forest Road, single-purpose)

| Role | Function(s) | Guard beyond the role |
|---|---|---|
| `ORIGINATOR_ROLE` | `ClaimBridge.originate` | + full attestation mint-gate (m-of-n) + concentration limits |
| `SERVICER_ROLE` | `WaterfallEngine.{fund, distribute}`, `DefaultManager.{declareDefault, accelerate, realizeLoss, clearPastDue}` | funding is bound to the signed recipient; payment/default/loss/cure facts are exact, single-use attestations |
| `MINTER_ROLE` | `USDfr.{mint, burn}` | held only by the controller; every mint is backing-asserted and burns remain live during an emergency pause |
| `CONTROLLER_ROLE` | `ReserveManager.{depositUSDC, releaseUSDC}` | held only by the controller; the only primary asset is configured USDC |
| `RESERVE_ADMIN_ROLE` | `ReserveManager.writeDownIdleUSDC` | can only reduce recognized idle backing |
| `COMPLIANCE_ADMIN_ROLE` | `ComplianceRegistry.{setAllowed, setAllowedBatch, setJurisdictionBlocked}` | cannot reach `protocolExempt` (that is governance) |
| `ATTESTER_ROLE` | (signer, not a caller) `AttestationOracle.attest` verifies signatures against holders | m-of-n threshold per kind |

### `CREDIT_ROLE` — trusted internal-module primitives (never an EOA)
These are the cross-module value/state operations. Each is callable **only** by the
specific sibling module granted the role at deploy, and several are **non-pausable**
at their own entry point. A guardian pause on `ReserveManager` still blocks the
principal-write-down leg until a controlled unpause; incident procedure must
explicitly restore that accounting path before realizing a loss.

| Callee . function | Authorized caller(s) | Pausable? |
|---|---|---|
| `MintRedeemController.mintYield` | WaterfallEngine | via mint path |
| `MintRedeemController.burnLoss` | WaterfallEngine, DefaultManager | **no** (cascade) |
| `CuratorModule.absorbLoss` | DefaultManager | **no** (cascade) |
| `CuratorModule.freezeOnDefault` | DefaultManager | **no** |
| `SGrove.coverShortfall(eventId, amount)` | DefaultManager | **no** (cascade). PM-R-07: the cap is cumulative PER EVENT (the defaulted facility's tokenId), snapshotted at the event's first draw — chunking a loss across calls no longer multiplies the draw. |
| `sUSDfr.beginYieldNotification` | WaterfallEngine | **no** (checkpoints and acquires the vault-side lock before either interest-leg mint) |
| `sUSDfr.notifyYield` | WaterfallEngine | **no** (moves no value; only defers recognition) |
| `DefaultManager.onDefaultResolved` | WaterfallEngine | **no** (clears a recovered facility's impairment mark) |
| `DefaultManager.onDefaultRecovery` | WaterfallEngine | **no** (H-2 — re-anchors a still-defaulted facility's impairment mark to `deployedTo` after a partial cash recovery) |
| `AttestationOracle.consume` | WaterfallEngine, DefaultManager, ClaimBridge | — |
| `ClaimBridge.transitionState` | WaterfallEngine, DefaultManager | — |
| `ReserveManager.{recordDeployment, recordFeeCapitalization, recordPayment, recordPrincipalWritedown}` | WaterfallEngine, DefaultManager | funding/payment paths move USDC and accounting atomically |
| `CollateralRegistry` exposure record/decrease | ClaimBridge, WaterfallEngine, DefaultManager | — |

### `FEE_ACCOUNTING_ROLE` — trusted fee-neutral checkpoint lock (never an EOA)

These calls bracket a mechanical junior-capacity change. The first call checkpoints
fees and snapshots share supply; the second confirms that supply did not change and
releases the persistent vault lock. Neither call derives a hurdle adjustment from an
observed NAV delta. Junior capital is excluded by the separate performance-fee
impairment view, so a capacity write cannot manufacture fee profit. The role does not
mint shares or move assets by itself.

| Callee . function | Authorized caller(s) | Why |
|---|---|---|
| `sUSDfr.beginFeeNeutralMarkedNavChange` / `endFeeNeutralMarkedNavChange` | CuratorModule | Brackets `postFirstLoss` and `withdrawFirstLoss` |
| `sUSDfr.beginFeeNeutralMarkedNavChange` / `endFeeNeutralMarkedNavChange` | SGrove | Brackets `fundCoverage` and `setPerEventCap` |
| `sUSDfr.beginFeeNeutralMarkedNavChange` / `endFeeNeutralMarkedNavChange` | DefaultManager | Brackets `setBackstop` |

The never-pausable cascade legs `CuratorModule.absorbLoss` and
`SGrove.coverShortfall` deliberately do not use this two-call protocol; their
accounting is part of the atomic loss cascade and may not inherit a new external-call
revert surface.

### Permissionless (no role — anyone may call)
Not every external mutator is role-gated; these are permissionless by design (audit R5
added this row so the role tables aren't read as the whole external surface):
- `sUSDfr.accrueFees` — crystallizes the time-based management fee and any
  performance-fee NAV profit above the global high-water mark. Shares mint only
  to the configured protocol-exempt recipient; no underlying asset moves. The
  performance rate launches at 10% and is prospectively governance-variable up to
  the hard 20% v1 cap.
- `ReserveManager.reconcileIdleUSDC` — permissionlessly lowers the internal idle ledger
  to actual custody after an out-of-band shortfall; it can never increase backing.
- `SGrove.fundCoverage` — donates USDfr to the coverage reserve (only ever raises capacity).
- `SGrove.notifyRewards` — funds the reward stream (M-1 guard makes it cost real money to
  affect the rate).
- **`SGrove.delegate(address)` / `SGrove.delegateBySig(...)`** — inherited from OZ
  `VotesUpgradeable` (ADR-0026, L-02). A staker re-points their staked-GROVE voting power.
  Deliberately **NOT guardian-pausable**: delegation moves no value, and a pausable `delegate`
  would be a stronger governance-censorship lever than the pause already is. Note that
  `stake`/`requestUnstake` ARE pausable, so a guardian pause freezes the *composition* of the
  sGROVE electorate (nobody can stake in to gain votes or unbond out to remove them) — a pause
  timed just before a proposal snapshot locks in the current distribution. Vote **reads** are
  never pausable, so the Governor itself never stalls. See `docs/threat-model.md`.
- `GroveVotesAggregator` — the Governor's `IVotes` source (ADR-0026). Immutable, **role-less**,
  no privileged functions and no state: view-only aggregation over GROVE and sGROVE. It is
  deliberately absent from `PrivilegeAudit.moduleSet` / `HandoverOps._modules` for the same
  reason `FRGovernor` is (a `hasRole` scan reverts on a non-AccessControl target), so the UUPS
  original deployment module count stays **15**; the two supplemental recovery tools are
  validated separately. `Validate.s.sol` pins both aggregator legs and its clock mode instead.
- `RedemptionQueue.closeEpoch` — permissionless chunked settlement (no privileged keeper).
- The MTM `marginCall`/`clearMarginCall`/`liquidate` triggers. Every action requires a
  fresh m-of-n attested valuation.
- `DefaultManager.markPastDue` — drives a receivable facility past
  `nextPaymentDue + graceWindow` into the reversible past-due impairment pool. Permissionless (the due-date
  clock is the evidence) and **NOT guardian-pausable** (it reads no oracle mark, only `maturity`
  and `block.timestamp`, so there is no oracle-misbehaviour vector to suppress; and suppressing
  loss recognition is never an emergency remedy). Accounting only — it emits no `RemedyInitiated`
  and requires no `DefaultDeclared` attestation; the servicer's legal declaration is separate.

### Per-borrower concentration override (2026-07-21, Forest Road direction)

`CollateralRegistry.setBorrowerLimitOverride(borrowerId, limitBps)` and its `clear` counterpart
are `DEFAULT_ADMIN_ROLE` (the timelock in production). They exist for the **single-borrower
vertical** case: the global `borrowerLimitBps` assumes a class has many borrowers, which is false
for **Digital Assets** (ADR-0015) — one borrower by construction, Forest Road's own trading
subsidiary. With one borrower the class and borrower dimensions measure the *same* exposure, so
the tighter one binds and that class's own `concentrationLimitBps` was unreachable configuration:
the vertical was silently capped at the global 15%, not its stated 20%.

The override names the borrower and the number rather than relaxing the global limit for everyone.
Every admission, breach-sync, headroom and disclosure read resolves through one helper, so
admission and disclosure cannot disagree about which limit applies.

**Not asserted in `Validate.s.sol`, deliberately and by necessity:** overrides are keyed by an
opaque off-chain `borrowerId`, and the key set is a mapping with no on-chain enumeration — there
is nothing for a post-deploy validator to iterate. A fresh deploy has no overrides set; any that
exist are visible in the `BorrowerLimitOverrideSet` event stream and readable per-id via
`effectiveBorrowerLimitBps`. **This is a monitoring obligation, not a validation one.**

**Related-party disclosure:** the intended first user is Forest Road's own subsidiary. Raising a
related party's concentration allowance is a governance act that must be visible — hence
timelocked, evented and publicly readable.

### Guardian (emergency)
`GUARDIAN_ROLE` may `pause`/`unpause` the **user-facing** paths of every pausable module
(mint/redeem, stake/unstake/claims, deposit, the permissionless MTM triggers). No cascade
FUNCTION carries `whenNotPaused` — `absorbLoss`, `coverShortfall`, `burnLoss`, `realizeLoss`
are module-level unpausable (ADR-0017 §4). **Honest caveat (audit R5-PAUSE1):** because
every cascade leg is ultimately a `USDfr` transfer/burn, a guardian `USDfr.pause()` (the
token-level pause) DOES transitively halt `realizeLoss` — a full break-glass freeze, not a
selective one (exits halt symmetrically, so no depositor escapes a loss; recoverable by
unpause). A recommended hardening (exempt protocol-internal `_update`s from the token pause,
mirroring `protocolExempt`) is flagged in `security-review.md` R5-PAUSE1.

## Verification
- **Static:** unit tests exercise every role-gated function with an authorized AND an
  unauthorized caller (100% branch on access paths).
- **Live:** `Validate.s.sol` asserts, on the deployed chain, that the timelock holds
  `DEFAULT_ADMIN`/`UPGRADER` everywhere, that no EOA holds `MINTER`/`CREDIT` on value
  modules, and (when `!keepOpsAdmin`) that the deployer holds nothing.
- **Audit:** the role×function graph was independently re-derived clean in the Round-4
  access-control lens (`docs/security-review.md`).

*Living document — any new role or privileged function must be added here and to
`Validate.s.sol` in the same change (CLAUDE.md §3.2).*
