This is the **first review of this protocol by a named external security firm**, and the first
conducted by human researchers under a commercial engagement rather than AI-assisted internally.
Every earlier round on this register was either an internal review or an AI-assisted one.

It is also, deliberately, the **narrowest** review on this register. Read the scope before the
result.

## Scope, which matters more than the headline

Two files at commit `71c285ec`: `contracts/src/MintRedeemController.sol` and
`contracts/src/libraries/Roles.sol`. That is the USDfr supply gateway and the role constants. It is
**not** a review of the vault, the queue, the waterfall, the cascade, the oracle, the bridge, the
curator module or governance.

A clean result across two files is not a clean result across the protocol. Anyone citing this
report should cite its scope in the same sentence.

## Result

Five findings, **all Informational**. No Critical, High, Medium or Low. One fixed, four
acknowledged.

The Cantina Managed team statement reads: *"No significant issues were identified during the
assessment, and the protocol is expected to operate as intended."*

## The five findings

**Fixed.** `redeem(uint256, uint256)` has no deadline, contradicting ADR-0034 W. The one-argument
form settles at par or reverts, so delay cannot make it worse, but the two-argument form bounds
price and not time. That is a free option: a caller who names a floor and is not included for an
hour lets a searcher hold the transaction until the ratio decays to that floor. The remedy was
documentary rather than a code change, and it is the correct one. ADR-0034 W now records which
form is canonical and points integrators at the three-argument form.

**Acknowledged, and open.**

*Oversized redemption input panics before balance validation.* `_quoteRedeem` computes
`usdfrIn + drawn` before checking the caller's balance, so a max-sized input with a live junior
draw overflows rather than returning a controller error. Reachable only on the under-backed path,
and no funds are at risk because no caller can hold such an amount.

*Invalid immutable module wiring requires an upgrade to recover.* `initialize` checks only that the
module addresses are non-zero, so a wrong or codeless address would leave the controller unusable
with no path back except an upgrade. Limited to deployment misconfiguration, and the recommended
validation is already in place: post-deploy checks assert `controller.modules()` against the
hash-bound manifest and confirm code through the ERC-1967 implementation slot.

*`previewRedeem()` can publish a redeem price that would not settle.* It checks the USDfr and
controller pauses but not the ReserveManager pause, so it can quote a full price while every
redemption reverts. It also passes a zero draw, so below par it publishes the gross marked price
while `redeem()` settles at the junior drawn price. A quoting defect, not a settlement one.

*Direct redemption does not consume the ADR-0033 exit interlock.* ADR-0033 §5 says junior and
senior exits share one interlock so neither cohort can escape while the other stays exposed.
`CuratorModule.withdrawFirstLoss` and `RedemptionQueue.closeEpoch` honour it; `_redeem` does not.
Most locked states are covered elsewhere, because an under-backed book and a latched deficit both
price sub-par and a live shortfall reverts. The state that leaves par reachable is **an active
reserve-loss arm before any physical shortfall**. Accepted as a known limitation of mainnet v1.

## What Cantina recorded as trust assumptions

The report devotes more space to trust assumptions than to findings, and that section is the more
useful read. It states plainly that attesters are the primary trust boundary for off-chain facts,
that once the oracle accepts the required signatures the protocol cannot independently verify the
underlying event, and that security therefore assumes no dishonest or compromised set of current
attester keys can meet the threshold.

It also records, so that it is not misreported as a safety guarantee, that **senior capital is
impairable** and direct redemption may settle below par after available junior protection is
applied, and that preventing every senior loss is not a protocol invariant.

## How to read this alongside the rest of the register

This review does not supersede the mainnet-v1 full audit of 16 August. That one covered the
deployed protocol against live mainnet state and its findings, including the open DV entries,
remain the substantive picture. This one examined two files in depth and found nothing above
informational in them.

The full report is published at `github.com/Forest-Road-Company/forest-road-vault` under `audit-reports/`.
