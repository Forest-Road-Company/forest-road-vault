# Access-Control Matrix — Forest Road Vault

> **LIVE MAINNET PRINCIPALS (chain 1, deployed block 25,768,251).** This matrix describes roles
> abstractly; these are the addresses actually holding them, so a reader can check the matrix
> against chain state rather than trust it. Manifest: `contracts/deployments/1-production-v1.json`.
>
> | Principal | Address | Holds |
> |---|---|---|
> | **Timelock** | `0x263289d62352f9326456d1430466337484c806Dc` | `DEFAULT_ADMIN` and `UPGRADER` on **every** module |
> | **opsAdmin** (Safe) | `0x297e88C997c2e0EDF70A5F817AAdcA2858Aa6c04` | 16 operational roles — `GUARDIAN` on every pausable module, `COMPLIANCE_ADMIN`, `SERVICER`, `ORIGINATOR`, `SETTLEMENT_KEEPER` |
> | **queueKeeper** (EOA) | `0x1Df7Adb9911e59d78c023B09E68711F97e05f4Cc` | `queue.SETTLEMENT_KEEPER_ROLE` |
> | **deployer** (EOA) | `0x89575b4FCfe2cf6833e96dE71765c6Ad15eAc11b` | **none** — bootstrap authority surrendered at handover |
>
> Verified on-chain by `tools/run-foundry-readonly-mainnet-validation.mjs`: no authority role and no
> timelock `PROPOSER`/`CANCELLER` survives on any EOA or named genesis principal. The deployer
> cannot even grant itself admin on the timelock — a real transaction attempting it reverts
> `AccessControlUnauthorizedAccount`.


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

<!-- BEGIN GENERATED PRIVILEGE ROLES -->
<!-- Generated from config/privilege-topology.json; do not edit this block. -->
| Role | Held by (prod) | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Governance **timelock** | Admin of all roles (grant/revoke); every parameter setter. |
| `UPGRADER_ROLE` | Governance **timelock** | Authorizes upgrades on role-gated UUPS modules. |
| `GUARDIAN_ROLE` | Guardian | Pause/unpause user paths and create one persistent reserve-loss arm; cannot release, renew, adjudicate, or execute the cascade. |
| `MINTER_ROLE` | MintRedeemController | Mint and burn USDfr through the backing-checked controller path. |
| `CONTROLLER_ROLE` | MintRedeemController | ReserveManager deposit/release custody operations. |
| `CREDIT_ROLE` | WaterfallEngine, DefaultManager, ClaimBridge | Trusted internal credit-module primitives; never an EOA. |
| `LOSS_BURNER_ROLE` | DefaultManager, ReserveManager | Burn protocol-owned junior capital and pro-rata senior vault assets during authenticated loss cascades; never held by WaterfallEngine or an EOA. |
| `FEE_ACCOUNTING_ROLE` | CuratorModule, SGrove, DefaultManager | Bracket fee-neutral junior-capacity changes; never an EOA. |
| `COMPLIANCE_ADMIN_ROLE` | Ops / compliance | KYC allow-list and jurisdiction blocklist; cannot set protocol exemptions. |
| `RESERVE_ADMIN_ROLE` | Governance **timelock** | Ratify bounded reserve losses and account physically recovered reserve capital. |
| `ORIGINATOR_ROLE` | Ops (Forest Road) | Originate facilities through ClaimBridge. |
| `ATTESTER_ROLE` | The m-of-n attester keys | Authorized EIP-712 signers; the oracle verifies bundles against current holders. |
| `SERVICER_ROLE` | Ops (Forest Road) | Facility funding, repayment distribution, default, acceleration, loss realization, and cure operations. |
| `SETTLEMENT_KEEPER_ROLE` | Dedicated queue keeper + ops-Safe backstop | Drive RedemptionQueue.closeEpoch and choose when its contract-bounded liquidity snapshot is taken. |
<!-- END GENERATED PRIVILEGE ROLES -->

## Canonical privilege-audit module inventory

<!-- BEGIN GENERATED PRIVILEGE MODULES -->
<!-- Generated from config/privilege-topology.json; do not edit this block. -->
| Deployment field | Contract | Privilege audit | Reason / handover treatment |
|---|---|---|---|
| `compliance` | `ComplianceRegistry` | Included | Admin/upgrader handed to Timelock |
| `usdfr` | `USDfr` | Included | Admin/upgrader handed to Timelock |
| `reserves` | `ReserveManager` | Included | Admin/upgrader handed to Timelock |
| `controller` | `MintRedeemController` | Included | Admin/upgrader handed to Timelock |
| `vault` | `SUSDfr` | Included | Admin/upgrader handed to Timelock |
| `points` | `PointsModule` | Included | Admin/upgrader handed to Timelock |
| `registry` | `CollateralRegistry` | Included | Admin/upgrader handed to Timelock |
| `oracle` | `AttestationOracle` | Included | Admin/upgrader handed to Timelock |
| `bridge` | `ClaimBridge` | Included | Admin/upgrader handed to Timelock |
| `curator` | `CuratorModule` | Included | Admin/upgrader handed to Timelock |
| `waterfall` | `WaterfallEngine` | Included | Admin/upgrader handed to Timelock |
| `defaultManager` | `DefaultManager` | Included | Admin/upgrader handed to Timelock |
| `assessedImpairmentSource` | `AssessedImpairmentSource` | Included | Admin/upgrader handed to Timelock |
| `queue` | `RedemptionQueue` | Included | Admin/upgrader handed to Timelock |
| `sGrove` | `SGrove` | Included | Admin/upgrader handed to Timelock |
| `grove` | `GroveToken` | Included | Admin/upgrader handed to Timelock |
| `timelock` | `ForestRoadTimelock` | Included | Timelock role graph scanned directly |
| `mtmExecutor` | `MtmAtomicExecutor` | Excluded | Immutable, non-AccessControl atomic executor; no role graph exists to scan or hand over. |
| `governor` | `FRGovernor` | Excluded | Governor-authorized rather than AccessControl-authorized; hasRole scanning is inapplicable. |
| `votesAggregator` | `GroveVotesAggregator` | Excluded | Immutable, role-less IVotes view aggregator. |
| `stable` | `MockERC20` | Excluded | External canonical USDC in production and a role-less mock in local deployments. |
<!-- END GENERATED PRIVILEGE MODULES -->

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
| ReserveManager | `setLossController`, `setReserveLossModules`, `setGuardianReserveLossArmsEnabled`, `cancelAndDisable`, `finalizeAndDisable`; no generic asset or reserve-instrument setter. The legacy `writeDownIdleUSDC` selector always reverts. |
| USDfr | `setComplianceModule` |
| CuratorModule | `setCuratorApproved`, `setFirstLossTarget`, **`liftDefaultFreeze`** (audit R4-EC2) |
| AttestationOracle | `setThreshold` (floored ≥2 for high-value kinds), `revoke` |
| RedemptionQueue | `setEpochDuration` (the ADR-0022 settlement HEARTBEAT, not the hold), `setEpochLiquidityBps`, **`setRedeemCooldown`** (ADR-0022 Option X — the forced per-request holding period; applies uniformly to in-flight requests, so a lengthening is bounded by the timelock delay), `setMinRedemptionValue` |
| WaterfallEngine | `setProtocolFee`, `setOriginationFee`, `setFeeRecipient`, **`setDefaultManager`** (ADR-0022 — wires the clean-resolve impairment hook; zero disables it) |
| DefaultManager | `setRemedyRef`, `setCureWindow`, **`setGraceWindow`** (H-5 — per-class past-due grace, capped at `DEFAULT_REDEEM_COOLDOWN`), `setBackstop` |
| AssessedImpairmentSource | `setAssessment`, `clearAssessment`, `setBaseSource` (ADR-0027 — time-limited professional senior-loss mark; assessment can only lower the live zero-recovery base and is invalidated by any revision/state-hash change) |
| SGrove | `setUnbondingPeriod`, **`setRewardsDuration`** (audit R4-EC1). ADR-0035 removes the per-event-cap setter. |
| PointsModule | `setRate`, `setUSDfrMultiplier`, `setCuratorMultiplier`, `setCuratorModule` |

