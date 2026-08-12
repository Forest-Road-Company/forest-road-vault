// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @title AUDIT FIX (MA-1 / R4-01 SECOND OUT-DOOR) — THE DEPLOYMENT DOOR
/// @notice THE FINDING, and it is a MERGE defect: it exists only because seven independently
///         developed fixes were combined.
///
///         R4-01 closed par MINT and par REDEEM against a reserve the contract can see is short
///         (`MintRedeemController._requireCustodiedReserve`) and closed
///         `ReserveManager._release`, the exit the controller calls
///         (`_requireIdleFullyCustodied`). R6-CF1 closed the CURATOR exit for the same window
///         (`CuratorModule.custodyFreezeActive` / `ReserveManager.custodyLossUnabsorbed`). Between
///         them every USER path and every CURATOR path was shut.
///
///         `ReserveManager` has TWO doors that move USDC out of the treasury, not one:
///           `_release`          — the redemption exit, guarded by R4-01; and
///           `recordDeployment`  — the CREDIT door, which pushes idle cash to a borrower.
///         Only the first was guarded. So while every retail and curator exit was frozen, a
///         SERVICER could still call `WaterfallEngine.fund` and a CREDIT_ROLE holder could still
///         call `ReserveManager.recordDeployment` directly, and hand the reserve's remaining LIVE
///         USDC — the only cash left standing behind the frozen USDfr — to a borrower, converting
///         it into an illiquid receivable. The holders whose exits R4-01 had just closed "for
///         their protection" were left with a claim on a facility instead of on cash, and the
///         recognised shortfall became unrecoverable by anything short of a workout.
///
///         It is strictly worse than the original R4-01 defect. R4-01 paid par first-come
///         first-served, which at least paid SOMEONE at 100 cents. The deployment door pays no
///         holder at all: it removes the cash entirely while the queue is frozen shut.
///
/// @dev THE FIX. `recordDeployment` now routes through the SAME `_requireIdleFullyCustodied`
///      predicate as `_release` — one shared derivation from `_observeIdle`, per the ReserveManager
///      MERGE NOTE's standing instruction not to re-inline the custody predicate. Cash may not
///      leave the reserve through EITHER door while the reserve can see it is short.
///
///      NOT A LATCH, and it consumes no capital: it clears the instant custody is restored or the
///      authenticated C-01 cascade (`reconcileIdleUSDC`) writes the ledger down to the live
///      balance. It is deliberately NOT applied to cash-IN paths (`depositUSDC`, `recordPayment`)
///      or to `recordFeeCapitalization`, which moves no USDC — see
///      `Fix_MA02-recognition-contamination.t.sol` for why halting incoming money would be the
///      opposite of a fix.
///
///      RED-PHASE PROVENANCE: every `test_MA1_*` assertion below was written and run against the
///      merged-but-unfixed build first. The door tests failed there — `recordDeployment` and
///      `WaterfallEngine.fund` both succeeded while the reserve was short and drained the live
///      balance to zero — and the access-control / not-a-latch tests passed unchanged.
contract Fix_MA01_CustodyDeploymentDoor is TokenLayerFixture {
    address internal sink = makeAddr("ma1-custody-sink");

    /// @dev A custody loss: USDC leaves the treasury with no ledger entry behind it. Deliberately
    ///      NOT a protocol path — the whole point is an out-of-band gap the ledger does not know
    ///      about but `balanceOf` does.
    function _drainCustody(uint256 units) internal {
        vm.prank(address(reserves));
        usdc.transfer(sink, units);
    }

    // ── 1. THE DOOR ──────────────────────────────────────────────────────

    /// @notice THE FINDING, minimally. The reserve is short 25 USDC; the credit door still opens.
    function test_MA1_recordDeploymentMustNotPushCashOutOfAKnownShortReserve() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        assertEq(reserves.idleCustodyShortfall(), 25e18, "precondition: the gap is recognised");

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 75e6)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 10e6);

        assertEq(usdc.balanceOf(borrower), 0, "MA-1: cash left a known-short reserve through the credit door");
        assertEq(reserves.deployedTo(1), 0, "MA-1: a deployment was booked against absent cash");
    }

    /// @notice THE ECONOMIC HARM, as a value assertion rather than a revert check. Every user exit
    ///         is frozen by R4-01, and the credit door then removes the last live dollar behind
    ///         them. Pre-fix the reserve ended this test holding ZERO USDC against 100e18 of USDfr.
    function test_MA1_theDoorEmptiesTheReserveWhileEveryUserExitIsFrozen() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);
        uint256 liveBefore = usdc.balanceOf(address(reserves));
        assertEq(liveBefore, 75e6);

        // The user door is shut (R4-01) ...
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 25e18, 75e18)
        );
        vm.prank(alice);
        controller.redeem(10e18);

        // ... so the credit door must be shut too, or the freeze protects nobody.
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 75e6)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, liveBefore);

        assertEq(usdc.balanceOf(address(reserves)), liveBefore, "MA-1: the last live dollar left through the door");
        assertEq(usdc.balanceOf(borrower), 0, "MA-1: a borrower received the frozen holders' cash");
        assertGt(usdc.balanceOf(address(reserves)), 0, "MA-1: nothing stands behind the frozen supply");
    }

    /// @notice BOTH out-doors, side by side, refusing with the SAME error from the SAME predicate.
    ///         This is the anti-divergence test: `grep -n safeTransfer src/ReserveManager.sol`
    ///         finds exactly two ways out, and a future third must be added to this list.
    function test_MA1_bothUSDCOutDoorsRefuseWithTheOneSharedPredicate() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(1); // one unit: no tolerance band on either door

        bytes memory expected =
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 100e6 - 1);

        vm.expectRevert(expected);
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 1e6);

        vm.expectRevert(expected);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 1e6);
    }

    /// @notice Boundary: ONE missing unit (1e-6 USDC) closes the credit door. There is no
    ///         tolerance band, for the same reason `_release` has none — deploying out of a
    ///         known-short pool is the harm and it is done on the FIRST dollar out, not the last.
    function test_MA1_oneMissingUnitClosesTheDeploymentDoor() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(1);

        assertEq(reserves.idleCustodyShortfall(), 1e12);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 100e6 - 1)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 1e6);
    }

    /// @notice A live SURPLUS is not a shortfall. An unsolicited donation must not close the credit
    ///         door (it is still not backing — the pre-existing donation rule is untouched).
    function test_MA1_aDonationSurplusDoesNotCloseTheDeploymentDoor() public {
        _mintUSDfr(alice, 100e6);
        usdc.mint(address(reserves), 40e6);

        assertEq(reserves.idleCustodyShortfall(), 0);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 10e6);
        assertEq(usdc.balanceOf(borrower), 10e6, "an over-custodied reserve must still deploy");
        assertEq(reserves.totalBackingValue(), 100e18, "a donation is still not backing");
    }

    // ── 2. IT IS NOT A LATCH ─────────────────────────────────────────────

    /// @notice Restoring custody reopens the credit door in the same block, with no role, no
    ///         keeper and no governance action. Anything else would let a token transfer brick
    ///         origination permanently.
    function test_MA1_restoringCustodyReopensTheDeploymentDoorWithNoGovernanceAction() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 75e6)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 10e6);

        usdc.mint(address(reserves), 25e6); // permissionless recapitalisation

        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 10e6);
        assertEq(usdc.balanceOf(borrower), 10e6, "restored custody must reopen the credit door");
        assertEq(reserves.deployedTo(1), 10e18);
    }

    /// @notice And the authenticated C-01 absorption cascade also reopens it, by writing the ledger
    ///         down to the live balance. The guard therefore never blocks the protocol's own way
    ///         out of the state it describes.
    function test_MA1_absorptionReopensTheDeploymentDoor() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        _drainCustody(25e6);
        _armReserveLoss(91);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(25e18);
        assertEq(actualLoss, 25e18, "the cascade must not be bricked by the new guard");
        assertEq(reserves.idleCustodyShortfall(), 0);

        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 10e6);
        assertEq(usdc.balanceOf(borrower), 10e6, "absorption must reopen the credit door");
    }

    // ── 3. THE GUARD MUST NOT MASK ANYTHING THAT RAN BEFORE IT ───────────

    /// @notice Access control still precedes the custody guard, so an unauthorised caller cannot
    ///         probe custody state through the difference in revert reason.
    function test_MA1_roleCheckStillPrecedesTheDeploymentDoorGuard() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, Roles.CREDIT_ROLE)
        );
        vm.prank(bob);
        reserves.recordDeployment(1, borrower, 1e6);
    }

    /// @notice Argument validation still precedes it too — the pre-existing errors are unchanged,
    ///         so no caller loses a precise diagnosis to the new guard.
    function test_MA1_argumentValidationStillPrecedesTheDeploymentDoorGuard() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        vm.expectRevert(IReserveManager.ReserveManager_ZeroAddress.selector);
        vm.prank(creditModule);
        reserves.recordDeployment(1, address(0), 1e6);

        vm.expectRevert(IReserveManager.ReserveManager_SelfDeployment.selector);
        vm.prank(creditModule);
        reserves.recordDeployment(1, address(reserves), 1e6);

        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 0);
    }

    // ── 4. FUZZED: NO LIVE CUSTODY EVER LEAVES A SHORT RESERVE ───────────

    /// @notice For ANY shortfall and ANY deployment size, the reserve's live USDC balance is
    ///         unchanged by the credit door while a shortfall stands.
    function testFuzz_MA1_noLiveCustodyLeavesThroughTheCreditDoorWhileShort(
        uint256 mintUnits,
        uint256 drainUnits,
        uint256 deployUnits
    ) public {
        mintUnits = bound(mintUnits, 2, 1_000_000e6);
        drainUnits = bound(drainUnits, 1, mintUnits); // at least one unit missing
        _mintUSDfr(alice, mintUnits);
        _drainCustody(drainUnits);

        uint256 liveBefore = usdc.balanceOf(address(reserves));
        deployUnits = bound(deployUnits, 1, mintUnits);

        vm.prank(creditModule);
        try reserves.recordDeployment(1, borrower, deployUnits) {
            revert("MA-1: the credit door opened on a known-short reserve");
        } catch (bytes memory err) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            assertEq(
                sel,
                IReserveManager.ReserveManager_IdleCustodyShortfall.selector,
                "MA-1: the credit door must fail with the protocol's custody error"
            );
        }
        assertEq(usdc.balanceOf(address(reserves)), liveBefore, "MA-1: live custody fell while the reserve was short");
        assertEq(reserves.deployedTo(1), 0);
    }
}

