// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ReserveManager} from "../../src/ReserveManager.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IReserveLossAbsorber} from "../../src/interfaces/IReserveLossAbsorber.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

// ─────────────────────────────────────────────────────────────────────────
//  TEST DOUBLES — each one is shaped to reach EXACTLY ONE guard
// ─────────────────────────────────────────────────────────────────────────

/// @dev Reports a `reserveLossSource()` that is NOT the ReserveManager installing it. Models the
///      genuinely dangerous mis-wire: an absorber bound to a DIFFERENT reserve, which would let
///      that reserve's cascade be driven by this one's write-downs.
contract ForeignSourceAbsorber is IReserveLossAbsorber {
    address private immutable foreignSource;

    constructor(address foreignSource_) {
        foreignSource = foreignSource_;
    }

    function reserveLossSource() external view returns (address) {
        return foreignSource;
    }

    function absorbReserveLoss(uint256, uint256) external pure returns (ReserveLossAllocation memory allocation) {
        return allocation;
    }
}

/// @dev `reserveLossSource()` reverts, so `setLossAbsorber`'s try/catch arm is the only way the
///      call can be classified. A contract that merely lacks the function reaches the same arm.
contract RevertingSourceAbsorber is IReserveLossAbsorber {
    function reserveLossSource() external pure returns (address) {
        revert("source unavailable");
    }

    function absorbReserveLoss(uint256, uint256) external pure returns (ReserveLossAllocation memory allocation) {
        return allocation;
    }
}

/// @dev Has code but no `reserveLossSource()`/`modules()` at all: the dispatch itself reverts.
contract SelectorlessContract {
    uint256 public marker;
}

/// @dev Claims to have burned MORE supply than the backing that was actually lost — the shape
///      that would silently mint solvency out of a custody loss.
contract OverclaimingAbsorber is IReserveLossAbsorber {
    address private immutable reserves;

    constructor(address reserves_) {
        reserves = reserves_;
    }

    function reserveLossSource() external view returns (address) {
        return reserves;
    }

    function absorbReserveLoss(uint256, uint256 requiredSupplyReduction)
        external
        pure
        returns (ReserveLossAllocation memory allocation)
    {
        allocation.seniorBurned = requiredSupplyReduction + 1;
    }
}

/// @dev Returns an all-zero allocation while a real burn was required: neither burned nor
///      recorded the residual, so supply would stay above backing with nothing latched.
contract SilentAbsorber is IReserveLossAbsorber {
    address private immutable reserves;

    constructor(address reserves_) {
        reserves = reserves_;
    }

    function reserveLossSource() external view returns (address) {
        return reserves;
    }

    function absorbReserveLoss(uint256, uint256) external pure returns (ReserveLossAllocation memory allocation) {
        return allocation;
    }
}

/// @dev A loss controller that passes `setLossController`'s binding check but reports backing far
///      BELOW the reduction being applied. Only the four functions the cascade actually calls are
///      implemented; `setLossController` takes an address, so no interface inheritance is needed.
contract UnderReportingController {
    address private immutable reserves;
    address private immutable usdfr;

    constructor(address reserves_, address usdfr_) {
        reserves = reserves_;
        usdfr = usdfr_;
    }

    function modules() external view returns (address, address, address) {
        return (usdfr, address(0), reserves);
    }

    function totalUSDfr() external pure returns (uint256) {
        return 1e18;
    }

    function backingValue() external pure returns (uint256) {
        return 1e18;
    }

    function burnLoss(address, uint256) external {}
}

/// @dev `modules()` reverts, exercising `setLossController`'s try/catch arm.
contract RevertingModulesController {
    function modules() external pure returns (address, address, address) {
        revert("modules unavailable");
    }
}

/// @dev `modules()` binds to a DIFFERENT reserve than the one installing it.
contract ForeignBoundController {
    address private immutable foreignReserves;

    constructor(address foreignReserves_) {
        foreignReserves = foreignReserves_;
    }

    function modules() external view returns (address, address, address) {
        return (address(0), address(0), foreignReserves);
    }
}