### Operational roles (Forest Road, single-purpose)

| Role | Function(s) | Guard beyond the role |
|---|---|---|
| `ORIGINATOR_ROLE` | `ClaimBridge.originate` | + full attestation mint-gate (m-of-n) + concentration limits |
| `SERVICER_ROLE` | `WaterfallEngine.{fund, distribute}`, `DefaultManager.{declareDefault, accelerate, realizeLoss, clearPastDue}` | funding is bound to the signed recipient; payment/default/loss/cure facts are exact, single-use attestations |
| `MINTER_ROLE` | `USDfr.{mint, burn}` | held only by the controller; every mint is backing-asserted and burns remain live during an emergency pause |
| `CONTROLLER_ROLE` | `ReserveManager.{depositUSDC, releaseUSDC}` | held only by the controller; the only primary asset is configured USDC |
| `RESERVE_ADMIN_ROLE` | `ReserveManager.{ratifyAndOpen, creditRecoveredIdleUSDC}` | ratification re-derives the canonical live shortfall and cannot exceed the voted maximum; recovery credit cannot exceed physical surplus or the arm's remaining write-down ceiling |
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
| `MintRedeemController.burnLoss` | WaterfallEngine, DefaultManager, ReserveManager | **no** (facility or custody cascade) |
| `CuratorModule.absorbLoss` | DefaultManager | **no** (facility cascade) |
| `CuratorModule.absorbGlobalLoss` | ReserveManager | **no** (classless custody cascade) |
| `CuratorModule.freezeOnDefault` | DefaultManager | **no** |
| `SGrove.coverShortfall(eventId, amount)` | DefaultManager, ReserveManager | **no** (cascade). ADR-0035: `eventId` is observability only; every call reaches the same live reserve. One shortfall may exhaust layer two, leaving all later loss to senior principal until replenishment. |
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
| `sUSDfr.beginFeeNeutralMarkedNavChange` / `endFeeNeutralMarkedNavChange` | SGrove | Brackets `fundCoverage` |
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
- `ReserveManager.reconcileIdleUSDC` — always permissionless and observation-only. It derives and
  emits the canonical recorded/live/shortfall tuple but never changes backing or moves junior or
  senior capital. A real backing reduction requires arm-bound `RESERVE_ADMIN_ROLE` ratification
  and runs the ordered loss cascade atomically.
- `SGrove.fundCoverage` — donates USDfr to the coverage reserve (only ever raises capacity and is
  the only way to restore layer-two capacity after exhaustion).
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
- `RedemptionQueue.closeEpoch` is intentionally absent from this permissionless list: it requires
  `SETTLEMENT_KEEPER_ROLE`, held by a dedicated single-role hot EOA and an ops-Safe backstop. The
  role has no parameter, role-graph or upgrade authority, but it is economically meaningful because
  its holder controls when the contract samples liquidity and initiates FIFO settlement.
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
mirroring `protocolExempt`) is flagged in `security-review.md` R5-PAUSE1.\n\n## Compiler-derived role surface and probe disposition

The generated block below is the compiler-backed role/function matrix. It is derived from the AST of
`contracts/src` and `contracts/script`, cross-checked against compiled `methodIdentifiers`, and
includes inherited role-admin entrypoints plus the non-deployed recovery and timelock modules. It is
not a hand-maintained list.

The invariant access-control handler still needs module-specific calldata and therefore retains its
stateful probe branches. Its disposition is generated separately at
`docs/remediation/landing-2026-08-11/ACCESS_CONTROL_PROBE_COVERAGE.json`: this landing has 196
role-gated functions represented by 197 guarded rows, 28 rows matched to executable handler probes,
and 169 explicit named exclusions. The exclusions are not counted as coverage; each carries a reason
(code plus prose) and remains visible to the audit stream. This is deliberately not reported as
196/196 proof.

Run from the repository root:

```
node tools/generate-access-control-matrix.mjs --check
node tools/check-access-control-probes.mjs --check
```

The second command regenerates the AST model and parses the handler's probe branches. It fails when a
role-gated row is added or removed without an updated committed disposition, so a new privileged
function cannot silently reduce the measured surface.

<!-- BEGIN GENERATED ACCESS-CONTROL MATRIX -->
<!-- GENERATED by tools/generate-access-control-matrix.mjs from the compiler AST of
     contracts/src + contracts/script and the compiled artifacts' methodIdentifiers.
     DO NOT EDIT THIS BLOCK BY HAND — run the tool. Prose outside the block is human. -->

_Generated from 24 modules_

### Declared roles (from `src/libraries/Roles.sol`)

| Role | Identifier |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `bytes32(0)` (inherited from OZ `AccessControl`) |
| `ATTESTER_ROLE` | `keccak256("ATTESTER_ROLE")` |
| `COMPLIANCE_ADMIN_ROLE` | `keccak256("COMPLIANCE_ADMIN_ROLE")` |
| `CONTROLLER_ROLE` | `keccak256("CONTROLLER_ROLE")` |
| `CREDIT_ROLE` | `keccak256("CREDIT_ROLE")` |
| `FEE_ACCOUNTING_ROLE` | `keccak256("FEE_ACCOUNTING_ROLE")` |
| `GUARDIAN_ROLE` | `keccak256("GUARDIAN_ROLE")` |
| `LOSS_BURNER_ROLE` | `keccak256("LOSS_BURNER_ROLE")` |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` |
| `ORIGINATOR_ROLE` | `keccak256("ORIGINATOR_ROLE")` |
| `RESERVE_ADMIN_ROLE` | `keccak256("RESERVE_ADMIN_ROLE")` |
| `SERVICER_ROLE` | `keccak256("SERVICER_ROLE")` |
| `SETTLEMENT_KEEPER_ROLE` | `keccak256("SETTLEMENT_KEEPER_ROLE")` |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` |

`script/PrivilegeAudit.sol` enumerates 0 of these 13. **GAP: `ATTESTER_ROLE`, `COMPLIANCE_ADMIN_ROLE`, `CONTROLLER_ROLE`, `CREDIT_ROLE`, `FEE_ACCOUNTING_ROLE`, `GUARDIAN_ROLE`, `LOSS_BURNER_ROLE`, `MINTER_ROLE`, `ORIGINATOR_ROLE`, `RESERVE_ADMIN_ROLE`, `SERVICER_ROLE`, `SETTLEMENT_KEEPER_ROLE`, `UPGRADER_ROLE`** — declared but NOT scanned by the deployer-privilege receipt, so a hot key holding it reads clean.

### Role x function — every role-gated external entrypoint

One row per `(module, external function, guard)`. Selector is the compiled selector; the AST and `methodIdentifiers` were cross-checked and agree for every module below.

