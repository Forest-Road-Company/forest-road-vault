// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @dev SWEEP-3 F1. A loss absorber with a PERMISSIVE FALLBACK: it passes
///      `ReserveManager.setLossAbsorber`'s only check (`reserveLossSource()`), and answers every
///      other selector with SUCCESS and EMPTY RETURNDATA. This is the exact shape
///      `CuratorModule._markedFirstLoss`'s NatSpec names as the whole reason it uses a raw
///      length-checked staticcall instead of `try`/`catch`:
///
///        "it is NOT `try`/`catch` for the reason `_liveGovernancePath` documents at length —
///         a permissive fallback answers with SUCCESS and EMPTY returndata, and Solidity's
///         `catch` does not catch the `abi.decode` failure that follows."
///
///      `SweepR2_Remediation.t.sol`'s `S2MuteCreditBook` has NO fallback, so it exercises only the
///      `!success` limb; its own comment asserts that "a permissive fallback answering with empty
///      returndata is covered by the same length check" WITHOUT driving it. Nothing else in the
///      tree wires a permissive-fallback absorber, which is why `data.length != 32` was deletable
///      with the whole non-fork suite green.
contract S3PermissiveCreditBook {
    address internal immutable RESERVE_SOURCE;

    constructor(address reserveSource) {
        RESERVE_SOURCE = reserveSource;
    }

    function reserveLossSource() external view returns (address) {
        return RESERVE_SOURCE;
    }

    /// @dev SUCCESS with EMPTY returndata for `declaredDefaultedPrincipal` / `pastDuePrincipal`.
    fallback() external {}
}

/// @title SWEEP-3 — guard vacuity across the FIX-R2 diff
contract SweepR3_GuardVacuityTest is GovernanceFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @notice ══════════ SWEEP-3 F1 — THE UNTESTED LIMB OF THE CSG-F1 FAIL-CLOSED READ ══════════
    ///         `CuratorModule._readClassPrincipal`'s `data.length != 32` disjunct is the ONLY thing
    ///         that distinguishes the shipped raw staticcall from a plain `try`/`catch`, and it is
    ///         the ONLY reason the NatSpec gives for not using one. Against a permissive-fallback
    ///         absorber the read must still fail CLOSED — sentinel out, pool locked, VIEWS STILL
    ///         ANSWERING — rather than propagating an `abi.decode` revert out through
    ///         `headroom()`, which `Validate.s.sol`, the dashboards and the invariant oracles read.
    ///
    /// @dev MUTATION (compiles; both operands still referenced; deny_warnings-safe):
    ///        `if (!success || (data.length != 32 && data.length != data.length)) return (false, 0);`
    ///      i.e. the length check neutralised, the revert check kept. MEASURED SWEEP-3: that
    ///      mutation is GREEN across the ENTIRE non-fork suite (1,629/1/3) and reds ONLY this test.
    ///      DO NOT DELETE OR WEAKEN THIS TEST.
    function test_S3_F1_aPermissiveFallbackAbsorberStillFailsClosedWithoutRevertingTheViews() public {
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 0);
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        assertEq(curator.headroom(FILM), 100_000e18, "precondition: with no mark the whole pool is free");

        S3PermissiveCreditBook permissive = new S3PermissiveCreditBook(address(reserves));
        vm.prank(admin);
        reserves.setLossAbsorber(address(permissive));

        // The distinguishing assertion: SUCCESS + EMPTY returndata, so `!success` is FALSE and only
        // the length check can catch it. Without it, `abi.decode` reverts and these two VIEWS
        // revert with it.
        assertEq(
            curator.requiredFirstLoss(FILM),
            type(uint128).max,
            "S3-F1: a permissive-fallback book must publish the lock sentinel, not revert the view"
        );
        assertEq(curator.headroom(FILM), 0, "S3-F1: a permissive-fallback book must lock the pool");

        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, uint256(1e18), uint256(0))
        );
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @notice CONTROL — attribution. The SAME fixture with a REVERTING (no-fallback) absorber is
    ///         the shape `SweepR2_Remediation`'s `S2MuteCreditBook` already covers, and it is
    ///         caught by the `!success` limb alone. Keeping it here proves a red above is
    ///         attributable to the LENGTH check and not to the fixture or to the sentinel.
    function test_S3_F1_control_aRevertingAbsorberIsCaughtByTheSuccessLimbAlone() public {
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 0);
        _postFirstLoss(anchorCurator, FILM, 100_000e18);

        S3NoFallbackCreditBook mute = new S3NoFallbackCreditBook(address(reserves));
        vm.prank(admin);
        reserves.setLossAbsorber(address(mute));

        assertEq(curator.requiredFirstLoss(FILM), type(uint128).max, "control: the revert limb still locks");
        assertEq(curator.headroom(FILM), 0, "control: the revert limb still locks the pool");
    }
}

/// @dev SWEEP-3 control. No fallback, so the raw staticcalls REVERT and `!success` catches them.
contract S3NoFallbackCreditBook {
    address internal immutable RESERVE_SOURCE;

    constructor(address reserveSource) {
        RESERVE_SOURCE = reserveSource;
    }

    function reserveLossSource() external view returns (address) {
        return RESERVE_SOURCE;
    }
}