/// @dev Minimal absorber bound to whatever reserve constructs it. Used only to get a BARE
///      ReserveManager past `setLossAbsorber` so the *controller* leg can be probed alone.
contract BoundNoopAbsorber is IReserveLossAbsorber {
    address private immutable reserves;

    constructor(address reserves_) {
        reserves = reserves_;
    }

    function reserveLossSource() external view returns (address) {
        return reserves;
    }

    function absorbReserveLoss(uint256, uint256) external pure returns (ReserveLossAllocation memory allocation) {
        return allocation;
    }
}

/// @title ReserveCascadeGuardCoverage — ReserveManager leg
/// @notice AUDIT FINDING (campaign 5, coverage gap). CLAUDE.md §1.2 binds this repository to
///         **100% line and branch coverage on all value-moving and accounting logic**, and names
///         "first-loss/backstop cascade" and "reserve/DSRA accounting" explicitly. The release
///         candidate measured 95.63% branch, and NINE of the custom errors that guard the
///         idle-reserve loss cascade appeared **zero times in the entire test tree**:
///
///           ReserveManager_InvalidLossAbsorber            ReserveManager_NoReserveDeficit
///           ReserveManager_InvalidLossController          ReserveManager_DeficitStillExists
///           ReserveManager_InvalidIncidentNonce           ReserveManager_LossAllocationMismatch
///           ReserveManager_LossAbsorberContractViolated   DefaultManager_ReserveLossCallerNotReserve
///                                                         DefaultManager_InvalidReserveLossIncident
///
///         Every existing cascade test drives the HAPPY path through a correctly wired
///         `MockReserveLossAbsorber`, so the wiring validation and the absorber-contract
///         post-checks — the guards that exist precisely because a mis-wired or lying absorber
///         would move real senior principal — were never entered. This suite enters each one and
///         asserts the SPECIFIC selector and arguments (CLAUDE.md §1.1), never bare `expectRevert`.
///
/// @dev DO NOT DELETE OR WEAKEN ANY ASSERTION HERE. Each test is the only execution of its
///      branch in the repository; deleting one silently restores a never-executed guard, which is
///      the finding itself. Each guard's own NatSpec in `ReserveManager.sol` / `DefaultManager.sol`
///      names the test that covers it.
contract ReserveCascadeGuardCoverageTest is TokenLayerFixture {
    function _deposit(address from, uint256 units) internal {
        vm.prank(from);
        usdc.approve(address(reserves), units);
        vm.prank(creditModule);
        reserves.depositUSDC(from, units);
    }

    /// @dev A second, deliberately UNWIRED ReserveManager: no loss absorber and no loss
    ///      controller. It is the only way to reach the two defensive zero-address checks inside
    ///      `_allocateReserveLoss`, because the shared fixture wires both in `setUp`.
    function _bareReserves() internal returns (ReserveManager bare) {
        bare = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(new ReserveManager()),
                    abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(usdc)))
                )
            )
        );
        vm.prank(admin);
        bare.grantRole(Roles.CREDIT_ROLE, address(this));
        usdc.mint(address(this), 100e6);
        usdc.approve(address(bare), 100e6);
        bare.depositUSDC(address(this), 100e6);
    }

    // ── setLossAbsorber: all three refusal arms ──────────────────────────

    function test_setLossAbsorber_rejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossAbsorber.selector, address(0)));
        vm.prank(admin);
        reserves.setLossAbsorber(address(0));
    }

    function test_setLossAbsorber_rejectsEOA() public {
        // An EOA has no code, so `reserveLossSource()` would succeed vacuously on a raw call.
        assertEq(bob.code.length, 0, "fixture actor must be an EOA for this branch to mean anything");
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossAbsorber.selector, bob));
        vm.prank(admin);
        reserves.setLossAbsorber(bob);
    }

    function test_setLossAbsorber_rejectsRevertingSourceProbe() public {
        RevertingSourceAbsorber reverter = new RevertingSourceAbsorber();
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossAbsorber.selector, address(reverter))
        );
        vm.prank(admin);
        reserves.setLossAbsorber(address(reverter));
    }

    function test_setLossAbsorber_rejectsContractWithoutTheSelector() public {
        SelectorlessContract stranger = new SelectorlessContract();
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossAbsorber.selector, address(stranger))
        );
        vm.prank(admin);
        reserves.setLossAbsorber(address(stranger));
    }

    function test_setLossAbsorber_rejectsAbsorberBoundToADifferentReserve() public {
        ForeignSourceAbsorber foreign = new ForeignSourceAbsorber(makeAddr("someOtherReserveManager"));
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossAbsorber.selector, address(foreign))
        );
        vm.prank(admin);
        reserves.setLossAbsorber(address(foreign));
        assertEq(
            reserves.lossAbsorber(), address(reserveLossAbsorber), "a refused wiring must not replace the live one"
        );
    }

    // ── setLossController: all three refusal arms ────────────────────────

    function test_setLossController_rejectsZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(0))
        );
        vm.prank(admin);
        reserves.setLossController(address(0));
    }

    function test_setLossController_rejectsEOA() public {
        assertEq(bob.code.length, 0, "fixture actor must be an EOA for this branch to mean anything");
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, bob));
        vm.prank(admin);
        reserves.setLossController(bob);
    }

    function test_setLossController_rejectsRevertingModulesProbe() public {
        RevertingModulesController reverter = new RevertingModulesController();
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(reverter))
        );
        vm.prank(admin);
        reserves.setLossController(address(reverter));
    }

    function test_setLossController_rejectsControllerBoundToADifferentReserve() public {
        ForeignBoundController foreign = new ForeignBoundController(makeAddr("someOtherReserveManager"));
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(foreign))
        );
        vm.prank(admin);
        reserves.setLossController(address(foreign));
        assertEq(reserves.lossController(), address(controller), "a refused wiring must not replace the live one");
    }

    // ── _allocateReserveLoss: the two defensive zero-address arms ────────

    function test_legacyWriteDownOnUnwiredReserveIsDisabledBeforeMovingAnyValue() public {
        ReserveManager bare = _bareReserves();
        vm.prank(admin);
        bare.openReserveLossIncident(21, keccak256("unwired-absorber"));

        vm.expectRevert(IReserveManager.ReserveManager_LegacyPathDisabled.selector);
        vm.prank(admin);
        bare.writeDownIdleUSDC(10e18);
        assertEq(bare.idleReserve(), 100e18, "a refused allocation must not lower recorded backing");
    }

    function test_legacyWriteDownWithAbsorberIsDisabledBeforeMovingAnyValue() public {
        ReserveManager bare = _bareReserves();
        BoundNoopAbsorber absorber = new BoundNoopAbsorber(address(bare));
        vm.prank(admin);
        bare.setLossAbsorber(address(absorber));
        vm.prank(admin);
        bare.openReserveLossIncident(22, keccak256("unwired-controller"));

        vm.expectRevert(IReserveManager.ReserveManager_LegacyPathDisabled.selector);
        vm.prank(admin);
        bare.writeDownIdleUSDC(10e18);
        assertEq(bare.idleReserve(), 100e18, "a refused allocation must not lower recorded backing");
    }

    // ── incident-namespace guard ─────────────────────────────────────────

    function test_openReserveLossIncident_rejectsNonceInsideTheCustodyNamespace() public {
        uint256 collidingNonce = LossEventIds.CUSTODY_EVENT_NAMESPACE_START;
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidIncidentNonce.selector, collidingNonce)
        );
        vm.prank(admin);
        reserves.openReserveLossIncident(collidingNonce, keccak256("namespace-collision"));

        // Boundary, off-by-one on the safe side: the largest nonce that is still admissible.
        vm.prank(admin);
        uint256 incidentId = reserves.openReserveLossIncident(collidingNonce - 1, keccak256("boundary"));
        assertGe(incidentId, LossEventIds.CUSTODY_EVENT_NAMESPACE_START, "custody ids stay in the upper namespace");
    }

    function test_openReserveLossIncident_rejectsMaxNonce() public {
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidIncidentNonce.selector, type(uint256).max)
        );
        vm.prank(admin);
        reserves.openReserveLossIncident(type(uint256).max, keccak256("max-nonce"));
    }

    // ── deficit-resolution guards ────────────────────────────────────────

    function test_resolveReserveDeficit_rejectsWhenNoDeficitWasEverRecorded() public {
        assertEq(reserves.reserveDeficit(), 0, "precondition: nothing latched");
        vm.expectRevert(IReserveManager.ReserveManager_NoReserveDeficit.selector);
        vm.prank(admin);
        reserves.resolveReserveDeficit(keccak256("nothing-to-resolve"));
    }

    function test_resolveReserveDeficit_rejectsWhileTheProtocolIsStillUnderBacked() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(23);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);
        assertEq(reserves.reserveDeficit(), 40e18, "precondition: a genuine deficit is latched");

        // NO recapitalisation happened. Clearing the latch here would restore
        // `backingInvariantHolds()` to true over a protocol that is still 40e18 short.
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_DeficitStillExists.selector, 40e18, 40e18)
        );
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("premature-resolution"));

        assertEq(reserves.reserveDeficit(), 40e18, "the latch survives a refused resolution");
        assertFalse(controller.backingInvariantHolds(), "and the protocol stays honestly frozen");
    }

    // ── absorber post-condition guards ───────────────────────────────────

    function test_curatorClaimingBurnWithoutTransferIsRefused() public {
        _mintUSDfr(alice, 100e6);
        reserveLossCurator.setReportMode(2);
        (uint256 armId,) = _armReserveLoss(24);
        _createReserveShortfall(10e18);
        (,, bytes32 evidenceHash,) = reserves.reserveLossArm();

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_LossAbsorberContractViolated.selector, 10e18, 0)
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 10e18);

        assertEq(reserves.idleReserve(), 100e18, "a refused allocation rolls the reserve back");
        assertEq(usdfr.totalSupply(), 100e18, "and moves no supply");
    }

    function test_curatorReportingNoAllocationAtAllIsRefused() public {
        _mintUSDfr(alice, 100e6);
        reserveLossCurator.setReportMode(1);
        (uint256 armId,) = _armReserveLoss(25);
        _createReserveShortfall(10e18);
        (,, bytes32 evidenceHash,) = reserves.reserveLossArm();

        // expectedSurplus 0, reported 0; expectedAccounted 10e18, reported 0.
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_LossAllocationMismatch.selector, uint256(0), uint256(0), 10e18, 0
            )
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 10e18);

        assertEq(reserves.idleReserve(), 100e18, "a refused allocation rolls the reserve back");
        assertEq(usdfr.totalSupply(), 100e18, "and moves no supply");
    }

    function test_reductionLargerThanReportedBackingIsRefusedBeforeTheCascadeRuns() public {
        _mintUSDfr(alice, 100e6);
        UnderReportingController thin = new UnderReportingController(address(reserves), address(usdfr));
        vm.prank(admin);
        reserves.setLossController(address(thin));
        (uint256 armId,) = _armReserveLoss(26);
        _createReserveShortfall(10e18);
        (,, bytes32 evidenceHash,) = reserves.reserveLossArm();

        // 10e18 of backing is being written down against a controller that reports only 1e18.
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_LossAllocationMismatch.selector, uint256(0), uint256(0), 10e18, 1e18
            )
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 10e18);
        assertEq(reserves.idleReserve(), 100e18, "a refused allocation rolls the reserve back");
    }

    /// @notice Documents the ONE reserve-cascade branch that is provably unreachable, so nobody
    ///         later "covers" it with a test that fakes the state.
    /// @dev `resolveReserveDeficit` re-checks `lossController != address(0)`. `reserveDeficit`
    ///      becomes non-zero ONLY in `_recordPostLossDeficit`, which runs after
    ///      `_allocateReserveLoss` has already required a non-zero controller; and
    ///      `setLossController` refuses `address(0)` outright (asserted above), so the pointer can
    ///      never be cleared once set. The branch is therefore dead defence-in-depth, not missing
    ///      coverage. This test asserts the two facts the proof rests on.
    function test_lossControllerCanNeverBeClearedOnceSet() public {
        assertTrue(reserves.lossController() != address(0), "fixture wires a controller");
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(0))
        );
        vm.prank(admin);
        reserves.setLossController(address(0));
        assertEq(reserves.lossController(), address(controller), "the pointer is unchanged");
    }
}

