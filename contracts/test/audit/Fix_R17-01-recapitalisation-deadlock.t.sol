// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ReserveManager} from "../../src/ReserveManager.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev A 6-decimal token that skims one unit off every transfer. Used to prove the exact-receipt
///      discipline on the recapitalisation path, exactly as `GuardBranches.t.sol` does for
///      `depositUSDC` and `recordPayment`. Declared locally so this file stands alone.
contract SkimmingUSDC is ERC20 {
    enum Mode {
        Normal,
        NoTransfer,
        ShortTransfer
    }

    Mode internal mode;

    constructor() ERC20("Skimming USDC", "sUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(Mode next) external {
        mode = next;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (mode == Mode.NoTransfer) return;
            if (mode == Mode.ShortTransfer) value -= 1;
        }
        super._update(from, to, value);
    }
}

/// @title AUDIT FIX (R17-01) — THE UNFUNDABLE PROTOCOL: A RECAPITALISATION DEADLOCK AND THE
///        AUTHORITY GAP UNDERNEATH IT
///
/// @notice THE FINDING. `ReserveManager.totalBackingValue()` is the RECORDED ledger, never the
///         live USDC balance, and only two call sites could raise `idleUSDCUnits`:
///
///           - `depositUSDC`, reached from `MintRedeemController.mint`, which issues USDfr 1:1 —
///             so supply and backing rise by the SAME amount, the gap is unchanged, and
///             `_assertBacking` still reverts. MINTING CANNOT CLOSE A DEFICIT, BY CONSTRUCTION.
///           - `recordPayment`, borrower repayments, which does raise backing without raising
///             supply — but it is reached through `WaterfallEngine.distribute`, whose closing
///             gate is `if (!controller.backingInvariantHolds()) revert Waterfall_BackingWouldBreak`.
///             So every repayment that does not cure the WHOLE shortfall in one transaction —
///             i.e. every partial recovery, the normal shape of a workout — is REFUSED precisely
///             while the shortfall exists.
///
///         And `reconcileIdleUSDC` computes `current = live < previous ? live : previous`, so it
///         can ONLY EVER LOWER the tally. Sending USDC to the contract therefore did NOTHING: the
///         balance rose, the ledger did not, backing did not, the freeze did not lift — and with
///         no sweep, the money was unrecoverable. `resolveReserveDeficit` clears a LATCH; it moves
///         no money and refuses to run while the deficit is still observable, so it cannot
///         bootstrap the repair either.
///
///         Once the cascade was exhausted and a residual deficit stood, NOTHING external repaired
///         it — not a donation, not a mint, not a repayment. Only a governance upgrade or a fresh
///         deployment.
///
/// @dev THE MERGED FIX. Two non-overlapping functions restore backing without creating supply:
///        - `recapitalize(amount)` — PERMISSIONLESS. Pulls new USDC from `msg.sender` and credits
///          exactly what arrived. Monotone, irreversible, confers nothing.
///        - `creditRecoveredIdleUSDC(armId,evidenceHash)` — `RESERVE_ADMIN_ROLE`. Credits physically
///          returned USDC only up to the loss previously recognized under that exact arm.
///      The first is fresh capital; the second is recovery of an adjudicated custody loss. The
///      merged contract deliberately has no free-standing pre-existing-surplus credit path.
///
///      SECTION 1 BELOW USES ONLY THE PRE-EXISTING API AND ASSERTS THE DEFECT. It passes against
///      the unfixed tree as well — that is its job. Sections 2 onward are the cure and its
///      boundaries, and go RED the moment either credit is removed.
contract Fix_R17_01_RecapitalisationDeadlock is TokenLayerFixture {
    address internal sink = makeAddr("r17-custody-sink");
    address internal rescuer = makeAddr("r17-rescuer");
    bytes32 internal constant EVIDENCE = keccak256("R17-01 unencumbered-surplus memorandum");

    function setUp() public virtual override {
        super.setUp();
        usdc.mint(rescuer, 1_000_000e6);
    }

    /// @dev Drives the protocol into the exact terminal state the finding describes:
    ///      supply 80e18, recorded backing 60e18, a LATCHED residual deficit of 20e18, the
    ///      incident still open, and live custody equal to the (already written-down) ledger so
    ///      the R4-01 live-shortfall path is NOT what is holding the protocol closed.
    function _latchResidualDeficit() internal returns (uint256 armId, uint256 incidentId) {
        _mintUSDfr(alice, 100e6); // supply 100e18, idle 100e6, backing 100e18
        vm.startPrank(alice);
        usdfr.approve(address(vault), 20e18);
        vault.deposit(20e18, alice); // only 20e18 of senior capital to absorb with
        vm.stopPrank();

        (armId, incidentId) = _armReserveLoss(17);
        _createReserveShortfall(40e18); // custody loss of 40e18, cascade capacity 20e18
        (uint256 ratifiedIncident, uint256 actualLoss) = _ratifyCurrentReserveLoss(40e18);
        assertEq(ratifiedIncident, incidentId, "the arm must bind the adjudicated incident");
        assertEq(actualLoss, 40e18, "the adjudication must use the live physical shortfall");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  1. THE DEADLOCK — pre-existing API only. These assert the DEFECT.
    // ═════════════════════════════════════════════════════════════════════

    function test_R17_01_theTerminalStateIsReachableAndClosesTheProtocol() public {
        _latchResidualDeficit();

        assertEq(controller.totalUSDfr(), 80e18, "senior absorbed everything it could");
        assertEq(reserves.totalBackingValue(), 60e18, "backing written down to live custody");
        assertEq(reserves.reserveDeficit(), 20e18, "the residual is latched");
        assertEq(reserves.idleCustodyShortfall(), 0, "ledger and custody agree; the hole is economic");
        assertFalse(controller.backingInvariantHolds(), "the protocol is honestly under-backed");
    }

    /// @notice DEFECT 1 — MINTING CANNOT CLOSE A DEFICIT. Issuance is 1:1, so supply and backing
    ///         move together and the gap survives every possible mint size.
    function test_R17_01_defect_mintingCanNeverCloseTheGap() public {
        _latchResidualDeficit();

        vm.startPrank(bob);
        usdc.approve(address(controller), 20e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, 80e18, 60e18)
        );
        controller.mint(20e6);
        vm.stopPrank();

        assertEq(reserves.reserveDeficit(), 20e18, "nothing changed");
    }

    /// @notice A direct transfer does not silently become backing. The recovery must be explicitly
    ///         attributed to the already-recognized arm, so unrelated surplus cannot reverse a loss.
    function test_R17_01_directTransferRequiresArmBoundRecoveryCredit() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.prank(rescuer);
        usdc.transfer(address(reserves), 20e6);

        assertEq(usdc.balanceOf(address(reserves)), 80e6, "the tokens really did arrive");
        assertEq(reserves.totalBackingValue(), 60e18, "R17-01: backing did not move");
        assertFalse(controller.backingInvariantHolds(), "R17-01: the freeze did not lift");

        assertEq(reserves.reconcileIdleUSDC(), 0, "observation reports no custody shortfall");
        assertEq(reserves.totalBackingValue(), 60e18, "still nothing");

        vm.prank(admin);
        assertEq(reserves.creditRecoveredIdleUSDC(armId, EVIDENCE), 20e18, "arm-bound recovery is credited");
        assertEq(reserves.totalBackingValue(), 80e18, "the attributed recovery restores backing");
    }

    /// @notice DEFECT 3 — `resolveReserveDeficit` MOVES NO MONEY. It refuses while the deficit is
    ///         observable, so it cannot bootstrap the repair; it can only ratify one.
    function test_R17_01_defect_resolveReserveDeficitCannotBootstrapTheRepair() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_DeficitStillExists.selector, 20e18, 20e18)
        );
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, EVIDENCE);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  2. THE CURE
    // ═════════════════════════════════════════════════════════════════════

    /// @notice THE HEADLINE PROPERTY, in Forest Road's words: funding the protocol increases
    ///         `idleUSDC`. Recorded backing rises by exactly X with NO new USDfr supply.
    function test_R17_01_recapitalisationRaisesRecordedBackingWithNoNewSupply() public {
        _latchResidualDeficit();
        uint256 supplyBefore = controller.totalUSDfr();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 20e6);
        uint256 credited = reserves.recapitalize(20e6);
        vm.stopPrank();

        assertEq(credited, 20e18, "credited value is the 18-decimal normalisation of what arrived");
        assertEq(reserves.idleUSDC(), 80e6, "the idle ledger rose by exactly the cash");
        assertEq(reserves.totalBackingValue(), 80e18, "recorded backing rose by exactly X");
        assertEq(controller.totalUSDfr(), supplyBefore, "R17-01: supply must not move");
        assertTrue(controller.backingInvariantHolds(), "the protocol is solvent again");
    }

    /// @notice Solvency can be restored permissionlessly, but only governance may consume the
    ///         adjudication interlock before normal operation resumes.
    function test_R17_01_recapitalisationReopensMintAndParRedemption() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 20e6);
        reserves.recapitalize(20e6);
        vm.stopPrank();

        assertTrue(reserves.custodyLossUnabsorbed(), "fresh capital must not consume the active arm");
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, EVIDENCE);
        assertFalse(reserves.custodyLossUnabsorbed(), "governance finalization releases the interlock");

        uint256 out = _mintUSDfr(bob, 10e6);
        assertEq(out, 10e18, "issuance reopened");

        vm.prank(alice);
        assertEq(controller.redeem(5e18), 5e6, "par redemption reopened");
    }

    /// @notice Returned USDC becomes backing only through the arm whose recognized loss created
    ///         the recovery capacity.
    function test_R17_01_strandedDirectTransfersCanBeCreditedByGovernance() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.prank(rescuer);
        usdc.transfer(address(reserves), 20e6); // the well-meaning operator's transfer
        assertEq(reserves.unrecordedUSDC(), 20e6, "the surplus is visible");

        vm.prank(admin);
        uint256 credited = reserves.creditRecoveredIdleUSDC(armId, EVIDENCE);

        assertEq(credited, 20e18);
        assertEq(reserves.unrecordedUSDC(), 0, "the surplus was consumed exactly");
        assertEq(reserves.totalBackingValue(), 80e18, "the stranded money is backing now");
        assertEq(reserves.idleCustodyShortfall(), 0, "and the ledger still never exceeds custody");
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice THE FULL WORKOUT, end to end: add fresh capital, attribute returned custody to the
    ///         active arm, then atomically finalize the cured adjudication.
    function test_R17_01_theWholeRecoveryPathCompletes() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 12e6);
        reserves.recapitalize(12e6);
        usdc.transfer(address(reserves), 8e6);
        vm.stopPrank();

        vm.prank(admin);
        reserves.creditRecoveredIdleUSDC(armId, EVIDENCE);
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, EVIDENCE);

        assertEq(reserves.reserveDeficit(), 0, "the latch is finally clearable");
        assertEq(reserves.totalBackingValue(), 80e18);
        assertFalse(reserves.custodyLossUnabsorbed(), "every limb of the curator freeze is clear");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  3. TRAP (e) — THE FUNDER ACQUIRES NOTHING
    // ═════════════════════════════════════════════════════════════════════

    /// @notice It must be IMPOSSIBLE to use this to mint yourself anything, claim shares, or
    ///         acquire any right. It is a gift to the backing pool.
    function test_R17_01_theFunderAcquiresNoClaimOfAnyKind() public {
        _latchResidualDeficit();
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 vaultSharesBefore = vault.totalSupply();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 20e6);
        reserves.recapitalize(20e6);
        vm.stopPrank();

        assertEq(usdfr.balanceOf(rescuer), 0, "no USDfr");
        assertEq(vault.balanceOf(rescuer), 0, "no sUSDfr shares");
        assertEq(usdc.balanceOf(rescuer), 1_000_000e6 - 20e6, "the cash is gone, permanently");
        assertEq(controller.totalUSDfr(), supplyBefore, "supply unchanged");
        assertEq(vault.totalSupply(), vaultSharesBefore, "share count unchanged");

        // There is no withdrawal path of any kind for the funder: no role, no receipt, no record
        // keyed to them. The only trace is the event.
        assertFalse(reserves.hasRole(Roles.RESERVE_ADMIN_ROLE, rescuer));
        assertFalse(reserves.hasRole(Roles.CONTROLLER_ROLE, rescuer));
        assertFalse(reserves.hasRole(Roles.CREDIT_ROLE, rescuer));
    }

    /// @notice The gift raises the value backing OTHER people's claims and nothing else — the
    ///         funder cannot even redeem it back out, because they hold no USDfr to redeem.
    function test_R17_01_theFunderCannotRedeemTheGiftBackOut() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 50e6);
        reserves.recapitalize(50e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, rescuer));
        controller.redeem(1e18);
        vm.stopPrank();

        // Even a KYC'd funder gets nothing: `redeem` burns USDfr they do not have.
        vm.startPrank(bob);
        usdc.approve(address(reserves), 10e6);
        reserves.recapitalize(10e6);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(bob), 0, "recapitalising is not minting");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  4. TRAP (d) — EXACT RECEIPT
    // ═════════════════════════════════════════════════════════════════════

    function _skimmingReserve() internal returns (SkimmingUSDC token, ReserveManager manager) {
        token = new SkimmingUSDC();
        manager = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(new ReserveManager()),
                    abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(token)))
                )
            )
        );
    }

    /// @notice Mirrors `depositUSDC`'s discipline: measure what actually arrived and revert on a
    ///         mismatch. Without this a fee-on-transfer or silently-failing token would let the
    ///         ledger claim dollars the contract does not hold — R4-01's shortfall, manufactured.
    function test_R17_01_recapCreditsOnlyWhatActuallyArrived() public {
        (SkimmingUSDC token, ReserveManager manager) = _skimmingReserve();
        token.mint(rescuer, 10e6);
        vm.prank(rescuer);
        token.approve(address(manager), type(uint256).max);

        token.setMode(SkimmingUSDC.Mode.NoTransfer);
        vm.prank(rescuer);
        vm.expectRevert(IReserveManager.ReserveManager_NoValueReceived.selector);
        manager.recapitalize(2e6);

        token.setMode(SkimmingUSDC.Mode.ShortTransfer);
        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_UnexpectedUSDCReceipt.selector, 2e6, 2e6 - 1)
        );
        manager.recapitalize(2e6);

        assertEq(manager.idleUSDC(), 0, "nothing was credited on either failure");

        token.setMode(SkimmingUSDC.Mode.Normal);
        vm.prank(rescuer);
        assertEq(manager.recapitalize(2e6), 2e18);
        assertEq(manager.idleUSDC(), 2e6);
    }

    function test_R17_01_recapRejectsZero() public {
        vm.prank(rescuer);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.recapitalize(0);
    }

    /// @notice The units-to-value identity, fuzzed: recorded backing rises by exactly
    ///         `amount * 1e12` and supply never moves, at any size.
    function testFuzz_R17_01_recapIsExactAtEveryScale(uint256 seedUnits, uint256 giftUnits) public {
        seedUnits = bound(seedUnits, 1, 500_000e6);
        giftUnits = bound(giftUnits, 1, 500_000e6);
        _mintUSDfr(alice, seedUnits);

        uint256 backingBefore = reserves.totalBackingValue();
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 shortfallBefore = reserves.idleCustodyShortfall();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), giftUnits);
        assertEq(reserves.recapitalize(giftUnits), giftUnits * 1e12);
        vm.stopPrank();

        assertEq(reserves.totalBackingValue(), backingBefore + giftUnits * 1e12, "backing rose by exactly X");
        assertEq(controller.totalUSDfr(), supplyBefore, "supply never moves");
        assertEq(reserves.idleCustodyShortfall(), shortfallBefore, "a gift can never create a custody hole");
        assertLe(reserves.idleUSDC(), usdc.balanceOf(address(reserves)), "ledger never exceeds custody");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  5. TRAP (b) — THE LATCHES ARE NOT TOUCHED
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Recapitalisation restores backing ARITHMETICALLY and must not silently desynchronise
    ///         the recognised-loss latches. A gift is not an adjudication.
    function test_R17_01_recapitalisationClearsNoLatch() public {
        (, uint256 incidentId) = _latchResidualDeficit();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 40e6);
        reserves.recapitalize(40e6); // MORE than the deficit: over-fund it
        vm.stopPrank();

        (uint256 activeId,) = reserves.activeReserveLossIncident();
        assertEq(activeId, incidentId, "the incident latch stands");
        assertEq(reserves.reserveDeficit(), 20e18, "the deficit latch stands");
        assertTrue(reserves.custodyLossUnabsorbed(), "curator first-loss stays frozen on limbs 1 and 2");
        assertTrue(controller.backingInvariantHolds(), "even though backing is fully restored");
    }

    /// @notice Governance finalization remains necessary and access-controlled after a gift.
    function test_R17_01_onlyGovernanceCanClearTheLatchAfterAGift() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 20e6);
        reserves.recapitalize(20e6);
        vm.stopPrank();

        // And no unauthorised party can clear it either, gift or no gift.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rescuer, bytes32(0))
        );
        vm.prank(rescuer);
        reserves.finalizeAndDisable(armId, EVIDENCE);

        vm.prank(admin);
        reserves.finalizeAndDisable(armId, EVIDENCE);
        assertEq(reserves.reserveDeficit(), 0);
    }

    /// @notice A gift cannot release the arm while a later physical shortfall remains live.
    function test_R17_01_aGiftCannotDesynchroniseTheCascadeFromTheLatch() public {
        (uint256 armId,) = _latchResidualDeficit();

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 20e6);
        reserves.recapitalize(20e6);
        vm.stopPrank();

        // A further custody loss leaves the existing adjudication fail-closed.
        vm.prank(address(reserves));
        usdc.transfer(sink, 5e6);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_LiveShortfallExists.selector, 5e6));
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, EVIDENCE);
    }

    /// @notice A gift does not release a G3 conservative mark either. Marks come off through
    ///         `releasePrincipalImpairment` (adjudication) or by the marked face being repaid.
    function test_R17_01_recapitalisationDoesNotReleaseAG3Mark() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 100e6);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(1, 40e18, EVIDENCE);
        assertEq(reserves.totalBackingValue(), 60e18);

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 40e6);
        reserves.recapitalize(40e6);
        vm.stopPrank();

        assertEq(reserves.totalPrincipalImpairment(), 40e18, "the mark is untouched");
        assertEq(reserves.principalImpairmentOf(1), 40e18);
        assertEq(reserves.totalBackingValue(), 100e18, "backing repaired by fresh capital, not by unmarking");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  6. TRAP (c) — CASCADE INTERACTION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice THE ANSWER, TESTED. If a custody loss is recognised and someone recapitalises the
    ///         full amount BEFORE absorption, the junior layers are never drawn: the write-down
    ///         lands entirely on `surplusAbsorbed`. That is CORRECT — the loss was made whole, and
    ///         the junior layers exist to protect seniors from a hole that no longer exists.
    ///
    ///         IT IS NOT A FIRST-LOSS DODGE, and the reason is the next test: the gift does not
    ///         clear limb 1 or limb 2 of `custodyLossUnabsorbed()`, so cascade layer-1 capital
    ///         still cannot LEAVE until governance closes and resolves. A curator may make the
    ///         pool whole with fresh dollars instead of escrowed ones — the same dollars either
    ///         way — but it cannot walk out on the strength of having done so.
    function test_R17_01_recapBeforeAbsorptionMakesTheLossFallOnSurplusNotOnJuniors() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 60e18);
        vault.deposit(60e18, alice); // 60e18 of senior capital that COULD have been burned
        vm.stopPrank();

        _armReserveLoss(18);
        _createReserveShortfall(40e18); // a 40e18 custody loss

        // The rescuer makes the pool whole before absorption runs.
        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 40e6);
        reserves.recapitalize(40e6);
        vm.stopPrank();

        uint256 vaultAssetsBefore = vault.totalAssets();
        _ratifyCurrentReserveLoss(40e18);

        assertEq(controller.totalUSDfr(), 100e18, "no supply was burned");
        assertEq(vault.totalAssets(), vaultAssetsBefore, "senior capital was never drawn");
        assertEq(reserves.reserveDeficit(), 0, "no residual: the loss was fully absorbed by surplus");
        assertEq(reserves.idleCustodyShortfall(), 0, "the ledger is back in line with custody");
        assertEq(reserves.totalBackingValue(), 100e18, "backing intact");
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice The other half of the answer: a gift is NOT a release. Layer 1 stays frozen.
    function test_R17_01_recapDoesNotReleaseCascadeLayerOne() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(19);

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 500e6);
        reserves.recapitalize(500e6); // wildly over-fund
        vm.stopPrank();

        assertTrue(reserves.custodyLossUnabsorbed(), "an open incident still freezes layer 1");

        vm.prank(admin);
        reserves.cancelAndDisable(armId, EVIDENCE);
        assertFalse(reserves.custodyLossUnabsorbed(), "and only governance consuming the arm releases");
    }

    /// @notice A PARTIAL gift leaves the junior/senior layers to absorb exactly the uncovered
    ///         part — the surplus is consumed first, then the cascade, in that order.
    function test_R17_01_aPartialGiftOnlyShrinksWhatTheCascadeMustAbsorb() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 60e18);
        vault.deposit(60e18, alice);
        vm.stopPrank();

        _armReserveLoss(20);
        _createReserveShortfall(40e18); // 40e18 loss

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 15e6);
        reserves.recapitalize(15e6); // covers 15e18 of it
        vm.stopPrank();

        _ratifyCurrentReserveLoss(40e18);

        assertEq(controller.totalUSDfr(), 75e18, "the cascade burned exactly the uncovered 25e18");
        assertEq(reserves.reserveDeficit(), 0, "senior capacity covered the remainder");
        assertEq(reserves.totalBackingValue(), 75e18);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  7. THE SWEEP — ACCESS CONTROL AND THE CEILING
    // ═════════════════════════════════════════════════════════════════════

    /// @notice WHY RECOVERY CREDIT IS AUTHENTICATED WHILE `recapitalize` IS NOT. The former changes
    ///         the treatment of a pre-existing balance; the latter can credit only cash received
    ///         during its own call.
    function test_R17_01_anUnauthorisedCallerCannotSweepAWrittenDownSurplus() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(21);
        _createReserveShortfall(40e18);
        _ratifyCurrentReserveLoss(40e18);

        vm.prank(rescuer);
        usdc.transfer(address(reserves), 40e6);
        assertEq(reserves.unrecordedUSDC(), 40e6, "physically returned custody is visible");

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ReserveLossCallerNotAdmin.selector, rescuer)
        );
        vm.prank(rescuer);
        reserves.creditRecoveredIdleUSDC(armId, EVIDENCE);

        assertEq(reserves.totalBackingValue(), 60e18, "the recognised loss stands");
    }

    /// @notice And `recapitalize`, which IS permissionless, cannot reverse that write-down either
    ///         — it credits only cash that arrived inside its own call. This is the property that
    ///         makes the asymmetric access control safe.
    function test_R17_01_recapCannotReverseAGovernanceWriteDown() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(22);
        _createReserveShortfall(40e18);
        _ratifyCurrentReserveLoss(40e18);
        assertEq(reserves.totalBackingValue(), 60e18);

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 5e6);
        reserves.recapitalize(5e6);
        vm.stopPrank();

        assertEq(reserves.totalBackingValue(), 65e18, "up by the NEW cash only, not by the recognized 40e18");
        assertEq(reserves.unrecordedUSDC(), 0, "recapitalisation cannot manufacture recovery surplus");
        assertEq(reserves.reserveLossRecoveryCapacity(armId), 40e6, "the arm's recovery ceiling is unchanged");
    }

    /// @notice THE TWO-DIMENSIONAL CEILING. Credit is bounded by both observed surplus and the
    ///         amount previously written down under this exact arm.
    function test_R17_01_creditIsHardBoundedByTheObservedSurplus() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(24);
        _createReserveShortfall(10e18);
        _ratifyCurrentReserveLoss(10e18);

        // Recovery capacity without physical returned custody is insufficient.
        assertEq(reserves.unrecordedUSDC(), 0);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, armId));
        vm.prank(admin);
        reserves.creditRecoveredIdleUSDC(armId, EVIDENCE);

        // A 30e6 surplus can credit only the arm's 10e6 recognized-loss capacity.
        vm.prank(rescuer);
        usdc.transfer(address(reserves), 30e6);
        vm.prank(admin);
        assertEq(reserves.creditRecoveredIdleUSDC(armId, EVIDENCE), 10e18);
        assertEq(reserves.unrecordedUSDC(), 20e6, "surplus beyond the adjudicated loss remains uncredited");
        assertLe(reserves.idleUSDC(), usdc.balanceOf(address(reserves)), "ledger never exceeds custody");
        assertEq(reserves.idleCustodyShortfall(), 0);
    }

    function test_R17_01_recoveryCreditRequiresAnArmWithCapacity() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(rescuer);
        usdc.transfer(address(reserves), 10e6);

        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, 0));
        vm.prank(admin);
        reserves.creditRecoveredIdleUSDC(0, EVIDENCE);
    }

    /// @notice Recovery capacity makes partial credit expressible without a caller-selected amount;
    ///         surplus beyond that capacity remains visible rather than being silently swept.
    function test_R17_01_creditCanBePartialAndTheResidueStaysVisible() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(25);
        _createReserveShortfall(10e18);
        _ratifyCurrentReserveLoss(10e18);
        vm.prank(rescuer);
        usdc.transfer(address(reserves), 30e6);

        vm.prank(admin);
        assertEq(reserves.creditRecoveredIdleUSDC(armId, EVIDENCE), 10e18);
        assertEq(reserves.unrecordedUSDC(), 20e6, "the rest is still uncredited and still visible");
        assertEq(reserves.totalBackingValue(), 100e18);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  8. THE R4-01 SEAM — a gift must not paper over a LIVE custody shortfall
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Recorded and live rise by the SAME units, so `idleCustodyShortfall()` is unchanged.
    ///         That is deliberate and must stay: if custodied USDC was stolen, the ledger is still
    ///         overstated, and the honest repairs are (a) restoring the tokens by plain transfer,
    ///         which already works permissionlessly because R4-01's predicate reads the live
    ///         balance, or (b) governance writing the ledger down. A `recapitalize` that "helpfully"
    ///         netted the shortfall would be R4-01 reopened through a new door.
    function test_R17_01_recapDoesNotPaperOverALiveCustodyShortfall() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(address(reserves));
        usdc.transfer(sink, 40e6);
        assertEq(reserves.idleCustodyShortfall(), 40e18);

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 40e6);
        reserves.recapitalize(40e6);
        vm.stopPrank();

        assertEq(reserves.idleCustodyShortfall(), 40e18, "R4-01's gap is NOT closed by a gift");
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 40e18, 100e18)
        );
        vm.prank(alice);
        controller.redeem(1e18);

        // The documented repair: a plain transfer restores custody, permissionlessly (R4-01).
        vm.prank(rescuer);
        usdc.transfer(address(reserves), 40e6);
        assertEq(reserves.idleCustodyShortfall(), 0);
        vm.prank(alice);
        assertEq(controller.redeem(1e18), 1e6);
    }

    /// @notice The mirror-image identity: `unrecordedUSDC()` and `idleCustodyShortfall()` are the
    ///         two sides of one comparison and can never both be nonzero.
    function testFuzz_R17_01_surplusAndShortfallAreMutuallyExclusive(uint256 giftUnits, uint256 drainUnits) public {
        _mintUSDfr(alice, 100e6);
        giftUnits = bound(giftUnits, 0, 100e6);
        drainUnits = bound(drainUnits, 0, 100e6);
        if (drainUnits != 0) {
            vm.prank(address(reserves));
            usdc.transfer(sink, drainUnits);
        }
        if (giftUnits != 0) {
            vm.startPrank(rescuer);
            usdc.approve(address(reserves), giftUnits);
            reserves.recapitalize(giftUnits);
            vm.stopPrank();
        }
        assertTrue(
            reserves.unrecordedUSDC() == 0 || reserves.idleCustodyShortfall() == 0,
            "surplus and shortfall are two sides of one comparison"
        );
    }
}

