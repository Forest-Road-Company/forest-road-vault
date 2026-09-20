// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {DefaultAccrualLib} from "./DefaultAccrualLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimBridge} from "../ClaimBridge.sol";
import {Config} from "./Config.sol";
import {DefaultManager} from "../DefaultManager.sol";
import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";
import {ICascadeBackstop} from "../interfaces/ICascadeBackstop.sol";
import {IDefaultManager} from "../interfaces/IDefaultManager.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";

/// @title DefaultLossLib - the DefaultManager's loss-realisation body
///
/// @notice EXTRACTED 2026-09-10 FOR EIP-170, the second of two extractions made that day and the
///         larger one. `DefaultInitLib` came first and bought 536 bytes, which left 264 of margin:
///         under the limit but still frozen against any future change, which is the condition that
///         caused this whole exercise. See `DefaultInitLib`'s header for how the contract came to
///         be 272 bytes over in the first place.
///
/// @dev THIS IS THE LOSS CASCADE, so read the extraction rules before touching it.
///      Every function here is a VERBATIM move of a body that lived in `DefaultManager`. The order
///      of operations was not altered, and it must not be: ADR-0012 requires that all `burnLoss`
///      calls execute BEFORE `recordPrincipalWritedown`, so that the backing invariant asserted
///      inside each burn sees supply falling while backing is still whole. Nothing in between may
///      observe a violation. If you change anything here, re-read that note in `realizeLoss` first.
///
/// @dev `realizeLoss` IS `public`; THE HELPERS ARE `internal`, AND THE SPLIT IS DELIBERATE.
///      A `public` library function is deployed as its own contract and reached by delegatecall, so
///      its bytecode leaves the caller's runtime; an `internal` one is inlined and saves nothing.
///      `realizeLoss` is the body worth moving. The helpers stay `internal` because several of them
///      are ALSO called from `DefaultManager` (`consumeExact`, `coverFromBackstop`,
///      `releaseCoverageConsumption` and `advanceImpairmentRevision` all have callers there), and
///      an internal library function gives those call sites exactly the inlined code they had
///      before while keeping ONE definition. Duplicating cascade helpers between the contract and
///      the library was the alternative, and two copies of loss-allocation logic that can drift
///      apart is precisely the defect this repository keeps finding in other forms.
///
/// @dev THE CALLER KEEPS THE GUARDS. `DefaultManager.realizeLoss` retains `onlyRole(SERVICER_ROLE)`
///      and `nonReentrant`, because a delegatecall runs in the proxy's context and a library cannot
///      see the caller's modifiers. Do not call `realizeLoss` here from a path that lacks them.
///
/// @dev THE `public` ENTRY POINT IS DIRECTLY CALLABLE ON THE DEPLOYED LIBRARY, and that is inert
///      rather than merely unlikely. A `public` library function has a selector, and its
///      storage-struct parameter is ABI-encoded as a plain slot number, so anyone can call
///      `DefaultLossLib.realizeLoss(anySlot, ...)` on the library address itself. That call runs in
///      the LIBRARY's own context, where storage is entirely zero: `$.bridge` reads as
///      `address(0)`, and solc's extcodesize check on a call that expects return data reverts
///      before anything else happens. The library holds no roles, no balances and no proxy, so
///      there is nothing for a direct caller to reach even if a future edit made an early read
///      survive. Do NOT add state to this library.
///
/// @dev DELEGATECALL MEANS `address(this)` IS THE PROXY, which is what keeps
///      `$.controller.burnLoss(address(this), selfBurn)` burning from the manager exactly as it did
///      when this body lived in the contract.
library DefaultLossLib {
    /// @dev MOVED WITH `coverFromBackstop`, verbatim from `DefaultManager`. The bounded-gas probe
    ///      and the hand-rolled call exist so a hostile or broken backstop cannot brick the
    ///      cascade; see the body for the full reasoning.
    /// @dev `internal` so `DefaultManager`'s two remaining probe sites share this ONE
    ///      definition rather than keeping a second copy that could drift.
    uint256 internal constant BACKSTOP_PROBE_GAS = 200_000;
    uint256 private constant COVER_DELEGATE_SELECTOR =
        0xc4e35fac00000000000000000000000000000000000000000000000000000000;

    /// @dev Body of `DefaultManager.realizeLoss`; the caller keeps every modifier.
    /// @dev Order matters for ADR-0012: all burns execute BEFORE the write-down, so the
    ///      backing invariant asserted inside each `burnLoss` sees supply falling while
    ///      backing is still whole; the write-down then drops backing by exactly the
    ///      amount supply already fell. Nothing in between can observe a violation.
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

        // ── layer 0: junior absorption ALREADY PAID FORWARD by senior exits ───
        // ADR-0034 Y-bis — LOAD-BEARING, DO NOT DELETE. See `exitPrepaidAbsorption`'s field
        // NatSpec for the full derivation. Without this the junior tranche pays TWICE for one
        // loss: once at the exit draw, again here.
        uint256 allocatable = loss - $.reserves.consumeExitPrepayment(tokenId, loss);

        // ── layer 1: curator first-loss (always consulted first) ──────────
        uint256 absorbed;
        uint256 residual;
        if (allocatable != 0) (absorbed, residual) = $.curator.absorbLoss(f.classId, allocatable);

        // ── layer 2: sGROVE backstop (only for the residual) ──────────────
        // ADR-0035 draws from the shared live reserve. The event row is synchronized inside the
        // helper so its post-draw principal state never has to live in this frame.
        uint256 covered = drawLayer2ForLiveDefault($, tokenId, f.classId, residual);

        // ── burn junior layers' absorption from this contract ─────────────
        uint256 selfBurn = absorbed + covered;
        if (selfBurn != 0) $.controller.burnLoss(address(this), selfBurn);

        // ── layer 3: depositor principal (only past BOTH junior layers) ───
        // NOTE (ADR-0034 Y-bis): `allocatable`, not `loss`. The layer-0 prepayment has already
        // been burned out of junior capital by the exit that drew it, so charging the vault for
        // it here would burn the same dollar of supply twice.
        uint256 depositorLoss = allocatable - selfBurn;
        if (depositorLoss != 0) {
            // ADR-0023: bound by the vault's VESTED assets, not its raw USDfr balance. The
            // balance also contains realized yield still streaming in, which is not yet
            // credited to any share. Burning into it would leave `unvestedYield()` above the
            // balance, collapsing `totalAssets()` to zero for the rest of the stream — a
            // §1.3 exchange-rate monotonicity break far larger than the loss itself, and
            // fatal to the TWAP rate oracle. Bounding here keeps `balance >= unvested` true
            // by construction; the vault's own clamp is then unreachable defence-in-depth.
            // Strictly the CONSERVATIVE direction: it can only make `realizeLoss` revert
            // earlier into the existing governance-intervention path, never absorb more.
            uint256 vaultAssets = IsUSDfr($.vault).totalAssets();
            if (vaultAssets < depositorLoss) {
                // beyond total absorption capacity: unstaked USDfr would be impaired —
                // fail loudly; governance must intervene (CLAUDE.md prime directive 4).
                //
                // AUDIT FIX (G3) — WHAT "INTERVENE" NOW MEANS ON-CHAIN. This revert rolls back
                // the whole call INCLUDING `reserves.recordPrincipalWritedown` below, so before
                // G3 there was no way to state that the unabsorbable portion had become
                // worthless: backing stayed at face, `backingInvariantHolds()` reported true
                // against that fiction, and 1:1 minting continued. The intervention is
                // `ReserveManager.recognizePrincipalImpairment(tokenId, residual, evidence)` —
                // a governance valuation act that lowers backing without burning supply, leaving
                // this cascade to allocate whatever capital does exist. DO NOT relax this bound
                // to "make the loss go through": that would impair unstaked USDfr holders, who
                // sit outside the §1.3 cascade entirely.
                revert IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity(tokenId, depositorLoss, vaultAssets);
            }
            $.controller.burnLoss($.vault, depositorLoss);
        }

        // ── pair the write-down with the burns, atomically (ADR-0012) ─────
        $.reserves.recordPrincipalWritedown(tokenId, loss);
        $.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, loss);
        // ADR-0022: the realized portion leaves the at-risk (unrealized-impairment) pool —
        // it is now reflected in the vault's balance via the layer-3 burn above.
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

        emit IDefaultManager.LossRealized(tokenId, f.classId, loss, absorbed, covered, depositorLoss);
    }

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

    function coverFromBackstop(DefaultManager.DefaultStorage storage $, uint256 eventId, uint256 residual)
        internal
        returns (uint256 covered)
    {
        address backstopAddress = address($.backstop);
        address asset = address($.usdfr);
        address ledger = address($.commitmentLedger);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, COVER_DELEGATE_SELECTOR)
            mstore(add(ptr, 0x04), backstopAddress)
            mstore(add(ptr, 0x24), asset)
            mstore(add(ptr, 0x44), eventId)
            mstore(add(ptr, 0x64), residual)
            let ok := delegatecall(gas(), ledger, ptr, 0x84, ptr, 0x20)
            if iszero(ok) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            covered := mload(ptr)
        }
    }

    /// @dev Drop `tokenId`'s historical sGROVE consumption and live principal row. Idempotent: a
    ///      second call is a no-op, so the two terminal callers cannot double-release.
    function releaseCoverageConsumption(DefaultManager.DefaultStorage storage $, uint256 tokenId) internal {
        uint256 consumed = $.coverageConsumedByDefault[tokenId];
        if (consumed != 0) {
            $.coverageConsumedByDefault[tokenId] = 0;
            $.liveDefaultCoverageConsumed -= consumed;
        }
        $.commitmentLedger.release(tokenId);
    }

    /// @dev One bump per externally observable risk transition. Checked arithmetic deliberately
    ///      fails loudly at the theoretical uint256 limit rather than wrapping and reviving a
    ///      centuries-old assessment.
    function advanceImpairmentRevision(DefaultManager.DefaultStorage storage $) internal {
        $.impairmentRevision += 1;
        emit IDefaultManager.ImpairmentRevisionAdvanced($.impairmentRevision);
    }

    /// @dev ADR-0022: reduce a loan's impairment contribution (and its class pool) by up to
    ///      `amount` (clamped so a partial/over realizeLoss can never underflow the pool), then
    ///      re-anchor what is left to the principal that is actually still at risk.
    ///
    ///      AUDIT FIX (H-2). The contribution was snapshotted from `deployedTo` at declare and
    ///      only ever decremented by realized loss, but a principal RECOVERY on a defaulted
    ///      facility (`WaterfallEngine.distribute` on a Defaulted/Accelerated loan) reduces
    ///      `deployedTo` without telling this contract. Recover part, write off the rest, and the
    ///      loan lands at `deployedTo == 0` with a contribution equal to the CASH RECOVERED —
    ///      stranded forever, because `Resolved` is only reachable through `distribute`'s
    ///      `outstanding == 0` branch and `distribute` reverts once outstanding is zero. The
    ///      On the pre-ADR-0035 tree the stranded mark also pinned
    ///      `liveDefaultCoverageConsumed` and its capacity floor, under-netting the backstop for
    ///      every FUTURE default. Those fields are now historical, but the stuck mark itself is
    ///      still the defect this re-anchor prevents.
    ///
    ///      The re-anchor is `min(remaining, deployedTo(tokenId))`, taken AFTER
    ///      `recordPrincipalWritedown` so `deployedTo` is already net of this loss. It cannot
    ///      UNDER-mark: `realizeLoss` reverts when `loss > deployedTo(tokenId)`, so the largest
    ///      senior loss this facility can ever still produce is exactly its current
    ///      `deployedTo`, and `deployedTo` never rises for a defaulted loan (it only grows in
    ///      `recordDeployment`/`recordFeeCapitalization`, both reachable only from a Pending
    ///      facility). Everything the clamp removes is principal that is provably no longer
    ///      losable — either repaid in cash or already written down.
    ///
    ///      BELT AND BRACES ONLY, since the H-2 remediation. `onDefaultRecovery` now re-anchors
    ///      at RECOVERY time, so on the wired path this clamp finds `derecognized == 0` and is a
    ///      no-op. It still fires — and must be kept — when the engine's `defaultManager` wiring
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
            if ($.coverageConsumedByDefault[tokenId] != 0) $.drawnDefaultPrincipal[classId] -= dec;
            $.defaultedContribution[tokenId] = c - dec;
            $.declaredDefaultedPrincipal[classId] -= dec;
        }
        // The realized part is already reported by `LossRealized`; the clamped part is
        // impairment de-recognised WITHOUT a loss, so it emits the same event the clean-resolve
        // path uses — the impairment pool stays reconstructable from events alone.
        if (derecognized != 0) emit IDefaultManager.DefaultImpairmentCleared(tokenId, classId, derecognized);
        // Once nothing of this default is left unrealized, release its row and historical
        // consumption counters. The live reserve already reflects every actual draw.
        uint256 updated = $.defaultedContribution[tokenId];
        if (updated == 0) releaseCoverageConsumption($, tokenId);
        else $.commitmentLedger.updatePrincipal(tokenId, updated);
    }

    /// @dev Attested LTV in bps: outstanding principal over the latest mark. A facility
    ///      with no mark at all cannot use the margin path (reverts NoValuation).
    /// @dev LAYER 2 helper shared by facility `realizeLoss` and `drawForSeniorExit`. The retained
    ///      `absorbReserveLoss` compatibility entry also calls it, but no production source calls
    ///      that entry; live custody losses use `ReserveManager._drawJuniorReserveLoss` and its own
    ///      equivalent balance-delta check. This helper takes `residual` — layer 1's leftover — and
    ///      NOTHING ELSE, which makes "never before layer 1, never for more than layer 1 declined"
    ///      a property of the dataflow rather than a comment.
    ///
    ///      THE STRICT EQUALITY IS THE `ICascadeBackstop` CONTRACT (AUDIT FIX L) — DO NOT RELAX IT
    ///      TO `received >= covered`. Over-delivery would strand USDfr at this contract AND make
    ///      the senior layer over-absorb, because every caller computes its layer-3 charge from
    ///      `covered`. Falsified in both directions by the existing backstop-double suites.
    /// @dev Layer 2 for a facility default: draw the shared reserve, then mark this row drawn.
    ///      ADR-0035 gives a drawn row no frozen room; its claim bound is only its remaining
    ///      principal, and the ledger applies the live shared reserve during every mark-time walk.
    function drawLayer2ForLiveDefault(
        DefaultManager.DefaultStorage storage $,
        uint256 tokenId,
        uint256 classId,
        uint256 residual
    ) internal returns (uint256 covered) {
        bool firstDraw;
        covered = coverFromBackstop($, tokenId, residual);
        if (covered == 0) return 0;
        uint256 remainingPrincipal = $.defaultedContribution[tokenId];
        firstDraw = $.commitmentLedger.sync(tokenId, remainingPrincipal, remainingPrincipal, covered);
        if (firstDraw) {
            // Historical drawn-cohort observability; no distinct cap arithmetic survives.
            $.drawnDefaultPrincipal[classId] += $.defaultedContribution[tokenId];
        }
        $.coverageConsumedByDefault[tokenId] += covered;
        $.liveDefaultCoverageConsumed += covered;
    }
    /// @notice Native recovery continuation; the host retains credit authority and operation guards.

    function onDefaultResolved(DefaultManager.DefaultStorage storage $, uint256 tokenId) public {
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Resolved) revert IDefaultManager.DefaultManager_NotResolved(tokenId);
        uint256 c = $.defaultedContribution[tokenId];
        if (c != 0) {
            if ($.coverageConsumedByDefault[tokenId] != 0) $.drawnDefaultPrincipal[f.classId] -= c;
            $.defaultedContribution[tokenId] = 0;
            $.declaredDefaultedPrincipal[f.classId] -= c;
            emit IDefaultManager.DefaultImpairmentCleared(tokenId, f.classId, c);
        }
        releaseCoverageConsumption($, tokenId); // PM-R-11: no longer a live default
        advanceImpairmentRevision($);
    }

    /// @notice Native recovery continuation; the host retains credit authority and operation guards.
    function onDefaultRecovery(DefaultManager.DefaultStorage storage $, uint256 tokenId) public {
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        // Defensive, mirroring `onDefaultResolved`: a CREDIT_ROLE caller must not be able to
        // re-anchor a facility that is not actually in default (its contribution is zero in
        // every other state anyway, so this is belt-and-braces, not load-bearing arithmetic).
        if (f.state != ClaimBridge.LoanState.Defaulted && f.state != ClaimBridge.LoanState.Accelerated) {
            revert IDefaultManager.DefaultManager_NotInDefault(tokenId);
        }
        uint256 c = $.defaultedContribution[tokenId];
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        if (stillAtRisk >= c) return; // idempotent: nothing recovered since the last anchor
        uint256 derecognized = c - stillAtRisk;
        if ($.coverageConsumedByDefault[tokenId] != 0) {
            $.drawnDefaultPrincipal[f.classId] -= derecognized;
        }
        $.defaultedContribution[tokenId] = stillAtRisk;
        $.declaredDefaultedPrincipal[f.classId] -= derecognized;
        emit IDefaultManager.DefaultImpairmentCleared(tokenId, f.classId, derecognized);
        // If recovery emptied the mark, release its historical consumption and live ledger row.
        // Unreachable from `WaterfallEngine.distribute` (a zero outstanding routes to
        // `onDefaultResolved` instead), kept so the two hooks cannot diverge.
        if (stillAtRisk == 0) releaseCoverageConsumption($, tokenId);
        else $.commitmentLedger.updatePrincipal(tokenId, stillAtRisk);
        advanceImpairmentRevision($);
    }
}
