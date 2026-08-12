# Access-Control Matrix — Forest Road Vault

**Audience:** external auditors. Derived 1:1 from `src/libraries/Roles.sol`,
`script/Deploy.s.sol` (grants), and `script/Validate.s.sol` (which asserts the live
topology, positive AND negative holdings, after every deploy). All roles are admin'd by
`DEFAULT_ADMIN_ROLE`; there is **no `_setRoleAdmin` override anywhere**, so no role can
grant itself (no escalation loop).

> **Production vs testnet.** In production, `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` are
> held **only** by the governance timelock (`KEEP_OPS_ADMIN=false`). On the Sepolia
> QA deployment, the ops EOA additionally retains `DEFAULT_ADMIN_ROLE` for test operations
> (`KEEP_OPS_ADMIN=true`). This is the single largest live privilege, flagged in the manifest
> and validator. The clean mainnet deployment rejects any retained ops admin.

## Roles and holders

| Role | Held by (prod) | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (0x00) | Governance **timelock** | Admin of all roles (grant/revoke); every parameter setter. |
| `UPGRADER_ROLE` | Governance **timelock** | `_authorizeUpgrade` on the clean deployment's role-gated UUPS modules, including `AssessedImpairmentSource`. `FRGovernor` authorizes upgrades through `onlyGovernance`; `GroveVotesAggregator` remains immutable and role-less. An `SGrove` upgrade can rewrite a vote source, so this authority is security-critical. |
| `GUARDIAN_ROLE` | Guardian | Pause/unpause **user paths only**, never the cascade. |
| `MINTER_ROLE` | MintRedeemController | Mint USDfr (on `USDfr`). |
| `CONTROLLER_ROLE` | MintRedeemController | `ReserveManager.releaseUSDC` (redemption custody-out) **only**. |
| `CREDIT_ROLE` | WaterfallEngine, DefaultManager, ClaimBridge | The **trusted internal-module** role, the only caller of the cross-module value/state primitives (below). Never held by an EOA. |
| `FEE_ACCOUNTING_ROLE` | CuratorModule, SGrove, DefaultManager | Checkpoints and locks fee accounting across mechanical junior-capacity changes. Never held by an EOA. |
| `ORIGINATOR_ROLE` | Ops (Forest Road) | `ClaimBridge.originate`. |
| `SERVICER_ROLE` | Ops (Forest Road) | Facility funding, exact-payment distribution, default/cure/amendment execution, acceleration and exact attested loss realization. |
| `ATTESTER_ROLE` | The m-of-n attester keys | Authorized EIP-712 signers; the oracle verifies `attest()` bundles against these holders. |
| `COMPLIANCE_ADMIN_ROLE` | Ops / compliance | KYC allow-list for the **mint/redeem primary gate** and sanctions blocklist. Points are per wallet; no compliance identity mapping exists. |

## Role × privileged-function matrix

### Governance-only (`DEFAULT_ADMIN_ROLE` = timelock)
Every economic / safety parameter. A compromised holder is the top of the threat model,
hence the timelock + (prod) no-EOA rule.

| Contract | Functions |
|---|---|
| CollateralRegistry | `setClass`, `setBorrowerLimit`, `setBorrowerLimitOverride`, `clearBorrowerLimitOverride`, `setStateLimit`, `setComplianceModule`, `setConcentrationFloor` |
| ComplianceRegistry | `setProtocolExempt` (transfers are sanctions-only, no per-token transfer allow-list) |
| ClaimBridge | `setRequiredMintAttestations` |
| sUSDfr | `setRedemptionQueue`, `setPointsModule`, `setImpairmentSource` (validated normal path), `clearUnreadableImpairmentSource` (recovery-only clear), `clearStaleFeeOperation` (evented trusted-module lock recovery), `setYieldVestingPeriod` (launch zero; optional smoothing), `setPerformanceFee` (0–20%, prospective), `setManagementFee` (0–2% annual, prospective), `setFeeRecipient` |
| ReserveManager | No asset-list, reserve-instrument or DSRA setter exists; canonical USDC is immutable deployment wiring |
| USDfr | `setComplianceModule`, `setPointsModule` |
| CuratorModule | `setCuratorApproved`, `setFirstLossTarget`, **`liftDefaultFreeze`** (audit R4-EC2) |
| AttestationOracle | `setThreshold` (floored ≥2 for high-value kinds), `revoke` |
| RedemptionQueue | `setEpochDuration`, `setEpochLiquidityBps`, `setRedeemCooldown`, `setMinRedemptionValue` |
| AssessedImpairmentSource *(included in clean mainnet v1; first exercised on Sepolia)* | Publish/clear a time-limited, revision-bound professional senior-impairment assessment; change its zero-recovery base source (which clears the assessment) |
| WaterfallEngine | `setProtocolFee`, `setOriginationFee`, `setFeeRecipient`, `setDefaultManager` |
| DefaultManager | `setRemedyRef`, `setCureWindow`, `setGraceWindow`, `setBackstop` |
| SGrove | `setUnbondingPeriod`, **`setRewardsDuration`** (audit R4-EC1) |
| PointsModule | `setRate`, `setUSDfrMultiplier`, `setCuratorMultiplier`, `setCuratorModule` (multiples bounded; changes apply forward, never retroactively) |

### Operational roles (Forest Road, single-purpose)

