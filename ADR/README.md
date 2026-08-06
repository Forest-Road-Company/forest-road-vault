# Architecture Decision Records

One file per material design decision: the decision, the alternatives considered, the
rationale, and the status. Statuses: **Locked** (Forest Road direction — do not reopen
without their input), **Resolved** (settled; challengeable on technical grounds),
**Accepted** (made during implementation).

| ADR | Title | Status |
|---|---|---|
| [0001](0001-identified-per-asset-collateral.md) | Identified-per-asset collateral, not a blind pool | Locked |
| [0002](0002-variable-yield-pass-through.md) | Variable-yield pass-through, not fixed-rate | Locked |
| [0003](0003-multi-collateral-five-classes.md) | Multi-collateral; all five classes at launch (amended) | Locked (Forest Road) |
| [0004](0004-anchor-curator-first-loss.md) | Anchor curator + pluggable curators; $10M/class first-loss | Resolved (Forest Road) |
| [0005](0005-erc4626-susdfr.md) | ERC-4626 for sUSDfr | Accepted |
| [0006](0006-erc721-loan-positions.md) | Loan positions as ERC-721 NFTs | Accepted |
| [0007](0007-attestation-trust-model.md) | Attestation trust model (authorized attesters, EIP-712) | Resolved — buildable |
| [0008](0008-uups-upgradeability.md) | UUPS proxies + timelock + guardian | Resolved |
| [0009](0009-ethereum-l1.md) | Chain: Ethereum L1, single-chain | Resolved; disposable mainnet test authorized, production gated (Forest Road, 2026-07-29) |
| [0010](0010-epoch-fifo-redemption-queue.md) | Epoch FIFO redemption queue | Accepted |
| [0011](0011-kyc-compliance-gating.md) | KYC gating; broad access policy | Resolved (Forest Road) |
| [0012](0012-backing-invariant.md) | On-chain backing-invariant enforcement | Accepted |
| [0013](0013-governance-forest-road-controlled.md) | Governance Forest-Road-controlled at launch | Resolved (Forest Road) |
| [0014](0014-sgrove-backstop-parameters.md) | sGROVE backstop parameters | Resolved (calibration pending economic review) |
| [0015](0015-digital-assets-collateral-class.md) | Digital Assets class: marked-to-market, related-party | Resolved (Forest Road, added mid-build) |
| [0016](0016-points-system.md) | Participation points: time-weighted, identity-keyed, honest framing | Resolved (Forest Road, added mid-build) |
| [0017](0017-credit-layer-mechanics.md) | Historical credit-layer mechanics; clean-v1 surface superseded by ADR-0030 | Superseded in part |
| [0018](0018-redemption-queue-mechanics.md) | RedemptionQueue settlement: stable-liquidity budget, chunked permissionless close, no cancellation, points stop at request | Accepted |
| [0019](0019-origination-fee.md) | Origination fee: per-class OID at funding, fee capitalized + minted to feeRecipient | Accepted |
| [0020](0020-attestation-oracle-implementation.md) | AttestationOracle: relayed EIP-712 bundles, m-of-n on identical payloads, consume/revoke lifecycle, attested-fact re-wiring | Accepted |
| [0021](0021-sgrove-backstop-implementation.md) | sGROVE backstop: USDfr coverage-reserve model (no GROVE conversion), per-event cap re-based, OZ Governor/timelock | Accepted (user-confirmed) |
| [0022](0022-redemption-cooldown-and-conservative-nav.md) | Forced 21-day redemption cooldown (decoupled from the epoch) + conservative-redemption NAV | Accepted (user-confirmed; calibration + declared-default mark are review-gated) |
| [0023](0023-streamed-senior-yield-vesting.md) | Optional senior-yield vesting: launch recognizes realized interest immediately and checkpoints fees atomically; governance may later enable tested linear smoothing | Accepted; launch default amended to zero vesting (2026-07-30) |
| [0025](0025-internal-idle-stable-accounting.md) | Internal idle-stable accounting: idleReserve() reads storage not balanceOf (closes M-04 as a class); measured-delta deposits close fee-on-transfer; emergency levers may move backing DOWN on authority, UP only on proof | Accepted (Forest Road direction; the "counts unverifiable value" trade-off is flagged for audit) |
| [0026](0026-staked-grove-voting.md) | Staked GROVE retains voting rights, per-staker (unbonding does not vote; auto-self-delegate on first stake). SGrove checkpoints stake as voting units; an immutable GroveVotesAggregator sums both sources for the Governor while sourcing the quorum denominator from GROVE ALONE. Amends ADR-0013; closes L-02 | Accepted (Forest Road direction; the fail-loud aggregator legs are flagged for audit as a contested choice) |
| [0027](0027-assessed-recovery-and-discretionary-topups.md) | Professionally assessed recovery marks for redemption pricing + separately funded discretionary recovery top-ups | Sepolia deployed/tested; mainnet valuation, funding, disclosure, and deployment remain gated |
| [0028](0028-retire-self-funded-dsra.md) | Historical transition: retire self-funded DSRA; clean v1 removes the legacy surface entirely | Superseded by ADR-0030 |
| [0029](0029-mainnet-v1-feature-scope.md) | Mainnet v1 scope: Points required; all five classes active; USDC-only; reserve-instrument valuation excluded; recovery top-up distributor deferred | Locked (Forest Road) |
| [0030](0030-clean-mainnet-v1-contract-surface.md) | Clean mainnet-v1 contract surface: exact attestations, USDC-only custody, no DSRA/reserve-instrument legacy, pause-safe internal loss paths, $10 excluded seed | Locked (Forest Road) |
| [0031](0031-protocol-level-fees.md) | Protocol-level fees: 10% interest, global-HWM performance 10% at launch (20% cap), management 0% at launch (2% cap) | Locked (Forest Road) |
| [0032](0032-roleless-mtm-executor-and-redundant-keepers.md) | Immutable roleless MTM executor with canonical action selection and two independently operated private keepers | Accepted; deployment, drills and external audit pending |
