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