| Role | Function(s) | Guard beyond the role |
|---|---|---|
| `ORIGINATOR_ROLE` | `ClaimBridge.originate` | + full attestation mint-gate (m-of-n) + concentration limits |
| `SERVICER_ROLE` | `WaterfallEngine.{fund, distribute}`, `DefaultManager.{declareDefault, accelerate, realizeLoss, clearPastDue}` | Funding uses signed terms. Payments, defaults, cures and losses consume exact payload-bound attestations; the payment atomically pulls USDC from the signed payer. |
| `MINTER_ROLE` | `USDfr.{mint, burn}` | Held only by the controller; every mint is backing-asserted. The removed dormant `BURNER_ROLE` is not part of v1. |
| `CONTROLLER_ROLE` | `ReserveManager.releaseUSDC` | Held only by the controller. |
| `COMPLIANCE_ADMIN_ROLE` | `ComplianceRegistry.{setAllowed, setAllowedBatch, setJurisdictionBlocked}` | Cannot reach `protocolExempt` (that is `DEFAULT_ADMIN_ROLE`). |
| `ATTESTER_ROLE` | (signer, not a caller) `AttestationOracle.attest` verifies signatures against holders | m-of-n threshold per kind |

### `CREDIT_ROLE`: trusted internal-module primitives (never an EOA)
These are the cross-module value/state operations. Each is callable **only** by the
specific sibling module granted the role at deploy, and several are **non-pausable**
at their own entry point. A guardian pause on `ReserveManager` still blocks the
principal-write-down leg until a controlled unpause; that accepted operational
dependency is tested and must be part of incident procedure.

| Callee . function | Authorized caller(s) | Pausable? |
|---|---|---|
| `MintRedeemController.mintYield` | WaterfallEngine | via mint path |
| `MintRedeemController.burnLoss` | WaterfallEngine, DefaultManager | **no** (cascade) |
| `CuratorModule.absorbLoss` | DefaultManager | **no** (cascade) |
| `CuratorModule.freezeOnDefault` | DefaultManager | **no** |
| `SGrove.coverShortfall` | DefaultManager | **no** (cascade) |
| `sUSDfr.beginYieldNotification` / `notifyYield` | WaterfallEngine | **no**; one vault-side lock spans both interest-leg mints, then Waterfall calls permissionless `accrueFees` |
| `AttestationOracle.consume` | WaterfallEngine | — |
| `ClaimBridge.transitionState` | WaterfallEngine, DefaultManager | — |
| `ReserveManager.{recordDeployment, recordFeeCapitalization, recordPayment, recordPrincipalWritedown}` | WaterfallEngine, DefaultManager | — |
| `CollateralRegistry` exposure record/decrease | ClaimBridge, WaterfallEngine, DefaultManager | — |

### `FEE_ACCOUNTING_ROLE`: fee-neutral junior-capacity changes

CuratorModule brackets first-loss posts/withdrawals, SGrove brackets coverage funding and
per-event-cap changes, and DefaultManager brackets backstop replacement with
`sUSDfr.beginFeeNeutralMarkedNavChange` /
`sUSDfr.endFeeNeutralMarkedNavChange`. The vault checkpoints first, snapshots share supply,
and keeps permissionless fee accrual locked between the calls. It does not infer a hurdle
change from a free-running NAV read. Instead, performance-fee NAV excludes temporary
junior-capital credit at its source, so a capacity write cannot become chargeable profit.
The never-pausable `absorbLoss` and `coverShortfall` cascade legs deliberately do not add
this external-call surface.

### Permissionless: staked-GROVE voting (ADR-0026)
`SGrove.delegate(address)` and `SGrove.delegateBySig(...)` are inherited from OpenZeppelin
`VotesUpgradeable` and carry no role: a staker re-points their own staked-GROVE voting power.
They are deliberately **not** guardian-pausable. Delegation moves no value, and a pausable
`delegate` would be a stronger governance-censorship lever than the pause already is.
`stake`/`requestUnstake` *are* pausable, so a guardian pause freezes the composition of the
sGROVE electorate; vote **reads** are never pausable, so the Governor itself never stalls.

`GroveVotesAggregator`, the Governor's vote source, is immutable, holds no roles and has no
privileged functions. It sums voting power across GROVE and staked GROVE, while sourcing the
quorum denominator from **GROVE alone** so staking cannot move the quorum bar.

### Guardian (emergency)
`GUARDIAN_ROLE` may `pause`/`unpause` the **user-facing** paths of every pausable module
(mint/redeem, stake/unstake/claims, deposit, the permissionless MTM triggers). It can
**never** pause `absorbLoss`, `coverShortfall`, `burnLoss`, or `realizeLoss`. The cascade
is always reachable (ADR-0017 §4).

## Verification
- **Static:** unit tests exercise every role-gated function with an authorized AND an
  unauthorized caller (100% branch on access paths).
- **Live:** `Validate.s.sol` asserts, on the deployed chain, that the timelock holds
  `DEFAULT_ADMIN`/`UPGRADER` everywhere, that no EOA holds `MINTER`/`CREDIT` on value
  modules, and (when `!keepOpsAdmin`) that the deployer holds nothing.
- **Audit:** the role×function graph was independently re-derived clean in the Round-4
  access-control lens (`docs/security-review.md`).

*Living document. Any new role or privileged function must be added here and to
`Validate.s.sol` in the same change (CLAUDE.md §3.2).*
