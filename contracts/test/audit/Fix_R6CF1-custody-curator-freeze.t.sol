// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title AUDIT FIX R6-CF1 — curator first-loss capital may not exit ahead of a RESERVE-CUSTODY loss
/// @notice THE DEFECT (High; campaign 4, independently corroborated round 6).
///         `CuratorModule.withdrawFirstLoss` was blocked only by `unresolvedDefaults[classId]`,
///         and the ONLY writer of that counter is `DefaultManager.freezeOnDefault`, reached from
///         `declareDefault` and `liquidate` — both FACILITY paths. The reserve-CUSTODY loss path
///         (now `ReserveManager.armReserveLossFreeze` -> physical shortfall -> `ratifyAndOpen`
///         -> `DefaultManager.absorbReserveLoss` -> `CuratorModule.absorbGlobalLoss`) armed
///         nothing. A curator watching an adjudicated custody incident could therefore withdraw
///         every dollar of headroom before the write-down executed and hand the loss it is
///         CASCADE LAYER 1 for straight to the sGROVE backstop and senior depositors — precisely
///         the inversion R4-EC2 exists to prevent on the facility side, whose own comment reads
///         "otherwise a curator could front-run realizeLoss and pull excess first-loss ahead of
///         the loss".
///
///         MEASURED PRE-FIX (`Fix_R6CF1_PreFixRed.t.sol`, since replaced by this file): with
///         300,000e18 of first-loss posted and 100,000e18 of senior capital staked, the curator
///         withdrew the full 300,000e18 after the incident opened and the senior vault then
///         absorbed 40,000e18 of the custody write-down — a loss layer 1 was standing there to
///         take.
///
/// @dev Every test below pins one clause of the C-01 workstream's specification for the freeze:
///        - it must cover the ENTIRE recognition-to-absorption window;
///        - it releases only when absorption is complete, no deficit or live shortfall remains,
///          and `totalUSDfr() <= backingValue()`;
///        - a guardian may PRE-ARM but may NOT release;
///        - the pre-arm must outlast the full governance path, DERIVED from
///          `GOV_VOTING_DELAY + GOV_VOTING_PERIOD + TIMELOCK_MIN_DELAY` rather than hardcoded,
///          because all three are governance-mutable;
///        - re-arming is bounded so a guardian cannot freeze curator capital indefinitely.
contract Fix_R6CF1_CustodyCuratorFreeze is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    /// @dev First-loss posted into a class with ZERO live exposure, so the ADR-0004 subordination
    ///      headroom (`pool - min(target, exposure)`) is the FULL pool and the only thing that can
    ///      stop the withdrawal is a freeze.
    uint256 internal constant POSTED = 300_000e18;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _postFirstLoss(anchorCurator, FILM, POSTED);
        assertEq(curator.headroom(FILM), POSTED, "setup: full headroom expected (zero class exposure)");
        assertFalse(curator.custodyFreezeActive(), "setup: no custody loss in flight");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE DEFECT — reproduction
    // ─────────────────────────────────────────────────────────────────────

    /// @notice REPRODUCTION. Governance adjudicates and OPENS a custody incident; the curator
    ///         tries to leave before the write-down executes. Pre-fix this succeeded.
    function test_R6CF1_curatorCannotExitAfterIncidentRecognition() public {
        _openReserveLossIncident(41);
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        assertTrue(incidentId != 0, "custody incident must be open");
        assertEq(curator.unresolvedDefaults(FILM), 0, "no FACILITY default: the R4-EC2 gate is silent here");

        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, POSTED);

        assertEq(curator.poolBalance(FILM), POSTED, "layer 1 capital must still stand behind the open incident");
    }

    /// @notice THE ECONOMIC CONSEQUENCE, as a value assertion rather than a revert check: with the
    ///         freeze in force the custody write-down is absorbed by LAYER 1, exactly as
    ///         CLAUDE.md §1.3 orders it. Pre-fix the curator's exit left this to the senior vault.
    function test_R6CF1_layer1AbsorbsTheCustodyLossItCouldOtherwiseHaveDucked() public {
        uint256 loss = 40_000e18;
        _stakeSenior(100_000e18);
        uint256 seniorBefore = vault.totalAssets();

        _armReserveLoss(42);
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, loss);

        _applyCustodyLoss(42, loss);

        assertEq(curator.poolBalance(FILM), POSTED - loss, "layer 1 must absorb the whole custody loss");
        assertEq(vault.totalAssets(), seniorBefore, "senior principal must be untouched");
    }

    /// @notice The window OPENS BEFORE governance can act. A physical custody shortfall — USDC
    ///         gone from the treasury while `idleUSDCUnits` still records it — freezes curator
    ///         withdrawals permissionlessly, with no transaction from anyone.
    function test_R6CF1_liveCustodyShortfallFreezesBeforeAnyGovernanceAction() public {
        (,, uint256 shortfallBefore) = reserves.observeIdleUSDC();
        assertEq(shortfallBefore, 0, "precondition: no shortfall");

        // The custody event itself: tokens leave the treasury out of band.
        vm.prank(address(reserves));
        usdc.transfer(borrower, 10_000e6);

        (,, uint256 shortfallAfter) = reserves.observeIdleUSDC();
        assertGt(shortfallAfter, 0, "the loss is observable on-chain");
        assertTrue(curator.custodyFreezeActive(), "an observable custody shortfall must freeze layer 1");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @notice An under-backed protocol (`totalUSDfr() > backingValue()`) freezes layer 1 whatever
    ///         produced the gap — here the G3 conservative mark on deployed principal, which
    ///         lowers backing without burning supply. Curator capital is layer 1 for that too.
    function test_R6CF1_underBackingFreezesLayer1() public {
        uint256 tokenId = _liveFilmFacility(200_000e18);
        assertFalse(curator.custodyFreezeActive(), "precondition: fully backed");

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(tokenId, 50_000e18, keccak256("adjudication"));
        assertGt(controller.totalUSDfr(), controller.backingValue(), "protocol is now under-backed");
        assertTrue(curator.custodyFreezeActive(), "layer 1 must not exit an under-backed protocol");

        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);

        // ...and it releases once the mark is reversed, so this is a freeze and not a brick.
        vm.prank(admin);
        reserves.releasePrincipalImpairment(tokenId, 50_000e18, keccak256("recovered"));
        assertFalse(curator.custodyFreezeActive(), "a reversed mark must release the freeze");
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE FULL RECOGNITION-TO-ABSORPTION WINDOW, AND THE RELEASE PREDICATE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice C-01 clauses 1+2. Walk the whole lifecycle and assert the freeze at EVERY step:
    ///         open -> partial write-down -> full write-down -> close -> released. The freeze must
    ///         not lapse at any intermediate point, and must lift only once absorption is complete
    ///         with no deficit, no live shortfall and `totalUSDfr() <= backingValue()`.
    function test_R6CF1_freezeCoversTheEntireRecognitionToAbsorptionWindow() public {
        (uint256 armId,) = _armReserveLoss(43);
        assertTrue(curator.custodyFreezeActive(), "recognition arms the freeze");

        _applyCustodyLoss(43, 20_000e18);
        assertTrue(curator.custodyFreezeActive(), "a PARTIAL absorption must not release it");

        _applyCustodyLoss(43, 20_000e18);
        assertTrue(curator.custodyFreezeActive(), "the incident is still open: more may follow");

        (,, bytes32 evidenceHash,) = reserves.reserveLossArm();
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, evidenceHash);
        assertEq(reserves.reserveDeficit(), 0, "absorption completed with no residual deficit");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "backing restored");
        assertFalse(curator.custodyFreezeActive(), "and only THEN does layer 1 become free again");

        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @notice C-01 clause 2. A LATCHED residual deficit keeps the freeze on even after governance
    ///         closes the incident — closing is a declaration that the adjudication is finished,
    ///         not that the capital was found. This ordering is forced by the contract:
    ///         `resolveReserveDeficit` REQUIRES the incident to be closed first.
    function test_R6CF1_latchedDeficitHoldsTheFreezeAfterTheIncidentCloses() public {
        // A loss larger than every layer combined latches `reserveDeficit`: layer 1 holds 300k,
        // the backstop mock is unfunded and the vault is unstaked, so 100k has nowhere to go.
        _mintUSDfrTo(alice, 100_000e18);
        uint256 armId = _applyCustodyLoss(44, 400_000e18);
        assertEq(reserves.reserveDeficit(), 100_000e18, "a residual deficit must have latched");

        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        (uint256 stillActive,) = reserves.activeReserveLossIncident();
        assertEq(stillActive, 0, "the incident is closed");
        (uint256 stillArmed,,,) = reserves.reserveLossArm();
        assertEq(stillArmed, armId, "the canonical adjudication arm remains live");
        assertTrue(curator.custodyFreezeActive(), "the arm and residual still hold layer 1");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  GUARDIAN PRE-ARM — may arm, may NOT release, bounded re-arming
    // ─────────────────────────────────────────────────────────────────────

    /// @notice C-01 clause 3 (first half). A guardian who learns of a custody event before it is
    ///         visible on-chain — a custodian insolvency, a legal seizure, a frozen off-chain
    ///         balance — can arm the freeze immediately, without waiting out governance.
    function test_R6CF1_guardianMayPreArm() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        (uint64 expiry, uint32 count) = curator.custodyPreArm();
        assertEq(expiry, uint64(block.timestamp) + curator.custodyPreArmDuration(), "pre-arm expiry");
        assertEq(count, 1, "one arm used");
        assertTrue(curator.custodyFreezeActive(), "the guardian pre-arm freezes layer 1");

        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    function test_R6CF1_preArmIsGuardianOnly() public {
        vm.prank(anchorCurator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, anchorCurator, Roles.GUARDIAN_ROLE
            )
        );
        curator.preArmCustodyFreeze();
    }

    /// @notice C-01 clause 3 (second half) — THE LOAD-BEARING NEGATIVE. The guardian has no
    ///         release. Cancelling a pre-arm is governance-only, and even governance's cancel
    ///         cannot release a REAL custody freeze: the derived limbs stand on their own.
    function test_R6CF1_guardianMayNotRelease() public {
        _openReserveLossIncident(45);
        vm.prank(guardian);
        curator.preArmCustodyFreeze();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                guardian,
                bytes32(0) // DEFAULT_ADMIN_ROLE
            )
        );
        curator.cancelCustodyPreArm();

        // Governance may cancel the PRE-ARM limb; the incident limb still refuses the exit.
        vm.prank(admin);
        curator.cancelCustodyPreArm();
        assertTrue(curator.custodyFreezeActive(), "cancelling a pre-arm cannot release a real incident");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @notice C-01 clause 4. The pre-arm must outlast the FULL governance path, and that duration
    ///         must be DERIVED — a hardcoded literal silently becomes wrong the day governance
    ///         retunes any of the three parameters. Asserted here against the `Config` launch
    ///         parameters, which are the floor when no governor is wired.
    function test_R6CF1_preArmOutlastsTheDerivedGovernancePath() public view {
        assertGt(
            uint256(curator.custodyPreArmDuration()),
            _configGovernancePath(),
            "a pre-arm that expires inside the governance path cannot be ratified in time"
        );
    }

    /// @notice C-01 clause 4, dynamically: the derivation TRACKS a governance change to the
    ///         parameters instead of going stale. A live path longer than the launch constants
    ///         must lengthen the pre-arm.
    function test_R6CF1_preArmDurationTracksTheLiveGovernanceParameters() public {
        uint256 baseline = curator.custodyPreArmDuration();
        StubGovernor gov = new StubGovernor(15 days, 15 days, 15 days);
        vm.prank(admin);
        curator.setGovernor(address(gov));
        uint256 tracked = curator.custodyPreArmDuration();
        assertGt(tracked, baseline, "a longer live governance path must lengthen the pre-arm");
        assertGt(tracked, 45 days, "the pre-arm must exceed the LIVE 45-day governance path");
    }

    /// @notice The derivation is capped, so a hostile or fat-fingered governance parameter cannot
    ///         convert a guardian pre-arm into an unbounded lock on curator capital.
    function test_R6CF1_preArmDurationIsCapped() public {
        StubGovernor gov = new StubGovernor(type(uint256).max, type(uint256).max, type(uint256).max);
        vm.prank(admin);
        curator.setGovernor(address(gov));
        assertEq(curator.custodyPreArmDuration(), curator.CUSTODY_PRE_ARM_MAX_DURATION(), "capped, not overflowed");
    }

    /// @notice A governor on a BLOCK-NUMBER clock reports voting windows in units that are not
    ///         commensurable with `block.timestamp`. It must be ignored, leaving the Config floor,
    ///         rather than silently producing a nonsense duration.
    function test_R6CF1_blockClockGovernorIsIgnored() public {
        uint256 baseline = curator.custodyPreArmDuration();
        StubGovernor gov = new StubGovernor(15 days, 15 days, 15 days);
        gov.setClockMode("mode=blocknumber&from=default");
        vm.prank(admin);
        curator.setGovernor(address(gov));
        assertEq(curator.custodyPreArmDuration(), baseline, "an incommensurable clock must fall back to the floor");
    }

    /// @notice A governor that answers nothing must not brick the guardian's arm — the derivation
    ///         falls back to the Config floor and `preArmCustodyFreeze` still works.
    function test_R6CF1_unresponsiveGovernorDoesNotDisarmTheGuardian() public {
        uint256 baseline = curator.custodyPreArmDuration();
        vm.prank(admin);
        curator.setGovernor(address(usdc)); // real code, none of the three getters
        assertEq(curator.custodyPreArmDuration(), baseline, "fallback to the Config floor");
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        assertTrue(curator.custodyFreezeActive());
    }

    /// @notice C-01 clause 5. Re-arming is BOUNDED: after the budget is spent the guardian cannot
    ///         extend the freeze again, so guardian-only custody of curator capital is finite.
    function test_R6CF1_reArmingIsBounded() public {
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
        }
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_PreArmBudgetExhausted.selector, uint32(max + 1), max)
        );
        curator.preArmCustodyFreeze();
    }

    /// @notice C-01 clause 5, the liveness half. The guardian's budget is finite AND the freeze it
    ///         buys expires, so curator capital is never frozen indefinitely by the guardian alone.
    /// @dev COMMENT CORRECTED BY AUDIT FIX F3-PA-b. This test used to read "Only governance can
    ///      replenish the budget", and that was the DEFECT rather than the property:
    ///      `custodyPreArmCount` was a LIFETIME counter, so two arms anywhere in the protocol's
    ///      life spent the guardian's emergency lever permanently. The counter is now genuinely
    ///      CONSECUTIVE and resets once the episode has lapsed AND layer-1 has stood unfrozen for
    ///      `custodyPreArmCooldown()`. Every assertion below is UNCHANGED and still passes: within
    ///      the cooldown the budget really is exhausted, and governance really can restore it
    ///      immediately. What is new is that the guardian is not permanently disarmed — see
    ///      `Fix_F3PA-prearm-budget-trap.t.sol`.
    function test_R6CF1_guardianCannotFreezeIndefinitely() public {
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        uint64 duration = curator.custodyPreArmDuration();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
        }
        // Everything the guardian can buy, spent at once, still expires.
        vm.warp(block.timestamp + uint256(duration) + 1);
        assertFalse(curator.custodyFreezeActive(), "the guardian pre-arm must expire on its own");
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);

        // And it cannot be renewed without governance.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_PreArmBudgetExhausted.selector, uint32(max + 1), max)
        );
        curator.preArmCustodyFreeze();

        vm.prank(admin);
        curator.cancelCustodyPreArm();
        vm.prank(guardian);
        curator.preArmCustodyFreeze(); // budget replenished by governance only
        assertTrue(curator.custodyFreezeActive());
    }

    /// @notice A single pre-arm must be long enough to be RATIFIED: governance needs the full path
    ///         to open an incident, and the freeze must still be standing when it lands.
    function test_R6CF1_governanceCanRatifyBeforeThePreArmLapses() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        vm.warp(block.timestamp + _configGovernancePath());
        assertTrue(curator.custodyFreezeActive(), "the pre-arm must survive the whole governance path");
        _openReserveLossIncident(46);
        // Now the incident limb carries it, and the pre-arm may lapse harmlessly.
        vm.warp(block.timestamp + 365 days);
        assertTrue(curator.custodyFreezeActive(), "ratified: the incident holds the freeze");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  WIRING / FAIL-CLOSED
    // ─────────────────────────────────────────────────────────────────────

    function test_R6CF1_unwiredReserveFailsClosed() public {
        vm.prank(admin);
        curator.setReserveManager(address(0));
        assertTrue(curator.custodyFreezeActive(), "an unwired reserve must read as frozen, never as clear");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_ReserveNotWired.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    function test_R6CF1_setReserveManagerRejectsANonReserve() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_InvalidReserveManager.selector, address(registry))
        );
        curator.setReserveManager(address(registry));
    }

    function test_R6CF1_setReserveManagerIsGovernanceOnly() public {
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        curator.setReserveManager(address(reserves));
    }

    function test_R6CF1_setGovernorIsGovernanceOnly() public {
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        curator.setGovernor(address(0));
    }

    function test_R6CF1_setGovernorRejectsAnEOA() public {
        address eoa = makeAddr("notAContract");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_InvalidGovernor.selector, eoa));
        curator.setGovernor(eoa);
    }

    function test_R6CF1_cancelWithNothingArmedReverts() public {
        vm.prank(admin);
        vm.expectRevert(ICuratorModule.Curator_NoPreArm.selector);
        curator.cancelCustodyPreArm();
    }

    /// @notice POSTING first-loss stays open while frozen. The freeze exists to stop capital
    ///         LEAVING ahead of a loss; blocking a top-up would block recapitalisation exactly
    ///         when it is most wanted.
    function test_R6CF1_postingStaysOpenWhileFrozen() public {
        _openReserveLossIncident(47);
        _postFirstLoss(anchorCurator, FILM, 10_000e18);
        assertEq(curator.poolBalance(FILM), POSTED + 10_000e18, "a top-up must still land while frozen");
    }

    /// @notice The CASCADE is never blocked by the freeze. `absorbGlobalLoss` must still run while
    ///         `custodyFreezeActive()` is true — it is the whole point of freezing.
    function test_R6CF1_cascadeStillRunsWhileFrozen() public {
        _armReserveLoss(49);
        assertTrue(curator.custodyFreezeActive());
        _applyCustodyLoss(49, 25_000e18);
        assertEq(curator.poolBalance(FILM), POSTED - 25_000e18, "the freeze must not block absorption");
    }

    /// @notice The R4-EC2 FACILITY freeze and the R6-CF1 CUSTODY freeze are independent limbs:
    ///         neither substitutes for the other, and clearing one does not clear the other.
    function test_R6CF1_facilityFreezeAndCustodyFreezeAreIndependent() public {
        _openReserveLossIncident(48);
        assertEq(curator.unresolvedDefaults(FILM), 0, "no facility default");
        assertTrue(curator.custodyFreezeActive(), "custody limb is on");

        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        assertFalse(curator.custodyFreezeActive(), "custody limb cleared");

        // Arm the FACILITY limb only: the custody view must stay false and the withdrawal must
        // still be refused, by the OTHER error.
        vm.prank(address(defaultManager));
        curator.freezeOnDefault(FILM);
        assertFalse(curator.custodyFreezeActive(), "custody limb unaffected by a facility default");
        vm.prank(anchorCurator);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  helpers
    // ─────────────────────────────────────────────────────────────────────

    function _configGovernancePath() internal pure returns (uint256) {
        return uint256(Config.GOV_VOTING_DELAY) + uint256(Config.GOV_VOTING_PERIOD) + Config.TIMELOCK_MIN_DELAY;
    }

    function _applyCustodyLoss(uint256 context, uint256 loss) internal returns (uint256 armId) {
        (armId,,,) = reserves.reserveLossArm();
        if (armId == 0) (armId,) = _armReserveLoss(context);
        _createReserveShortfall(loss);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(loss);
        assertEq(actualLoss, loss, "fixture: ratification must use the canonical live loss");
    }

    function _stakeSenior(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }
}

/// @dev Minimal governor stand-in exposing exactly the three live parameters the pre-arm
///      derivation reads. Not a mock of governance behaviour — a source of parameters.
contract StubGovernor {
    uint256 public votingDelay;
    uint256 public votingPeriod;
    address public timelock;
    string internal clockMode = "mode=timestamp";

    constructor(uint256 delay_, uint256 period_, uint256 minDelay_) {
        votingDelay = delay_;
        votingPeriod = period_;
        timelock = address(new StubTimelock(minDelay_));
    }

    function CLOCK_MODE() external view returns (string memory) {
        return clockMode;
    }

    function setClockMode(string calldata mode) external {
        clockMode = mode;
    }
}

contract StubTimelock {
    uint256 public getMinDelay;

    constructor(uint256 minDelay_) {
        getMinDelay = minDelay_;
    }
}