/// @title AUDIT FIX (R17-01) — the parts that need the full credit stack: the WaterfallEngine
///        repayment gate that made the deadlock terminal, the D7-01 epoch-budget surface, and the
///        curator first-loss freeze.
contract Fix_R17_01_RecapitalisationDeadlockCreditLayer is CreditLayerFixture {
    address internal rescuer = makeAddr("r17-credit-rescuer");
    bytes32 internal constant EVIDENCE = keccak256("R17-01 credit-layer memorandum");

    function setUp() public virtual override {
        super.setUp();
        usdc.mint(rescuer, 5_000_000e6);
    }

    // ── THE DEADLOCK'S SHARPEST EDGE: PARTIAL REPAYMENTS MUST BE ACCEPTED ─

    /// @notice ═══ INVERTED (R18 HAND-MERGE) — DO NOT RESTORE THE OLD ASSERTION ═══
    ///         The predecessor, `test_R17_01_partialRepaymentsAreRefusedUntilSomeoneFundsTheGap`,
    ///         ASSERTED THE DEADLOCK: that a partial repayment MUST be refused until an unrelated
    ///         party recapitalised the protocol. That is the defect this whole campaign exists to
    ///         remove, written down as though it were a safety property — the single most
    ///         dangerous kind of test, because it makes fixing the bug look like a regression.
    ///         Round-4 TASK 2 removed the deadlock; this test now pins the cure.
    ///
    ///         WHY REFUSING WAS NEVER SAFE: `distribute` is cash-IN. `ReserveManager.recordPayment`
    ///         pulls the borrower's USDC and verifies receipt by balance delta, so the operation
    ///         can only RAISE backing. Refusing it left a G3-marked facility permanently
    ///         unrepayable while the only cure for the mark — borrower cash — was the very thing
    ///         being refused. The closing gate is now NON-WORSENING, so a receipt that repairs
    ///         part of the gap is accepted and the residual stays honestly visible
    ///         (`backingInvariantHolds()` remains FALSE below).
    ///
    /// @dev    THIS TEST HAS TEETH — VERIFIED BY MUTATION, NOT ASSUMED (RC3 fixer, 2026-08-08).
    ///         Restoring round 3's absolute gate in `WaterfallEngine.distribute` makes this RED
    ///         with `Waterfall_BackingWouldBreak(1)`. The mutation compiled cleanly
    ///         ("Compiler run successful!"), so the RED is behavioural, not a build failure.
    function test_R17_01_partialRepaymentsRepairTheGapWithoutRecapitalisation() public {
        uint256 id = _liveFilmFacility(100_000e18);
        uint256 supply = controller.totalUSDfr();
        assertEq(reserves.totalBackingValue(), supply, "baseline: exactly backed");
        assertTrue(controller.backingInvariantHolds());

        // Governance marks 10,000 of the face unrecoverable (G3): backing falls 10,000 below supply.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 10_000e18, EVIDENCE);
        assertEq(reserves.totalBackingValue(), supply - 10_000e18);
        assertFalse(controller.backingInvariantHolds());

        // A 5,000 partial recovery is ACCEPTED. The cash-in operation must not be rolled back.
        //
        // ═══ ASSERTIONS NARROWED (SWEEP-1 RMDM-F2, 2026-08-08) — READ BEFORE RESTORING ═══
        // These lines used to require the recovery to RAISE backing by exactly 5,000 and shrink
        // the deficit to 5,000. That was an artefact of the OPTIMISTIC mark consumption in
        // `ReserveManager.recordPayment`, which released `min(principal, recognized)` of an
        // evidenced governance mark on every ordinary payment — so ordinary amortisation ground
        // an adjudicated mark away with no evidence and overstated `totalBackingValue()`.
        // Backing is now FLAT across the collection: the cash moves from receivable into idle and
        // the mark on the remaining face is unchanged.
        //
        // THE R17-01 PROPERTY IS UNTOUCHED, AND IT IS THE ONE THAT MATTERS. `distribute`'s closing
        // gate is NON-WORSENING, and a flat delta is non-worsening, so the payment still settles.
        // The deadlock this campaign removed stays removed. IF THIS TEST EVER REVERTS INSTEAD OF
        // SETTLING, the SWEEP-1 change has reinstated the deadlock and must be reverted, not
        // patched around.
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, 5_000e18);
        uint256 deployedBefore = reserves.deployedTo(id);
        uint256 idleBefore = reserves.idleReserve();
        vm.prank(servicer);
        waterfall.distribute(payment);
        assertEq(reserves.deployedTo(id), deployedBefore - 5_000e18, "the partial recovery did not settle");
        assertEq(reserves.idleReserve(), idleBefore + 5_000e18, "the recovered cash did not reach idle");
        assertEq(reserves.totalBackingValue(), supply - 10_000e18, "SWEEP-1: the collection moved reported backing");
        assertEq(controller.recognizedDeficit(), 10_000e18, "the honest deficit is the standing mark, unchanged");
        assertFalse(controller.backingInvariantHolds(), "a partial repair must not claim the protocol is whole");
    }

    // ── TRAP (a): THE D7-01 EPOCH-BUDGET SURFACE ─────────────────────────

    /// @notice `RedemptionQueue.availableLiquidity()` is the spot read
    ///         `idleReserve() * epochLiquidityBps / BPS`, and raising `idleUSDCUnits` raises it in
    ///         the same block. D7-01 is the flash-manipulation of that read, so a new lever on it
    ///         has to be argued, not assumed.
    ///
    ///         THE ARGUMENT, MEASURED HERE: `recapitalize(X)` moves the budget by EXACTLY what
    ///         `mint(X)` already moved it by — and `mint` is the stronger lever, because it is
    ///         fully REVERSIBLE through `redeem`, returning the budget to baseline in the next
    ///         transaction. `recapitalize` is one-directional and costs the mover the entire
    ///         amount with no way to unwind and no claim acquired. D7-01's own fix additionally
    ///         put `closeEpoch` behind `SETTLEMENT_KEEPER_ROLE`, so an attacker cannot co-locate
    ///         the settlement with the manipulation at all. The surface is not widened.
    function test_R17_01_recapMovesTheEpochBudgetNoMoreThanMintAlreadyDoes() public {
        _mintUSDfrTo(alice, 100_000e18);
        uint256 base = queue.availableLiquidity();
        assertGt(base, 0, "VACUOUS: the budget must be live for this comparison to mean anything");

        // The PRE-EXISTING lever: mint. Permissioned only by KYC, immediate, and REFUNDABLE.
        _mintUSDfrTo(bob, 50_000e18);
        uint256 mintDelta = queue.availableLiquidity() - base;
        assertGt(mintDelta, 0);
        vm.prank(bob);
        controller.redeem(50_000e18);
        assertEq(queue.availableLiquidity(), base, "the mint lever unwinds completely");

        // The NEW lever: recapitalize, here from an address with NO KYC at all.
        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 50_000e6);
        reserves.recapitalize(50_000e6);
        vm.stopPrank();
        uint256 recapDelta = queue.availableLiquidity() - base;

        assertEq(recapDelta, mintDelta, "R17-01: the new lever moves the budget by exactly the old one's amount");
        // ... and it cannot be unwound: the funder holds nothing to redeem.
        assertEq(usdfr.balanceOf(rescuer), 0, "no claim was acquired");
        assertEq(vault.balanceOf(rescuer), 0);
        assertEq(usdc.balanceOf(rescuer), 5_000_000e6 - 50_000e6, "the manipulation costs 100 cents on the dollar");
    }

    /// @notice And the D7-01 gate itself is untouched: `closeEpoch` still refuses an unauthorised
    ///         caller, so recapitalising buys nobody the ability to settle at a chosen moment.
    function test_R17_01_recapDoesNotBuyTheAbilityToSettle() public {
        _mintUSDfrTo(alice, 100_000e18);
        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 50_000e6);
        reserves.recapitalize(50_000e6);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rescuer, Roles.SETTLEMENT_KEEPER_ROLE
            )
        );
        vm.prank(rescuer);
        queue.closeEpoch(10);
    }

    // ── TRAP (c): CURATOR FIRST-LOSS CANNOT BE BOUGHT OUT OF ─────────────

    /// @notice The real protection against a first-loss dodge, on the production `CuratorModule`:
    ///         a gift restores backing but does NOT release cascade layer 1. `custodyLossUnabsorbed()`
    ///         limb 1 (an open incident) survives any amount of funding, so curator capital stays
    ///         frozen until governance closes the adjudication.
    function test_R17_01_aGiftDoesNotUnfreezeCuratorFirstLoss() public {
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 50_000e18);
        assertFalse(curator.custodyFreezeActive(), "baseline: nothing frozen");

        (uint256 armId,) = _armReserveLoss(23);
        assertTrue(curator.custodyFreezeActive());

        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 500_000e6);
        reserves.recapitalize(500_000e6); // vastly over-fund the protocol
        vm.stopPrank();

        assertTrue(curator.custodyFreezeActive(), "R17-01: funding must not buy an exit from layer 1");
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1e18);

        // Only governance consuming the unused arm releases it.
        vm.prank(admin);
        reserves.cancelAndDisable(armId, EVIDENCE);
        assertFalse(curator.custodyFreezeActive());
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1e18);
    }
}
