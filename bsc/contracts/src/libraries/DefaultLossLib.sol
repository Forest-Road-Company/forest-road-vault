// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {DefaultManager} from "../DefaultManager.sol";
import {ClaimBridge} from "../ClaimBridge.sol";
import {IDefaultManager} from "../interfaces/IDefaultManager.sol";
import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {DefaultAccrualLib} from "./DefaultAccrualLib.sol";

/// @title DefaultLossLib
/// @notice The native BSC facility-loss cascade, linked to preserve the implementation size limit.
/// @dev Moved from DefaultManager without changing its allocation, evidence or write-down rules.
///      The only new preparation is delivery of existing virtual claims before physical burns.
///      The host retains SERVICER_ROLE and nonReentrant. Delegate calls retain the native proxy's
///      namespace and identity. No second loss layer, arbitrary write-off or rounding path is added.
library DefaultLossLib {
    /// @notice Allocates an attested default loss through prepaid absorption, curator, then senior.
    /// @dev The caller retains authorization and the outer operation guard; every burn precedes face removal.
    function realizeLoss(DefaultManager.DefaultStorage storage $, uint256 tokenId, uint256 loss, bytes32 evidenceHash)
        public
    {
        if (loss == 0) revert IDefaultManager.DefaultManager_ZeroAmount();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Defaulted && f.state != ClaimBridge.LoanState.Accelerated) {
            revert IDefaultManager.DefaultManager_NotInDefault(tokenId);
        }
        // Block-scoped so `outstanding` does not survive into the cascade body: ADR-0034 Y-bis's
        // layer-0 local (`allocatable`) pushed this function over the stack limit otherwise.
        {
            uint256 outstanding = $.reserves.deployedTo(tokenId);
            if (loss > outstanding) {
                revert IDefaultManager.DefaultManager_LossExceedsOutstanding(tokenId, loss, outstanding);
            }
        }
        // C4-01: the durable oracle fact key uses the economic evidence identity, not
        // signature salt; a zero evidence id would collapse distinct equal-sized events.
        if (evidenceHash == bytes32(0)) revert IDefaultManager.DefaultManager_ZeroEvidenceHash();
        consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(tokenId, loss, evidenceHash)),
            true
        );

        // Crystallize all pre-loss fees before any cascade leg moves value. The HWM then
        // remains at the pre-loss post-fee peak, so recovery from this loss is never charged
        // again as performance. A later revert rolls this checkpoint back atomically.
        DefaultAccrualLib.materialize($);
        IsUSDfr($.vault).accrueFees();

        // -- layer 0: junior absorption ALREADY PAID FORWARD by senior exits ---
        // ADR-0034 Y-bis - LOAD-BEARING, DO NOT DELETE. See `exitPrepaidAbsorption`'s field
        // NatSpec for the full derivation. Without this the junior tranche pays TWICE for one
        // loss: once at the exit draw, again here.
        uint256 allocatable = loss - $.reserves.consumeExitPrepayment(tokenId, loss);

        // -- layer 1: curator first-loss (always consulted first) ----------
        uint256 absorbed;
        if (allocatable != 0) (absorbed,) = $.curator.absorbLoss(f.classId, allocatable);

        // -- THERE IS NO LAYER TWO ON THIS INSTANCE (ADR-0037 D3a(ii)) -----
        // The residual `absorbLoss` returns is layer 1's SECOND return and there is nothing left
        // to offer it to, so it is senior loss by construction. `absorbLoss` clamps to the class
        // pool's balance, therefore a non-zero residual means that pool is EXHAUSTED - the
        // ordering property is a theorem about the dataflow, not an assertion in it (C-04). The
        // residual is deliberately not bound to a local: `allocatable - selfBurn` below IS it, and
        // a second name for the same number is a second thing to keep in step. `LossRealized`'s
        // layer-two field is emitted as a literal zero, which is itself the disclosure.

        // -- burn layer 1's absorption from this contract ------------------
        uint256 selfBurn = absorbed;
        if (selfBurn != 0) $.controller.burnLoss(address(this), selfBurn);

        // -- layer 2: depositor principal (only past curator first-loss) ---
        // NOTE (ADR-0034 Y-bis): `allocatable`, not `loss`. The layer-0 prepayment has already
        // been burned out of junior capital by the exit that drew it, so charging the vault for
        // it here would burn the same dollar of supply twice.
        uint256 depositorLoss = allocatable - selfBurn;
        if (depositorLoss != 0) {
            // ADR-0023: bound by the vault's VESTED assets, not its raw USDfr balance. The
            // balance also contains realized yield still streaming in, which is not yet
            // credited to any share. Burning into it would leave `unvestedYield()` above the
            // balance, collapsing `totalAssets()` to zero for the rest of the stream - a
            // section 1.3 exchange-rate monotonicity break far larger than the loss itself, and
            // fatal to the TWAP rate oracle. Bounding here keeps `balance >= unvested` true
            // by construction; the vault's own clamp is then unreachable defence-in-depth.
            // Strictly the CONSERVATIVE direction: it can only make `realizeLoss` revert
            // earlier into the existing governance-intervention path, never absorb more.
            uint256 vaultAssets = IsUSDfr($.vault).totalAssets();
            if (vaultAssets < depositorLoss) {
                // beyond total absorption capacity: unstaked USDfr would be impaired -
                // fail loudly; governance must intervene (CLAUDE.md prime directive 4).
                //
                // AUDIT FIX (G3) - WHAT "INTERVENE" NOW MEANS ON-CHAIN. This revert rolls back
                // the whole call INCLUDING `reserves.recordPrincipalWritedown` below, so before
                // G3 there was no way to state that the unabsorbable portion had become
                // worthless: backing stayed at face, `backingInvariantHolds()` reported true
                // against that fiction, and 1:1 minting continued. The intervention is
                // `ReserveManager.recognizePrincipalImpairment(tokenId, residual, evidence)` -
                // a governance valuation act that lowers backing without burning supply, leaving
                // this cascade to allocate whatever capital does exist. DO NOT relax this bound
                // to "make the loss go through": that would impair unstaked USDfr holders, who
                // sit outside the section 1.3 cascade entirely.
                revert IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity(tokenId, depositorLoss, vaultAssets);
            }
            $.controller.burnLoss($.vault, depositorLoss);
        }

        // -- pair the write-down with the burns, atomically (ADR-0012) -----
        $.reserves.recordPrincipalWritedown(tokenId, loss);
        $.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, loss);
        // ADR-0022: the realized portion leaves the at-risk (unrealized-impairment) pool -
        // it is now reflected in the vault's balance via the senior burn above.
        reduceDefaulted($, tokenId, f.classId, loss);
        // A write-down can be the final act of a workout (including a zero-recovery
        // resolution, or cash recovered before the residual is written off). Previously
        // only WaterfallEngine's final cash repayment could enter `Resolved`, so a full
        // write-off left a zero-outstanding NFT permanently `Defaulted`/`Accelerated`.
        // Transition here once the atomic write-down has exhausted the outstanding.
        if ($.reserves.deployedTo(tokenId) == 0) {
            $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Resolved);
            DefaultAccrualLib.retireAfterLoss($, tokenId);
        }
        advanceImpairmentRevision($);

        emit IDefaultManager.LossRealized(tokenId, f.classId, loss, absorbed, 0, depositorLoss);
    }

    /// @notice Validates the exact standing fact and optionally consumes its durable identity.
    function consumeExact(
        DefaultManager.DefaultStorage storage $,
        uint256 tokenId,
        IAttestationOracle.AttestationKind kind,
        bytes32 expected,
        bool consume
    ) internal {
        (bytes32 payload,, bool ok) = $.oracle.latestPayload(tokenId, kind);
        if (!ok || payload != expected) revert IDefaultManager.DefaultManager_DefaultNotAttested(tokenId);
        if (consume) $.oracle.consume(tokenId, kind);
    }

    /// @dev ADR-0022: reduce a loan's impairment contribution (and its class pool) by up to
    ///      `amount` (clamped so a partial/over realizeLoss can never underflow the pool), then
    ///      re-anchor what is left to the principal that is actually still at risk.
    ///
    ///      AUDIT FIX (H-2). The contribution was snapshotted from `deployedTo` at declare and
    ///      only ever decremented by realized loss, but a principal RECOVERY on a defaulted
    ///      facility (`WaterfallEngine.distribute` on a Defaulted/Accelerated loan) reduces
    ///      `deployedTo` without telling this contract. Recover part, write off the rest, and the
    ///      loan lands at `deployedTo == 0` with a contribution equal to the CASH RECOVERED -
    ///      stranded forever, because `Resolved` is only reachable through `distribute`'s
    ///      `outstanding == 0` branch and `distribute` reverts once outstanding is zero. The
    ///      On the pre-ADR-0035 tree the stranded mark also pinned
    ///      `liveDefaultCoverageConsumed` and its capacity floor, under-netting layer two for
    ///      every FUTURE default. Those fields are permanently zero here, but the stuck mark
    ///      itself is still the defect this re-anchor prevents.
    ///
    ///      The re-anchor is `min(remaining, deployedTo(tokenId))`, taken AFTER
    ///      `recordPrincipalWritedown` so `deployedTo` is already net of this loss. It cannot
    ///      UNDER-mark: `realizeLoss` reverts when `loss > deployedTo(tokenId)`, so the largest
    ///      senior loss this facility can ever still produce is exactly its current
    ///      `deployedTo`, and `deployedTo` never rises for a defaulted loan (it only grows in
    ///      `recordDeployment`/`recordFeeCapitalization`, both reachable only from a Pending
    ///      facility). Everything the clamp removes is principal that is provably no longer
    ///      losable - either repaid in cash or already written down.
    ///
    ///      BELT AND BRACES ONLY, since the H-2 remediation. `onDefaultRecovery` now re-anchors
    ///      at RECOVERY time, so on the wired path this clamp finds `derecognized == 0` and is a
    ///      no-op. It still fires - and must be kept - when the engine's `defaultManager` wiring
    ///      is zero (the optional-wiring configuration `WaterfallEngine.distribute` explicitly
    ///      supports), which is the only remaining way `deployedTo` can fall behind the mark.
    ///
    ///      THREAT MODEL: the no-under-mark argument depends on CREDIT_ROLE being held by
    ///      protocol modules only. A CREDIT_ROLE grant to an EOA could call
    ///      `ReserveManager.recordPayment`/`recordPrincipalWritedown` directly, dropping
    ///      `deployedTo` with no cash arriving and no cascade run, after which this clamp would
    ///      de-recognise a genuine loss.
    function reduceDefaulted(DefaultManager.DefaultStorage storage $, uint256 tokenId, uint256 classId, uint256 amount)
        internal
    {
        uint256 c = $.defaultedContribution[tokenId];
        uint256 dec = amount < c ? amount : c;
        uint256 remaining = c - dec;
        // H-2: principal recovered in cash since the declare is no longer at risk.
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        uint256 derecognized = stillAtRisk < remaining ? remaining - stillAtRisk : 0;
        dec += derecognized;
        if (dec != 0) {
            // The Ethereum tree decremented `drawnDefaultPrincipal[classId]` here whenever this
            // token had drawn layer two. Nothing can draw layer two on this instance, so that
            // cohort is empty by construction and the decrement is deleted rather than left as a
            // permanently-false branch pretending to guard something (ADR-0037 D3a(ii)).
            $.defaultedContribution[tokenId] = c - dec;
            $.declaredDefaultedPrincipal[classId] -= dec;
        }
        // The realized part is already reported by `LossRealized`; the clamped part is
        // impairment de-recognised WITHOUT a loss, so it emits the same event the clean-resolve
        // path uses - the impairment pool stays reconstructable from events alone.
        if (derecognized != 0) emit IDefaultManager.DefaultImpairmentCleared(tokenId, classId, derecognized);
        // Once nothing of this default is left unrealized, release its row and historical
        // consumption counters. The live reserve already reflects every actual draw.
        uint256 updated = $.defaultedContribution[tokenId];
        if (updated == 0) releaseCoverageConsumption($, tokenId);
        else $.commitmentLedger.updatePrincipal(tokenId, updated);
    }

    /// @notice Releases the historical coverage observations when a default closes.
    function releaseCoverageConsumption(DefaultManager.DefaultStorage storage $, uint256 tokenId) internal {
        uint256 consumed = $.coverageConsumedByDefault[tokenId];
        if (consumed != 0) {
            $.coverageConsumedByDefault[tokenId] = 0;
            $.liveDefaultCoverageConsumed -= consumed;
        }
        $.commitmentLedger.release(tokenId);
    }

    /// @notice Invalidates prior risk assessments after a substantive native risk transition.
    function advanceImpairmentRevision(DefaultManager.DefaultStorage storage $) internal {
        $.impairmentRevision += 1;
        emit IDefaultManager.ImpairmentRevisionAdvanced($.impairmentRevision);
    }
}
