# Live Deployment Status

**Updated 25 September 2026.** Forest Road Vault V2 is live on Ethereum mainnet and lending to
real borrowers. The application reads the deployment whose permanent entry points appear on the
[deployed-addresses page](/docs/addresses). Bootstrap administration has been surrendered to
timelocked governance.

Minting USDfr and redeeming it directly for USDC require a KYC-verified address. Holding,
transferring and staking are open to any wallet that is not sanctions- or jurisdiction-blocked.
The [how-to guide](/docs/how-to) walks through each action.

## The loan book

The first facilities were originated and funded on 21 September 2026. By 25 September the book
held eleven funded facilities, about USD 5 million of principal:

- **Digital assets:** one facility, secured by collateral that is marked to market. Signed
  collateral valuations are relayed daily, and each one is checked against the facility's
  margin-call and liquidation thresholds in the same transaction.
- **Renewable energy:** five tranches of USD 1 million each. Every tranche pays part of its
  interest in cash and part as PIK (interest added to principal), so each is booked as two
  facilities, a cash leg and a PIK leg.

No facility could be funded before its Loan NFT was minted, and the NFT could only mint once every
attestation its class requires had been signed by the attester quorum and bound to its exact
terms. Curator first-loss capital is posted in both lending classes.

The [transparency dashboard](/transparency) shows the live book, collateral, rates, reserves and
each loss layer, read directly from the contracts.

## Loss protection today

Losses fall first on the curator first-loss capital of the affected class, then on the sGROVE
coverage reserve, and only then on sUSDfr principal. As of 25 September the sGROVE coverage
reserve is unfunded, so a loss larger than a class's curator capital would pass directly to sUSDfr
principal. The dashboard shows the live balance of every layer.

## What has run live

- **Launch acceptance.** On 21 September a funded canary exercised minting, transfer, staking,
  direct redemption and entry into the redemption queue. Supply equalled recognized backing
  afterwards, and the USDC held by ReserveManager matched its ledger.
- **Jurisdiction control.** The operations Safe blocked and then unblocked a wallet on mainnet.
  While blocked, the wallet could not send or receive USDfr or sUSDfr, mint, or redeem.
- **Originations and funding.** Every facility above was originated and funded on mainnet
  through the attestation gate.
- **Continuous accrual.** Earned cash and PIK interest, the protocol interest fee and the vault
  performance fee are reflected before cash is received. Accrual uses each facility's frozen
  basis; PIK capitalizes into contractual principal only at its scheduled boundary.
- **Keepers.** Automated keepers settle the redemption queue, checkpoint accrual, watch for late
  payments, relay digital-asset valuations and supply exact rounding corrections.

## In progress

Two governance proposals were open on 25 September:

- **FRV-005** upgrades five core contracts so that one facility can carry both cash and PIK
  interest, and approves a borrower payout destination. The new interest mode stays switched off
  until a separate, later proposal turns it on. Voting closes on 27 September.
- **FRV-007** upgrades USDfr and sUSDfr to remove the fixed gas floor on balance changes described
  in [Integrating](/docs/integrating). Voting runs from 26 to 28 September.

A passed proposal executes only after the two-day timelock. Proposal state is public on the
Governor contract.

The module-wide Guardian pause and unpause has been rehearsed on a fork but not yet run as a live
Safe drill. The wallet-level jurisdiction control above is a separate control and has been
exercised live.

## Limits and operating assumptions

The configured **USD 100 million value is a bootstrap concentration floor, not a deposit cap**.
Each new loan must fit within the per-borrower (15%), per-state (25%) and per-class limits,
measured against the larger of the actual book and that floor. The floor does not authorize
USDfr minting without USDC and does not waive any concentration check.

sUSDfr exits settle only through the redemption queue. Each request waits out a 21-day minimum
hold and then fills strictly first in, first out. Settlement runs daily, and each settlement can
fill requests worth at most 1.67% of idle USDC reserves, so a large exit may take several
settlements. A request cannot be cancelled once made. Direct USDfr-to-USDC redemption is instant but limited to
idle reserves.

An extreme loss that exhausts curator capital, sGROVE coverage and senior assets can leave a
sub-USDC-unit rounding remainder. Value-sensitive operations fail closed in that state. A funded,
rate-limited worker is configured to supply the exact correction, within a 0.01 USDC per-payment
and 0.10 USDC rolling-daily budget.

Review the [audit register](/docs/audit) with each review's scope and limitations. Reviews reduce
risk; they do not prove that software, custody, governance, keepers, signers or real-world loan
facts cannot fail.