| Module | Function | Selector | Guard | How the guard is reached | Pausable |
|---|---|---|---|---|---|
| `AssessedImpairmentSource` | `clearAssessment()` | `0xe4b666c8` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `AssessedImpairmentSource` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `AssessedImpairmentSource` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `AssessedImpairmentSource` | `setAssessment(uint256,uint64,bytes32)` | `0xa53c4090` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `AssessedImpairmentSource` | `setBaseSource(address)` | `0x14936047` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `AssessedImpairmentSource` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in AssessedImpairmentSource._authorizeUpgrade *(indirect)* | no |
| `AttestationOracle` | `consume(uint256,uint8)` | `0x107ebbaa` | `CREDIT_ROLE` | onlyRole modifier | no |
| `AttestationOracle` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `AttestationOracle` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `AttestationOracle` | `revoke(uint256,uint8)` | `0x14f6b1fb` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `AttestationOracle` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `AttestationOracle` | `setThreshold(uint8,uint8)` | `0x315344c3` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `AttestationOracle` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `AttestationOracle` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in AttestationOracle._authorizeUpgrade *(indirect)* | no |
| `ClaimBridge` | `amendTerms(uint256,bytes32,(uint16,uint64,uint64,uint64,uint8,uint8,bool,bytes32,bytes32,bytes32))` | `0x67e38793` | `ORIGINATOR_ROLE` | onlyRole modifier | yes |
| `ClaimBridge` | `cancelPending(uint256)` | `0x5588fdf1` | `ORIGINATOR_ROLE` | onlyRole modifier | no |
| `ClaimBridge` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `ClaimBridge` | `originate(address,(uint256,bytes32,bytes32,uint256,uint16,uint16,uint64,address,uint64,uint64,uint8,uint8,bool,bytes32,bytes32,bytes32,bytes32))` | `0xe603932c` | `ORIGINATOR_ROLE` | onlyRole modifier | yes |
| `ClaimBridge` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `ClaimBridge` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `ClaimBridge` | `safeTransferFrom(address,address,uint256,bytes)` | `0xb88d4fde` | `DEFAULT_ADMIN_ROLE` | inline hasRole in ClaimBridge._update *(indirect)* | no |
| `ClaimBridge` | `safeTransferFrom(address,address,uint256)` | `0x42842e0e` | `DEFAULT_ADMIN_ROLE` | inline hasRole in ClaimBridge._update *(indirect)* | no |
| `ClaimBridge` | `setNextPaymentDue(uint256,uint64)` | `0x716d5bf8` | `CREDIT_ROLE` | onlyRole modifier | no |
| `ClaimBridge` | `setRequiredMintAttestations(uint256,uint256)` | `0x33ed51c9` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ClaimBridge` | `transferFrom(address,address,uint256)` | `0x23b872dd` | `DEFAULT_ADMIN_ROLE` | inline hasRole in ClaimBridge._update *(indirect)* | no |
| `ClaimBridge` | `transitionState(uint256,uint8)` | `0xb6d4cd7d` | `CREDIT_ROLE` | onlyRole modifier | no |
| `ClaimBridge` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `ClaimBridge` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in ClaimBridge._authorizeUpgrade *(indirect)* | no |
| `CollateralRegistry` | `clearBorrowerLimitOverride(bytes32)` | `0x5a88773e` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `CollateralRegistry` | `recordExposureDecrease(uint256,bytes32,bytes32,uint256)` | `0x68b48233` | `CREDIT_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `recordExposureIncrease(uint256,bytes32,bytes32,uint256)` | `0xc7dbcab3` | `CREDIT_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `CollateralRegistry` | `setBorrowerLimit(uint16)` | `0x2a3abef5` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `setBorrowerLimitOverride(bytes32,uint16)` | `0x87cc8ee5` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `setClass(uint256,(string,uint8,bool,uint16,uint64,uint16,uint16,uint16,uint64))` | `0x35de1f97` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `setConcentrationFloor(uint256)` | `0x70e89f5b` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `setPastDueWeight(uint256)` | `0x0402d85e` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `setStateLimit(uint16)` | `0x6e13b82e` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CollateralRegistry` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in CollateralRegistry._authorizeUpgrade *(indirect)* | no |
| `ComplianceRegistry` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `ComplianceRegistry` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `ComplianceRegistry` | `setAllowed(address,bool)` | `0x4697f05d` | `COMPLIANCE_ADMIN_ROLE` | onlyRole modifier | no |
| `ComplianceRegistry` | `setAllowedBatch(address[],bool)` | `0x5a265dae` | `COMPLIANCE_ADMIN_ROLE` | onlyRole modifier | no |
| `ComplianceRegistry` | `setJurisdictionBlocked(address,bool)` | `0x76e4099c` | `COMPLIANCE_ADMIN_ROLE` | onlyRole modifier | no |
| `ComplianceRegistry` | `setProtocolExempt(address,bool)` | `0x18cf2b61` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ComplianceRegistry` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in ComplianceRegistry._authorizeUpgrade *(indirect)* | no |
| `CuratorModule` | `absorbGlobalLoss(uint256)` | `0x3f17045f` | `CREDIT_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `absorbLoss(uint256,uint256)` | `0xc00b2a1f` | `CREDIT_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `cancelCustodyPreArm()` | `0x5b3c4fdc` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `freezeOnDefault(uint256)` | `0x409627bc` | `CREDIT_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `governanceUnpause()` | `0xd108ca7f` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `CuratorModule` | `liftDefaultFreeze(uint256)` | `0xd6158b3d` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `preArmCustodyFreeze()` | `0xe6bb0242` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `replenishCustodyPreArmBudget()` | `0xe5741763` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `CuratorModule` | `setCuratorApproved(uint256,address,bool)` | `0x1ff35d35` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `setFirstLossTarget(uint256,uint256)` | `0xb827644a` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `setGovernor(address)` | `0xc42cf535` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `setPointsModule(address)` | `0xe8bf3999` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `setReserveManager(address)` | `0xdf7da754` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `CuratorModule` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in CuratorModule._authorizeUpgrade *(indirect)* | no |
| `DefaultManager` | `accelerate(uint256)` | `0x9d94f3d7` | `SERVICER_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `clearPastDue(uint256,bytes32)` | `0xcb22b7f8` | `SERVICER_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `declareDefault(uint256,bytes32)` | `0x21c221d7` | `SERVICER_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `DefaultManager` | `initializeCommitmentLedger()` | `0x140fc2c1` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `onDefaultRecovery(uint256)` | `0xf3bc6321` | `CREDIT_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `onDefaultResolved(uint256)` | `0x6e00dfd7` | `CREDIT_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `onPerformingRepayment(uint256)` | `0x3898cdfe` | `CREDIT_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `realizeLoss(uint256,uint256,bytes32)` | `0xc40b9521` | `SERVICER_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `DefaultManager` | `setBackstop(address)` | `0x916c2b87` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `setCureWindow(uint256,uint64)` | `0x9a9528eb` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `setGraceWindow(uint256,uint64)` | `0x985a1740` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `setRemedyRef(uint256,bytes32)` | `0x7316018c` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `DefaultManager` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in DefaultManager._authorizeUpgrade *(indirect)* | no |
| `GroveToken` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `GroveToken` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `GroveToken` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in GroveToken._authorizeUpgrade *(indirect)* | no |
| `MintRedeemController` | `burnLoss(address,uint256)` | `0xc3b0dba1` | `LOSS_BURNER_ROLE` | onlyRole modifier | no |
| `MintRedeemController` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `MintRedeemController` | `mintYield(address,uint256)` | `0x06ddf8b9` | `CREDIT_ROLE` | onlyRole modifier | yes |
| `MintRedeemController` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `MintRedeemController` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `MintRedeemController` | `setLossSource(address,bool)` | `0xaa469c3d` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `MintRedeemController` | `setYieldSink(address,bool)` | `0x4e8d0f87` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `MintRedeemController` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `MintRedeemController` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in MintRedeemController._authorizeUpgrade *(indirect)* | no |
| `PointsModule` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `PointsModule` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `PointsModule` | `setCuratorModule(address)` | `0x9554e98c` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `PointsModule` | `setCuratorMultiplier(uint32)` | `0xd67d68e7` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `PointsModule` | `setRate(uint256)` | `0x34fcf437` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `PointsModule` | `setUSDfrMultiplier(uint32)` | `0x6f6e4572` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `PointsModule` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in PointsModule._authorizeUpgrade *(indirect)* | no |
| `RecoveryTopUpDistributor` | `createRound(bytes32,uint256,uint64,address,bytes32)` | `0x112aea15` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `RecoveryTopUpDistributor` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `RecoveryTopUpDistributor` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `RecoveryTopUpDistributor` | `reclaimExpired(uint256)` | `0x01bb9baa` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `RecoveryTopUpDistributor` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `RecoveryTopUpDistributor` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `RecoveryTopUpDistributor` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in RecoveryTopUpDistributor._authorizeUpgrade *(indirect)* | no |
| `RedemptionQueue` | `closeEpoch(uint256)` | `0xd16d9057` | `SETTLEMENT_KEEPER_ROLE` | onlyRole modifier | yes |
| `RedemptionQueue` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `RedemptionQueue` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `RedemptionQueue` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `RedemptionQueue` | `setEpochDuration(uint64)` | `0x5f98ba82` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `RedemptionQueue` | `setEpochLiquidityBps(uint16)` | `0x60fe6542` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `RedemptionQueue` | `setMinRedemptionValue(uint256)` | `0xc0bf8aed` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `RedemptionQueue` | `setRedeemCooldown(uint64)` | `0xdfe2162f` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `RedemptionQueue` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `RedemptionQueue` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in RedemptionQueue._authorizeUpgrade *(indirect)* | no |
| `ReserveManager` | `armReserveLossFreeze(bytes32)` | `0xbace10d1` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `cancelAndDisable(uint256,bytes32)` | `0x76cfbb62` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `closeReserveLossIncident(uint256)` | `0x31bb795c` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `creditRecoveredIdleUSDC(uint256,bytes32)` | `0x724f3d69` | `RESERVE_ADMIN_ROLE` | inline hasRole in ReserveManager._requireReserveLossAdmin *(indirect)* | no |
| `ReserveManager` | `depositUSDC(address,uint256)` | `0x56b22bf2` | `CONTROLLER_ROLE` | inline hasRole | yes |
| `ReserveManager` | `depositUSDC(address,uint256)` | `0x56b22bf2` | `CREDIT_ROLE` | inline hasRole | yes |
| `ReserveManager` | `finalizeAndDisable(uint256,bytes32)` | `0x0adc4b6c` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `ReserveManager` | `openReserveLossIncident(uint256,bytes32)` | `0xd8b080c0` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `ratifyAndOpen(uint256,bytes32,uint256)` | `0x9ead8944` | `RESERVE_ADMIN_ROLE` | inline hasRole in ReserveManager._requireReserveLossAdmin *(indirect)* | no |
| `ReserveManager` | `recognizePrincipalImpairment(uint256,uint256,bytes32)` | `0x63874b58` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `recordDeployment(uint256,address,uint256)` | `0x334b7433` | `CREDIT_ROLE` | onlyRole modifier | yes |
| `ReserveManager` | `recordFeeCapitalization(uint256,uint256)` | `0x2fc3aadd` | `CREDIT_ROLE` | onlyRole modifier | yes |
| `ReserveManager` | `recordPayment(uint256,address,uint256,uint256)` | `0x67d2cd3d` | `CREDIT_ROLE` | onlyRole modifier | yes |
| `ReserveManager` | `recordPrincipalWritedown(uint256,uint256)` | `0x69249e56` | `CREDIT_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `releasePrincipalImpairment(uint256,uint256,bytes32)` | `0x97e1594e` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `releaseUSDC(address,uint256)` | `0xca258c9f` | `CONTROLLER_ROLE` | onlyRole modifier | yes |
| `ReserveManager` | `resolveReserveDeficit(bytes32)` | `0xaae98a38` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `ReserveManager` | `setGuardianReserveLossArmsEnabled(bool)` | `0x34ec2d41` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `setLossAbsorber(address)` | `0x98ca56d8` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `setLossController(address)` | `0x16783256` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `setReserveLossModules(address,address,address,address,address)` | `0x0973f315` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `ReserveManager` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in ReserveManager._authorizeUpgrade *(indirect)* | no |
| `SGrove` | `coverShortfall(uint256,uint256)` | `0xb636ed55` | `CREDIT_ROLE` | onlyRole modifier | no |
| `SGrove` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `SGrove` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `SGrove` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `SGrove` | `setRewardsDuration(uint64)` | `0x5fe8301b` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SGrove` | `setUnbondingPeriod(uint64)` | `0xf10d1de1` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SGrove` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `SGrove` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in SGrove._authorizeUpgrade *(indirect)* | no |
| `SUSDfr` | `beginFeeNeutralMarkedNavChange()` | `0x3b045933` | `FEE_ACCOUNTING_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `beginYieldNotification()` | `0xe574b69e` | `CREDIT_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `clearStaleFeeOperation()` | `0x40fc7d4e` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `clearUnreadableImpairmentSource()` | `0x29bbfca0` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `endFeeNeutralMarkedNavChange()` | `0xea7a5b04` | `FEE_ACCOUNTING_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `SUSDfr` | `notifyYield(uint256)` | `0x3ded15b5` | `CREDIT_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `SUSDfr` | `setFeeRecipient(address)` | `0xe74b981b` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `setImpairmentSource(address)` | `0x07727c41` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `setManagementFee(uint16)` | `0x8dd09af3` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `setPerformanceFee(uint16)` | `0xaa290e6d` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `setPointsModule(address)` | `0xe8bf3999` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `setRedemptionQueue(address)` | `0x3b4c46d0` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `setYieldVestingPeriod(uint64)` | `0xe2da4d42` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `SUSDfr` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in SUSDfr._authorizeUpgrade *(indirect)* | no |
| `TimelockControllerUpgradeable` | `cancel(bytes32)` | `0xc4d252f5` | `CANCELLER_ROLE` | onlyRole modifier | no |
| `TimelockControllerUpgradeable` | `execute(address,uint256,bytes,bytes32,bytes32)` | `0x134008d3` | `EXECUTOR_ROLE` | modifier onlyRoleOrOpenRole | no |
| `TimelockControllerUpgradeable` | `executeBatch(address[],uint256[],bytes[],bytes32,bytes32)` | `0xe38335e5` | `EXECUTOR_ROLE` | modifier onlyRoleOrOpenRole | no |
| `TimelockControllerUpgradeable` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `TimelockControllerUpgradeable` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `TimelockControllerUpgradeable` | `schedule(address,uint256,bytes,bytes32,bytes32,uint256)` | `0x01d5062a` | `PROPOSER_ROLE` | onlyRole modifier | no |
| `TimelockControllerUpgradeable` | `scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)` | `0x8f2a0bb0` | `PROPOSER_ROLE` | onlyRole modifier | no |
| `USDfr` | `burn(address,uint256)` | `0x9dc29fac` | `MINTER_ROLE` | inline _checkRole | no |
| `USDfr` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `USDfr` | `mint(address,uint256)` | `0x40c10f19` | `MINTER_ROLE` | onlyRole modifier | no |
| `USDfr` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `USDfr` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `USDfr` | `setComplianceModule(address)` | `0x423db9c7` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `USDfr` | `setPointsModule(address)` | `0xe8bf3999` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `USDfr` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `USDfr` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in USDfr._authorizeUpgrade *(indirect)* | no |
| `WaterfallEngine` | `distribute((uint256,bytes32,address,uint256,uint256,uint64))` | `0x1ad2f567` | `SERVICER_ROLE` | onlyRole modifier | yes |
| `WaterfallEngine` | `fund(uint256,uint256)` | `0xa65e2cfd` | `SERVICER_ROLE` | onlyRole modifier | yes |
| `WaterfallEngine` | `grantRole(bytes32,address)` | `0x2f2ff15d` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `WaterfallEngine` | `pause()` | `0x8456cb59` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `WaterfallEngine` | `revokeRole(bytes32,address)` | `0xd547741f` | `DEFAULT_ADMIN_ROLE:via getRoleAdmin(role)` | onlyRole modifier | no |
| `WaterfallEngine` | `setDefaultManager(address)` | `0x50474f3a` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `WaterfallEngine` | `setFeeRecipient(address)` | `0xe74b981b` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `WaterfallEngine` | `setOriginationFee(uint256,uint16)` | `0x40caee7d` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `WaterfallEngine` | `setProtocolFee(uint16)` | `0xe4467f35` | `DEFAULT_ADMIN_ROLE` | onlyRole modifier | no |
| `WaterfallEngine` | `unpause()` | `0x3f4ba83a` | `GUARDIAN_ROLE` | onlyRole modifier | no |
| `WaterfallEngine` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | `UPGRADER_ROLE` | onlyRole modifier in WaterfallEngine._authorizeUpgrade *(indirect)* | no |