/// @title AUDIT FIX (MA-1) — the same door, reached through the production credit stack
/// @notice The reserve-level test above proves the guard; this proves the door is REACHABLE by a
///         real, correctly-roled actor through the shipped path, which is what makes it a finding
///         rather than a theoretical hole. `WaterfallEngine.fund` is `SERVICER_ROLE` and the engine
///         holds `CREDIT_ROLE` on the reserve, so funding an already-originated facility is exactly
///         the transaction that empties a frozen treasury.
contract Fix_MA01_CustodyDeploymentDoorThroughTheCreditStack is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    address internal sink = makeAddr("ma1-credit-sink");

    function _drainCustody(uint256 units) internal {
        vm.prank(address(reserves));
        usdc.transfer(sink, units);
    }

    /// @notice THE PRODUCTION-PATH REPRODUCTION. Liquidity is seeded, a facility is originated,
    ///         custody is then lost out of band, and the servicer funds anyway. Pre-fix the
    ///         borrower received 200,000 USDC out of a treasury that was already 50,000 short and
    ///         whose USDfr holders were frozen out by R4-01.
    function test_MA1_servicerCannotFundAFacilityOutOfAKnownShortTreasury() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 200_000e18);
        _drainCustody(50_000e6);

        assertEq(reserves.idleCustodyShortfall(), 50_000e18, "precondition: the gap is recognised");
        assertTrue(curator.custodyFreezeActive(), "precondition: R6-CF1 has frozen curator capital");

        uint256 liveBefore = usdc.balanceOf(address(reserves));
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 500_000e6, 450_000e6)
        );
        vm.prank(servicer);
        waterfall.fund(id, 200_000e6);

        assertEq(usdc.balanceOf(address(reserves)), liveBefore, "MA-1: funding drained a known-short treasury");
        assertEq(usdc.balanceOf(borrower), 0, "MA-1: the borrower received frozen holders' cash");
        assertEq(
            uint8(bridge.facility(id).state),
            uint8(ClaimBridge.LoanState.Pending),
            "MA-1: the facility went live against absent cash"
        );
    }

    /// @notice The freeze is coherent across all three layers in the same block: the USER exit
    ///         (R4-01), the CURATOR exit (R6-CF1) and now the CREDIT door (MA-1). Before this fix
    ///         two of the three were shut and the third was wide open, which is the merge defect.
    function test_MA1_allThreeExitsAreShutInTheSameBlock() public {
        _mintUSDfrTo(alice, 500_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 200_000e18);

        _drainCustody(50_000e6);

        // user
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 50_000e18, 550_000e18
            )
        );
        vm.prank(alice);
        controller.redeem(1e18);

        // curator
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 100_000e18);

        // credit
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 600_000e6, 550_000e6)
        );
        vm.prank(servicer);
        waterfall.fund(id, 200_000e6);
    }

    /// @notice And with custody whole, funding is completely unaffected: the guard costs the
    ///         ordinary origination path nothing.
    function test_MA1_fundingIsUntouchedWhenCustodyIsWhole() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 200_000e18);

        vm.prank(servicer);
        waterfall.fund(id, 200_000e6);

        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active));
        assertEq(reserves.deployedTo(id), 200_000e18);
    }
}
