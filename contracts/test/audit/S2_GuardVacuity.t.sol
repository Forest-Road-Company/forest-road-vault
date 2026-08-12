// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {ISeniorExitDrawSource} from "../../src/interfaces/ISeniorExitDrawSource.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";
import {ADR0034Y_AtomicJuniorExitDraw, LyingExitDrawSource} from "./ADR0034Y_AtomicJuniorExitDraw.t.sol";

/// @dev SWEEP-2 falsifier for the `drawn > target` disjunct of
///      `MintRedeemController._drawJuniorForExit`. It moves MORE than it was asked for and
///      reports the movement HONESTLY, so `drawn == reported` and only the second disjunct can
///      refuse it. `LyingExitDrawSource` — the source the guard's own NatSpec names as its
///      falsifier — cannot produce this shape: its own comment records that "the balance does not
///      move here at all", so both of its modes are caught by `drawn != reported` alone.
contract OverDeliveringExitDrawSource is ISeniorExitDrawSource {
    IERC20 public immutable USDFR;
    address public immutable WHALE;
    address internal immutable RESERVE_SOURCE;
    uint256 public immutable EXTRA;

    constructor(IERC20 usdfr, address whale, address reserveSource, uint256 extra) {
        USDFR = usdfr;
        WHALE = whale;
        RESERVE_SOURCE = reserveSource;
        EXTRA = extra;
    }

    function reserveLossSource() external view returns (address) {
        return RESERVE_SOURCE;
    }

    function drawForSeniorExit(uint256 required) external returns (uint256) {
        uint256 delivered = required + EXTRA;
        require(USDFR.transferFrom(WHALE, address(this), delivered), "S2: pull failed");
        return delivered; // an HONEST report of an OVER-delivery
    }
}

/// @title SWEEP-2 — the `drawn > target` disjunct has no falsifier in the tree
///
/// @notice `ADR0034Y_AtomicJuniorExitDraw.t.sol`'s header states that "EVERY GUARD ADDED BY THIS
///         CHANGE HAS A NAMED FALSIFIER HERE", and `_drawJuniorForExit`'s NatSpec states that a
///         source that "over-reports, under-delivers, OR HANDS BACK MORE THAN ASKED can therefore
///         only cause a REVERT... Falsified by
///         `test_Y_G06_aLyingDrawSourceCanOnlyRevertTheExitNeverOverpayIt`."
///
///         `test_Y_G06` cannot reach the third case. `LyingExitDrawSource` never moves a token —
///         its own inline comment says so — so in BOTH of its modes the controller measures
///         `drawn == 0` and refuses on `drawn != reported`. The `|| drawn > target` disjunct is
///         therefore deletable with the whole non-fork suite green (MEASURED, SWEEP-2 M3).
contract S2_DrawnGreaterThanTargetHasNoFalsifier is ADR0034Y_AtomicJuniorExitDraw {
    /// @notice THE MISSING FALSIFIER. A source that delivers MORE junior capital than the exit
    ///         asked for, and says so, must still be refused — otherwise the controller burns
    ///         junior capital the exit never needed, which is ADR-0034 requirement 3 inverted
    ///         ("the draw brings absorption FORWARD in time, it does not ENLARGE it").
    /// @dev MUTATION: `if (drawn != reported || drawn > type(uint256).max)` in
    ///      `MintRedeemController._drawJuniorForExit` (compiles; `target` is still read on the
    ///      line above and on the revert path) -> RED here, and RED nowhere else in the tree.
    function test_S2_anOverDeliveringDrawSourceMustStillBeRefused() public {
        _recognise(MARK);
        OverDeliveringExitDrawSource src =
            new OverDeliveringExitDrawSource(IERC20(address(usdfr)), bob, address(reserves), 1e18);
        vm.prank(bob);
        usdfr.approve(address(src), type(uint256).max);
        vm.startPrank(admin);
        reserves.setLossAbsorber(address(src));
        controller.setLossSource(address(src), true);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_ExitDrawNotDelivered.selector);
        controller.redeem(EXIT, 0, block.timestamp);
    }

    /// @notice THE VACUITY ITSELF, MEASURED. The revert payload carries `(target, reported,
    ///         drawn)`, so the claim that `test_Y_G06` exercises the `drawn > target` limb is
    ///         checkable — and false. In BOTH of the named falsifier's modes `drawn` is ZERO.
    function test_S2_theNamedFalsifierNeverReachesTheOverDeliveryLimb() public {
        _recognise(MARK);
        for (uint8 mode = 0; mode < 2; ++mode) {
            uint256 snap = vm.snapshotState();
            LyingExitDrawSource liar = new LyingExitDrawSource(IERC20(address(usdfr)), mode);
            vm.startPrank(admin);
            reserves.setLossAbsorber(address(liar));
            controller.setLossSource(address(liar), true);
            vm.stopPrank();

            vm.prank(alice);
            try controller.redeem(EXIT, 0, block.timestamp) returns (uint256) {
                revert("S2: the lying source was accepted");
            } catch (bytes memory err) {
                bytes4 sel;
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    sel := mload(add(err, 0x20))
                }
                assertEq(
                    sel,
                    IMintRedeemController.Controller_ExitDrawNotDelivered.selector,
                    "S2: precondition - the exit must refuse on the draw guard"
                );
                (uint256 target, uint256 reported, uint256 drawn) = abi.decode(_body(err), (uint256, uint256, uint256));
                emit log_named_uint("mode", mode);
                emit log_named_uint("target", target);
                emit log_named_uint("reported", reported);
                emit log_named_uint("drawn", drawn);
                assertEq(drawn, 0, "S2: the named falsifier never moves a token");
                assertTrue(drawn != reported, "S2: the FIRST disjunct is what refuses it");
                assertLe(drawn, target, "S2: the `drawn > target` limb is NEVER reached by test_Y_G06");
            }
            vm.revertToState(snap);
        }
    }

    function _body(bytes memory err) private pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }
}

/// @title ADR-0035 re-point — standing-key chunks consume one physical reserve
contract S2_StandingExitKeySharedReserve is GovernanceFixture {
    uint256 internal constant EXIT_KEY = LossEventIds.CUSTODY_EVENT_NAMESPACE_START;

    /// @notice Chunking and one-shot realization have the same physical reserve bound.
    function test_S2_chunkingTheStandingKeyIsNoWorseThanOneDraw() public {
        _fundCoverage(100_000e18);
        uint256 drawn;
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(address(defaultManager));
            drawn += sGrove.coverShortfall(EXIT_KEY, 5_000e18);
        }
        assertEq(drawn, 100_000e18, "chunks did not consume exactly the shared reserve");
    }

    /// @notice The compatibility event view must expose live reach, never a frozen snapshot.
    function test_S2_theStandingKeyViewTracksTheFallingLiveReserve() public {
        _fundCoverage(100_000e18);
        for (uint256 i = 0; i < 6; ++i) {
            vm.prank(address(defaultManager));
            sGrove.coverShortfall(EXIT_KEY, 5_000e18);
            (uint256 drawn, uint256 cap) = sGrove.eventCoverage(EXIT_KEY);
            assertEq(cap - drawn, sGrove.coverageReserve(), "event view diverged from live reserve");
        }
        assertEq(sGrove.coverageReserve(), 70_000e18, "six chunks did not execute");
    }
}