### Privileged or explicitly disabled, but NOT role-gated (inline caller / governance checks)

These non-role surfaces would be invisible to a scan that only looked for `onlyRole`. Most carry real authority; a row marked terminally disabled has no executable effect in this version. They are the reason the matrix cannot be built from `Roles.sol` alone.

| Module | Function | Selector | Guard | How | Pausable |
|---|---|---|---|---|---|
| `CommitmentLedger` | `register(uint256,uint256,uint256)` | `0xfaa5c564` | address-gated | { if (msg.sender != manager) revert CommitmentLedger_NotManager(msg.sender); _; } | no |
| `CommitmentLedger` | `release(uint256)` | `0x37bdc99b` | address-gated | { if (msg.sender != manager) revert CommitmentLedger_NotManager(msg.sender); _; } | no |
| `CommitmentLedger` | `sync(uint256,uint256,uint256,uint256)` | `0xa29aba88` | address-gated | { if (msg.sender != manager) revert CommitmentLedger_NotManager(msg.sender); _; } | no |
| `CommitmentLedger` | `updatePrincipal(uint256,uint256)` | `0x44d6ed31` | address-gated | { if (msg.sender != manager) revert CommitmentLedger_NotManager(msg.sender); _; } | no |
| `CuratorModule` | `postFirstLoss(uint256,uint256)` | `0x9be38591` | allowlist-gated | !$.approved[classId][msg.sender] | yes |
| `DefaultManager` | `absorbReserveLoss(uint256,uint256)` | `0xd1f07b38` | address-gated | msg.sender != address($.reserves) | no |
| `DefaultManager` | `drawForSeniorExit(uint256)` | `0x9eee3b33` | address-gated | msg.sender != address($.controller) | no |
| `FRGovernor` | `relay(address,uint256,bytes)` | `0xc28bc2fa` | governance (`onlyGovernance`) | modifier onlyGovernance | no |
| `FRGovernor` | `setProposalThreshold(uint256)` | `0xece40cc1` | governance (`onlyGovernance`) | modifier onlyGovernance | no |
| `FRGovernor` | `setVotingDelay(uint48)` | `0x79051887` | governance (`onlyGovernance`) | modifier onlyGovernance | no |
| `FRGovernor` | `setVotingPeriod(uint32)` | `0xe540d01d` | governance (`onlyGovernance`) | modifier onlyGovernance | no |
| `FRGovernor` | `updateQuorumNumerator(uint256)` | `0x06f3f9e6` | governance (`onlyGovernance`) | modifier onlyGovernance | no |
| `FRGovernor` | `updateTimelock(address)` | `0xa890c910` | governance (`onlyGovernance`) | modifier onlyGovernance; terminally disabled in v1 (body always reverts) | no |
| `FRGovernor` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | governance (`onlyGovernance`) | modifier onlyGovernance in FRGovernor._authorizeUpgrade *(indirect)* | no |
| `PointsModule` | `onCuratorLoss(uint256,uint256,uint256)` | `0x5b6d8ccc` | address-gated | msg.sender != $.curatorModule | no |
| `PointsModule` | `onCuratorStakeChange(address,uint256,uint256)` | `0x72191945` | address-gated | msg.sender != $.curatorModule | no |
| `PointsModule` | `onSharesTransfer(address,address,uint256)` | `0x8b1914c6` | address-gated | msg.sender != $.vault | no |
| `PointsModule` | `onUSDfrTransfer(address,address,uint256)` | `0xa2417573` | address-gated | msg.sender != $.usdfrToken | no |
| `ReserveManager` | `consumeExitPrepayment(uint256,uint256)` | `0x9d2fae9b` | address-gated | msg.sender != address($.lossAbsorber) | no |
| `ReserveManager` | `recordExitPrepayment(uint256)` | `0x1e5ca889` | address-gated | msg.sender != address($.lossAbsorber) | no |
| `SUSDfr` | `prepareRedemptionPricing(uint256)` | `0xb0845d9f` | address-gated | msg.sender != $.redemptionQueue | no |
| `TimelockControllerUpgradeable` | `updateDelay(uint256)` | `0x64d62353` | address-gated | sender != address(this) | no |

