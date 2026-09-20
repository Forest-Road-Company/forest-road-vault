// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title ATK_AccrualEngineFork: adversarial attacks on the continuous-accrual RECOGNITION path
///        against the FULL protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice This suite does not document the engine, it tries to BREAK it. The target is the
///         ADR-0038 recognition path: AccrualBook, AccrualLoans, AccrualSegments, AccrualMath and
///         AccrualCeiling, hosted inside ReserveManager through the ReserveAccrual* adapters and
///         reached from WaterfallEngine, ClaimBridge, DefaultManager, sUSDfr and the controller.
///         The invariants under attack (CLAUDE.md 1.3):
///           I1. backing: USDfr supply, physical and effective, never exceeds backing;
///           I2. value conservation: recognised interest is never created by keeper cadence and
///               never destroyed or duplicated by a lifecycle event;
///           I3. loss cascade ordering: a reversal of recognised interest, whole or sub-unit,
///               lands on curator first-loss before sGROVE and before the senior rate;
///           I7. sUSDfr rate integrity: materialisation is not a second price jump, and a stale
///               book never quotes above the fresh one;
///           I8. access control: every module-bound accrual mutator rejects a roleless caller.
///
///         The attacker is carol: not KYC'd, holding no role, funded with 1,000,000 real USDC.
///         Operator calls appear only to reach a legitimate state; the attack itself is made by
///         carol. Every outcome is unambiguous: a blocked attack asserts the specific custom error
///         with its arguments and the untouched state; a successful one would fail an assertion
///         that names the money.
///
///         Attacks:
///           A1. TELESCOPING: checkpoints once, weekly, and at payment boundaries plus odd second
///               offsets; gross, canonical interest, backing and vault assets must be identical to
///               the wei at the same final timestamp (I2, I7).
///           A2. CEILING: monthly checkpoints past the last payment date and past maturity;
///               principal plus interest binds to the balance ceiling exactly, a checkpoint after
///               maturity recognises nothing, and service, post, checkpoint and an over-sized
///               receipt cannot re-open recognition on a matured facility (I2).
///           A3. STALENESS: both refusals of the freshness gate. At the exact second a boundary
///               falls due, and again 400 days later with no checkpoint, vault deposit, queue
///               request, controller mint and redeem, materialisation, posting and servicing are
///               refused with AccrualBook_BoundaryPending naming the boundary; the stale frontier
///               never quotes above the fresh price, and one permissionless checkpoint restores
///               service at exactly the contractual amount (I7).
///           A4. PERMISSIONLESS SURFACE: every module-bound mutator rejects carol with its exact
///               error; the four permissionless entries move no value to carol, cause no second
///               price jump and recognise nothing the clock alone did not; selecting one
///               materialisation leg neither forfeits nor redirects the other (I8, I7).
///           A5. MISSED CHECKPOINT: for fund, distribute, markPastDue, clearPastDue, declareDefault
///               and amendTerms the event itself checkpoints (its aligned or posted event carries
///               block.timestamp and the computed amount), and recognition with and without an
///               explicit checkpoint just before the event is identical to the wei, at the event
///               and thirty days later (I2).
///           A6. BACKING WITH ACCRUAL: after sixty-three days and a materialisation the backing
///               invariant holds; declaring default and realising a loss equal to the recognised
///               interest reverses it through the cascade, curator first, leaving the senior
///               rate untouched and backing whole (I1, I3).
///           A7. DUST: a receipt at a non-grid instant makes the book's interpolation exceed the
///               contractual grid by fewer than 1e12 wei; that dust is written down through the
///               cascade, curator first when curator capital exists and the senior vault only when
///               no junior capital stands, never left as phantom backing (I3, I1).
///           A8. PIK CEILING: a PIK note compounds on signed boundaries only; its face never
///               exceeds the AccrualCeiling.pik reservation, every capitalisation is the exact
///               grid-floored coupon, the face at maturity is the exact compounded amount, the
///               reservation is trimmed to that face, and neither the crank, the servicer, the
///               poster, an over-sized receipt nor a cash interest leg re-opens recognition or
///               reclassifies debt a second time (I2, I1).
///           A9. FEE EPOCH: a protocol-fee change mid-accrual splits only the interest earned
///               afterwards at the new rate; gross already accrued keeps its old split, the change
///               is not a price event, a recipient change delivers the old recipient's claim first,
///               and carol cannot move either field (I7, I2, I8).
contract ATK_AccrualEngineForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant P = 1_000_000e18;
    uint256 internal constant RATE_BPS = 1400;
    uint256 internal constant YEAR = 360 days; // the fixture note is Actual/360
    uint256 internal constant TERM = 365 days;
    uint256 internal constant SCALE = 1e12; // one USDC unit in 18-dec wei
    uint256 internal constant P2 = 500_000e18; // the second facility funded in A5
    uint256 internal constant AMENDED_RATE_BPS = 2000; // the rate installed by A5's amendment

    // The PIK note attacked in A8: 100,000 at 14% fixed Actual/360, capitalising every 90 days,
    // 360-day term, so four signed capitalisations and no maturity stub.
    uint256 internal constant PIK_P = 100_000e18;
    uint256 internal constant PIK_INTERVAL = 90 days;
    uint256 internal constant PIK_TERM = 360 days;
    /// @dev AccrualCeiling.pik for the note above, derived by hand and checked by _pikCeilingBound:
    ///      100,000 x 1.035 (first coupon, rounded up to the grid) x 1.035^3 (three signed
    ///      successors, each factor rounded up at 1e27) with no stub. Every step is exact here.
    uint256 internal constant PIK_CEILING = 114_752_300_062_500_000_000_000;
    /// @dev The exact compounded face: four grid-floored coupons of 3,500, 3,622.5, 3,749.2875 and
    ///      3,880.512562 (the last one floors 3,880.5125625 to the 1e12 grid). Half a reserve unit
    ///      under the ceiling, never above it.
    uint256 internal constant PIK_FACE = 114_752_300_062_000_000_000_000;
    uint16 internal constant NEW_FEE_BPS = 2000; // the fee rate installed by A9, the permanent v1 cap

    /// @dev One coherent reading of everything the engine publishes about a facility and the
    ///      portfolio, taken at a single timestamp.
    struct Reading {
        uint256 gross;
        uint256 unposted;
        uint256 principal;
        uint256 interest;
        uint256 face;
        uint256 recorded;
        uint256 deployedTotal;
        uint256 backing;
        uint256 supply;
        uint256 assets;
        uint256 vaultShares;
        uint256 price;
        uint64 accruedThrough;
        bool fresh;
        bool active;
    }

    // ---------------------------------------------------------------------
    // A1: recognition telescopes whatever cadence the keeper chooses (I2, I7)
    // ---------------------------------------------------------------------

    /// @notice Attacks I2 and I7 through the keeper cadence. If recognition depended on how often
    ///         checkpointAccrual is called, a keeper (or carol, since it is permissionless) could
    ///         mint or destroy senior income by choosing when to call it: every wei of drift per
    ///         checkpoint is a wei of USDfr backed by nothing, or a wei of contractual interest
    ///         the senior vault never sees. Three cadences must land on identical numbers.
    function test_atk_recognitionTelescopesAcrossKeeperCadence() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        uint256 base = vm.snapshotState();

        // (i) one checkpoint after ninety days.
        _warpTo(t0 + 90 days);
        (uint256 processed, bool fresh) = _checkpointAsCarol();
        assertEq(processed, 0, "(i): no boundary is due inside the first technical segment");
        assertTrue(fresh, "(i): the book is fresh after the single checkpoint");
        Reading memory once = _read(id);

        // (ii) a checkpoint every seven days, ending on the same instant.
        assertTrue(vm.revertToState(base), "revert to the funded state");
        for (uint256 i = 1; i <= 12; ++i) {
            _warpTo(t0 + i * 7 days);
            _checkpointAsCarol();
        }
        _warpTo(t0 + 90 days);
        _checkpointAsCarol();
        Reading memory weekly = _read(id);

        // (iii) every payment boundary plus adversarial second offsets, same final instant.
        assertTrue(vm.revertToState(base), "revert to the funded state");
        uint256[10] memory offsets = [
            uint256(1),
            59,
            86_399,
            30 days,
            30 days + 1,
            30 days + 59,
            60 days,
            60 days + 86_399,
            90 days - 1,
            90 days
        ];
        for (uint256 i; i < offsets.length; ++i) {
            _warpTo(t0 + offsets[i]);
            _checkpointAsCarol();
        }
        Reading memory jagged = _read(id);

        // All three cadences must agree to the wei on every published quantity.
        _assertSame(once, weekly, "once vs weekly");
        _assertSame(once, jagged, "once vs jagged");

        // And the agreed numbers are the contractual ones, not merely mutually consistent.
        assertEq(once.gross, _slopeOnly(90 days), "book gross is the integer slope times elapsed seconds");
        assertEq(once.interest, _canonical(90 days), "canonical interest is the grid-rounded Actual/360 amount");
        assertEq(once.interest, 35_000e18, "ninety days at 14% Actual/360 on 1,000,000 is exactly 35,000");
        assertEq(once.principal, P, "principal is untouched by recognition");
        assertEq(once.recorded, P, "nothing was posted to the recorded face by a checkpoint");
        assertEq(once.face, P + once.gross, "the effective face is principal plus the unposted recognition");
        assertEq(once.unposted, once.gross, "everything recognised is still unposted");
        assertEq(once.supply, once.backing, "effective supply and backing move together under accrual");
    }

    // ---------------------------------------------------------------------
    // A2: the contractual ceiling binds exactly and nothing re-opens it (I2)
    // ---------------------------------------------------------------------

    /// @notice Attacks I2 through time. A recognition engine that keeps accruing past maturity,
    ///         or that rounds the endpoint above the contractual face, creates senior income the
    ///         borrower never owes: every wei above the ceiling is unbacked USDfr. The ceiling must
    ///         bind to the wei and no permissionless entry may re-open recognition afterwards.
    function test_atk_ceilingBindsAtMaturityAndNothingReopensRecognition() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        uint256 ceiling = reserves.accruedDebt(id).balanceCeiling;
        assertEq(ceiling, P + _cap(), "the cash ceiling is principal plus the grid-rounded term interest");

        _a2MonthlyUnderTheCeiling(id, t0, ceiling);
        Reading memory matured = _a2ProcessMaturity(id, t0, ceiling);
        _a2NothingAfterMaturity(id, t0, matured);
        _a2ReopenAttempts(id);
        _a2RefusedInputs(id);
    }

    /// @dev Month by month, past the first (and only) payment date at day 30, the debt stays under
    ///      the ceiling and equals the canonical curve exactly.
    function _a2MonthlyUnderTheCeiling(uint256 id, uint256 t0, uint256 ceiling) internal {
        for (uint256 m = 1; m <= 12; ++m) {
            _warpTo(t0 + m * 30 days);
            (uint256 processed,) = _checkpointAsCarol();
            assertEq(processed, 0, "no boundary before the last second of the term");
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            assertEq(d.interest, _canonical(m * 30 days), "interest follows the canonical grid curve");
            assertLe(d.principal + d.interest, ceiling, "the ceiling is the invariant side: debt never exceeds it");
            assertTrue(d.active, "the facility is still accruing before maturity");
        }
    }

    /// @dev The planner ends the first technical segment one second before maturity because the
    ///      grid cap is attained exactly at maturity. Process that boundary and the maturity one.
    function _a2ProcessMaturity(uint256 id, uint256 t0, uint256 ceiling) internal returns (Reading memory matured) {
        uint256 maturity = t0 + TERM;
        _warpTo(maturity - 1);
        (uint256 processedBoundary,) = _checkpointAsCarol();
        assertEq(processedBoundary, 1, "the pre-maturity technical boundary is processed on its second");
        assertEq(reserves.accrualSnapshot().gross, _segmentAmount(), "the first segment endpoint is recognised exactly");

        _warpTo(maturity);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualCeilingReserved(id, ceiling, ceiling);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(maturity), 0, 0, true);
        (uint256 processedMaturity, bool freshAtMaturity) = _checkpointAsCarol();
        assertEq(processedMaturity, 1, "the maturity boundary is processed on its second");
        assertTrue(freshAtMaturity, "nothing is left due after maturity");

        matured = _read(id);
        assertEq(matured.gross, _cap(), "gross binds to the term interest at maturity, to the wei");
        assertEq(matured.interest, _cap(), "canonical interest binds to the term interest at maturity");
        assertEq(matured.principal + matured.interest, ceiling, "the ceiling binds exactly");
        assertFalse(matured.active, "the facility stopped accruing at maturity");
        assertFalse(reserves.accrualLoanScheduled(id), "no segment survives maturity");
    }

    /// @dev ATTACK: keep checkpointing long past maturity. Nothing further may be recognised.
    function _a2NothingAfterMaturity(uint256 id, uint256 t0, Reading memory matured) internal {
        uint256 maturity = t0 + TERM;
        uint256[3] memory later = [maturity + 1, maturity + 35 days, maturity + 365 days];
        for (uint256 i; i < later.length; ++i) {
            _warpTo(later[i]);
            (uint256 processed, bool fresh) = _checkpointAsCarol();
            assertEq(processed, 0, "a matured book has no boundary to process");
            assertTrue(fresh, "a matured book is always fresh");
            Reading memory r = _read(id);
            assertEq(r.gross, _cap(), "a checkpoint after maturity recognises zero further interest");
            assertEq(r.interest, _cap(), "canonical interest is frozen at the term amount");
            assertEq(r.backing, matured.backing, "backing does not grow after maturity");
            assertEq(r.assets, matured.assets, "senior assets do not grow after maturity");
        }
    }

    /// @dev ATTACK: re-open recognition through the dormant-date servicer and the poster. A cash
    ///      facility has no signed capitalisation date, so service is an exact no-op; posting
    ///      reclassifies, it does not create.
    function _a2ReopenAttempts(uint256 id) internal {
        uint256 cap = _cap();
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(block.timestamp), 0, 0, false);
        vm.prank(carol);
        uint256 capitalised = reserves.serviceAccruedLoan(id);
        assertEq(capitalised, 0, "service capitalises nothing on a matured cash facility");
        assertEq(reserves.accrualSnapshot().gross, cap, "service recognised nothing");
        assertFalse(reserves.accruedDebt(id).active, "service did not re-activate the facility");

        Reading memory beforePost = _read(id);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, cap, P + cap);
        vm.prank(carol);
        uint256 posted = reserves.postAccruedLoan(id);
        assertEq(posted, cap, "the whole recognised interest is posted once");
        Reading memory afterPost = _read(id);
        assertEq(afterPost.recorded, P + cap, "the recorded face carries principal plus the posted interest");
        assertEq(afterPost.face, beforePost.face, "the effective face is unchanged by posting");
        assertEq(afterPost.unposted, 0, "nothing remains unposted");
        assertEq(afterPost.gross, beforePost.gross, "posting recognised nothing new");
        assertEq(afterPost.backing, beforePost.backing, "posting created no backing");
        assertEq(afterPost.supply, beforePost.supply, "posting created no supply");
        assertEq(afterPost.assets, beforePost.assets, "posting moved no senior value");
        vm.prank(carol);
        uint256 again = reserves.postAccruedLoan(id);
        assertEq(again, 0, "a second post finds nothing to post");
    }

    /// @dev ATTACK: a receipt above the contractual face and batch sizes outside the admitted
    ///      range are refused by name before any accounting moves.
    function _a2RefusedInputs(uint256 id) internal {
        uint256 cap = _cap();
        IWaterfallEngine.Payment memory over = _prepInterestPayment(id, cap + SCALE);
        vm.prank(ops);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        waterfall.distribute(over);
        assertEq(reserves.deployedTo(id), P + cap, "the refused receipt changed nothing");

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_BadBatch.selector, uint256(0)));
        reserves.checkpointAccrual(0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_BadBatch.selector, uint256(33)));
        reserves.checkpointAccrual(33);
    }

    // ---------------------------------------------------------------------
    // A3: a stale book refuses every priced action and never quotes above fresh (I7)
    // ---------------------------------------------------------------------

    /// @notice Attacks I7 through neglect. ADR-0038 says a missed checkpoint at a boundary must
    ///         refuse rather than drift. If any priced action proceeded on the stale frontier, an
    ///         entrant or exiter would be priced on a book that stops at the last processed
    ///         boundary: the difference between that quote and the fresh one is value moved
    ///         between holders. Every priced action must revert with the pending boundary named,
    ///         and the stale view must sit at or below the fresh one.
    function test_atk_staleBookRefusesPricedActionsAndNeverQuotesAboveFresh() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        uint256 base = vm.snapshotState();
        _a3BoundarySecondRefusesUntilTheKeeperRuns(id, t0);
        assertTrue(vm.revertToState(base), "revert to the funded state");
        _a3FourHundredDaysStale(id, t0);
    }

    /// @dev The second refusal branch, AccrualBook.requireFresh: at the exact second a boundary
    ///      falls due it is not yet overdue (so _requireTime admits the clock) but it is due and
    ///      unprocessed, and every price-sensitive write must refuse with BoundaryPending(at, at)
    ///      until a keeper processes it. The only unrecognised amount at that instant is the
    ///      segment's sub-unit remainder, so a leak here is small and conservative, but a gate
    ///      with one of its two branches missing is a gate that can be walked around by timing.
    function _a3BoundarySecondRefusesUntilTheKeeperRuns(uint256 id, uint256 t0) internal {
        uint256 aliceShares = vault.balanceOf(alice);
        _warpTo(t0 + TERM - 1);
        uint64 boundary = uint64(block.timestamp);

        IContinuousAccrual.Snapshot memory due = reserves.accrualSnapshot();
        assertFalse(due.fresh, "a boundary due this second makes the book stale");
        assertEq(due.accruedThrough, boundary, "the frontier is the boundary itself");
        assertEq(due.gross, _slopeOnly(TERM - 1), "the remainder is not yet recognised");
        bytes memory pending =
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, boundary, boundary);

        // The four priced actions, as alice.
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        vm.expectRevert(pending);
        vault.deposit(1_000e18, alice);
        vault.approve(address(queue), aliceShares);
        vm.expectRevert(pending);
        queue.requestRedeem(aliceShares);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(pending);
        controller.mint(1_000e6);
        usdfr.approve(address(controller), 1_000e18);
        vm.expectRevert(pending);
        controller.redeem(1_000e18);
        vm.stopPrank();

        // The three permissionless engine writes, as carol.
        vm.prank(carol);
        vm.expectRevert(pending);
        reserves.materializeAccrued(3);
        vm.prank(carol);
        vm.expectRevert(pending);
        reserves.postAccruedLoan(id);
        vm.prank(carol);
        vm.expectRevert(pending);
        reserves.serviceAccruedLoan(id);

        assertEq(vault.balanceOf(alice), aliceShares, "no shares minted or queued at the boundary second");
        assertEq(reserves.accrualSnapshot().gross, due.gross, "the refusals recognised nothing");

        // The keeper path is the one entry the gate must admit at this second.
        (uint256 processed, bool fresh) = _checkpointAsCarol();
        assertEq(processed, 1, "the boundary due this second is processed");
        assertTrue(fresh, "the book is fresh at the same second");
        Reading memory now_ = _read(id);
        assertEq(now_.gross, _segmentAmount(), "the endpoint, remainder included, is recognised exactly");
        assertEq(now_.accruedThrough, boundary, "the frontier is the clock again");
        assertGe(now_.gross, due.gross, "fresh gross is the invariant side: the due frontier never quoted above it");

        uint256 expectedShares = vault.previewDeposit(1_000e18);
        vm.prank(alice);
        uint256 minted = vault.deposit(1_000e18, alice);
        assertEq(minted, expectedShares, "the same deposit is admitted at the fresh preview once the keeper ran");
    }

    /// @dev The first refusal branch, AccrualBook._requireTime: a boundary strictly in the past.
    function _a3FourHundredDaysStale(uint256 id, uint256 t0) internal {
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "precondition: alice holds senior shares");

        // Four hundred days pass with NO checkpoint. Two boundaries are now overdue: the technical
        // one at maturity minus one second and maturity itself.
        _warpTo(t0 + 400 days);
        uint64 boundary = uint64(t0 + TERM - 1);
        uint64 nowTs = uint64(block.timestamp);

        IContinuousAccrual.Snapshot memory stale = reserves.accrualSnapshot();
        assertFalse(stale.fresh, "the snapshot reports itself stale");
        assertEq(stale.accruedThrough, boundary, "the frontier is capped at the first unprocessed boundary");
        assertEq(stale.gross, _slopeOnly(TERM - 1), "the stale gross is the slope through the boundary, no remainder");
        IAccrualLifecycle.Debt memory staleDebt = reserves.accruedDebt(id);
        assertEq(staleDebt.accruedThrough, boundary, "canonical debt is capped at the same frontier");
        assertEq(staleDebt.interest, _canonical(TERM - 1), "canonical interest through the boundary");
        uint256 stalePrice = vault.convertToAssets(10 ** vault.decimals());
        uint256 staleAssets = vault.totalAssets();

        bytes memory pending = abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, boundary, nowTs);

        // ATTACK 1: enter the senior vault on the stale price.
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        vm.expectRevert(pending);
        vault.deposit(1_000e18, alice);
        vm.stopPrank();

        // ATTACK 2: queue an exit on the stale price.
        vm.startPrank(alice);
        vault.approve(address(queue), aliceShares);
        vm.expectRevert(pending);
        queue.requestRedeem(aliceShares);
        vm.stopPrank();

        // ATTACK 3: mint USDfr against stale backing.
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(pending);
        controller.mint(1_000e6);
        vm.stopPrank();

        // ATTACK 4: redeem USDfr against stale backing.
        vm.startPrank(alice);
        usdfr.approve(address(controller), 1_000e18);
        vm.expectRevert(pending);
        controller.redeem(1_000e18);
        vm.stopPrank();

        // The capacity views advertise nothing executable while stale.
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit is zero on a stale book");
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem is zero on a stale book");
        assertEq(controller.mintableHeadroom(), 0, "mintableHeadroom is zero on a stale book");

        // Nothing moved: balances and the book are exactly as before the four attacks.
        assertEq(vault.balanceOf(alice), aliceShares, "no shares minted or queued");
        assertEq(reserves.accrualSnapshot().gross, stale.gross, "the refused actions recognised nothing");

        // One permissionless checkpoint by carol restores service: both overdue boundaries are
        // processed and the fresh numbers are exactly the contractual term interest.
        (uint256 processed, bool fresh) = _checkpointAsCarol();
        assertEq(processed, 2, "both overdue boundaries are processed in one call");
        assertTrue(fresh, "the book is fresh again");
        Reading memory now_ = _read(id);
        assertTrue(now_.fresh, "snapshot reports fresh");
        assertEq(now_.accruedThrough, nowTs, "the frontier is the clock again");
        assertEq(now_.gross, _cap(), "fresh gross is the term interest, remainder and last second included");
        assertEq(now_.interest, _cap(), "fresh canonical interest is the term interest");
        assertEq(
            now_.gross - stale.gross,
            _cap() - _slopeOnly(TERM - 1),
            "the stale quote lagged by exactly the remainder plus the last second"
        );
        assertGe(
            now_.price, stalePrice, "the fresh price is the invariant side: the stale frontier never quotes above it"
        );
        assertGe(now_.assets, staleAssets, "fresh senior assets are at least the stale ones");

        // And the same entrant is now admitted at the fresh price, at exactly the preview.
        uint256 expectedShares = vault.previewDeposit(1_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        uint256 minted = vault.deposit(1_000e18, alice);
        vm.stopPrank();
        assertEq(minted, expectedShares, "the fresh deposit prices at the fresh preview");
        assertEq(vault.balanceOf(alice), aliceShares + minted, "alice received exactly the fresh shares");
    }

    // ---------------------------------------------------------------------
    // A4: the permissionless surface, hostile and neutral (I8, I7)
    // ---------------------------------------------------------------------

    /// @notice Attacks I8 and I7. Every module-bound accrual mutator must reject the roleless
    ///         attacker with its exact error, and the four entries that are genuinely
    ///         permissionless must be value-neutral: nothing reaches carol, the senior price does
    ///         not jump when claims are materialised, and recognition is what the clock says.
    function test_atk_permissionlessSurfaceIsHostileProofAndValueNeutral() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        _warpTo(t0 + 45 days);
        _a4HostileSweep(id);
        _a4RefusedByName(id);

        // Nothing the hostile sweep tried moved the book.
        Reading memory before = _read(id);
        assertEq(before.gross, _slopeOnly(45 days), "the hostile sweep recognised nothing beyond the clock");
        assertEq(before.recorded, P, "the hostile sweep posted nothing");
        assertEq(before.face, P + before.gross, "the effective face is principal plus the unposted recognition");

        _a4CheckpointAndServiceAreNeutral(id, before);
        _a4SingleLegSelectionIsExact(id, before);
        _a4MaterializeIsNotASecondPriceJump(id, before);
        _a4PostIsReclassificationOnly(id, before);
    }

    /// @dev Every module-bound mutator rejects carol with its exact error and arguments.
    function _a4HostileSweep(uint256 id) internal {
        IContinuousAccrual.Modules memory m = reserves.accrualModules();

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.waterfall, carol)
        );
        reserves.registerAccruingLoan(id);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.waterfall, carol)
        );
        reserves.repayAccruingLoan(id, carol, 1, 1);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.waterfall, carol)
        );
        reserves.retireAccruedLoan(id);

        IAccrualLifecycle.Terms memory terms = IAccrualLifecycle.Terms({
            rateBps: 1400,
            yearSeconds: uint32(360 days),
            nextPaymentDue: uint64(block.timestamp + 30 days),
            paymentInterval: 30 days,
            maturity: uint64(block.timestamp + 365 days)
        });
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.bridge, carol)
        );
        reserves.amendAccruingLoan(id, terms);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.defaultManager, carol)
        );
        reserves.stopAccruingLoan(id);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.defaultManager, carol)
        );
        reserves.setAccrualPastDue(id, true);

        vm.prank(carol);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotWaterfall.selector);
        reserves.setAccrualFee(1, carol);

        IContinuousAccrual.Modules memory hostile = IContinuousAccrual.Modules({
            token: carol,
            controller: carol,
            vault: carol,
            waterfall: carol,
            bridge: carol,
            registry: carol,
            defaultManager: carol
        });
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        reserves.configureContinuousAccrual(hostile);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        reserves.enableContinuousAccrual();

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        reserves.prepareContinuousAccrualMigration(bytes(""));

        vm.prank(carol);
        vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
        reserves.consumeAccrualLossBurn(carol, alice, 1);
    }

    /// @dev The waterfall's permissionless crank refuses a cash facility by name, and an
    ///      out-of-range leg mask is refused by name.
    function _a4RefusedByName(uint256 id) internal {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotDesignated.selector, id));
        waterfall.capitalizePik(id);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidLegs.selector, uint8(0)));
        reserves.materializeAccrued(0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidLegs.selector, uint8(4)));
        reserves.materializeAccrued(4);
    }

    /// @dev checkpoint is a pure settle and service is an exact no-op on a cash facility.
    function _a4CheckpointAndServiceAreNeutral(uint256 id, Reading memory before) internal {
        (uint256 processed, bool fresh) = _checkpointAsCarol();
        assertEq(processed, 0, "checkpoint: no boundary due");
        assertTrue(fresh, "checkpoint: fresh");
        _assertSame(before, _read(id), "checkpoint changed a published quantity");

        vm.prank(carol);
        uint256 capitalised = reserves.serviceAccruedLoan(id);
        assertEq(capitalised, 0, "service capitalises nothing");
        _assertSame(before, _read(id), "service changed a published quantity");
    }

    /// @dev ATTACK: select one leg at a time, in both orders. Selecting the senior leg must not
    ///      deliver, forfeit or redirect the fee claim, and the reverse; each single-leg delivery
    ///      moves exactly its own claim to exactly its own destination and nothing else; the
    ///      order of the two deliveries does not change the end state; and no single-leg delivery
    ///      is a price event. A leg delivered twice or to the wrong destination is USDfr minted
    ///      against a claim that was already paid, or a fee paid into the senior rate.
    function _a4SingleLegSelectionIsExact(uint256 id, Reading memory before) internal {
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        assertGt(claims.seniorUnissued, 0, "precondition: a senior claim is outstanding");
        assertGt(claims.feeUnissued, 0, "precondition: a fee claim is outstanding");
        address feeSink = waterfall.feeRecipient();
        assertTrue(feeSink != address(vault), "precondition: the fee sink is not the senior vault");
        uint256 base = vm.snapshotState();

        // Order A: senior first (the fee claim must survive intact), then the fee.
        _a4SelectLeg(id, before, claims, 1, 1, claims.feeUnissued);
        _a4SelectLeg(id, before, claims, 2, 2, 0);
        assertEq(reserves.accrualSnapshot().unissued, 0, "order A: nothing remains virtual after both legs");
        vm.prank(carol);
        (uint256 s3, uint256 f3) = reserves.materializeAccrued(3);
        assertEq(s3 + f3, 0, "order A: a third call finds nothing to deliver");
        Reading memory endA = _read(id);
        uint256 vaultA = usdfr.balanceOf(address(vault));
        uint256 sinkA = usdfr.balanceOf(feeSink);
        uint256 physicalA = usdfr.totalSupply();

        // Order B: fee first, then senior, from the same state.
        assertTrue(vm.revertToState(base), "revert to the undelivered state");
        _a4SelectLeg(id, before, claims, 2, 1, claims.seniorUnissued);
        _a4SelectLeg(id, before, claims, 1, 2, 0);
        assertEq(reserves.accrualSnapshot().unissued, 0, "order B: nothing remains virtual after both legs");
        _assertSame(endA, _read(id), "order of single-leg delivery");
        assertEq(usdfr.balanceOf(address(vault)), vaultA, "order of delivery does not change the vault's balance");
        assertEq(usdfr.balanceOf(feeSink), sinkA, "order of delivery does not change the fee sink's balance");
        assertEq(usdfr.totalSupply(), physicalA, "order of delivery does not change physical supply");

        assertTrue(vm.revertToState(base), "restore the undelivered state for the two-leg attack");
    }

    /// @dev One single-leg delivery by carol, with every destination and claim measured.
    ///      `otherRemaining` is what the unselected leg must still show as virtual afterwards:
    ///      its whole claim if it has not been delivered yet, zero if it already has.
    function _a4SelectLeg(
        uint256 id,
        Reading memory before,
        IContinuousAccrual.Snapshot memory claims,
        uint8 legs,
        uint256 nonce,
        uint256 otherRemaining
    ) internal {
        // held[0] vault, held[1] fee sink, held[2] carol, held[3] physical supply.
        uint256[4] memory held = _holdings();
        uint256 expectedSenior = legs == 1 ? claims.seniorUnissued : 0;
        uint256 expectedFee = legs == 2 ? claims.feeUnissued : 0;

        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualMaterialized(nonce, uint64(block.timestamp), legs, expectedSenior, expectedFee);
        vm.prank(carol);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(legs);
        assertEq(senior, expectedSenior, "the senior leg is delivered only when selected, and then in full");
        assertEq(fee, expectedFee, "the fee leg is delivered only when selected, and then in full");
        uint256[4] memory after_ = _holdings();
        assertEq(after_[3], held[3] + senior + fee, "physical supply rose by exactly the selected leg");
        assertEq(after_[0], held[0] + senior, "the vault received exactly the senior leg");
        assertEq(after_[1], held[1] + fee, "the fee sink received exactly the fee leg");
        assertEq(after_[2], held[2], "carol received nothing");

        _a4AssertClaims(claims, legs, otherRemaining);
        Reading memory now_ = _read(id);
        assertEq(now_.assets, before.assets, "NO PRICE JUMP: totalAssets is identical to the wei");
        assertEq(now_.price, before.price, "NO PRICE JUMP: the fee-net rate is identical to the wei");
        assertEq(now_.supply, before.supply, "effective supply is unchanged by a single-leg delivery");
        assertEq(now_.backing, before.backing, "backing is unchanged by a single-leg delivery");
    }

    /// @dev The unselected leg's claim is exactly intact (or exactly gone if delivered earlier).
    function _a4AssertClaims(IContinuousAccrual.Snapshot memory claims, uint8 legs, uint256 otherRemaining)
        internal
        view
    {
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertEq(s.gross, claims.gross, "delivery recognised nothing");
        assertEq(
            s.seniorUnissued,
            legs == 1 ? 0 : otherRemaining,
            "the senior claim is exactly zero once selected and exactly intact while not"
        );
        assertEq(
            s.feeUnissued,
            legs == 2 ? 0 : otherRemaining,
            "the fee claim is exactly zero once selected and exactly intact while not"
        );
    }

    /// @dev USDfr held by the vault, the fee sink and carol, and the physical supply.
    function _holdings() internal view returns (uint256[4] memory h) {
        h[0] = usdfr.balanceOf(address(vault));
        h[1] = usdfr.balanceOf(waterfall.feeRecipient());
        h[2] = usdfr.balanceOf(carol);
        h[3] = usdfr.totalSupply();
    }

    /// @dev materialize: claims become physical USDfr in the vault and the fee sink, nowhere
    ///      else, and no published economic quantity moves.
    function _a4MaterializeIsNotASecondPriceJump(uint256 id, Reading memory before) internal {
        uint256 carolUSDfr = usdfr.balanceOf(carol);
        uint256 carolUSDC = IERC20(USDC).balanceOf(carol);
        uint256 physicalBefore = usdfr.totalSupply();
        uint256 vaultHeld = usdfr.balanceOf(address(vault));
        address feeSink = waterfall.feeRecipient();
        uint256 feeSinkHeld = usdfr.balanceOf(feeSink);
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        assertGt(claims.seniorUnissued, 0, "precondition: a senior claim is outstanding");
        assertGt(claims.feeUnissued, 0, "precondition: a fee claim is outstanding");
        assertEq(
            claims.feeUnissued,
            Math.mulDiv(claims.gross, waterfall.protocolFeeBps(), Config.BPS),
            "the protocol fee is the configured share of gross"
        );

        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualMaterialized(
            1, uint64(block.timestamp), 3, claims.seniorUnissued, claims.feeUnissued
        );
        vm.prank(carol);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(3);
        assertEq(senior, claims.seniorUnissued, "materialised exactly the senior claim");
        assertEq(fee, claims.feeUnissued, "materialised exactly the fee claim");
        assertEq(usdfr.totalSupply(), physicalBefore + senior + fee, "physical supply rose by exactly the claims");
        assertEq(usdfr.balanceOf(address(vault)), vaultHeld + senior, "the vault received exactly the senior leg");
        assertEq(usdfr.balanceOf(feeSink), feeSinkHeld + fee, "the fee sink received exactly the fee leg");
        assertEq(usdfr.balanceOf(carol), carolUSDfr, "carol received nothing");
        assertEq(IERC20(USDC).balanceOf(carol), carolUSDC, "carol paid nothing");

        Reading memory after_ = _read(id);
        assertEq(after_.assets, before.assets, "NO SECOND PRICE JUMP: totalAssets is identical to the wei");
        assertEq(after_.vaultShares, before.vaultShares, "materialisation minted no shares");
        assertEq(after_.price, before.price, "NO SECOND PRICE JUMP: the fee-net rate is identical to the wei");
        assertEq(after_.supply, before.supply, "effective supply is unchanged by delivery");
        assertEq(after_.backing, before.backing, "backing is unchanged by delivery");
        assertEq(after_.gross, before.gross, "delivery recognised nothing");
        assertEq(reserves.accrualSnapshot().unissued, 0, "no claim remains virtual");

        vm.prank(carol);
        (uint256 seniorAgain, uint256 feeAgain) = reserves.materializeAccrued(3);
        assertEq(seniorAgain + feeAgain, 0, "a second materialisation finds nothing to deliver");
    }

    /// @dev post: reclassification only.
    function _a4PostIsReclassificationOnly(uint256 id, Reading memory before) internal {
        uint256 carolUSDfr = usdfr.balanceOf(carol);
        vm.prank(carol);
        uint256 posted = reserves.postAccruedLoan(id);
        assertEq(posted, before.gross, "post moves exactly the recognised interest to the face");
        Reading memory after_ = _read(id);
        assertEq(after_.recorded, P + posted, "the recorded face carries the posted interest");
        assertEq(after_.face, before.face, "the effective face is unchanged by posting");
        assertEq(after_.backing, before.backing, "post created no backing");
        assertEq(after_.supply, before.supply, "post created no supply");
        assertEq(after_.assets, before.assets, "post moved no senior value");
        assertEq(after_.gross, before.gross, "post recognised nothing");
        assertEq(usdfr.balanceOf(carol), carolUSDfr, "carol still holds nothing");
    }

    // ---------------------------------------------------------------------
    // A5: every rate-changing event checkpoints; a missed one would drift silently (I2)
    // ---------------------------------------------------------------------

    /// @notice Attacks I2 at the six rate-changing events reachable on the fixture. ADR-0038 says
    ///         "an omission does not revert; it drifts". For each event the test proves, by
    ///         measurement, that the event settles the clock at block.timestamp (its aligned or
    ///         posted event carries the exact computed amount) and that running the event with
    ///         and without an explicit checkpoint just before it lands on identical numbers, at
    ///         the event and thirty days later. Any difference is interest created or destroyed by
    ///         the order of two calls, which is unbacked USDfr or lost senior income.
    function test_atk_everyRateChangingEventCheckpointsWithoutDrift() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        // Sixty-three days is past the 21-day grace window after the day-30 payment date, and is
        // a grid-exact instant on this note (the canonical curve has no remainder there), so the
        // aligned events below carry a positive correction rather than a rounding loss.
        uint256 T = t0 + 63 days;
        _warpTo(T);
        uint256 elapsed = T - t0;

        // Expected thirty-day growth of the portfolio gross AFTER each event, derived from the
        // planner's integer slopes, so an event that fails to change the rate cannot pass by
        // path-equality alone.
        uint256 same = _slope() * 30 days;
        _telescopesAcrossExplicitCheckpoint(id, _actFund, "fund", same + _freshEpochSlope(P2, RATE_BPS, TERM) * 30 days);
        _telescopesAcrossExplicitCheckpoint(
            id, _actRepayInterest, "distribute", ((_cap() - _canonical(elapsed)) / (TERM - elapsed)) * 30 days
        );
        _telescopesAcrossExplicitCheckpoint(id, _actMarkPastDue, "markPastDue", same);
        _telescopesAcrossExplicitCheckpoint(id, _actDeclareDefault, "declareDefault", 0);
        _telescopesAcrossExplicitCheckpoint(
            id, _actAmend, "amendTerms", _freshEpochSlope(P, AMENDED_RATE_BPS, TERM - elapsed) * 30 days
        );

        // clearPastDue needs a standing mark: mark now (as carol), then compare the cure paths
        // nine days later, another grid-exact instant.
        _actMarkPastDue(id);
        _warpTo(T + 9 days);
        _telescopesAcrossExplicitCheckpoint(id, _actClearPastDue, "clearPastDue", same);

        // The event data asserted inside the actors was derived from these two curves; pin them so
        // a change in the planner cannot make the assertions pass vacuously.
        assertGt(_canonical(elapsed), _interpolated(elapsed), "at a grid-exact instant canonical exceeds interpolation");
        assertLt(_canonical(elapsed) - _interpolated(elapsed), SCALE, "the correction is below one reserve unit");
    }

    // ---------------------------------------------------------------------
    // A6: backing holds under accrual, and a reversal runs through the cascade (I1, I3)
    // ---------------------------------------------------------------------

    /// @notice Attacks I1 and I3. Accrued interest enters backing at full face (ADR-0038 Q1) and
    ///         is reversed through the cascade (Q3). If backing ever fell below supply the token
    ///         would be unbacked; if the reversal came straight out of the senior rate, curator
    ///         capital would be spared a loss it exists to absorb and every senior holder would
    ///         pay for income that never existed.
    function test_atk_backingHoldsUnderAccrualAndReversalRunsThroughTheCascade() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        _postFirstLossOps(500_000e18); // layer 1
        _fundCoverageOps(200_000e18); // layer 2
        assertEq(curator.poolBalance(FILM), 500_000e18, "precondition: layer 1 seeded");
        assertEq(sGrove.coverageReserve(), 200_000e18, "precondition: layer 2 seeded");

        uint256 T = t0 + 63 days; // grid-exact instant, see A5
        _warpTo(T);
        assertEq(_canonical(T - t0), 24_500e18, "sixty-three days at 14% Actual/360 on 1,000,000 is exactly 24,500");

        Reading memory accrued = _a6BackingHoldsWhileAccrued(id, T - t0);
        Reading memory delivered = _a6MaterializeIsNeutral(id, accrued);
        _a6DeclareStopsAndPosts(id, T - t0, delivered);

        // Time passes; a defaulted facility earns nothing more.
        _warpTo(T + 10 days);
        _checkpointAsCarol();
        assertEq(reserves.accrualSnapshot().gross, _canonical(T - t0), "a defaulted facility earns nothing more");

        _a6ReversalRunsThroughTheCascade(id, _canonical(T - t0));
    }

    /// @dev Backing holds with unposted, unissued accrued interest on the book.
    function _a6BackingHoldsWhileAccrued(uint256 id, uint256 elapsed) internal view returns (Reading memory accrued) {
        accrued = _read(id);
        assertEq(accrued.gross, _slopeOnly(elapsed), "gross is the slope through the instant");
        assertLe(usdfr.totalSupply(), accrued.backing, "I1 physical: supply within backing");
        assertLe(accrued.supply, accrued.backing, "I1 effective: supply including unissued claims within backing");
        assertTrue(controller.backingInvariantHolds(), "I1 recognised: the controller reports whole");
    }

    /// @dev Materialise once. Physical supply rises by the claims; nothing economic moves.
    function _a6MaterializeIsNeutral(uint256 id, Reading memory accrued) internal returns (Reading memory delivered) {
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        uint256 physicalBefore = usdfr.totalSupply();
        vm.prank(carol);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(3);
        assertEq(senior + fee, claims.unissued, "exactly the outstanding claims were delivered");
        assertEq(usdfr.totalSupply(), physicalBefore + claims.unissued, "physical supply rose by the claims");
        delivered = _read(id);
        assertEq(delivered.supply, accrued.supply, "effective supply unchanged by delivery");
        assertEq(delivered.backing, accrued.backing, "backing unchanged by delivery");
        assertEq(delivered.assets, accrued.assets, "senior assets unchanged by delivery");
        assertEq(delivered.price, accrued.price, "senior rate unchanged by delivery");
        assertLe(usdfr.totalSupply(), delivered.backing, "I1 physical after delivery");
        assertTrue(controller.backingInvariantHolds(), "I1 recognised after delivery");
    }

    /// @dev Declare default: the engine stops and posts the full earned claim first. The stop
    ///      credits the interpolated remainder and then the positive correction up to the
    ///      canonical grid, so the book moves from slope-only to canonical in one step.
    function _a6DeclareStopsAndPosts(uint256 id, uint256 elapsed, Reading memory delivered) internal {
        uint256 canonical = _canonical(elapsed);
        bytes32 evidence = keccak256("atk-accrual-default");
        _attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidence)));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(
            id, 1, uint64(block.timestamp), canonical - _interpolated(elapsed), 0, true
        );
        vm.prank(ops);
        defaultManager.declareDefault(id, evidence);

        Reading memory declared = _read(id);
        assertFalse(declared.active, "accrual stopped at declaration");
        assertEq(declared.gross, canonical, "the stop reconciles the book to the canonical amount");
        assertEq(declared.interest, canonical, "canonical interest at declaration");
        assertEq(declared.face, P + canonical, "the native face carries principal plus the posted interest");
        assertEq(declared.unposted, 0, "nothing is left unposted at declaration");
        assertEq(
            declared.backing,
            delivered.backing + (canonical - _slopeOnly(elapsed)),
            "backing rose by exactly the remainder plus the correction"
        );
        assertEq(
            declared.supply,
            delivered.supply + (canonical - _slopeOnly(elapsed)),
            "effective supply rose by exactly the remainder plus the correction"
        );
        assertTrue(controller.backingInvariantHolds(), "I1 holds at declaration");
    }

    /// @dev Realise a loss equal to the recognised interest. The cascade must take it from the
    ///      curator first; layer 2 and the senior rate must be untouched.
    function _a6ReversalRunsThroughTheCascade(uint256 id, uint256 loss) internal {
        uint256 curatorPool = curator.poolBalance(FILM);
        uint256 coverage = sGrove.coverageReserve();
        Reading memory before = _read(id);
        bytes32 lossEvidence = _attestLoss(id, loss, bytes32(0));
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit IDefaultManager.LossRealized(id, FILM, loss, loss, 0, 0);
        vm.prank(ops);
        defaultManager.realizeLoss(id, loss, lossEvidence);

        Reading memory after_ = _read(id);
        assertEq(curator.poolBalance(FILM), curatorPool - loss, "CURATOR FIRST: layer 1 paid the whole reversal");
        assertEq(sGrove.coverageReserve(), coverage, "layer 2 untouched while layer 1 sufficed");
        assertEq(after_.assets, before.assets, "the senior vault lost nothing: reversal did not hit the senior rate");
        assertEq(after_.vaultShares, before.vaultShares, "no fee shares were minted by the reversal");
        assertEq(after_.price, before.price, "the senior rate is unchanged to the wei");
        assertEq(after_.supply, before.supply - loss, "effective supply fell by exactly the loss");
        assertEq(after_.backing, before.backing - loss, "backing fell by exactly the loss");
        assertTrue(controller.backingInvariantHolds(), "I1 holds after the reversal");
        assertLe(usdfr.totalSupply(), after_.backing, "I1 physical after the reversal");
        assertEq(after_.principal + after_.interest, P, "the canonical face is back to principal");
        assertEq(after_.face, P, "the native face is back to principal");
    }

    // ---------------------------------------------------------------------
    // A7: sub-unit dust settles through the cascade, never as phantom backing (I3, I1)
    // ---------------------------------------------------------------------

    /// @notice Attacks I3 and I1 at the six-decimal boundary. Between grid instants the book's
    ///         linear interpolation can exceed the contractual grid amount by fewer than 1e12 wei.
    ///         A receipt at such an instant must write that dust down through the cascade, curator
    ///         first, and only fall on the senior vault when no junior capital stands. Dust left on
    ///         the face would be backing for USDfr that no borrower owes.
    function test_atk_subUnitDustSettlesThroughTheCascadeNotOnTheFace() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        uint256 T = t0 + 60 days; // NOT grid-exact: interpolation exceeds the canonical grid here
        _warpTo(T);
        uint256 elapsed = T - t0;
        uint256 canonical = _canonical(elapsed);
        uint256 interpolated = _interpolated(elapsed);
        assertGt(interpolated, canonical, "precondition: the interpolation overshoots the grid at this instant");
        uint256 dust = interpolated - canonical;
        assertLt(dust, SCALE, "the discrepancy is below one reserve unit");
        uint256 base = vm.snapshotState();

        // Scenario 1: curator capital exists. The dust must come from the curator pool exactly.
        _postFirstLossOps(500_000e18);
        uint256 pool = curator.poolBalance(FILM);
        Reading memory before = _read(id);
        IWaterfallEngine.Payment memory p = _prepInterestPayment(id, canonical);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveRoundingLib.AccrualRoundingAllocated(id, 1, dust, 0, dust, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(id, 1, uint64(T), 0, dust, false);
        vm.prank(ops);
        waterfall.distribute(p);
        Reading memory after_ = _read(id);
        assertEq(curator.poolBalance(FILM), pool - dust, "CURATOR FIRST: the dust came out of layer 1 exactly");
        assertEq(after_.face, P, "the receipt cleared the posted interest and the dust is not on the face");
        assertEq(after_.interest, 0, "canonical interest is discharged by the receipt");
        assertEq(after_.gross, interpolated, "recognised income is retained, not cancelled");
        assertEq(after_.unposted, 0, "nothing remains unposted");
        assertEq(
            after_.backing,
            before.backing + canonical - _slopeOnly(elapsed),
            "backing: cash in, unposted out, dust written down"
        );
        assertEq(after_.supply, after_.backing, "effective supply and backing still agree after the dust write-down");
        assertEq(reserves.roundingLossUnabsorbed(), 0, "nothing was left unabsorbed");
        assertTrue(controller.backingInvariantHolds(), "I1 holds after the dust write-down");
        assertEq(
            after_.assets,
            before.assets + _seniorShare(interpolated) - _seniorShare(_slopeOnly(elapsed)),
            "the senior vault received its share of the remainder and was not charged the dust"
        );

        // Scenario 2: no junior capital at all. The dust must then fall on the senior vault, and
        // on nothing else, exactly once.
        assertTrue(vm.revertToState(base), "revert to the funded state");
        assertEq(curator.poolBalance(FILM), 0, "precondition: empty curator pool");
        assertEq(sGrove.coverageReserve(), 0, "precondition: empty sGROVE reserve");
        Reading memory bare = _read(id);
        p = _prepInterestPayment(id, canonical);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveRoundingLib.AccrualRoundingAllocated(id, 1, dust, 0, 0, 0, dust, 0, 0);
        vm.prank(ops);
        waterfall.distribute(p);
        Reading memory bareAfter = _read(id);
        assertEq(bareAfter.face, P, "the dust is not on the face when the senior pays it either");
        assertEq(bareAfter.gross, interpolated, "recognised income retained");
        assertEq(bareAfter.backing, bare.backing + canonical - _slopeOnly(elapsed), "backing accounts for the dust");
        assertEq(bareAfter.supply, bareAfter.backing, "supply and backing agree after the senior write-down");
        // The senior share of the remainder credit lands in the vault; the dust leaves it.
        uint256 seniorCredit = _seniorShare(interpolated) - _seniorShare(_slopeOnly(elapsed));
        assertEq(
            bareAfter.assets,
            bare.assets + seniorCredit - dust,
            "the senior vault paid exactly the dust and nothing more"
        );
        assertEq(reserves.roundingLossUnabsorbed(), 0, "nothing was left unabsorbed");
        assertTrue(controller.backingInvariantHolds(), "I1 holds after the senior dust write-down");
    }

    // ---------------------------------------------------------------------
    // A8: the PIK ceiling bounds compounding and nothing re-opens or double-counts it (I2, I1)
    // ---------------------------------------------------------------------

    /// @notice Attacks I2 and I1 on a PIK note, the only shape that enters AccrualCeiling.sol. A
    ///         PIK face compounds on signed boundaries; the ceiling reserves arithmetic space for
    ///         the whole schedule and must never be exceeded, and the capitalisations must be the
    ///         exact grid-floored coupons and nothing else. A coupon capitalised twice (once by
    ///         the keeper and again by the crank or the servicer), a face above the reservation,
    ///         or interest recognised after maturity is USDfr backed by debt the borrower does
    ///         not owe; a coupon lost is senior income destroyed.
    function test_atk_pikCeilingBoundsCompoundingAndNothingReopensRecognition() public onFork {
        (uint256 id, uint256 t0) = _fundedPikFacility();
        uint256 base = vm.snapshotState();

        _a8CrankAtAndOffTheBoundaryEqualsTheKeeper(id, t0);
        assertTrue(vm.revertToState(base), "revert to the funded PIK state");
        _a8ZeroRateAmendmentIsRefused(id);

        _a8MonthlyUnderTheCeiling(id, t0);
        Reading memory matured = _read(id);
        _a8NothingAfterMaturity(id, t0, matured);
        _a8ReopenAttempts(id);
        _a8RefusedReceipts(id);
    }

    /// @dev Month by month through four signed capitalisations. At every instant the face is at
    ///      or under the ceiling; every capitalisation is the exact coupon; the bridge's due date
    ///      follows the engine; maturity capitalises the last coupon, stops the clock and trims
    ///      the reservation to the exact face.
    function _a8MonthlyUnderTheCeiling(uint256 id, uint256 t0) internal {
        uint256 ceiling = reserves.accruedDebt(id).balanceCeiling;
        for (uint256 m = 1; m <= 12; ++m) {
            uint256 at = t0 + m * 30 days;
            uint256 k = (m * 30 days) / PIK_INTERVAL; // signed boundaries completed at `at`
            bool onBoundary = (m * 30 days) % PIK_INTERVAL == 0;
            _warpTo(at);
            if (onBoundary && k < 4) {
                vm.expectEmit(true, true, true, true, address(reserves));
                emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(
                    id, uint64(at), _pikCoupon(k), uint64(at + PIK_INTERVAL), false
                );
            }
            if (onBoundary && k == 4) {
                // The planner ends the last period one second before maturity because the last
                // coupon attains the whole-grid cap exactly at maturity (the ceiling binds there).
                vm.expectEmit(true, true, true, true, address(reserves));
                emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(at - 1), 0, 0, false);
                vm.expectEmit(true, true, true, true, address(reserves));
                emit ReserveAccrualCreditLib.AccrualCeilingReserved(id, PIK_CEILING, PIK_FACE);
                vm.expectEmit(true, true, true, true, address(reserves));
                emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(at), _pikCoupon(4), 0, true);
            }
            (uint256 processed,) = _checkpointAsCarol();
            assertEq(processed, onBoundary ? (k == 4 ? 2 : 1) : 0, "boundaries processed this month");

            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            assertLe(d.principal + d.interest, ceiling, "the ceiling is the invariant side: the face never exceeds it");
            assertEq(d.principal, _pikFaceAfter(k), "principal is exactly the compounded face after k coupons");
            if (k < 4) {
                uint256 elapsed = m * 30 days - k * PIK_INTERVAL;
                assertEq(
                    d.interest,
                    _pikCanonical(_pikFaceAfter(k), elapsed, ceiling - _pikFaceAfter(k)),
                    "interest is the canonical grid amount on the frozen period basis"
                );
                assertTrue(d.active, "the note accrues before maturity");
                assertEq(
                    bridge.facility(id).nextPaymentDue,
                    t0 + (k + 1) * PIK_INTERVAL,
                    "the bridge's due date follows the engine's next capitalisation"
                );
            }
            assertEq(
                reserves.deployedTo(id), PIK_P + reserves.accrualSnapshot().gross, "effective face is P plus gross"
            );
        }

        Reading memory matured = _read(id);
        assertEq(matured.principal, PIK_FACE, "the face at maturity is the exact compounded amount");
        assertEq(matured.interest, 0, "the last coupon was capitalised, not left as interest");
        assertEq(matured.gross, PIK_FACE - PIK_P, "gross binds to the compounded face minus principal, to the wei");
        assertEq(matured.face, PIK_FACE, "the effective face is the compounded face");
        assertLt(PIK_CEILING - PIK_FACE, SCALE, "the reservation was tight to within one reserve unit");
        assertFalse(matured.active, "the note stopped at maturity");
        assertFalse(reserves.accrualLoanScheduled(id), "no segment survives maturity");
        assertEq(reserves.accruedDebt(id).nextCapitalization, 0, "no signed capitalisation remains");
        assertEq(reserves.accrualReservedExposure(), 0, "no future face is reserved beyond the effective face");
        assertTrue(controller.backingInvariantHolds(), "I1 holds at PIK maturity");
    }

    /// @dev ATTACK: keep checkpointing past maturity. Nothing further may be recognised or
    ///      reclassified.
    function _a8NothingAfterMaturity(uint256 id, uint256 t0, Reading memory matured) internal {
        uint256 maturity = t0 + PIK_TERM;
        uint256[3] memory later = [maturity + 1, maturity + 35 days, maturity + 365 days];
        for (uint256 i; i < later.length; ++i) {
            _warpTo(later[i]);
            (uint256 processed, bool fresh) = _checkpointAsCarol();
            assertEq(processed, 0, "a matured PIK book has no boundary to process");
            assertTrue(fresh, "a matured PIK book is always fresh");
            Reading memory r = _read(id);
            assertEq(r.principal, PIK_FACE, "principal is frozen at the compounded face");
            assertEq(r.interest, 0, "no interest accrues after maturity");
            assertEq(r.gross, matured.gross, "a checkpoint after maturity recognises nothing");
            assertEq(r.backing, matured.backing, "backing does not grow after maturity");
            assertEq(r.assets, matured.assets, "senior assets do not grow after maturity");
        }
    }

    /// @dev ATTACK: re-open or double-count through the servicer, the crank and the poster.
    function _a8ReopenAttempts(uint256 id) internal {
        uint256 carolUSDfr = usdfr.balanceOf(carol);
        Reading memory before = _read(id);

        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(block.timestamp), 0, 0, false);
        vm.prank(carol);
        uint256 serviced = reserves.serviceAccruedLoan(id);
        assertEq(serviced, 0, "the servicer capitalises nothing on a matured note");
        _assertSame(before, _read(id), "service on a matured PIK note");

        vm.expectEmit(true, true, true, true, address(waterfall));
        emit WaterfallEngine.AccrualCheckpointed(id, 0, true, 0);
        vm.prank(carol);
        uint256 cranked = waterfall.capitalizePik(id);
        assertEq(cranked, 0, "the crank capitalises nothing on a matured note");
        _assertSame(before, _read(id), "crank on a matured PIK note");

        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, PIK_FACE - PIK_P, PIK_FACE);
        vm.prank(carol);
        uint256 posted = reserves.postAccruedLoan(id);
        assertEq(posted, PIK_FACE - PIK_P, "the whole compounded interest is posted once");
        Reading memory after_ = _read(id);
        assertEq(after_.recorded, PIK_FACE, "the recorded face carries the compounded face");
        assertEq(after_.face, before.face, "the effective face is unchanged by posting");
        assertEq(after_.unposted, 0, "nothing remains unposted");
        assertEq(after_.gross, before.gross, "posting recognised nothing new");
        assertEq(after_.backing, before.backing, "posting created no backing");
        assertEq(after_.supply, before.supply, "posting created no supply");
        assertEq(after_.assets, before.assets, "posting moved no senior value");
        assertEq(after_.principal, PIK_FACE, "posting reclassified no debt");
        vm.prank(carol);
        uint256 again = reserves.postAccruedLoan(id);
        assertEq(again, 0, "a second post finds nothing");
        assertEq(usdfr.balanceOf(carol), carolUSDfr, "carol received nothing");
    }

    /// @dev ATTACK: settle the PIK note with more than it owes, or with a cash interest leg.
    function _a8RefusedReceipts(uint256 id) internal {
        IWaterfallEngine.Payment memory over = _prepPrincipalPayment(id, PIK_FACE + SCALE);
        vm.prank(ops);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        waterfall.distribute(over);
        assertEq(reserves.deployedTo(id), PIK_FACE, "the refused receipt changed nothing");

        IWaterfallEngine.Payment memory cashInterest = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256("atk-pik-cash-interest"),
            payer: borrower,
            interest: SCALE,
            principal: 0,
            nextPaymentDue: 0
        });
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikCashInterestNotPermitted.selector, id));
        waterfall.distribute(cashInterest);
        assertEq(reserves.deployedTo(id), PIK_FACE, "a cash interest leg on a PIK note changed nothing");
    }

    /// @dev ATTACK: the permissionless crank at the exact boundary second and ten days off it,
    ///      against a keeper that runs ten days late. At the boundary second the servicer and the
    ///      poster refuse with BoundaryPending(at, at); ten days later they refuse with the
    ///      boundary named as overdue; the crank is itself a keeper on both occasions and must
    ///      capitalise the coupon exactly once. The on-time crank plus ten days and the ten-day-late
    ///      keeper must land on identical numbers: recognition telescopes across a capitalisation.
    ///      Carol gains nothing on either path.
    function _a8CrankAtAndOffTheBoundaryEqualsTheKeeper(uint256 id, uint256 t0) internal {
        uint256 s = vm.snapshotState();
        uint256 boundary = t0 + PIK_INTERVAL;
        uint256 carolUSDfr = usdfr.balanceOf(carol);

        // Path a: the crank at the exact boundary second, then again ten days later.
        _warpTo(boundary);
        _a8ServiceAndPostRefuse(id, boundary, boundary);
        assertEq(reserves.accruedDebt(id).principal, PIK_P, "nothing capitalised while the boundary is pending");
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(
            id, uint64(boundary), _pikCoupon(1), uint64(boundary + PIK_INTERVAL), false
        );
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit WaterfallEngine.AccrualCheckpointed(id, 1, true, _pikCoupon(1));
        vm.prank(carol);
        uint256 cranked = waterfall.capitalizePik(id);
        assertEq(cranked, _pikCoupon(1), "the crank capitalised exactly the first coupon");
        Reading memory onTime = _read(id);
        assertEq(onTime.principal, _pikFaceAfter(1), "principal is the face after one coupon");
        assertEq(onTime.interest, 0, "the new period starts at zero interest");
        assertEq(onTime.gross, _pikCoupon(1), "gross is exactly the first coupon at the boundary");

        _warpTo(boundary + 10 days);
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit WaterfallEngine.AccrualCheckpointed(id, 0, true, 0);
        vm.prank(carol);
        uint256 crankedAgain = waterfall.capitalizePik(id);
        assertEq(crankedAgain, 0, "a second crank capitalises nothing");
        Reading memory a = _read(id);
        assertEq(a.principal, _pikFaceAfter(1), "principal unchanged by the second crank");
        assertEq(
            a.interest,
            _pikCanonical(_pikFaceAfter(1), 10 days, PIK_CEILING - _pikFaceAfter(1)),
            "ten days of interest on the compounded basis"
        );
        assertEq(usdfr.balanceOf(carol), carolUSDfr, "carol received nothing from the crank");

        // Path b: no crank; the keeper runs ten days late.
        assertTrue(vm.revertToState(s), "revert to the funded PIK state");
        _warpTo(boundary + 10 days);
        _a8ServiceAndPostRefuse(id, boundary, boundary + 10 days);
        (uint256 processed,) = _checkpointAsCarol();
        assertEq(processed, 1, "the late keeper processes the skipped boundary");
        _assertSame(a, _read(id), "on-time crank plus ten days vs ten-day-late keeper");
        assertTrue(vm.revertToState(s), "restore the funded PIK state");
    }

    /// @dev The servicer and the poster refuse a pending boundary by name.
    function _a8ServiceAndPostRefuse(uint256 id, uint256 boundary, uint256 at) internal {
        bytes memory pending =
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(boundary), uint64(at));
        vm.prank(carol);
        vm.expectRevert(pending);
        reserves.serviceAccruedLoan(id);
        vm.prank(carol);
        vm.expectRevert(pending);
        reserves.postAccruedLoan(id);
    }

    /// @dev The dormant-date branch of the servicer (_settleDormantPik with a due date) needs an
    ///      active PIK period that schedules no work: a zero rate, or a frozen basis so small
    ///      that a whole period's coupon rounds to zero on the 1e12 grid (under 28.57e12 wei at
    ///      14% over 90 days, reachable only by repeated near-total paydowns across renewed
    ///      periods). The direct route, a zero-rate amendment, is refused by the bridge at the
    ///      door; this pins that refusal so a relaxation of the gate shows up as a coverage change.
    function _a8ZeroRateAmendmentIsRefused(uint256 id) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: 0,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        vm.prank(ops);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(id, keccak256("atk-pik-zero-rate"), a);
        assertEq(bridge.facility(id).interestRateBps, RATE_BPS, "the rate is unchanged");
    }

    // ---------------------------------------------------------------------
    // A9: a fee-epoch change is prospective, not a price event, and not carol's to make (I7, I2, I8)
    // ---------------------------------------------------------------------

    /// @notice Attacks I7, I2 and I8 through the protocol fee. If a rate change re-split gross
    ///         already accrued, the senior claim would drop at the instant of the change (a price
    ///         event no holder agreed to) and the fee sink would be paid on interest earned under
    ///         the old rate; if a recipient change forfeited or redirected the old recipient's
    ///         claim, a fee already earned would be paid to the wrong party or twice. Carol can do
    ///         neither, and ops can do only the prospective thing.
    function test_atk_feeEpochChangeIsProspectiveAndNotAPriceEvent() public onFork {
        (uint256 id, uint256 t0) = _fundedFacility();
        _warpTo(t0 + 45 days);
        uint16 oldBps = waterfall.protocolFeeBps();
        address oldSink = waterfall.feeRecipient();
        assertEq(oldBps, uint16(Config.DEFAULT_PROTOCOL_FEE_BPS), "precondition: the default fee rate");
        assertEq(oldSink, ops, "precondition: the fee sink is the operator");

        _a9HostileFeeWrites(oldBps, oldSink);
        IContinuousAccrual.Snapshot memory epochOne = _a9RateChangeIsNotAPriceEvent(id, oldBps, oldSink);
        _a9NewRateAppliesOnlyToLaterInterest(id, t0, epochOne);
        _a9RecipientChangeDeliversTheOldClaimFirst(id, t0, oldSink);
    }

    /// @dev Carol can move neither the rate nor the recipient, through either host.
    function _a9HostileFeeWrites(uint16 oldBps, address oldSink) internal {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        waterfall.setProtocolFee(NEW_FEE_BPS);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        waterfall.setFeeRecipient(carol);
        vm.prank(carol);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotWaterfall.selector);
        reserves.setAccrualFee(NEW_FEE_BPS, carol);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_BadFee.selector, uint16(NEW_FEE_BPS + 1)));
        waterfall.setProtocolFee(NEW_FEE_BPS + 1);
        assertEq(waterfall.protocolFeeBps(), oldBps, "the rate is unchanged");
        assertEq(waterfall.feeRecipient(), oldSink, "the recipient is unchanged");
    }

    /// @dev Ops doubles the rate. Every published quantity, the price included, is identical to
    ///      the wei before and after; the claims at the instant of the change are untouched.
    function _a9RateChangeIsNotAPriceEvent(uint256 id, uint16 oldBps, address oldSink)
        internal
        returns (IContinuousAccrual.Snapshot memory epochOne)
    {
        Reading memory before = _read(id);
        epochOne = reserves.accrualSnapshot();
        assertEq(
            epochOne.feeUnissued,
            Math.mulDiv(epochOne.gross, oldBps, Config.BPS),
            "epoch one fee is the old rate on gross"
        );
        assertEq(epochOne.seniorUnissued, epochOne.gross - epochOne.feeUnissued, "epoch one senior is the rest");

        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualFeeConfigured(NEW_FEE_BPS, oldSink, uint64(block.timestamp));
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit IWaterfallEngine.ProtocolFeeSet(NEW_FEE_BPS);
        vm.prank(ops);
        waterfall.setProtocolFee(NEW_FEE_BPS);
        assertEq(waterfall.protocolFeeBps(), NEW_FEE_BPS, "the new rate is installed");

        _assertSame(before, _read(id), "fee rate change");
        IContinuousAccrual.Snapshot memory after_ = reserves.accrualSnapshot();
        assertEq(after_.feeUnissued, epochOne.feeUnissued, "the fee claim at the instant of the change is untouched");
        assertEq(
            after_.seniorUnissued, epochOne.seniorUnissued, "the senior claim at the instant of the change is untouched"
        );
    }

    /// @dev Forty-five days later the fee is the old epoch's amount plus the new rate on the
    ///      interest earned since, and only that; the senior claim is the rest.
    function _a9NewRateAppliesOnlyToLaterInterest(uint256 id, uint256 t0, IContinuousAccrual.Snapshot memory epochOne)
        internal
    {
        _warpTo(t0 + 90 days);
        _checkpointAsCarol();
        IContinuousAccrual.Snapshot memory later = reserves.accrualSnapshot();
        assertEq(later.gross, _slopeOnly(90 days), "gross is the slope through day ninety");
        uint256 earnedSince = later.gross - epochOne.gross;
        uint256 expectedFee = epochOne.feeUnissued + Math.mulDiv(earnedSince, NEW_FEE_BPS, Config.BPS);
        assertEq(later.feeUnissued, expectedFee, "the fee is epoch one plus the new rate on interest earned since");
        assertEq(later.seniorUnissued, later.gross - expectedFee, "the senior claim is gross minus the two-epoch fee");
        assertNotEq(
            later.feeUnissued,
            Math.mulDiv(later.gross, NEW_FEE_BPS, Config.BPS),
            "already-accrued gross was not re-split at the new rate"
        );
        assertEq(later.seniorUnissued + later.feeUnissued, later.gross, "the two-epoch split conserves gross exactly");
        assertEq(reserves.deployedTo(id), P + later.gross, "the effective face is unaffected by the fee split");
    }

    /// @dev Ops moves the fee to a new sink. The old recipient's whole earned claim is delivered
    ///      first (a fee-leg materialisation inside the change), the vault is untouched, and the
    ///      next delivery pays the new sink only the fee earned afterwards.
    function _a9RecipientChangeDeliversTheOldClaimFirst(uint256 id, uint256 t0, address oldSink) internal {
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        Reading memory before = _read(id);
        uint256 oldSinkHeld = usdfr.balanceOf(oldSink);
        uint256 bobHeld = usdfr.balanceOf(bob);
        uint256 vaultHeld = usdfr.balanceOf(address(vault));
        uint256 physicalBefore = usdfr.totalSupply();

        vm.prank(ops);
        controller.setYieldSink(bob, true);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualMaterialized(1, uint64(block.timestamp), 2, 0, claims.feeUnissued);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualFeeConfigured(NEW_FEE_BPS, bob, uint64(block.timestamp));
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit IWaterfallEngine.FeeRecipientSet(bob);
        vm.prank(ops);
        waterfall.setFeeRecipient(bob);

        assertEq(usdfr.balanceOf(oldSink), oldSinkHeld + claims.feeUnissued, "the old sink received its whole claim");
        assertEq(usdfr.balanceOf(bob), bobHeld, "the new sink received nothing it had not earned");
        assertEq(usdfr.balanceOf(address(vault)), vaultHeld, "the vault received nothing");
        assertEq(usdfr.totalSupply(), physicalBefore + claims.feeUnissued, "physical supply rose by the fee leg only");
        IContinuousAccrual.Snapshot memory after_ = reserves.accrualSnapshot();
        assertEq(after_.feeUnissued, 0, "no fee claim remains for the old recipient");
        assertEq(after_.seniorUnissued, claims.seniorUnissued, "the senior claim is untouched by the recipient change");
        assertEq(after_.feeRecipient, bob, "the engine's recipient is the new sink");
        Reading memory now_ = _read(id);
        assertEq(now_.assets, before.assets, "NO PRICE JUMP: totalAssets is identical to the wei");
        assertEq(now_.price, before.price, "NO PRICE JUMP: the fee-net rate is identical to the wei");
        assertEq(now_.supply, before.supply, "effective supply is unchanged by the recipient change");
        assertEq(now_.backing, before.backing, "backing is unchanged by the recipient change");

        _warpTo(t0 + 120 days);
        _checkpointAsCarol();
        uint256 earnedSince = reserves.accrualSnapshot().gross - claims.gross;
        uint256 newFee = Math.mulDiv(earnedSince, NEW_FEE_BPS, Config.BPS);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualMaterialized(2, uint64(block.timestamp), 2, 0, newFee);
        vm.prank(carol);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(2);
        assertEq(senior, 0, "the fee leg alone was selected");
        assertEq(fee, newFee, "the new sink's claim is the new rate on interest earned since the change, exactly");
        assertEq(usdfr.balanceOf(bob), bobHeld + newFee, "the new sink received exactly that");
        assertEq(usdfr.balanceOf(oldSink), oldSinkHeld + claims.feeUnissued, "the old sink received nothing more");
        assertTrue(controller.backingInvariantHolds(), "I1 holds after both fee deliveries");
    }

    // -- A5 actors ------------------------------------------------------------

    /// @dev Funds a second facility now. Registration must settle the portfolio clock at this
    ///      instant, which the emitted fundedAt proves.
    function _actFund(uint256) internal {
        uint256 principal2 = P2;
        uint256 id2 = bridge.totalOriginated() + 1;
        uint64 maturity2 = uint64(block.timestamp + TERM);
        bytes32 borrower2 = keccak256("FORK_BORROWER_2");
        uint256 ceiling2 = principal2 + Math.mulDiv(principal2 * RATE_BPS, TERM, YEAR * 10_000 * SCALE) * SCALE;
        _attestFilmGate(id2, borrower2, keccak256("US-GA"), principal2, 7500, maturity2, keccak256("ucc-ref-2"));
        vm.prank(ops);
        uint256 minted = bridge.originate(
            ops, _forkTerms(borrower2, keccak256("US-GA"), principal2, 7500, maturity2, keccak256("ucc-ref-2"))
        );
        assertEq(minted, id2, "second facility id");
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruingLoanRegistered(
            id2, USDC, FILM, principal2, ceiling2, uint16(RATE_BPS), uint32(YEAR), uint64(block.timestamp), false
        );
        vm.prank(ops);
        waterfall.fund(id2, principal2 / SCALE);
        assertEq(reserves.accruedDebt(id2).principal, principal2, "second facility registered at its principal");
    }

    /// @dev Distributes exactly the canonical interest owed now. The aligned event must carry this
    ///      instant and the positive correction between interpolation and the canonical grid.
    function _actRepayInterest(uint256 id) internal {
        uint256 elapsed = block.timestamp - _fundedAt(id);
        uint256 canonical = _canonical(elapsed);
        assertEq(reserves.accruedDebt(id).interest, canonical, "owed interest is the canonical amount");
        IWaterfallEngine.Payment memory p = _prepInterestPayment(id, canonical);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, canonical, P + canonical);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(
            id, 1, uint64(block.timestamp), canonical - _interpolated(elapsed), 0, false
        );
        vm.prank(ops);
        waterfall.distribute(p);
        assertEq(reserves.deployedTo(id), P, "the receipt cleared the posted interest");
    }

    /// @dev Carol marks the facility past due. The mark posts the slope-only recognition first.
    function _actMarkPastDue(uint256 id) internal {
        uint256 elapsed = block.timestamp - _fundedAt(id);
        uint256 postedBefore = _recordedFace(id) - P;
        uint256 growth = _slopeOnly(elapsed) - postedBefore;
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, growth, P + _slopeOnly(elapsed));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualPastDueSet(id, true);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        assertEq(reserves.deployedTo(id), P + _slopeOnly(elapsed), "the mark posted the slope recognition");
        assertEq(reserves.unpostedAccruedLoan(id), 0, "nothing unposted after the mark");
    }

    /// @dev The servicer cures the mark. The cure posts the growth since the mark first.
    function _actClearPastDue(uint256 id) internal {
        uint256 elapsed = block.timestamp - _fundedAt(id);
        uint256 postedBefore = _recordedFace(id) - P;
        uint256 growth = _slopeOnly(elapsed) - postedBefore;
        bytes32 evidence = keccak256("atk-accrual-cure");
        _attest(id, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(id, evidence)));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, growth, P + _slopeOnly(elapsed));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualPastDueSet(id, false);
        vm.prank(ops);
        defaultManager.clearPastDue(id, evidence);
        assertEq(reserves.deployedTo(id), P + _slopeOnly(elapsed), "the cure posted the growth since the mark");
    }

    /// @dev Declares default. The stop must align the book to the canonical amount at this instant.
    function _actDeclareDefault(uint256 id) internal {
        uint256 elapsed = block.timestamp - _fundedAt(id);
        uint256 canonical = _canonical(elapsed);
        bytes32 evidence = keccak256("atk-accrual-declare");
        _attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidence)));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, canonical, P + canonical);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(
            id, 1, uint64(block.timestamp), canonical - _interpolated(elapsed), 0, true
        );
        vm.prank(ops);
        defaultManager.declareDefault(id, evidence);
        assertFalse(reserves.accruedDebt(id).active, "declaration stopped accrual");
        assertEq(reserves.deployedTo(id), P + canonical, "declaration posted the canonical interest");
    }

    /// @dev Amends the rate to 20%. The amendment must close the old curve at this instant.
    function _actAmend(uint256 id) internal {
        uint256 elapsed = block.timestamp - _fundedAt(id);
        uint256 canonical = _canonical(elapsed);
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: uint16(AMENDED_RATE_BPS),
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendmentId = keccak256("atk-accrual-amendment");
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendmentId, id, a)));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, canonical, P + canonical);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(
            id, 1, uint64(block.timestamp), canonical - _interpolated(elapsed), 0, false
        );
        vm.prank(ops);
        bridge.amendTerms(id, amendmentId, a);
        assertEq(reserves.deployedTo(id), P + canonical, "the amendment posted the old curve's interest");
        assertTrue(reserves.accruedDebt(id).active, "the amended facility keeps accruing");
        assertEq(bridge.facility(id).interestRateBps, AMENDED_RATE_BPS, "the new rate is installed");
    }

    /// @dev Runs `act` twice from the same state: once directly and once after an explicit
    ///      permissionless checkpoint. Every published quantity must agree at the event and thirty
    ///      days later. Leaves the state as it was before the call.
    function _telescopesAcrossExplicitCheckpoint(
        uint256 id,
        function(uint256) internal act,
        string memory name,
        uint256 growth30d
    ) internal {
        uint256 s = vm.snapshotState();

        act(id);
        Reading memory a1 = _read(id);
        _warp(30 days);
        _checkpointAsCarol();
        Reading memory a2 = _read(id);

        assertTrue(vm.revertToState(s), "revert to the pre-event state");
        _checkpointAsCarol();
        act(id);
        Reading memory b1 = _read(id);
        _warp(30 days);
        _checkpointAsCarol();
        Reading memory b2 = _read(id);

        _assertSame(a1, b1, string.concat(name, " at the event"));
        _assertSame(a2, b2, string.concat(name, " thirty days after the event"));
        assertTrue(
            a1.fresh && a2.fresh, string.concat(name, ": the event and the later checkpoint leave the book fresh")
        );
        assertEq(
            a2.gross - a1.gross,
            growth30d,
            string.concat(name, ": thirty-day growth after the event is the planned slope")
        );

        assertTrue(vm.revertToState(s), "restore the pre-event state");
    }

    // -- helpers ------------------------------------------------------------

    /// @dev Alice funds the reserve and the senior vault, then ops originates and funds the note
    ///      the whole suite attacks: 1,000,000 principal, 14% fixed Actual/360, 30-day interval,
    ///      365-day term. Alice keeps 2,000,000 USDC and 1,000,000 USDfr for the priced attacks.
    function _fundedFacility() internal returns (uint256 id, uint256 t0) {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        t0 = block.timestamp;
        id = _originateAndFund(P);
        assertEq(reserves.accruedDebt(id).principal, P, "registered at the funded principal");
        assertTrue(reserves.accruedDebt(id).active, "registered as accruing");
    }

    /// @dev Alice funds the reserve and the senior vault, then ops originates and funds the PIK
    ///      note A8 attacks. Registration must carry the AccrualCeiling.pik reservation exactly.
    function _fundedPikFacility() internal returns (uint256 id, uint256 t0) {
        _mintFromUSDC(alice, 1_000_000e6);
        _stake(alice, 600_000e18);
        t0 = block.timestamp;
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM,
            keccak256("FORK_PIK_BORROWER"),
            keccak256("US-GA"),
            PIK_P,
            7500,
            uint16(RATE_BPS),
            uint64(t0 + PIK_TERM),
            keccak256("atk-pik-note")
        );
        t.pik = true;
        t.paymentInterval = uint64(PIK_INTERVAL);
        t.nextPaymentDue = uint64(t0 + PIK_INTERVAL);
        id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, t);
        assertEq(minted, id, "PIK facility id");
        assertEq(_pikCeilingBound(), PIK_CEILING, "the hand-derived ceiling matches the sequential bound");
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruingLoanRegistered(
            id, USDC, FILM, PIK_P, PIK_CEILING, uint16(RATE_BPS), uint32(YEAR), uint64(t0), true
        );
        vm.prank(ops);
        waterfall.fund(id, PIK_P / SCALE);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.principal, PIK_P, "registered at the funded principal");
        assertEq(d.balanceCeiling, PIK_CEILING, "the AccrualCeiling.pik reservation, to the wei");
        assertTrue(d.pik && d.active, "registered as an accruing PIK note");
        assertEq(d.nextCapitalization, t0 + PIK_INTERVAL, "the first signed capitalisation date");
    }

    /// @dev The exact grid-floored coupon on `basis` for one signed PIK period.
    function _pikCouponOn(uint256 basis) internal pure returns (uint256) {
        return Math.mulDiv(basis, RATE_BPS * PIK_INTERVAL, 10_000 * YEAR) / SCALE * SCALE;
    }

    /// @dev The exact compounded face after `k` signed capitalisations (k in 0..4).
    function _pikFaceAfter(uint256 k) internal pure returns (uint256 face) {
        face = PIK_P;
        for (uint256 i; i < k; ++i) {
            face += _pikCouponOn(face);
        }
    }

    /// @dev The k-th coupon (1-based): the one capitalised at the k-th signed boundary.
    function _pikCoupon(uint256 k) internal pure returns (uint256) {
        return _pikFaceAfter(k) - _pikFaceAfter(k - 1);
    }

    /// @dev Canonical grid interest on a frozen PIK basis after `elapsed` seconds, capped at the
    ///      period's remaining ceiling room: AccrualSegments.cumulative for that period.
    function _pikCanonical(uint256 basis, uint256 elapsed, uint256 cap) internal pure returns (uint256) {
        uint256 exact = Math.mulDiv(basis, RATE_BPS * elapsed, 10_000 * YEAR);
        if (exact > cap) exact = cap;
        return exact / SCALE * SCALE;
    }

    /// @dev AccrualCeiling.pik for the A8 note, derived sequentially: the first coupon rounded up
    ///      to the grid, then one round-up multiplication per signed successor. The library uses
    ///      exponentiation by squaring; the two agree whenever every step is exact, as here, and
    ///      the constant PIK_CEILING pins the value independently of both.
    function _pikCeilingBound() internal pure returns (uint256 ceiling) {
        uint256 denominator = 10_000 * YEAR;
        ceiling = PIK_P + Math.mulDiv(PIK_P, RATE_BPS * PIK_INTERVAL, denominator * SCALE, Math.Rounding.Ceil) * SCALE;
        uint256 precision = 1e27;
        uint256 factor = precision + Math.mulDiv(RATE_BPS * PIK_INTERVAL, precision, denominator, Math.Rounding.Ceil);
        uint256 successors = (PIK_TERM - PIK_INTERVAL) / PIK_INTERVAL;
        for (uint256 i; i < successors; ++i) {
            ceiling = Math.mulDiv(ceiling, factor, precision, Math.Rounding.Ceil);
        }
    }

    /// @dev The funding instant of the note under attack: origination and funding share a block.
    function _fundedAt(uint256 id) internal view returns (uint256) {
        return bridge.facility(id).nextPaymentDue - bridge.facility(id).paymentInterval;
    }

    /// @dev The recorded native face: `deployedTo` is the effective face (recorded plus the
    ///      facility's unposted recognition), so the recorded part is the difference.
    function _recordedFace(uint256 id) internal view returns (uint256) {
        return reserves.deployedTo(id) - reserves.unpostedAccruedLoan(id);
    }

    function _warpTo(uint256 ts) internal {
        require(ts > block.timestamp, "ATK: warp must move forward");
        _warp(ts - block.timestamp);
    }

    function _checkpointAsCarol() internal returns (uint256 processed, bool fresh) {
        vm.prank(carol);
        return reserves.checkpointAccrual(32);
    }

    /// @dev The contractual grid cap of the note: the cash balance ceiling minus principal.
    function _cap() internal pure returns (uint256) {
        return Math.mulDiv(P * RATE_BPS, TERM, YEAR * 10_000 * SCALE) * SCALE;
    }

    /// @dev Canonical grid-rounded cumulative interest after `elapsed` seconds on the frozen basis.
    function _canonical(uint256 elapsed) internal pure returns (uint256) {
        uint256 exact = Math.mulDiv(P, RATE_BPS * elapsed, 10_000 * YEAR);
        uint256 cap = _cap();
        if (exact > cap) exact = cap;
        return exact / SCALE * SCALE;
    }

    /// @dev The first technical segment. The grid cap is attained exactly at maturity, so the
    ///      planner ends the segment one second earlier at the canonical amount there.
    function _segmentAmount() internal pure returns (uint256) {
        return _canonical(TERM - 1);
    }

    function _segmentDuration() internal pure returns (uint256) {
        return TERM - 1;
    }

    /// @dev The integer per-second slope of the note's first technical segment.
    function _slope() internal pure returns (uint256) {
        return _segmentAmount() / _segmentDuration();
    }

    /// @dev Book recognition at an interior instant: the integer slope only, no remainder.
    function _slopeOnly(uint256 elapsed) internal pure returns (uint256) {
        return _slope() * elapsed;
    }

    /// @dev Book recognition after a lifecycle reconcile: linear interpolation of the endpoint.
    function _interpolated(uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(_segmentAmount(), elapsed, _segmentDuration());
    }

    /// @dev Grid-rounded cumulative interest on `basis` at `rateBps` after `elapsed` seconds,
    ///      capped at `cap`: AccrualSegments.cumulative for a fresh epoch.
    function _cum(uint256 basis, uint256 rateBps, uint256 elapsed, uint256 cap) internal pure returns (uint256) {
        uint256 exact = Math.mulDiv(basis, rateBps * elapsed, 10_000 * YEAR);
        if (exact > cap) exact = cap;
        return exact / SCALE * SCALE;
    }

    /// @dev The integer slope of the first technical segment of a fresh cash epoch of `period`
    ///      seconds, replicating AccrualSegments.plan: the cash ceiling caps the period at its own
    ///      grid-rounded simple interest, so the cap is attained exactly at the period end and the
    ///      planner stops the segment one second earlier.
    function _freshEpochSlope(uint256 basis, uint256 rateBps, uint256 period) internal pure returns (uint256) {
        uint256 cap = Math.mulDiv(basis * rateBps, period, YEAR * 10_000 * SCALE) * SCALE;
        uint256 end = period < 365 days ? period : 365 days;
        if (_cum(basis, rateBps, period, cap) == cap) {
            uint256 capHit = Math.mulDiv(cap, 10_000 * YEAR, basis * rateBps, Math.Rounding.Ceil);
            uint256 capBoundary = capHit > 1 ? capHit - 1 : capHit;
            if (capBoundary < end) end = capBoundary;
        }
        return _cum(basis, rateBps, end, cap) / end;
    }

    /// @dev The senior share of a gross amount under the configured protocol fee, matching the
    ///      book's fee arithmetic from a zero fee base.
    function _seniorShare(uint256 gross) internal view returns (uint256) {
        return gross - Math.mulDiv(gross, waterfall.protocolFeeBps(), Config.BPS);
    }

    function _read(uint256 id) internal view returns (Reading memory r) {
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        r.gross = s.gross;
        r.unposted = s.unposted;
        r.accruedThrough = s.accruedThrough;
        r.fresh = s.fresh;
        r.principal = d.principal;
        r.interest = d.interest;
        r.active = d.active;
        r.face = reserves.deployedTo(id);
        r.recorded = r.face - reserves.unpostedAccruedLoan(id);
        r.deployedTotal = reserves.deployedPrincipal();
        r.backing = reserves.totalBackingValue();
        r.supply = controller.totalUSDfr();
        r.assets = vault.totalAssets();
        r.vaultShares = vault.totalSupply();
        r.price = vault.convertToAssets(10 ** vault.decimals());
    }

    function _assertSame(Reading memory a, Reading memory b, string memory ctx) internal pure {
        assertEq(a.gross, b.gross, string.concat(ctx, ": gross differs"));
        assertEq(a.unposted, b.unposted, string.concat(ctx, ": unposted differs"));
        assertEq(a.principal, b.principal, string.concat(ctx, ": principal differs"));
        assertEq(a.interest, b.interest, string.concat(ctx, ": canonical interest differs"));
        assertEq(a.face, b.face, string.concat(ctx, ": effective face differs"));
        assertEq(a.recorded, b.recorded, string.concat(ctx, ": recorded face differs"));
        assertEq(a.deployedTotal, b.deployedTotal, string.concat(ctx, ": deployed principal differs"));
        assertEq(a.backing, b.backing, string.concat(ctx, ": backing differs"));
        assertEq(a.supply, b.supply, string.concat(ctx, ": effective supply differs"));
        assertEq(a.assets, b.assets, string.concat(ctx, ": senior assets differ"));
        assertEq(a.vaultShares, b.vaultShares, string.concat(ctx, ": senior shares differ"));
        assertEq(a.price, b.price, string.concat(ctx, ": senior price differs"));
        assertEq(uint256(a.accruedThrough), uint256(b.accruedThrough), string.concat(ctx, ": frontier differs"));
        assertEq(a.fresh, b.fresh, string.concat(ctx, ": freshness differs"));
        assertEq(a.active, b.active, string.concat(ctx, ": activity differs"));
    }

    /// @dev Prepares an attested interest-only receipt without distributing it, so a test can bind
    ///      an expectRevert or expectEmit to the distribute call itself.
    function _prepInterestPayment(uint256 tokenId, uint256 interest)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = interest / SCALE;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        uint64 nextDue = f.nextPaymentDue + f.paymentInterval;
        bytes32 paymentId = keccak256(abi.encode("atk-accrual-interest", tokenId, interest, block.timestamp));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, interest, uint256(0), nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: 0,
            nextPaymentDue: nextDue
        });
    }

    /// @dev Prepares an attested principal-only receipt without distributing it.
    function _prepPrincipalPayment(uint256 tokenId, uint256 principal)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = principal / SCALE;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        bytes32 paymentId = keccak256(abi.encode("atk-accrual-principal", tokenId, principal, block.timestamp));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, uint256(0), principal, uint64(0)))
        );
        p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: 0,
            principal: principal,
            nextPaymentDue: 0
        });
    }

    /// @dev Post curator first-loss (layer 1) for FILM as the anchor curator (ops).
    function _postFirstLossOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / SCALE);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    /// @dev Fund the sGROVE shared reserve (layer 2) as ops.
    function _fundCoverageOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / SCALE);
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }
}
