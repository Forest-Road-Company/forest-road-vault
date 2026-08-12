// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {CustodyShortfallHandler} from "./handlers/CustodyShortfallHandler.sol";

/// @title AUDIT FIX (R4-01) — custody-shortfall recognition, stateful campaign
/// @notice WHY THIS CAMPAIGN EXISTS. Every pre-existing stateful campaign asserts, directly or by
///         construction, that the idle ledger never over-claims custody — see
///         `BackingFocusedInvariants.invariant_backing_idleLedgerNeverExceedsCustody`. That
///         assertion is true THERE only because no action in those handlers can move USDC out of
///         the treasury without a matching ledger entry, so the region in which the ledger
///         over-claims was unreachable and the R4-01 defect was invisible to all of them: par
///         redemption kept paying 100 cents on the dollar out of a reserve `observeIdleUSDC()` was
///         simultaneously reporting as short, and the redeemer who exhausted the live balance got
///         the token's raw `ERC20InsufficientBalance`.
///
///         `CustodyShortfallHandler.custodyDrain` enters that region on purpose and probes the exit
///         while standing in it. The pre-existing campaigns are left alone: their fully-custodied
///         assumption is intact and unweakened, and this is a NEW domain rather than a relaxation
///         of an old one.
///
/// @dev DELETING EITHER R4-01 GUARD MAKES THIS CAMPAIGN RED, which is the reachability proof
///      required of it (evidence in the R4-01 mutation log):
///        - delete `MintRedeemController._requireCustodiedReserve` from `redeem`
///            -> `invariant_R4_01_noParExitFromAKnownShortReserve` fails;
///        - delete it from `mint`
///            -> `invariant_R4_01_noParIssuanceIntoAKnownShortReserve` fails;
///        - delete `ReserveManager._requireIdleFullyCustodied` from `_release`
///            -> `invariant_R4_01_exitFailuresAreProtocolErrorsNotRawTokenReverts` fails;
///        - revert `backingInvariantHolds()` / `recognizedBackingValue()` to the recorded basis
///            -> `invariant_R4_01_recognitionIdentityHolds` fails;
///        - AUDIT FIX (MA-1): delete `ReserveManager._requireIdleFullyCustodied` from
///          `recordDeployment` -> `invariant_MA1_noDeploymentOutOfAKnownShortReserve` fails;
///        - AUDIT FIX (MA-2): collapse `creditServicingBackingHolds()` into
///          `backingInvariantHolds()` in either direction
///            -> `invariant_MA2_solvencyAndCreditPredicatesStayDistinct` fails.
contract CustodyShortfallRecognitionInvariants is TokenLayerFixture {
    CustodyShortfallHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CustodyShortfallHandler(
            address(usdc),
            address(usdfr),
            address(reserves),
            address(controller),
            address(vault),
            admin,
            creditModule,
            borrower,
            [alice, bob]
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CustodyShortfallHandler.mintPar.selector;
        selectors[1] = CustodyShortfallHandler.stake.selector;
        // The action the whole campaign is for: it breaks ledger/custody equality out of band.
        selectors[2] = CustodyShortfallHandler.custodyDrain.selector;
        selectors[3] = CustodyShortfallHandler.custodyRestore.selector;
        selectors[4] = CustodyShortfallHandler.parExit.selector;
        selectors[5] = CustodyShortfallHandler.deployPrincipal.selector;
        selectors[6] = CustodyShortfallHandler.repayPrincipal.selector;
        // The reserve-side exit surface: a CONTROLLER_ROLE holder asking for cash directly. This
        // is what makes `ReserveManager._requireIdleFullyCustodied` independently mutation-visible
        // rather than shadowed by the controller's own pre-check.
        selectors[7] = CustodyShortfallHandler.directRelease.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (R4-01, CLAUDE.md §1.3 backing): the protocol never pays an exit at par
    ///         out of a reserve it can see is short. This is the finding, stated as a property.
    function invariant_R4_01_noParExitFromAKnownShortReserve() public view {
        assertEq(handler.gExitsWhileShort(), 0, "R4-01: PAR EXIT PAID OUT OF A KNOWN-SHORT RESERVE");
    }

    /// @notice INVARIANT (R4-01): nor does it sell a new claim at par into that same hole.
    function invariant_R4_01_noParIssuanceIntoAKnownShortReserve() public view {
        assertEq(handler.gMintsWhileShort(), 0, "R4-01: PAR ISSUANCE INTO A KNOWN-SHORT RESERVE");
    }

    /// @notice INVARIANT (MA-1, CLAUDE.md §1.3 backing): nor does live custody leave through the
    ///         OTHER out-door. `ReserveManager` has two functions that move USDC out — `_release`
    ///         and `recordDeployment` — and R4-01 guarded only the first, so while every user and
    ///         curator exit was frozen a servicer could still fund a facility out of the remaining
    ///         live balance and convert the frozen holders' last cash into a receivable.
    /// @dev DELETING `_requireIdleFullyCustodied` FROM `recordDeployment` MAKES THIS RED. That is
    ///      the reachability proof required of the guard; `CustodyShortfallHandler.custodyDrain`
    ///      probes the door on every drain so the illegal region is entered by construction rather
    ///      than by a lucky ordering.
    function invariant_MA1_noDeploymentOutOfAKnownShortReserve() public view {
        assertEq(handler.gDeploymentsWhileShort(), 0, "MA-1: CREDIT DEPLOYMENT OUT OF A KNOWN-SHORT RESERVE");
        assertEq(handler.gUSDCDeployedWhileShort(), 0, "MA-1: LIVE CUSTODY LEFT A KNOWN-SHORT RESERVE");
    }

    /// @notice INVARIANT (MA-2): the SOLVENCY predicate and the PERFORMING-CREDIT predicate are
    ///         two different questions and neither may be collapsed into the other. R4-01 flipped
    ///         `backingInvariantHolds()` onto the recognised basis, which was right for solvency
    ///         and wrong for `WaterfallEngine.distribute`'s closing gate — one custody hole halted
    ///         every performing borrower's repayment protocol-wide, blocking the very money that
    ///         repairs the balance sheet.
    /// @dev Collapse either direction and this reds: point `creditServicingBackingHolds()` at the
    ///      recognised basis, or point `backingInvariantHolds()` back at the recorded one.
    function invariant_MA2_solvencyAndCreditPredicatesStayDistinct() public view {
        assertEq(
            controller.creditServicingBackingHolds(),
            controller.totalUSDfr() <= reserves.totalBackingValue(),
            "MA-2: THE CREDIT-SERVICING PREDICATE LEFT THE RECORDED LEDGER"
        );
        assertEq(
            controller.backingInvariantHolds(),
            controller.totalUSDfr() <= reserves.recognizedBackingValue(),
            "MA-2: THE SOLVENCY PREDICATE LEFT THE RECOGNISED BASIS"
        );
    }

    /// @notice INVARIANT (R4-01, CLAUDE.md prime directive 4 — fail loudly, with a clear custom
    ///         error): a blocked exit fails with the PROTOCOL's error. A bare
    ///         `ERC20InsufficientBalance` out of the token carries no protocol meaning, cannot be
    ///         decoded by the frontend, and is indistinguishable from a wallet-side mistake.
    function invariant_R4_01_exitFailuresAreProtocolErrorsNotRawTokenReverts() public view {
        assertEq(handler.gRawTokenRevertsOnExit(), 0, "R4-01: RAW ERC20 REVERT ON THE EXIT PATH");
    }

    /// @notice INVARIANT (R4-01): the two backing bases never drift. `totalBackingValue()` is the
    ///         RECORDED-ledger basis the C-01 custody-loss arithmetic reconciles against;
    ///         `recognizedBackingValue()` is that number net of the shortfall the contract can
    ///         observe. Collapsing one into the other in either direction breaks this.
    function invariant_R4_01_recognitionIdentityHolds() public view {
        assertEq(
            reserves.recognizedBackingValue(),
            reserves.totalBackingValue() - reserves.idleCustodyShortfall(),
            "R4-01: RECOGNITION IDENTITY DRIFTED"
        );
        assertEq(reserves.idleCustodyShortfall(), handler.shortfallUnits() * 1e12, "R4-01: SHORTFALL MISREPORTED");
        assertEq(
            controller.backingInvariantHolds(),
            controller.totalUSDfr() <= reserves.recognizedBackingValue(),
            "R4-01: THE PUBLIC GATE IS NOT ON THE RECOGNISED BASIS"
        );
    }

    /// @notice INVARIANT (R4-01): recognised backing never counts a dollar of USDC the contract is
    ///         not holding. Stated against the token balance directly, so it cannot be satisfied by
    ///         any internal bookkeeping that merely agrees with itself.
    function invariant_R4_01_recognisedBackingNeverCountsAbsentCash() public view {
        assertLe(
            reserves.recognizedBackingValue(),
            usdc.balanceOf(address(reserves)) * 1e12 + reserves.deployedPrincipal()
                - reserves.totalPrincipalImpairment(),
            "R4-01: RECOGNISED BACKING COUNTED CASH THAT IS NOT THERE"
        );
    }

    /// @dev ANTI-VACUITY, and specifically anti-decoration. A campaign that never drained custody,
    ///      or never probed an exit while short, would pass every assertion above while proving
    ///      nothing — that is precisely how campaign 5's pre-filtered handlers passed. A protocol
    ///      that simply reverted every exit unconditionally would also pass, so ordinary par
    ///      business is required to have WORKED as well.
    function afterInvariant() public view {
        assertGt(controller.totalUSDfr(), 0, "VACUOUS: no supply was ever minted");
        assertGt(handler.callCount(), 0, "VACUOUS: the handler was never called");
        assertGt(handler.gDrains(), 0, "VACUOUS: custody was never drained, the region was never reached");
        assertGt(handler.gExitAttemptsWhileShort(), 0, "VACUOUS: no exit was ever probed while short");
        assertGt(handler.gExitsWhileWhole(), 0, "VACUOUS: par exit never worked, so blocking it proves nothing");
        assertGt(handler.gMintsWhileWhole(), 0, "VACUOUS: par issuance never worked, so blocking it proves nothing");
        // AUDIT FIX (MA-1): the second out-door must have been probed while short AND must have
        // worked while whole, or `invariant_MA1_noDeploymentOutOfAKnownShortReserve` is decoration.
        assertGt(handler.gDeployAttemptsWhileShort(), 0, "VACUOUS: the credit door was never probed while short");
        assertGt(
            handler.gDeploymentsWhileWhole(),
            0,
            "VACUOUS: credit deployment never worked, so blocking it proves nothing"
        );
        // AUDIT FIX (MA-2): the campaign must have STOOD in the state where the two predicates
        // disagree, or `invariant_MA2_solvencyAndCreditPredicatesStayDistinct` never separated
        // anything.
        assertGt(handler.gPredicatesDiverged(), 0, "VACUOUS: the solvency/credit divergence was never reached");
    }
}