### Permissionless or self-scoped state-changing entrypoints (no privileged guard)

Derived, not asserted: every non-`view`/`pure` external function with no role, governance or trusted-caller guard anywhere on its reachable path. Caller-owned actions are explicitly marked self-scoped. If another row appears here that should not be permissionless, that is a finding, not a documentation defect.

| Module | Function | Selector | Pausable | Note |
|---|---|---|---|---|
| `AssessedImpairmentSource` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `AttestationOracle` | `attest((uint256,uint8,bytes32,uint64,uint64,uint256),bytes[])` | `0xa23c287e` | yes |  |
| `AttestationOracle` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `ClaimBridge` | `approve(address,uint256)` | `0x095ea7b3` | no |  |
| `ClaimBridge` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `ClaimBridge` | `setApprovalForAll(address,bool)` | `0xa22cb465` | no |  |
| `CollateralRegistry` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `CollateralRegistry` | `syncConcentrationBreaches(bytes32[],bytes32[])` | `0x436ee48f` | no |  |
| `CommitmentLedger` | `coverDelegate(address,address,uint256,uint256)` | `0xc4e35fac` | no |  |
| `CommitmentLedgerFactory` | `create(address)` | `0x9ed93318` | no |  |
| `ComplianceRegistry` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `CuratorModule` | `claimClosedRound(uint256,address)` | `0x65e09b4b` | no |  |
| `CuratorModule` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `CuratorModule` | `withdrawFirstLoss(uint256,uint256)` | `0xef3f3f40` | yes |  |
| `DefaultManager` | `clearMarginCall(uint256)` | `0x4954fac6` | yes |  |
| `DefaultManager` | `liquidate(uint256)` | `0x415f1240` | yes |  |
| `DefaultManager` | `marginCall(uint256)` | `0xdedeaae6` | yes |  |
| `DefaultManager` | `markPastDue(uint256)` | `0x34615eec` | no |  |
| `DefaultManager` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `FRGovernor` | `cancel(address[],uint256[],bytes[],bytes32)` | `0x452115d6` | no | self-scoped: proposer-scoped; Pending state only |
| `FRGovernor` | `castVote(uint256,uint8)` | `0x56781388` | no |  |
| `FRGovernor` | `castVoteBySig(uint256,uint8,address,bytes)` | `0x8ff262e3` | no |  |
| `FRGovernor` | `castVoteWithReason(uint256,uint8,string)` | `0x7b3c71d3` | no |  |
| `FRGovernor` | `castVoteWithReasonAndParams(uint256,uint8,string,bytes)` | `0x5f398a14` | no |  |
| `FRGovernor` | `castVoteWithReasonAndParamsBySig(uint256,uint8,address,string,bytes,bytes)` | `0x5b8d0e0d` | no |  |
| `FRGovernor` | `execute(address[],uint256[],bytes[],bytes32)` | `0x2656227d` | no |  |
| `FRGovernor` | `onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)` | `0xbc197c81` | no |  |
| `FRGovernor` | `onERC1155Received(address,address,uint256,uint256,bytes)` | `0xf23a6e61` | no |  |
| `FRGovernor` | `onERC721Received(address,address,uint256,bytes)` | `0x150b7a02` | no |  |
| `FRGovernor` | `propose(address[],uint256[],bytes[],string)` | `0x7d5e81e2` | no |  |
| `FRGovernor` | `queue(address[],uint256[],bytes[],bytes32)` | `0x160cbed7` | no |  |
| `GroveToken` | `approve(address,uint256)` | `0x095ea7b3` | no |  |
| `GroveToken` | `delegate(address)` | `0x5c19a95c` | no |  |
| `GroveToken` | `delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)` | `0xc3cda520` | no |  |
| `GroveToken` | `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` | `0xd505accf` | no |  |
| `GroveToken` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `GroveToken` | `transfer(address,uint256)` | `0xa9059cbb` | no |  |
| `GroveToken` | `transferFrom(address,address,uint256)` | `0x23b872dd` | no |  |
| `MintRedeemController` | `mint(uint256)` | `0xa0712d68` | yes |  |
| `MintRedeemController` | `redeem(uint256,uint256,uint256)` | `0xb8192205` | yes |  |
| `MintRedeemController` | `redeem(uint256,uint256)` | `0x7cbc2373` | yes |  |
| `MintRedeemController` | `redeem(uint256)` | `0xdb006a75` | yes |  |
| `MintRedeemController` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `MtmAtomicExecutor` | `execute((uint256,uint8,bytes32,uint64,uint64,uint256),bytes[])` | `0x71860e0e` | no |  |
| `PointsModule` | `checkpoint(address)` | `0xa972985e` | no |  |
| `PointsModule` | `reconcile(address)` | `0x09a18635` | no |  |
| `PointsModule` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `RecoveryTopUpDistributor` | `claim(uint256,uint256,uint256,address,uint256,bytes32[])` | `0x0c3a0fff` | yes |  |
| `RecoveryTopUpDistributor` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `RedemptionQueue` | `claim(uint256)` | `0x379607f5` | no | self-scoped: r.owner != msg.sender |
| `RedemptionQueue` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `RedemptionQueue` | `requestRedeem(uint256)` | `0xaa2f892d` | yes |  |
| `ReserveManager` | `recapitalize(uint256)` | `0x0c47d267` | no |  |
| `ReserveManager` | `reconcileIdleUSDC()` | `0x87f0f89a` | no |  |
| `ReserveManager` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `SGrove` | `claimRewards()` | `0x372500ab` | yes |  |
| `SGrove` | `claimUnstake(uint256)` | `0xc5dd6fee` | yes |  |
| `SGrove` | `delegate(address)` | `0x5c19a95c` | no |  |
| `SGrove` | `delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)` | `0xc3cda520` | no |  |
| `SGrove` | `fundCoverage(uint256)` | `0x39db75da` | no |  |
| `SGrove` | `notifyRewards(uint256)` | `0xd3512cef` | no |  |
| `SGrove` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `SGrove` | `requestUnstake(uint256)` | `0x23095721` | yes |  |
| `SGrove` | `stake(uint256)` | `0xa694fc3a` | yes |  |
| `SUSDfr` | `accrueFees()` | `0x37a4e834` | no |  |
| `SUSDfr` | `approve(address,uint256)` | `0x095ea7b3` | no |  |
| `SUSDfr` | `deposit(uint256,address)` | `0x6e553f65` | no |  |
| `SUSDfr` | `mint(uint256,address)` | `0x94bf804d` | no |  |
| `SUSDfr` | `redeem(uint256,address,address)` | `0xba087652` | no |  |
| `SUSDfr` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `SUSDfr` | `transfer(address,uint256)` | `0xa9059cbb` | no |  |
| `SUSDfr` | `transferFrom(address,address,uint256)` | `0x23b872dd` | no |  |
| `SUSDfr` | `withdraw(uint256,address,address)` | `0xb460af94` | no |  |
| `TimelockControllerUpgradeable` | `onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)` | `0xbc197c81` | no |  |
| `TimelockControllerUpgradeable` | `onERC1155Received(address,address,uint256,uint256,bytes)` | `0xf23a6e61` | no |  |
| `TimelockControllerUpgradeable` | `onERC721Received(address,address,uint256,bytes)` | `0x150b7a02` | no |  |
| `TimelockControllerUpgradeable` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `USDfr` | `approve(address,uint256)` | `0x095ea7b3` | no |  |
| `USDfr` | `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` | `0xd505accf` | no |  |
| `USDfr` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |
| `USDfr` | `transfer(address,uint256)` | `0xa9059cbb` | no |  |
| `USDfr` | `transferFrom(address,address,uint256)` | `0x23b872dd` | no |  |
| `WaterfallEngine` | `renounceRole(bytes32,address)` | `0x36568abe` | no | self-scoped: callerConfirmation != _msgSender() |