/// @title ReserveCascadeGuardCoverage — retained DefaultManager compatibility leg
/// @notice `DefaultManager.absorbReserveLoss` is retained-but-unreachable production ABI. The live
///         ReserveManager custody cascade is inline and has no caller in `src/` or `script/` for
///         this entry. These tests pin the retained ABI's hand-rolled caller and namespace guards;
///         they do not count as coverage of the shipped custody cascade. The retained entry also
///         emits no transition event while moving three capital layers.
///
/// @dev NOTE FOR THE NEXT AUDITOR — WHY THE EXHAUSTIVE ACL INVARIANT DID NOT CATCH THIS.
///      `test/invariant/AccessControlSurfaceInvariants.t.sol` enumerates the privileged surface at
///      runtime by scanning `src/` for the literal `onlyRole(` modifier. `absorbReserveLoss` is
///      guarded by an explicit `msg.sender` comparison instead, so it is INVISIBLE to that
///      enumeration and was in neither the deterministic nor the stateful tier. The stateful gap
///      is closed by the `probeReserveLossEntryGuards` action on `CascadeSeniorityHandler`.
contract DefaultManagerReserveLossGuardTest is CreditLayerFixture {
    uint256 internal constant FILM = 1;

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function test_absorbReserveLoss_refusesEveryCallerThatIsNotTheReserveManager() public {
        uint256 incidentId = _openReserveLossIncident(31);
        _postFirstLoss(anchorCurator, FILM, 10e18);
        _fundBackstop(10e18);
        _stakeVault(alice, 100e18);

        uint256 supplyBefore = usdfr.totalSupply();
        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 seniorBefore = vault.totalAssets();

        address[5] memory intruders = [address(this), admin, servicer, alice, address(controller)];
        for (uint256 i = 0; i < intruders.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, intruders[i]
                )
            );
            vm.prank(intruders[i]);
            defaultManager.absorbReserveLoss(incidentId, 5e18);
        }

        assertEq(usdfr.totalSupply(), supplyBefore, "no unauthorised call may burn supply");
        assertEq(curator.poolBalance(FILM), poolBefore, "no unauthorised call may touch first-loss");
        assertEq(vault.totalAssets(), seniorBefore, "no unauthorised call may touch senior principal");
    }

    /// @dev The AUTHORIZED half of the same guard (CLAUDE.md §1.1 requires both). Pranking the
    ///      ReserveManager address proves the refusal above is about the CALLER and not about some
    ///      other precondition that would have rejected all five intruders anyway.
    function test_absorbReserveLoss_admitsTheReserveManagerItself() public {
        uint256 incidentId = _openReserveLossIncident(32);
        _postFirstLoss(anchorCurator, FILM, 10e18);

        vm.prank(address(reserves));
        IReserveLossAbsorber.ReserveLossAllocation memory allocation =
            defaultManager.absorbReserveLoss(incidentId, 5e18);

        assertEq(allocation.curatorAbsorbed, 5e18, "the authorized caller is admitted and layer 1 pays");
        assertEq(curator.poolBalance(FILM), 5e18, "first-loss actually moved");
    }

    function test_absorbReserveLoss_refusesAFacilityNamespaceIncidentId() public {
        _postFirstLoss(anchorCurator, FILM, 10e18);

        // A facility token id lives in the LOWER namespace. Accepting one here would collapse
        // custody and facility accounting onto the same event identity.
        uint256[4] memory facilityIds = [uint256(0), 1, 7, LossEventIds.CUSTODY_EVENT_NAMESPACE_START - 1];
        for (uint256 i = 0; i < facilityIds.length; ++i) {
            assertTrue(LossEventIds.isFacilityEvent(facilityIds[i]), "probe must be a facility-namespace id");
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDefaultManager.DefaultManager_InvalidReserveLossIncident.selector, facilityIds[i]
                )
            );
            vm.prank(address(reserves));
            defaultManager.absorbReserveLoss(facilityIds[i], 5e18);
        }

        // Boundary, off-by-one on the admissible side.
        vm.prank(address(reserves));
        defaultManager.absorbReserveLoss(LossEventIds.CUSTODY_EVENT_NAMESPACE_START, 1e18);
        assertEq(curator.poolBalance(FILM), 9e18, "the first admissible id is accepted");
    }

    /// @dev ORDERING: the caller check must run BEFORE the namespace check, so an outsider learns
    ///      nothing about incident state and cannot use the namespace error as an oracle.
    function test_absorbReserveLoss_callerCheckPrecedesTheNamespaceCheck() public {
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, address(this))
        );
        defaultManager.absorbReserveLoss(1, 5e18); // BOTH guards would fire; the caller one must win
    }

    function test_reserveLossSourceReportsTheBoundReserveManager() public view {
        assertEq(
            defaultManager.reserveLossSource(),
            address(reserves),
            "the absorber must name the reserve whose calls it admits"
        );
    }
}
