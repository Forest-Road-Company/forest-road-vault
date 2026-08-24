# ADR 0029 — Mainnet v1 feature scope

**Status:** Locked (Forest Road direction, 2026-07-24).

## Context

The Sepolia stack contains the full protocol plus testnet conveniences and several
forward-looking or legacy features. Mainnet v1 should expose the product Forest Road
intends to operate at launch without automatically carrying every deployed testnet
surface into production.

This decision consolidates the mainnet launch scope. It reaffirms ADR-0003 and ADR-0016,
narrows the reserve assets admitted at genesis, and distinguishes the recovery-pricing
mechanism from the separately funded recovery-top-up mechanism.

## Decision

### 1. Participation points are required at launch

`PointsModule` is part of mainnet v1 and must be deployed and wired to USDfr, sUSDfr,
the curator module, and the compliance registry.

The points programme remains subject to the framing and counsel requirements in
ADR-0016. Accrual is deliberately per wallet, not identity-keyed. There is no on-chain
identity mapping or manual-points path; the programme uses linear balance-time accrual
and resets the maturity ramp when value is moved to a fresh wallet. KYC policy may still
link wallets off chain, but that is not an on-chain accounting dependency.

### 2. All five collateral classes launch active

Film and TV tax credits, renewable energy, life sciences, real estate, and digital
assets are all mainnet-v1 collateral classes. The first four use the receivable model;
digital assets uses the marked-to-market model.

Launching every class does not approve placeholder economics. Before deployment, each
class still requires reviewed LTV, maturity, margin/liquidation, attestation, origination
fee, concentration, servicing, and legal-document parameters. Class, borrower, and state
concentration limits must be deliberate mainnet limits; the 100% Sepolia ramp posture is
not adopted by this ADR.

Every facility supplies its own contractual annual interest rate, bound into the signed
`CreditIssued` terms. A class-level rate is not a pricing authority. Self-funded DSRA is
retired under ADR-0028 and is not part of any launch class.

### 3. USDC is the only admitted reserve stablecoin at launch

Mainnet v1 approves only the canonical Ethereum-mainnet USDC contract as a reserve
stablecoin. The testnet mock stable is never deployed, approved, or referenced by the
production stack.

No other stablecoin may contribute to backing at genesis. Adding another stablecoin is
a post-launch governance decision requiring a new asset-specific risk review, including
contract behavior, decimals, upgrade/admin controls, blacklist behavior, liquidity,
depeg exposure, custody, and operational support.

**USDC risk posture (added 2026-08-20, raised by Cantina Managed).** The review list above is the
bar for admitting a *further* stablecoin. It is not a record of a review performed on USDC, and
this section previously implied otherwise. What was and was not assessed is therefore stated here
rather than left to inference.

Assessed:

- **Identity.** The canonical mainnet address is a compile-time constant,
  `MainnetConfig.CANONICAL_ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`. The reserve
  asset is not a deploy-time parameter and cannot be pointed at another token by configuration.
- **Decimals.** `ValidateMainnet.s.sol` asserts `decimals() == 6` against the live deployment after
  every deploy.
- **Transfer-path behaviour.** `MintRedeemController` measures delivery independently on both
  value-moving legs — `Controller_DepositNotCustodied` on the inflow and
  `Controller_RedemptionNotSettled` on the outflow. Their threat model is stated in NatSpec as "a
  botched upgrade, a blocklisting or fee-on-transfer USDC, a skimming implementation", and both
  fail closed rather than proceeding on the token's own word.

Not assessed, and accepted as residual:

- **Depeg.** USDC is valued at exactly one dollar by construction. `ReserveManager._normalize` is a
  pure six-to-eighteen decimal shift: no oracle, no price feed, no haircut. Mainnet v1 is
  single-asset, so the multi-stablecoin approval and disable levers examined in the 2026-07-14
  round-two audit are not present in this surface. Nothing expresses a USDC depeg in
  `totalBackingValue`.
- **Issuer authority.** Circle's ability to pause the token, upgrade its implementation, or
  blacklist an address — including a Forest Road contract — is not analysed and is not monitored
  on chain.

**Why nothing further is built.** These are systemic exposures rather than protocol-specific ones,
and two structural facts bound them.

First, `totalBackingValue` is `idle USDC + (deployed principal − impairment)`. At steady state the
USDC reserve is a liquidity buffer, not the book: the assets are deployed off-chain into facilities.
USDC exposure is confined to the buffer rather than to the collateral.

Second, an issuer blacklist of a protocol contract moves neither limb of that sum, so backing
remains intact and what fails is settlement. That distinction is already load-bearing here —
`RedemptionQueue` exists because backing is deliberately illiquid, and the separation between
backing and settleable liquidity is a property of the instrument rather than a defect. Note that
the ADR-0033 custody predicate cannot detect this state: it compares `idleUSDCUnits` against
`balanceOf`, and a blacklist reduces neither.

A depeg, a global pause, or an issuer action against a protocol address would require rethinking
the instrument, not tightening a guard. Forest Road accepts these exposures and records them here
rather than implying they are controlled. Revisiting this is a governance decision; admitting any
further stablecoin still requires the full review named above.

### 4. Reserve-instrument valuation is excluded from mainnet v1

Mainnet v1 does not recognize a facility-zero tokenized-T-bill or other off-chain reserve
instrument mark. Reserve backing at launch consists only of admitted USDC plus
conservatively accounted deployed facility principal.

The production implementation and validation must make this exclusion explicit: no
attested facility-zero valuation may increase `totalBackingValue`. The bootstrap manual
reserve-value setter is also unnecessary for a clean production deployment. Supporting
a reserve instrument later requires a new ADR, identified custody and legal ownership,
an asset-specific valuation policy, fresh threat modeling, and an audited upgrade.

### 5. RecoveryTopUpDistributor is deferred

`RecoveryTopUpDistributor` is not deployed at mainnet genesis and has no launch address,
role assignment, funding, compliance exemption, or frontend promise. Its source may
remain as reviewed optional tooling.

If a workout later justifies a discretionary payment to former redeemers, governance may
deploy the simple, separately funded distributor then, after publishing the funding
source, allocation file, evidence, proofs, and reconciliation. No top-up or airdrop is
promised.

This deferral does **not** remove the assessed-recovery pricing design. The
`AssessedImpairmentSource` remains the intended mechanism for a current, professionally
supported recovery estimate to affect queued-redemption pricing, subject to all
valuation-policy, monitoring, timelock, evidence-publication, audit, and legal gates in
ADR-0027.

## Consequences

- The production deployment profile differs deliberately from the retained Sepolia
  deployment and must not reuse the current testnet deploy script unchanged.
- Mainnet validation must fail if the configured asset is not canonical USDC, if a
  reserve-instrument mark can contribute to backing,
  if Points wiring is incomplete, or if any of the five classes is missing or inactive.
- Mainnet validation must also reject testnet privileges, mock assets, derived attester
  keys, and the 100% concentration ramp posture independently of this feature decision.
- The final production candidate should be redeployed on Sepolia from the mainnet-v1
  code and configuration, then subjected to the complete end-to-end and adversarial
  test programme before identical bytecode is considered for mainnet.