### One-shot initialisers (`initializer` / `reinitializer`, no role)

Permissionless until consumed. Finding A-01 is exactly this surface on an *implementation* contract: whoever calls it first owns that instance. They are listed separately from the permissionless table so neither category can hide the other.

| Module | Function | Selector |
|---|---|---|
| `AssessedImpairmentSource` | `initialize(address,address,address)` | `0xc0c53b8b` |
| `AttestationOracle` | `initialize(address,address,address)` | `0xc0c53b8b` |
| `ClaimBridge` | `initialize(address,address,address,address,address)` | `0x1459457a` |
| `CollateralRegistry` | `initialize(address,address)` | `0x485cc955` |
| `ComplianceRegistry` | `initialize(address,address,address,address)` | `0xf8c8765e` |
| `CuratorModule` | `initialize(address,address,address,address,address,address)` | `0xcc2a9a5b` |
| `DefaultManager` | `initialize(address,address,address,(address,address,address,address,address,address,address,address))` | `0xca62058a` |
| `FRGovernor` | `initialize(address,address)` | `0x485cc955` |
| `GroveToken` | `initialize(address,address,address)` | `0xc0c53b8b` |
| `MintRedeemController` | `initialize(address,address,address,address,address,address)` | `0xcc2a9a5b` |
| `PointsModule` | `initialize(address,address,address,address,address)` | `0x1459457a` |
| `RecoveryTopUpDistributor` | `initialize(address,address,address,address)` | `0xf8c8765e` |
| `RedemptionQueue` | `initialize(address,address,address,address,address,address)` | `0xcc2a9a5b` |
| `ReserveManager` | `initialize(address,address,address,address,address)` | `0x1459457a` |
| `SGrove` | `initialize(address,address,address,address,address,address)` | `0xcc2a9a5b` |
| `SUSDfr` | `initialize(address,address,address,address,address,address)` | `0xcc2a9a5b` |
| `TimelockControllerUpgradeable` | `initialize(uint256,address[],address[],address)` | `0xc4c4c7b3` |
| `USDfr` | `initialize(address,address,address,address)` | `0xf8c8765e` |
| `WaterfallEngine` | `initialize(address,address,address,(address,address,address,address,address,address,address))` | `0x20c92f70` |

