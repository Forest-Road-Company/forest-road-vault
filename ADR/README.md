# Architecture Decision Records

One file per material design decision: the decision, the alternatives considered, the
rationale, and the status. Statuses: **Locked** (Forest Road direction — do not reopen
without their input), **Deployed** (live on Ethereum V2 mainnet), **Resolved** (settled;
challengeable on technical grounds), **Accepted** (made during implementation), **Draft** (put
to Forest Road for decision; not accepted; binds nothing). References to "CLAUDE.md", "the
operating rules" and "brief Part n" point at internal governing documents that are not published.

*Index refreshed 25 November 2026.*

| ADR | Title | Status |
|---|---|---|
| [0001](0001-identified-per-asset-collateral.md) | Identified-per-asset collateral, not a blind pool | Locked / Deployed |
| [0002](0002-variable-yield-pass-through.md) | Variable-yield pass-through, not fixed-rate | Locked / Deployed (amended in part by ADR-0038) |
| [0003](0003-multi-collateral-five-classes.md) | Multi-collateral; all five classes at launch (amended) | Locked / Deployed |
| [0004](0004-anchor-curator-first-loss.md) | Anchor curator + pluggable curators (live: 500k Renewables, 1 USDfr DA) | Resolved / Deployed |
| [0005](0005-erc4626-susdfr.md) | ERC-4626 for sUSDfr (24 decimals in live V2) | Accepted / Deployed |
| [0006](0006-erc721-loan-positions.md) | Loan positions as ERC-721 NFTs | Accepted / Deployed |
| [0007](0007-attestation-trust-model.md) | Attestation trust model (authorized attesters, EIP-712) | Resolved / Deployed |
| [0008](0008-uups-upgradeability.md) | UUPS proxies + timelock + guardian | Resolved / Deployed |
| [0009](0009-ethereum-l1.md) | Chain: Ethereum L1 (amended for Phase 1 BSC OFT bridge by ADR-0045) | Deployed on Ethereum V2 |
| [0010](0010-epoch-fifo-redemption-queue.md) | Epoch FIFO redemption queue | Accepted / Deployed |
| [0011](0011-kyc-compliance-gating.md) | KYC gating on mint/redeem; sanctions-only transfers | Resolved / Deployed |
| [0012](0012-backing-invariant.md) | On-chain backing-invariant enforcement | Accepted / Deployed |
| [0013](0013-governance-forest-road-controlled.md) | Governance Forest-Road-controlled at launch | Resolved / Deployed |
| [0014](0014-sgrove-backstop-parameters.md) | sGROVE backstop parameters | Deployed; per-event cap superseded by ADR-0035 |
| [0015](0015-digital-assets-collateral-class.md) | Digital Assets class: marked-to-market, related-party | Resolved / Deployed (Class 5 live) |
| [0016](0016-points-system.md) | Participation points: time-weighted, per-wallet, honest framing | Deployed on Ethereum V2 (+ Morpho/Pendle off-chain) |
| [0017](0017-credit-layer-mechanics.md) | Historical credit-layer mechanics; clean-v1 surface superseded by ADR-0030 | Superseded in part |
| [0018](0018-redemption-queue-mechanics.md) | RedemptionQueue settlement: stable-liquidity budget, chunked settlement, no cancellation, points stop at request | Accepted / Deployed |
| [0019](0019-origination-fee.md) | Origination fee: per-class OID at funding, fee capitalized + minted to feeRecipient | Accepted / Deployed |
| [0020](0020-attestation-oracle-implementation.md) | AttestationOracle: relayed EIP-712 bundles, m-of-n on identical payloads, consume/revoke lifecycle | Accepted / Deployed |
| [0021](0021-sgrove-backstop-implementation.md) | sGROVE backstop: USDfr coverage-reserve model (no GROVE conversion), OZ Governor/timelock | Deployed; per-event cap superseded by ADR-0035 |
| [0022](0022-redemption-cooldown-and-conservative-nav.md) | Forced 21-day redemption cooldown + conservative-redemption NAV | Accepted / Deployed |
| [0023](0023-streamed-senior-yield-vesting.md) | Optional senior-yield vesting (launch default zero = immediate recognition) | Accepted / Deployed |
| [0025](0025-internal-idle-stable-accounting.md) | Internal idle-stable accounting (`idleReserve()` reads storage, measured-delta deposits) | Accepted / Deployed |
| [0026](0026-staked-grove-voting.md) | Staked GROVE voting via immutable `GroveVotesAggregator` (quorum denominator GROVE-only) | Accepted / Deployed |
| [0027](0027-assessed-recovery-and-discretionary-topups.md) | Professionally assessed recovery marks (`AssessedImpairmentSource` deployed; `RecoveryTopUpDistributor` undeployed) | Deployed (assessment source only; sGROVE directional in V2) |
| [0028](0028-retire-self-funded-dsra.md) | Historical transition: retire self-funded DSRA | Superseded by ADR-0030 |
| [0029](0029-mainnet-v1-feature-scope.md) | Mainnet scope: Points required; all five classes active; USDC-only; recovery top-up distributor deferred | Locked / Deployed |
| [0030](0030-clean-mainnet-v1-contract-surface.md) | Clean mainnet contract surface: exact attestations, USDC-only custody, no DSRA, pause-safe internal loss paths | Locked / Deployed |
| [0031](0031-protocol-level-fees.md) | Protocol-level fees: 10% interest, global-HWM performance 10% at launch (20% cap), management 0% at launch (2% cap) | Locked / Deployed |
| [0032](0032-roleless-mtm-executor-and-redundant-keepers.md) | Immutable roleless MTM executor with canonical action selection and two independently operated private keepers | Deployed on Ethereum V2 |
| [0033](0033-authenticated-reserve-loss-cascade.md) | Authenticated custody-loss incidents; observation-only `reconcileIdleUSDC`; arm-bound governed cascade | Accepted / Deployed |
| [0034](0034-exit-pricing-in-cascade-order.md) | Sub-par exit pricing off post-cascade residual; canonical 3-arg slippage-protected `redeem` | Accepted / Deployed |
| [0035](0035-sgrove-absorbs-without-a-per-event-cap.md) | sGROVE absorbs from the whole live reserve; no per-event ceiling or snapshot | Accepted / Deployed |
| [0036](0036-queued-governance-finality-no-proposal-guardian.md) | Queued governance is final: no proposal guardian and no post-queue veto; `updateTimelock` disabled | Accepted / Deployed |
| [0037](0037-bnb-smart-chain-instance-and-reserve-asset-admission.md) | Standalone BNB Smart Chain credit protocol instance and reserve-asset admission | Draft (unlaunched on BSC mainnet; see ADR-0045 for Phase 1 token bridge) |
| [0038](0038-continuous-interest-accrual-to-susdfr.md) | Continuous per-second accrual of earned-but-unreceived interest (PIK **and** cash) into `sUSDfr` | Deployed on Ethereum V2 |
| [0039](0039-single-facility-cash-and-pik-interest.md) | One facility with separate cash-pay and PIK interest curves, clocks and balances | Implemented / Deployed on Ethereum V2 |
| [0040](0040-governed-borrower-payout-allowlist.md) | Timelock-controlled loan-proceeds destinations enforced at origination and funding | Accepted / Deployed on Ethereum V2 |
| [0041](0041-morpho-quote-issuance-and-expiry.md) | Morpho quotes protect five minutes from completed issuance and expire before wallet or Safe handoff | Accepted / Deployed in production |
| [0042](0042-class-1-state-key-convention.md) | Class 1 state key: `keccak256("FRV:state:US-XX")`, USPS code from fixed list, permanent once used | Accepted (2026-11-04) |
| [0043](0043-morpho-blue-market-and-exit-value-oracle.md) | Morpho Blue USDC/sUSDfr market, immutable `SUSDfrExitValueOracle`, bounded liquidation bot | Accepted / Deployed (`FRV-NEW-02` bot rollout Open) |
| [0044](0044-solana-curator-subscription-vault.md) | Solana curator subscription vault (reproducible devnet program, Corrovera reviewed) | Devnet preview (mainnet gated) |
| [0045](0045-bsc-layerzero-oft-token-bridge.md) | Phase 1 Ethereum↔BSC LayerZero `SUSDfrOFT` token bridge (lockbox-backed; no BSC credit book) | Accepted / Deployed (Nov 2026) |
| [0046](0046-aws-kms-policy-signers-for-keepers.md) | AWS KMS policy-restricted signers and fail-closed raw-key guards for off-chain keepers/bots | Accepted / Deployed (Oct–Nov 2026) |
| [0047](0047-two-stage-lmv-upgrade-and-exit-controls.md) | Two-stage LMV governance upgrade (`ee9b228a`), INV-21 gas bounds, frozen re-audited artifact policy | Stage 1 live; Stage 2 pending (`LMV-09`/`LMV-18` Open) |
| [0048](0048-frontend-rpc-proxy-and-blob-cas-persistence.md) | Frontend same-origin `/api/rpc` proxy, secret-leak build checks and Vercel Blob CAS persistence | Accepted / Deployed (Nov 2026) |