### Who holds each role — at deploy, and after handover

From the actual `grantRole` / `revokeRole` / `renounceRole` call sites in `script/Deploy.s.sol` and `script/Handover.s.sol`. Expressions are reproduced verbatim from source.

| Role | Granted on | To | Op | Script fn |
|---|---|---|---|---|
| `TIMELOCK_PROPOSER_ROLE` | `tl` | `d.governor` | grantRole | `Deploy.s.sol:_wire` |
| `TIMELOCK_CANCELLER_ROLE` | `tl` | `d.governor` | grantRole | `Deploy.s.sol:_wire` |
| `TIMELOCK_EXECUTOR_ROLE` | `tl` | `address(0)` | grantRole | `Deploy.s.sol:_wire` |
| `MINTER_ROLE` | `USDfr(d.usdfr)` | `d.controller` | grantRole | `Deploy.s.sol:_wire` |
| `MINTER_ROLE` | `USDfr(d.usdfr)` | `c.deployer` | renounceRole | `Deploy.s.sol:_wire` |
| `CONTROLLER_ROLE` | `ReserveManager(d.reserves)` | `d.controller` | grantRole | `Deploy.s.sol:_wire` |
| `RESERVE_ADMIN_ROLE` | `ReserveManager(d.reserves)` | `c.deployer` | grantRole | `Deploy.s.sol:_wire` |
| `ORIGINATOR_ROLE` | `br` | `c.opsAdmin` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `br` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `br` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `reg` | `d.bridge` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `reg` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `reg` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `ReserveManager(d.reserves)` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `ReserveManager(d.reserves)` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `MintRedeemController(d.controller)` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `LOSS_BURNER_ROLE` | `MintRedeemController(d.controller)` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `LOSS_BURNER_ROLE` | `MintRedeemController(d.controller)` | `d.reserves` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `CuratorModule(d.curator)` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `CuratorModule(d.curator)` | `d.reserves` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `AttestationOracle(d.oracle)` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `AttestationOracle(d.oracle)` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `AttestationOracle(d.oracle)` | `d.bridge` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `SGrove(d.sGrove)` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `SGrove(d.sGrove)` | `d.reserves` | grantRole | `Deploy.s.sol:_wire` |
| `SETTLEMENT_KEEPER_ROLE` | `RedemptionQueue(d.queue)` | `c.queueKeeper` | grantRole | `Deploy.s.sol:_wire` |
| `SETTLEMENT_KEEPER_ROLE` | `RedemptionQueue(d.queue)` | `c.opsAdmin` | grantRole | `Deploy.s.sol:_wire` |
| `FEE_ACCOUNTING_ROLE` | `SUSDfr(d.vault)` | `d.curator` | grantRole | `Deploy.s.sol:_wire` |
| `FEE_ACCOUNTING_ROLE` | `SUSDfr(d.vault)` | `d.sGrove` | grantRole | `Deploy.s.sol:_wire` |
| `FEE_ACCOUNTING_ROLE` | `SUSDfr(d.vault)` | `d.defaultManager` | grantRole | `Deploy.s.sol:_wire` |
| `SERVICER_ROLE` | `WaterfallEngine(d.waterfall)` | `c.opsAdmin` | grantRole | `Deploy.s.sol:_wire` |
| `SERVICER_ROLE` | `DefaultManager(d.defaultManager)` | `c.opsAdmin` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `DefaultManager(d.defaultManager)` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `CREDIT_ROLE` | `SUSDfr(d.vault)` | `d.waterfall` | grantRole | `Deploy.s.sol:_wire` |
| `ATTESTER_ROLE` | `AttestationOracle(d.oracle)` | `_attester1(c)` | grantRole | `Deploy.s.sol:_wire` |
| `ATTESTER_ROLE` | `AttestationOracle(d.oracle)` | `c.attester2` | grantRole | `Deploy.s.sol:_wire` |
| `COMPLIANCE_ADMIN_ROLE` | `cr` | `c.deployer` | grantRole | `Deploy.s.sol:_seed` |
| `RESERVE_ADMIN_ROLE` | `rm` | `d.timelock` | grantRole | `Deploy.s.sol:_handover` |
| `RESERVE_ADMIN_ROLE` | `rm` | `c.deployer` | renounceRole | `Deploy.s.sol:_handover` |
| `RESERVE_ADMIN_ROLE` | `rm` | `c.opsAdmin` | revokeRole | `Deploy.s.sol:_handover` |
| `COMPLIANCE_ADMIN_ROLE` | `cr` | `c.deployer` | renounceRole | `Deploy.s.sol:_handover` |
| `TIMELOCK_DEFAULT_ADMIN_ROLE` | `tl` | `c.deployer` | renounceRole | `Deploy.s.sol:_handover` |
| `DEFAULT_ADMIN_ROLE` | `m` | `timelock` | grantRole | `Deploy.s.sol:_handoverOne` |
| `DEFAULT_ADMIN_ROLE` | `m` | `c.opsAdmin` | grantRole | `Deploy.s.sol:_handoverOne` |
| `DEFAULT_ADMIN_ROLE` | `m` | `c.opsAdmin` | revokeRole | `Deploy.s.sol:_handoverOne` |
| `DEFAULT_ADMIN_ROLE` | `m` | `c.deployer` | renounceRole | `Deploy.s.sol:_handoverOne` |

#### Handover drop coverage (derived)

Roles that a `Deploy` handover path actually revokes/renounces: `COMPLIANCE_ADMIN_ROLE`, `DEFAULT_ADMIN_ROLE`, `RESERVE_ADMIN_ROLE`, `TIMELOCK_DEFAULT_ADMIN_ROLE`.

Granted to an EOA by `Deploy` and dropped by **no** revoke/renounce anywhere in it:

- `ATTESTER_ROLE -> _attester1 on oracle (granted in _wire)`
- `ATTESTER_ROLE -> attester2 on oracle (granted in _wire)`
- `ORIGINATOR_ROLE -> opsAdmin on bridge (granted in _wire)`
- `SERVICER_ROLE -> opsAdmin on defaultManager (granted in _wire)`
- `SERVICER_ROLE -> opsAdmin on waterfall (granted in _wire)`
- `SETTLEMENT_KEEPER_ROLE -> opsAdmin on queue (granted in _wire)`
- `SETTLEMENT_KEEPER_ROLE -> queueKeeper on queue (granted in _wire)`

Some of these are deliberate (the ops EOA is *supposed* to keep `SERVICER_ROLE` and `ORIGINATOR_ROLE`, and `Validate` positively requires it). The point of the list is that the deploy script's drop set is HAND-WRITTEN — `_handoverOne` renounces `bytes32(0)` and nothing else, with `RESERVE_ADMIN_ROLE` and `COMPLIANCE_ADMIN_ROLE` handled as one-off special cases — rather than iterating `PrivilegeAudit.authorityRoleSet()`, the same enumeration the durable privilege RECEIPT is built from. A role added to `Roles.sol` tomorrow joins the receipt and does not join the drop set.

### What `Validate` / `ValidateMainnet` actually assert on chain

| Target | Role | Holder | Assertion | Script |
|---|---|---|---|---|
| `DefaultManager(a.defaultManager)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `SUSDfr(a.vault)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.usdfr)` | `MINTER_ROLE` | `a.controller` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `CONTROLLER_ROLE` | `a.controller` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.bridge)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.bridge)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.registry)` | `CREDIT_ROLE` | `a.bridge` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.registry)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.registry)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `LOSS_BURNER_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `LOSS_BURNER_ROLE` | `a.reserves` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `LOSS_BURNER_ROLE` | `a.waterfall` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `CREDIT_ROLE` | `a.defaultManager` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.curator)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.curator)` | `CREDIT_ROLE` | `a.reserves` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `CREDIT_ROLE` | `a.waterfall` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.sGrove)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.sGrove)` | `CREDIT_ROLE` | `a.reserves` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.curator)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.sGrove)` | `CREDIT_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.vault)` | `FEE_ACCOUNTING_ROLE` | `a.curator` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.vault)` | `FEE_ACCOUNTING_ROLE` | `a.sGrove` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.vault)` | `FEE_ACCOUNTING_ROLE` | `a.defaultManager` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.waterfall)` | `SERVICER_ROLE` | `a.opsAdmin` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.defaultManager)` | `SERVICER_ROLE` | `a.opsAdmin` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.bridge)` | `ORIGINATOR_ROLE` | `a.opsAdmin` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `ATTESTER_ROLE` | `_attester1(a)` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `ATTESTER_ROLE` | `a.attester2` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.usdfr)` | `MINTER_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `CREDIT_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.controller)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.curator)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.sGrove)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.vault)` | `FEE_ACCOUNTING_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.vault)` | `FEE_ACCOUNTING_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.bridge)` | `CREDIT_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.registry)` | `CREDIT_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `CREDIT_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.bridge)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.registry)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `CREDIT_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `RESERVE_ADMIN_ROLE` | `a.timelock` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `RESERVE_ADMIN_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.reserves)` | `RESERVE_ADMIN_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(mods[i])` | `DEFAULT_ADMIN_ROLE` | `a.timelock` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(mods[i])` | `UPGRADER_ROLE` | `a.timelock` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(mods[i])` | `UPGRADER_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(mods[i])` | `UPGRADER_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(mods[i])` | `DEFAULT_ADMIN_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(mods[i])` | `DEFAULT_ADMIN_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.compliance)` | `COMPLIANCE_ADMIN_ROLE` | `a.opsAdmin` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.compliance)` | `COMPLIANCE_ADMIN_ROLE` | `a.timelock` | MUST hold | `script/Validate.s.sol` |
| `tl` | `TIMELOCK_PROPOSER_ROLE` | `a.governor` | MUST hold | `script/Validate.s.sol` |
| `tl` | `TIMELOCK_CANCELLER_ROLE` | `a.governor` | MUST hold | `script/Validate.s.sol` |
| `tl` | `TIMELOCK_EXECUTOR_ROLE` | `address(0)` | MUST hold | `script/Validate.s.sol` |
| `tl` | `TIMELOCK_DEFAULT_ADMIN_ROLE` | `a.deployer` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.queue)` | `SETTLEMENT_KEEPER_ROLE` | `a.queueKeeper` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.queue)` | `SETTLEMENT_KEEPER_ROLE` | `a.opsAdmin` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.queue)` | `SETTLEMENT_KEEPER_ROLE` | `address(0)` | MUST NOT hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `ATTESTER_ROLE` | `a.deployer` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.usdfr)` | `DEFAULT_ADMIN_ROLE` | `a.deployer` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.usdfr)` | `DEFAULT_ADMIN_ROLE` | `a.opsAdmin` | MUST hold | `script/Validate.s.sol` |
| `IAccessControl(a.oracle)` | `ATTESTER_ROLE` | `a.deployer` | MUST NOT hold | `script/ValidateMainnet.s.sol` |
| `IAccessControl(a.oracle)` | `ATTESTER_ROLE` | `a.opsAdmin` | MUST NOT hold | `script/ValidateMainnet.s.sol` |
| `IAccessControl(a.compliance)` | `COMPLIANCE_ADMIN_ROLE` | `a.opsAdmin` | MUST hold | `script/ValidateMainnet.s.sol` |
| `IAccessControl(guarded[i])` | `GUARDIAN_ROLE` | `a.opsAdmin` | MUST hold | `script/ValidateMainnet.s.sol` |
| `IAccessControl(a.bridge)` | `ORIGINATOR_ROLE` | `a.opsAdmin` | MUST hold | `script/ValidateMainnet.s.sol` |
| `IAccessControl(a.waterfall)` | `SERVICER_ROLE` | `a.opsAdmin` | MUST hold | `script/ValidateMainnet.s.sol` |
| `IAccessControl(a.defaultManager)` | `SERVICER_ROLE` | `a.opsAdmin` | MUST hold | `script/ValidateMainnet.s.sol` |

**Positive coverage:** 33 of 35 distinct `(module, role, holder)` grants that survive `Deploy`/`Handover` are re-asserted post-deploy by a literal `hasRole`. **Not asserted: `oracle|CREDIT_ROLE|defaultManager`, `oracle|CREDIT_ROLE|bridge`.**

**Bootstrap grants** (granted then dropped by the same script): 2. Without a literal negative assertion: `compliance|COMPLIANCE_ADMIN_ROLE|deployer` — see the loop assertions below before calling that a gap.

**Loop assertions.** `Validate` also asserts through `PrivilegeAudit.scan*`, which iterates a role set rather than naming a role literally. Those calls are invisible to the literal scan above, so the positive-coverage number is a LOWER BOUND on the negative direction. Call sites:

| Script fn | Call |
|---|---|
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.moduleSet(_topologyTargets(a))` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scan(targets, names, a.deployer, false)` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scanTimelock(a.timelock, a.deployer, false)` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.authorityRoleSet()` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scanRoles(targets, names, authIds, authNames, a.deployer)` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scanRoles(targets, names, authIds, authNames, a.opsAdmin)` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scanTimelock(a.timelock, a.deployer, true)` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scanTimelock(a.timelock, a.opsAdmin, true)` |
| `Validate.s.sol:_reportPrivilegePosture` | `PrivilegeAudit.scan(targets, names, a.deployer, false)` |
| `Validate.s.sol:_assertNamedPrincipalsHoldNoAuthority` | `PrivilegeAudit.authorityRoleSet()` |
| `Validate.s.sol:_assertNamedPrincipalsHoldNoAuthority` | `PrivilegeAudit.scanRoles(targets, names, authIds, authNames, p)` |
| `Validate.s.sol:_assertNamedPrincipalsHoldNoAuthority` | `PrivilegeAudit.scanTimelock(a.timelock, p, true)` |
| `Validate.s.sol:_printPosture` | `PrivilegeAudit.scanEverything(targets, names, a.timelock, a.deployer)` |
| `Validate.s.sol:_printPosture` | `PrivilegeAudit.scanEverything(targets, names, a.timelock, a.opsAdmin)` |
| `Validate.s.sol:_printPosture` | `PrivilegeAudit.scanEverything(targets, names, a.timelock, a.queueKeeper)` |

<!-- END GENERATED ACCESS-CONTROL MATRIX -->

## Verification
- **Static:** unit tests exercise every role-gated function with an authorized AND an
  unauthorized caller (100% branch on access paths).
- **Live:** `Validate.s.sol` asserts, on the deployed chain, that the timelock holds
  `DEFAULT_ADMIN`/`UPGRADER` everywhere, that no EOA holds `MINTER`/`CREDIT` on value
  modules, and (when `!keepOpsAdmin`) that the deployer holds nothing.
- **Audit:** the role×function graph was independently re-derived clean in the Round-4
  access-control lens (`docs/security-review.md`).

*Living document — any new role or privileged function must be added here and to
`Validate.s.sol` in the same change (CLAUDE.md §3.2).*\n
