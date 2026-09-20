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
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";
import {AccrualSegments} from "../../src/libraries/AccrualSegments.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_AccrualDustFork: adversarial attacks on the six-decimal boundary of the accrual engine,
///        against the FULL protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice The stable leg is 6-decimal USDC; the claim leg is 18-decimal USDfr. Interest on a
///         1,000,001 USDC facility at 14% Actual/360 is 4,501,033,307,586,038 wei per second, which
///         is not a multiple of 1e12. This suite asks where every sub-USDC wei of that interest
///         settles when it is materialized, repaid or lost, and tries to make one of them vanish,
///         double-count, or land in the wrong pocket. The invariants attacked (CLAUDE.md 1.3):
///           I1. Backing: USDfr supply (physical and effective) never exceeds backing.
///           I2. Value conservation: every recognised wei is either issued or still unissued;
///               nothing is created or destroyed by the checkpoint schedule.
///           I3. Loss cascade ordering at the wei scale: curator, then sGROVE, then senior, never
///               skipped or inverted, never reachable by an unprivileged caller, and identical
///               whether the close is a repayment or a default declaration.
///           I4. sUSDfr fee-net exchange-rate integrity: yield alone cannot lower the rate; a
///               materialization or a fee crystallisation is exactly price-neutral.
///           I5. Access control on the fee configuration and the rounding-burn continuation.
///
///         Attacks (each outcome is unambiguous: a blocked attack asserts the specific custom
///         error and the untouched state; a legitimate operation asserts the exact wei):
///           A1. DUST ON MATERIALIZE: 20 materializations at odd second offsets versus one
///               materialization after the same elapsed time. Asserts equality to the wei for the
///               senior and fee legs separately, then locates the sub-slope remainder and proves it
///               is recognised at the segment boundary rather than lost.
///           A2. DUST ON REPAY: payments 1 wei and 1 USDC-unit either side of the exact contractual
///               interest. Asserts exactly which succeed, which revert and with which error, and
///               that the settlement leaves no wei nobody can claim.
///           A3. ROUNDING BURN WINDOW: the strict-equality balance windows around the curator and
///               sGROVE draws. Proves carol can hold USDfr and pre-position 1 wei on every measured
///               address, cannot execute inside the window, cannot reach the burn continuation
///               directly, and that the three-layer allocation then completes in the right order.
///           A4. SUPPLY versus BACKING AT THE BOUNDARY: 20 odd-offset materializations with fee
///               crystallisations interleaved. Asserts supply <= backing at every step and that the
///               fee-net rate never falls; the whole life of the facility conserves value to the wei.
///           A5. FEE LEG: every ordering of materializeAccrued(1), (2), (3) plus a mid-life fee-rate
///               change. Asserts fee + senior == gross and that the fee recipient never receives more
///               than floor(feeBps of gross), and that carol cannot touch the fee configuration.
///           A6. DEFAULT-DECLARATION CLOSE: the "or lost" half. A default declared at an offset whose
///               close over-recognises must allocate the dust in cascade order from inside the
///               declaration, leave the defaulted face at exactly principal plus grid interest, and
///               write off cleanly; carol can reach neither the stop nor the declaration.
///           A7. FEE RECIPIENT ALIASED TO THE VAULT: governance names the senior vault as the fee
///               recipient. The switch must pay the old recipient first; afterwards both legs must
///               be price-neutral, the vault must own the whole gross, and a rounding close must
///               deliver both legs before burning and leave the vault holding the grid interest.
contract ATK_AccrualDustForkTest is ForkLifecycleFixture {
    uint256 internal constant PRINCIPAL = 1_000_001e18;
    uint16 internal constant RATE_BPS = 1400;
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant YEAR = 360 days;
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant STEPS = 20;
    /// @dev Exact integer slope of the first technical segment for PRINCIPAL at RATE_BPS, in wei
    ///      per second. Pinned so a silent change to the grid arithmetic fails by name.
    uint256 internal constant EXPECTED_RATE = 4_501_033_307_586_038;

    /// @dev Declared locally so `vm.expectEmit` matches the real emissions by signature. The
    ///      library events surface from the reserve proxy because the libraries are delegatecalled.
    event AccrualMaterialized(uint256 indexed nonce, uint64 indexed at, uint8 legs, uint256 senior, uint256 fee);
    event AccrualRoundingAllocated(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint256 amount,
        uint256 prepaid,
        uint256 curator,
        uint256 backstop,
        uint256 senior,
        uint256 unabsorbed,
        uint256 markConsumed
    );
    event AccrualFeeConfigured(uint16 feeBps, address indexed recipient, uint64 indexed at);
    event AccruedLoanPosted(uint256 indexed facilityId, address indexed asset, uint256 amount, uint256 faceAfter);
    event AccrualLoanAligned(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint64 at,
        uint256 positiveCorrection,
        uint256 roundingLoss,
        bool stopped
    );
    event FeeRecipientSet(address indexed recipient);
    event DefaultDeclared(uint256 indexed tokenId, uint256 indexed classId, bytes32 remedyRef);
    event LossRealized(
        uint256 indexed tokenId,
        uint256 indexed classId,
        uint256 loss,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 depositorLoss
    );
    event LossAbsorbed(uint256 indexed classId, uint256 loss, uint256 absorbed, uint256 residual);
    event ShortfallCovered(address indexed caller, uint256 requested, uint256 covered);
    event LossBurned(address indexed from, uint256 amount);

    /// @dev Independent reference model of the facility's first technical segment, built from the
    ///      pure libraries so the on-chain book is checked against arithmetic it does not share.
    struct Model {
        AccrualSegments.Terms terms;
        uint64 start;
        uint64 end;
        uint256 segmentAmount;
        uint256 rate;
        uint256 remainder;
    }

    /// @dev Running tallies, kept in a struct to stay under the stack limit.
    struct Tally {
        uint256 senior;
        uint256 fee;
        uint256 elapsed;
        uint256 supply0;
        uint256 vault0;
        uint256 fee0;
    }

    /// @dev Per-layer figures of one rounding allocation.
    struct Layers {
        uint256 curator;
        uint256 backstop;
        uint256 senior;
        uint256 reserveBal;
    }

    /// @dev The fee-recipient switch of A7, kept in a struct to stay under the stack limit.
    struct Alias {
        address oldSink;
        uint256 oldClaim;
        uint256 rate0;
        uint256 assets0;
        uint256 grossAtChange;
        uint256 lastRate;
    }

    /// @dev The figures of one contractual close, kept in a struct to stay under the stack limit.
    struct Close {
        uint256 owed;
        uint256 full;
        uint256 streamed;
        uint256 loss;
        uint256 grossAfter;
        uint256 fee;
        uint256 supply0;
        uint256 vault0;
        uint256 feeSink0;
    }

    // ─────────────────────────────────────────────────────────────────────
    // A1. DUST ON MATERIALIZE (I2): the checkpoint schedule cannot create or lose a wei
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks value conservation (I2) at the six-decimal boundary. Twenty materializations
    ///         at odd second offsets are summed and compared, leg by leg, to one materialization
    ///         after the identical elapsed time. A difference of even one wei would mean the amount
    ///         the senior vault or the fee recipient is paid depends on how often a keeper calls the
    ///         permissionless functions, which is money an attacker could steer by timing. The test
    ///         then locates the sub-slope remainder (the wei below one-per-second granularity) and
    ///         proves it is recognised at the segment boundary, so over the segment every wei of
    ///         the grid-rounded contractual amount reaches a holder.
    function test_atk_dustOnMaterializeTelescopesToTheWei() public onFork {
        uint256 id = _fundDustFacility();
        uint64 t0 = uint64(block.timestamp);
        Model memory m = _model(id, t0);
        assertEq(m.rate, EXPECTED_RATE, "pinned integer slope of the first segment");
        assertTrue(m.rate % SCALE != 0, "precondition: one second of accrual is not on the USDC grid");
        assertGt(m.remainder, 0, "precondition: the segment amount is not an exact multiple of its duration");
        assertEq(waterfall.protocolFeeBps(), 1000, "deployed default protocol fee is 10% of interest");
        assertEq(
            reserves.accrualSnapshot().feeRecipient,
            waterfall.feeRecipient(),
            "book and waterfall agree on the fee recipient"
        );

        uint256 snap = vm.snapshotState();

        // ── Path N: twenty odd-offset checkpoints, each materialized by carol ──
        Tally memory n;
        n.supply0 = usdfr.totalSupply();
        n.vault0 = usdfr.balanceOf(address(vault));
        n.fee0 = usdfr.balanceOf(waterfall.feeRecipient());
        for (uint256 i; i < STEPS; ++i) {
            n.elapsed += _stepAndMaterialize(_oddOffset(i), m, n, i + 1);
        }
        assertEq(n.senior + n.fee, m.rate * n.elapsed, "N materializations sum to slope * elapsed, to the wei");
        emit log_named_uint("A1 integer slope, wei per second", m.rate);
        emit log_named_uint("A1 segment remainder, wei", m.remainder);
        emit log_named_uint("A1 elapsed seconds over 20 odd steps", n.elapsed);
        emit log_named_uint("A1 senior issued over 20 steps", n.senior);
        emit log_named_uint("A1 fee issued over 20 steps", n.fee);
        assertEq(
            n.fee, Math.mulDiv(m.rate * n.elapsed, 1000, Config.BPS), "fee is the cumulative floor of feeBps of gross"
        );
        assertEq(usdfr.balanceOf(address(vault)) - n.vault0, n.senior, "the vault holds every senior wei issued");
        assertEq(
            usdfr.balanceOf(waterfall.feeRecipient()) - n.fee0, n.fee, "the fee recipient holds every fee wei issued"
        );
        assertEq(reserves.roundingLossUnabsorbed(), 0, "no rounding loss exists before any close");

        // WHERE THE DUST SITS. The book streams an integer slope; the remainder of the segment
        // amount modulo its duration is not in gross, not in supply, not in unissued and not in
        // the unabsorbed counter. It is exactly floor(remainder * elapsed / duration) wei, strictly
        // less than one wei per elapsed second, and it is held back inside the book (its
        // `unearned` reservation) until reconcile or the segment boundary credits it.
        {
            uint256 lag = Math.mulDiv(m.segmentAmount, n.elapsed, m.end - m.start) - m.rate * n.elapsed;
            assertEq(
                lag,
                Math.mulDiv(m.remainder, n.elapsed, m.end - m.start),
                "sub-slope dust is the interpolated remainder"
            );
            assertLt(lag, n.elapsed, "sub-slope dust is below one wei per second");
            emit log_named_uint("A1 sub-slope dust held back in the book, wei", lag);
        }

        // Bounds against the contractual curve: the streamed amount never exceeds the unrounded
        // simple interest, and the grid-rounded contractual figure never exceeds it by more than
        // one USDC unit plus one wei per second.
        {
            uint256 canonical = AccrualSegments.cumulative(m.terms, uint64(block.timestamp));
            assertEq(reserves.accruedDebt(id).interest, canonical, "contractual grid interest agrees with the model");
            assertLe(
                m.rate * n.elapsed,
                AccrualMath.earnedInterest(PRINCIPAL, RATE_BPS, uint64(n.elapsed), YEAR),
                "streamed gross never exceeds the unrounded contractual interest"
            );
            assertLt(
                canonical,
                m.rate * n.elapsed + SCALE + n.elapsed,
                "grid interest exceeds streamed gross by less than 1e12 + elapsed"
            );
        }

        // One more second: exactly one slope unit is minted, sub-USDC precision intact.
        {
            _warp(1);
            n.elapsed += 1;
            vm.prank(carol);
            reserves.checkpointAccrual(32);
            vm.prank(carol);
            (uint256 s1, uint256 f1) = reserves.materializeAccrued(3);
            assertEq(s1 + f1, m.rate, "one second of accrual mints exactly 4,501,033,307,586,038 wei");
            n.senior += s1;
            n.fee += f1;
            assertEq(
                n.fee,
                Math.mulDiv(m.rate * n.elapsed, 1000, Config.BPS),
                "fee floor still cumulative after a one-second step"
            );
        }

        // ── Path 1: the same elapsed time, materialized once ──
        vm.revertToState(snap);
        require(block.timestamp == t0, "ATK: snapshot did not restore the clock");
        Tally memory one;
        one.supply0 = usdfr.totalSupply();
        _warp(n.elapsed);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        vm.prank(carol);
        (one.senior, one.fee) = reserves.materializeAccrued(3);
        assertEq(one.senior, n.senior, "a single materialization issues the identical senior leg, to the wei");
        assertEq(one.fee, n.fee, "a single materialization issues the identical fee leg, to the wei");
        assertEq(
            usdfr.totalSupply() - one.supply0, one.senior + one.fee, "single-path supply delta equals the issued claims"
        );

        // ── The boundary: the remainder is recognised at the segment's scheduled end, not lost ──
        _warp(m.end - block.timestamp);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, m.end, m.end));
        reserves.materializeAccrued(3);
        {
            vm.prank(carol);
            (uint256 processedAtEnd, bool freshAtEnd) = reserves.checkpointAccrual(32);
            assertEq(processedAtEnd, 1, "the segment boundary is processed by the permissionless keeper");
            assertTrue(freshAtEnd, "the book is fresh once the boundary is processed");
        }
        assertEq(
            reserves.accrualSnapshot().gross,
            m.segmentAmount,
            "the whole grid-rounded segment amount is recognised at its boundary"
        );
        {
            vm.prank(carol);
            (uint256 endSenior, uint256 endFee) = reserves.materializeAccrued(3);
            one.senior += endSenior;
            one.fee += endFee;
        }
        assertEq(
            one.senior + one.fee,
            m.segmentAmount,
            "every wei of the segment reached a holder: the slope remainder was recognised, not lost"
        );
        assertEq(
            one.fee, Math.mulDiv(m.segmentAmount, 1000, Config.BPS), "lifetime fee is floor(feeBps of the segment)"
        );
        assertEq(reserves.accrualSnapshot().unissued, 0, "nothing virtual remains at the boundary");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds at the boundary");
    }

    /// @dev One A1 step: warp an odd offset, checkpoint and materialize both legs as carol, and
    ///      assert the step's own conservation. Returns the offset warped.
    function _stepAndMaterialize(uint256 off, Model memory m, Tally memory n, uint256 expectedNonce)
        internal
        returns (uint256)
    {
        _warp(off);
        vm.prank(carol);
        (uint256 processed, bool fresh) = reserves.checkpointAccrual(32);
        assertEq(processed, 0, "no boundary is due inside the segment");
        assertTrue(fresh, "the book is fresh between boundaries");

        IContinuousAccrual.Snapshot memory before_ = reserves.accrualSnapshot();
        assertEq(before_.gross, m.rate * (n.elapsed + off), "gross is exactly the integer slope times elapsed seconds");

        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualMaterialized(expectedNonce, uint64(block.timestamp), 3, before_.seniorUnissued, before_.feeUnissued);
        vm.prank(carol);
        (uint256 s, uint256 f) = reserves.materializeAccrued(3);
        assertEq(s, before_.seniorUnissued, "senior leg issues exactly the unissued senior claim");
        assertEq(f, before_.feeUnissued, "fee leg issues exactly the unissued fee claim");
        n.senior += s;
        n.fee += f;

        IContinuousAccrual.Snapshot memory after_ = reserves.accrualSnapshot();
        assertEq(after_.unissued, 0, "nothing remains unissued after materialize(3)");
        assertEq(after_.gross, before_.gross, "materialization recognises nothing new (ADR-0038 point 4)");
        assertEq(usdfr.totalSupply() - n.supply0, n.senior + n.fee, "physical supply grew by exactly the issued claims");
        return off;
    }

    /// @dev The first odd extra offset after `elapsed` at which the contractual grid figure exceeds
    ///      the interpolated recognition, so a close there credits a positive correction.
    function _firstCorrectionOffset(Model memory m, uint256 elapsed) internal pure returns (uint256 off) {
        off = 1;
        for (uint256 i; i < 4096; ++i) {
            uint256 full = Math.mulDiv(m.segmentAmount, elapsed + off, m.end - m.start);
            uint256 canonical = AccrualSegments.cumulative(m.terms, uint64(m.start + elapsed + off));
            if (canonical > full) return off;
            off += 2;
        }
        revert("ATK: no offset with a positive correction found");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2. DUST ON REPAY (I2): the receipt settles on the grid, above the debt never
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the settlement identity in `ReserveAccrualCreditLib.repay` with receipts one
    ///         wei and one USDC-unit either side of the exact contractual interest. A payment above
    ///         the debt that succeeded would pull cash the borrower does not owe; a sub-unit leg
    ///         that succeeded would leave 18-decimal claims no 6-decimal receipt can settle. Records
    ///         precisely what `AccrualCredit_ReceiptMismatch` compares (normalised USDC received
    ///         versus principal + interest, and deployed face versus contractual face) and where it
    ///         sits: behind the waterfall's grid gate, the accrual library's grid check and the
    ///         debt and cash bounds, so it is unreachable through the sub-unit route and reached
    ///         only by a defect in `payAccrued` itself. The two settlements that do succeed are
    ///         asserted to the wei, including the rounding loss the close burns from the senior
    ///         layer, which the deterministic offset guarantees.
    function test_atk_dustOnRepaySettlesOnTheGridOnly() public onFork {
        uint256 id = _fundDustFacility();
        uint64 t0 = uint64(block.timestamp);
        Model memory m = _model(id, t0);
        _warp(33 days + 4321); // odd
        vm.prank(carol);
        reserves.checkpointAccrual(32);

        Close memory c;
        c.owed = reserves.accruedDebt(id).interest;
        assertEq(c.owed % SCALE, 0, "contractual interest is quoted on the USDC grid");
        assertEq(
            c.owed, AccrualSegments.cumulative(m.terms, uint64(block.timestamp)), "quoted interest matches the model"
        );
        c.full = Math.mulDiv(m.segmentAmount, block.timestamp - t0, m.end - m.start); // recognised at close
        c.streamed = reserves.accrualSnapshot().gross;
        assertEq(c.streamed, m.rate * (block.timestamp - t0), "streamed gross before the close");
        assertEq(reserves.deployedTo(id), PRINCIPAL + c.streamed, "deployed face carries the streamed receivable");
        c.supply0 = usdfr.totalSupply();

        // ATTACK: one wei above the grid. The waterfall's own grid gate (`denormalizeUSDC`) fires
        // before the attestation is inspected and before any cash moves. Established by seeding
        // defects (never by production code): gate 2 is the accrual library's grid check
        // `AccrualLoans_BadPayment`; gate 3 is `AccrualLoans_PaymentAboveDebt` for a receipt above
        // the debt and `ReserveManager_PrincipalExceedsPayment(total, received)` from
        // `ReserveCreditLib._pay` for one below it, because the face reduction asked for is the
        // 18-decimal total while the USDC pulled is its floor. `AccrualCredit_ReceiptMismatch`
        // sits behind all three and is reached only by a defect in `payAccrued` itself.
        _attemptInterestPayment(
            id,
            c.owed + 1,
            "a2-plus-wei",
            abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, c.owed + 1)
        );
        // ATTACK: one wei below the grid.
        _attemptInterestPayment(
            id,
            c.owed - 1,
            "a2-minus-wei",
            abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, c.owed - 1)
        );
        // ATTACK: one whole USDC unit above the debt. On the grid, but more than is owed.
        _attemptInterestPayment(
            id,
            c.owed + SCALE,
            "a2-plus-unit",
            abi.encodeWithSelector(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector)
        );
        assertEq(usdfr.totalSupply(), c.supply0, "rejected receipts minted nothing");
        assertEq(reserves.deployedTo(id), PRINCIPAL + c.streamed, "rejected receipts changed no face");
        assertEq(reserves.accruedDebt(id).interest, c.owed, "rejected receipts changed no debt");
        assertEq(reserves.accrualSnapshot().gross, c.streamed, "rejected receipts recognised nothing");

        // LEGITIMATE: one whole USDC unit below the debt settles, leaving exactly 1e12 owed.
        c.vault0 = usdfr.balanceOf(address(vault));
        c.feeSink0 = usdfr.balanceOf(waterfall.feeRecipient());
        assertGt(c.full, c.owed, "the deterministic offset lands the close on the over-recognition side");
        c.loss = c.full - c.owed;
        c.grossAfter = c.full;
        c.fee = Math.mulDiv(c.grossAfter, waterfall.protocolFeeBps(), Config.BPS);
        emit log_named_uint("A2 contractual grid interest owed", c.owed);
        emit log_named_uint("A2 streamed gross before close", c.streamed);
        emit log_named_uint("A2 interpolated recognition at close", c.full);
        emit log_named_uint("A2 rounding loss burned from senior", c.loss);
        {
            IWaterfallEngine.Payment memory p = _prepPayment(id, c.owed - SCALE, 0, "a2-minus-unit");
            // The close over-recognised by `loss` wei (below one USDC unit). Nothing junior is
            // seeded here, so the senior layer bears it in full after its claim is made physical.
            vm.expectEmit(true, true, true, true, address(reserves));
            emit AccrualRoundingAllocated(id, 1, c.loss, 0, 0, 0, c.loss, 0, 0);
            vm.expectEmit(true, true, true, true, address(reserves));
            emit AccrualLoanAligned(id, 1, uint64(block.timestamp), 0, c.loss, false);
            _settle(p);
        }

        assertEq(reserves.accruedDebt(id).interest, SCALE, "exactly one USDC unit of interest remains owed");
        assertEq(reserves.deployedTo(id), PRINCIPAL + SCALE, "deployed face is principal plus the one unit still owed");
        assertEq(
            reserves.accrualSnapshot().gross, c.grossAfter, "gross after the close is max(interpolated, contractual)"
        );
        assertEq(reserves.roundingLossUnabsorbed(), 0, "the senior layer absorbed the whole rounding loss");
        assertEq(
            usdfr.balanceOf(address(vault)) - c.vault0,
            c.grossAfter - c.fee - c.loss,
            "vault: senior claim made physical, then the sub-unit over-recognition burned"
        );
        assertEq(usdfr.totalSupply() - c.supply0, c.grossAfter - c.fee - c.loss, "supply: senior leg minus the burn");
        assertEq(reserves.accrualSnapshot().feeUnissued, c.fee, "the fee claim stays virtual and intact");
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0, "no senior claim remains virtual after the close");
        // DOCUMENTED DESIGN (ReserveRoundingLib: "both earned fee claims are retained"): the fee
        // recipient keeps feeBps of the over-recognised dust while the senior layer bears the
        // whole burn. Per close this is below feeBps of one USDC unit; it is quantified here so
        // the transfer from senior to fee recipient is visible rather than assumed.
        {
            uint256 feeOnDust = c.fee - Math.mulDiv(c.owed, waterfall.protocolFeeBps(), Config.BPS);
            assertLe(
                feeOnDust,
                Math.mulDiv(SCALE, waterfall.protocolFeeBps(), Config.BPS) + 1,
                "fee on dust is below feeBps of one unit"
            );
            emit log_named_uint("A2 fee claim on the burned dust, retained by the fee recipient (by design)", feeOnDust);
        }
        assertEq(
            usdfr.balanceOf(waterfall.feeRecipient()),
            c.feeSink0,
            "the fee recipient received nothing physical at the close"
        );
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds after the partial settlement");

        // LEGITIMATE: the remaining unit settles exactly; the same-block close recognises nothing new.
        _settle(_prepPayment(id, SCALE, 0, "a2-exact-remainder"));
        assertEq(reserves.accruedDebt(id).interest, 0, "no interest remains owed");
        assertEq(reserves.deployedTo(id), PRINCIPAL, "deployed face is exactly the principal");
        assertEq(reserves.accrualSnapshot().gross, c.grossAfter, "a same-block close recognises nothing twice");

        // ATTACK: one more unit above the now-zero interest debt.
        _attemptInterestPayment(
            id, SCALE, "a2-above-zero", abi.encodeWithSelector(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector)
        );
        assertEq(reserves.deployedTo(id), PRINCIPAL, "the rejected overpayment changed no face");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds after the exact settlement");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3. ROUNDING BURN WINDOW (I3, I5): the strict-equality windows cannot be entered
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the strict-equality measurement windows in `ReserveRoundingLib._curator`
    ///         (measurement 6) and `_backstop` (measurement 9), and the balance identity in
    ///         `allocate` (measurement 1). If a permissionless actor could land one wei on the
    ///         reserve inside a window, every rounding close would revert and no accruing facility
    ///         could be repaid, amended or declared in default: a liveness failure over the whole
    ///         book. The test proves the strongest permissionless attempt: carol obtains USDfr
    ///         (holding is not KYC-gated; only minting is), pre-positions one wei on every measured
    ///         address, and tries each window entry point directly. Then the legitimate close runs
    ///         with all three junior layers seeded at wei scale, and the allocation must complete
    ///         in cascade order with the exact per-layer amounts.
    function test_atk_roundingBurnWindowCannotBeEnteredPermissionlessly() public onFork {
        uint256 id = _fundDustFacility();
        Model memory m = _model(id, uint64(block.timestamp));
        Close memory c;
        Layers memory l;

        // Choose the first odd offset whose close over-recognises by at least 1,000 wei, so the
        // three-layer allocation is exercised. Deterministic: derived from the fork block clock.
        (uint256 off, uint256 loss) = _firstLossOffset(m);
        _warp(off);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        c.owed = reserves.accruedDebt(id).interest;
        c.loss = loss;
        c.grossAfter = c.owed + c.loss;
        c.fee = Math.mulDiv(c.grossAfter, waterfall.protocolFeeBps(), Config.BPS);
        assertLt(c.loss, SCALE, "the proved discrepancy is below one USDC unit");

        // Seed the two junior layers so that neither can absorb the whole loss: curator takes a
        // third, sGROVE takes the next third plus seven wei, senior takes the rest.
        l.curator = c.loss / 3;
        l.backstop = c.loss / 3 + 7;
        l.senior = c.loss - l.curator - l.backstop;
        _postFirstLossOps(l.curator);
        _fundCoverageOps(l.backstop);
        assertEq(curator.poolBalance(FILM), l.curator, "layer 1 seeded");
        assertEq(sGrove.coverageReserve(), l.backstop, "layer 2 seeded");
        emit log_named_uint("A3 offset seconds", off);
        emit log_named_uint("A3 rounding loss at close", c.loss);
        emit log_named_uint("A3 curator absorbs", l.curator);
        emit log_named_uint("A3 sGROVE absorbs", l.backstop);
        emit log_named_uint("A3 senior absorbs", l.senior);

        // A non-KYC address can HOLD USDfr: transfer is permissionless, only mint/redeem is gated.
        vm.prank(alice);
        usdfr.transfer(carol, 2);
        assertEq(usdfr.balanceOf(carol), 2, "carol holds USDfr without KYC");

        // Strongest permissionless attempt: pre-position one wei on every measured address. These
        // land BEFORE the windows open, so both sides of every strict equality include them.
        vm.prank(carol);
        usdfr.transfer(address(reserves), 1);
        vm.prank(carol);
        usdfr.transfer(address(vault), 1);

        // The window machinery itself is unreachable from carol.
        vm.prank(carol);
        vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
        reserves.consumeAccrualLossBurn(address(reserves), address(vault), 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.LOSS_BURNER_ROLE
            )
        );
        controller.burnLoss(address(vault), 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        curator.absorbLoss(FILM, 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        sGrove.coverShortfall(id, 1);
        assertEq(curator.poolBalance(FILM), l.curator, "layer 1 untouched by the rejected calls");
        assertEq(sGrove.coverageReserve(), l.backstop, "layer 2 untouched by the rejected calls");

        // The legitimate close: exact interest receipt. The rounding loss must allocate in order.
        l.reserveBal = usdfr.balanceOf(address(reserves));
        c.vault0 = usdfr.balanceOf(address(vault));
        c.supply0 = usdfr.totalSupply();

        IWaterfallEngine.Payment memory p = _prepPayment(id, c.owed, 0, "a3-exact");
        vm.expectEmit(true, true, true, true, address(curator));
        emit LossAbsorbed(FILM, c.loss, l.curator, c.loss - l.curator);
        vm.expectEmit(true, true, true, true, address(sGrove));
        emit ShortfallCovered(address(reserves), c.loss - l.curator, l.backstop);
        vm.expectEmit(true, true, true, true, address(controller));
        emit LossBurned(address(reserves), l.curator + l.backstop);
        vm.expectEmit(true, true, true, true, address(controller));
        emit LossBurned(address(vault), l.senior);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualRoundingAllocated(id, 1, c.loss, 0, l.curator, l.backstop, l.senior, 0, 0);
        _settle(p);

        assertEq(curator.poolBalance(FILM), 0, "layer 1 consumed first, in full");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 consumed second, in full");
        assertEq(
            usdfr.balanceOf(address(reserves)),
            l.reserveBal,
            "reserve balance unchanged: junior draws burned, the donation retained"
        );
        assertEq(
            usdfr.balanceOf(address(vault)) - c.vault0,
            c.grossAfter - c.fee - l.senior,
            "vault: senior claim made physical, then only the residual burned"
        );
        assertEq(
            usdfr.totalSupply() - c.supply0, c.grossAfter - c.fee - c.loss, "supply: senior leg minus the whole loss"
        );
        assertEq(reserves.roundingLossUnabsorbed(), 0, "nothing unabsorbed");
        assertEq(reserves.accruedDebt(id).interest, 0, "the exact receipt settled all interest");
        assertEq(reserves.deployedTo(id), PRINCIPAL, "deployed face is exactly the principal");
        assertEq(usdfr.balanceOf(carol), 0, "carol's two wei sit on the measured addresses, not consumed");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds after the ordered allocation");
    }

    /// @dev The first odd offset from five days whose close over-recognises by at least 1,000 wei.
    function _firstLossOffset(Model memory m) internal pure returns (uint256 off, uint256 loss) {
        return _firstLossOffsetFrom(m, 0, 5 days + 1);
    }

    /// @dev The first odd extra offset at or after `first`, on top of `elapsed`, whose close
    ///      over-recognises by at least 1,000 wei. Deterministic: a pure function of the model.
    function _firstLossOffsetFrom(Model memory m, uint256 elapsed, uint256 first)
        internal
        pure
        returns (uint256 off, uint256 loss)
    {
        off = first | 1;
        for (uint256 i; i < 64; ++i) {
            uint256 full = Math.mulDiv(m.segmentAmount, elapsed + off, m.end - m.start);
            uint256 canonical = AccrualSegments.cumulative(m.terms, uint64(m.start + elapsed + off));
            if (full > canonical && full - canonical >= 1000) return (off, full - canonical);
            off += 2;
        }
        revert("ATK: no offset with a rounding loss found");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4. SUPPLY versus BACKING AT THE BOUNDARY (I1, I4)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the backing invariant (I1) and the fee-net rate (I4) with twenty odd-offset
    ///         materializations and interleaved permissionless fee crystallisations. A step where
    ///         supply exceeded backing would be an unbacked mint; a step where the fee-net rate fell
    ///         without a loss event would be a senior holder paying for a virtual-to-physical
    ///         conversion or a fee mint (the ADR-0031 second price jump). The facility is then
    ///         repaid in full and the whole life is reconciled to the wei: supply change equals the
    ///         cash interest received, the fee recipient holds floor(feeBps of gross), and the vault
    ///         holds the rest less the allocated rounding burn.
    function test_atk_supplyNeverExceedsBackingAndFeeNetRateIsMonotone() public onFork {
        uint256 id = _fundDustFacility();
        uint64 t0 = uint64(block.timestamp);
        Model memory m = _model(id, t0);
        Tally memory t;
        t.supply0 = usdfr.totalSupply();
        t.vault0 = usdfr.balanceOf(address(vault));
        t.fee0 = usdfr.balanceOf(waterfall.feeRecipient());
        _assertBacked(id, "after funding");
        uint256 lastRate = vault.currentExchangeRate();

        for (uint256 i; i < STEPS; ++i) {
            uint256 off = _oddOffset(i);
            _warp(off);
            t.elapsed += off;
            uint256 r1 = vault.currentExchangeRate();
            assertGt(r1, lastRate, "the fee-net rate rises with recognised time (yield alone never lowers it)");
            vm.prank(carol);
            reserves.checkpointAccrual(32);
            assertEq(vault.currentExchangeRate(), r1, "a checkpoint is exactly price-neutral");
            _assertBacked(id, "after checkpoint");

            vm.prank(carol);
            (uint256 s, uint256 f) = reserves.materializeAccrued(3);
            t.senior += s;
            t.fee += f;
            assertEq(
                vault.currentExchangeRate(), r1, "materialization is exactly price-neutral: virtual became physical"
            );
            _assertBacked(id, "after materialization");

            if (i % 3 == 2) {
                vm.prank(carol);
                vault.accrueFees();
                assertEq(vault.currentExchangeRate(), r1, "fee crystallisation creates no second price jump (ADR-0031)");
                _assertBacked(id, "after fee crystallisation");
            }
            lastRate = r1;
        }
        assertEq(t.senior + t.fee, m.rate * t.elapsed, "twenty steps issued exactly slope * elapsed");

        // One more searched odd step lands the close on the side A2 and A3 do not exercise: the
        // contractual grid figure ABOVE the interpolated recognition, so the close must credit a
        // positive correction rather than burn. Deterministic: derived from the fork block clock.
        t.elapsed += _stepAndMaterialize(_firstCorrectionOffset(m, t.elapsed), m, t, STEPS + 1);
        _assertBacked(id, "after the searched step");

        // Full repayment at the exact contractual figures closes the facility. The searched step
        // guarantees the close credits a positive correction (asserted through the alignment
        // event) rather than burning, so lifetime gross is the contractual grid figure.
        uint256 owed = reserves.accruedDebt(id).interest;
        uint256 full = Math.mulDiv(m.segmentAmount, t.elapsed, m.end - m.start);
        assertGt(owed, full, "the searched step put the contractual figure above the interpolation");
        uint256 grossFinal = owed;
        emit log_named_uint("A4 elapsed seconds", t.elapsed);
        emit log_named_uint("A4 streamed gross (issued over 21 steps)", t.senior + t.fee);
        emit log_named_uint("A4 interpolated recognition at close", full);
        emit log_named_uint("A4 contractual grid interest at close", owed);
        emit log_named_uint("A4 positive correction credited at close", owed - full);
        uint256 assetsBefore = vault.totalAssets();
        uint16 feeBps = waterfall.protocolFeeBps();
        uint256 feeFinal = Math.mulDiv(grossFinal, feeBps, Config.BPS);
        {
            IWaterfallEngine.Payment memory p = _prepPayment(id, owed, PRINCIPAL, "a4-full");
            // A positive correction: `prepare` delivers nothing and no burn is allocated; the
            // correction is credited to the book and stays virtual until the sweep below.
            vm.expectEmit(true, true, true, true, address(reserves));
            emit AccrualLoanAligned(id, 1, uint64(block.timestamp), owed - full, 0, true);
            _settle(p);
        }
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid), "facility Repaid");
        assertEq(reserves.deployedTo(id), 0, "no face remains");
        assertEq(reserves.accrualSnapshot().gross, grossFinal, "lifetime gross is max(interpolated, contractual)");
        _assertBacked(id, "after full repayment");

        // No burn was allocated, so the close moves the vault's assets by exactly the senior share
        // of the correction. Before the close every streamed claim was physical (t.senior); after
        // it the vault carries the senior share of grossFinal, physical or virtual.
        assertEq(
            vault.totalAssets(),
            assetsBefore + (grossFinal - feeFinal) - t.senior,
            "vault assets after the close reconcile to the model, to the wei"
        );

        // Sweep the last virtual claims and reconcile the whole life of the facility from balances,
        // so the senior leg the close itself materialized is counted.
        {
            vm.prank(carol);
            (uint256 sEnd, uint256 fEnd) = reserves.materializeAccrued(3);
            assertEq(sEnd, grossFinal - feeFinal - t.senior, "senior sweep is the senior share of the correction");
            assertEq(fEnd, feeFinal - t.fee, "fee sweep is the remaining fee claim");
        }
        assertEq(reserves.accrualSnapshot().unissued, 0, "nothing virtual remains");
        assertEq(controller.totalUSDfr(), usdfr.totalSupply(), "effective supply equals physical supply once swept");
        uint256 seniorIssued = usdfr.balanceOf(address(vault)) - t.vault0;
        uint256 feeIssued = usdfr.balanceOf(waterfall.feeRecipient()) - t.fee0;
        assertEq(seniorIssued + feeIssued, grossFinal, "lifetime issuance equals lifetime gross, to the wei");
        assertEq(feeIssued, feeFinal, "the fee recipient received exactly floor(feeBps of gross)");
        assertEq(seniorIssued, grossFinal - feeFinal, "the vault received exactly gross minus the fee");
        assertEq(
            usdfr.totalSupply() - t.supply0,
            owed,
            "over the whole life, supply grew by exactly the cash interest received"
        );
        _assertBacked(id, "after the final sweep");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5. FEE LEG (I2, I5): fee + senior == gross under every leg ordering
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the fee split under every ordering of materializeAccrued(1), (2), (3) and
    ///         across a mid-life fee-rate change to the permanent maximum. If the fee recipient
    ///         could be paid more than floor(feeBps of recognised gross) by choosing which leg to
    ///         call first, the difference would be senior money moved to the protocol's own
    ///         recipient. Also proves carol cannot configure the fee on either host and cannot
    ///         request an invalid leg mask.
    function test_atk_feeLegNeverExceedsFeeBpsOfGrossUnderAnyOrdering() public onFork {
        uint256 id = _fundDustFacility();
        uint64 t0 = uint64(block.timestamp);
        Model memory m = _model(id, t0);
        address feeSink = waterfall.feeRecipient();
        assertEq(reserves.accrualSnapshot().feeRecipient, feeSink, "book fee recipient is the waterfall's");
        assertTrue(controller.isYieldSink(feeSink), "the fee recipient is an authorised yield sink");

        // ATTACK: the fee configuration is unreachable from carol on both hosts.
        vm.prank(carol);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotWaterfall.selector);
        reserves.setAccrualFee(Config.MAX_PROTOCOL_FEE_BPS, carol);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        waterfall.setProtocolFee(Config.MAX_PROTOCOL_FEE_BPS);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        waterfall.setFeeRecipient(carol);
        // ATTACK: an out-of-range leg mask.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidLegs.selector, uint8(4)));
        reserves.materializeAccrued(4);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidLegs.selector, uint8(0)));
        reserves.materializeAccrued(0);
        assertEq(reserves.accrualSnapshot().feeRecipient, feeSink, "fee recipient unchanged by the rejected calls");
        assertEq(waterfall.protocolFeeBps(), 1000, "fee rate unchanged by the rejected calls");

        uint8[12] memory legs = [1, 2, 3, 2, 1, 1, 3, 2, 2, 1, 3, 3];
        Tally memory t;
        t.supply0 = usdfr.totalSupply();
        t.vault0 = usdfr.balanceOf(address(vault));
        t.fee0 = usdfr.balanceOf(feeSink);
        uint256 grossAtChange;
        uint256 feeAtChange;
        for (uint256 i; i < legs.length; ++i) {
            uint256 off = _oddOffset(i);
            _warp(off);
            t.elapsed += off;
            vm.prank(carol);
            reserves.checkpointAccrual(32);
            IContinuousAccrual.Snapshot memory before_ = reserves.accrualSnapshot();
            vm.prank(carol);
            (uint256 s, uint256 f) = reserves.materializeAccrued(legs[i]);
            assertEq(
                s, (legs[i] & 1) == 0 ? 0 : before_.seniorUnissued, "senior leg issued iff selected, exactly the claim"
            );
            assertEq(f, (legs[i] & 2) == 0 ? 0 : before_.feeUnissued, "fee leg issued iff selected, exactly the claim");
            t.senior += s;
            t.fee += f;

            IContinuousAccrual.Snapshot memory after_ = reserves.accrualSnapshot();
            assertEq(after_.gross, m.rate * t.elapsed, "gross is the integer slope times elapsed");
            uint256 expectedFee = grossAtChange == 0
                ? Math.mulDiv(after_.gross, 1000, Config.BPS)
                : feeAtChange + Math.mulDiv(after_.gross - grossAtChange, Config.MAX_PROTOCOL_FEE_BPS, Config.BPS);
            assertEq(t.fee + after_.feeUnissued, expectedFee, "issued + unissued fee is exactly the epoch-wise floor");
            assertLe(t.fee, expectedFee, "the fee recipient never holds more than floor(feeBps of gross)");
            assertEq(t.senior + t.fee + after_.unissued, after_.gross, "issued + unissued == gross, to the wei");
            assertEq(usdfr.balanceOf(feeSink) - t.fee0, t.fee, "fee recipient balance equals the fee issued");
            assertEq(usdfr.balanceOf(address(vault)) - t.vault0, t.senior, "vault balance equals the senior issued");
            assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds under every leg ordering");

            if (i == 5) {
                // Governance raises the fee to the permanent maximum mid-segment. The old epoch must
                // close at the old rate; only later gross is charged at the new rate.
                grossAtChange = after_.gross;
                feeAtChange = Math.mulDiv(grossAtChange, 1000, Config.BPS);
                vm.expectEmit(true, true, true, true, address(reserves));
                emit AccrualFeeConfigured(Config.MAX_PROTOCOL_FEE_BPS, feeSink, uint64(block.timestamp));
                vm.prank(ops);
                waterfall.setProtocolFee(Config.MAX_PROTOCOL_FEE_BPS);
                assertEq(
                    t.fee + reserves.accrualSnapshot().feeUnissued,
                    feeAtChange,
                    "the fee claim is unchanged at the instant of the change"
                );
            }
        }

        // Final sweep of both legs: fee + senior == gross exactly, fee == the epoch-wise floor.
        vm.prank(carol);
        (uint256 sEnd, uint256 fEnd) = reserves.materializeAccrued(3);
        t.senior += sEnd;
        t.fee += fEnd;
        uint256 gross = reserves.accrualSnapshot().gross;
        uint256 feeFinal = feeAtChange + Math.mulDiv(gross - grossAtChange, Config.MAX_PROTOCOL_FEE_BPS, Config.BPS);
        assertEq(reserves.accrualSnapshot().unissued, 0, "nothing virtual remains");
        emit log_named_uint("A5 gross at the fee change", grossAtChange);
        emit log_named_uint("A5 lifetime gross", gross);
        emit log_named_uint("A5 lifetime fee", t.fee);
        assertEq(t.fee, feeFinal, "lifetime fee is floor(10% of the first epoch) + floor(20% of the second)");
        assertEq(t.senior, gross - feeFinal, "the senior leg is exactly gross minus the fee");
        assertEq(usdfr.totalSupply() - t.supply0, gross, "supply grew by exactly gross");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6. DEFAULT-DECLARATION CLOSE (I2, I3, I5): the "or lost" half of the question
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the close a default declaration forces (`DefaultManager.declareDefault`
    ///         -> `ReserveManager.stopAccruingLoan` -> `AccrualLoans.stop`) at an offset whose
    ///         interpolated recognition exceeds the contractual grid figure. The stop posts the
    ///         whole earned claim into recorded face before the default snapshot, so a wei of
    ///         over-recognition that survived it would be a permanently defaulted receivable
    ///         nobody owes: marked against the senior exit price, then written off from the
    ///         vault. Proves carol can reach neither the stop nor the declaration; that from
    ///         inside the declaration the loss allocates curator, sGROVE, senior in order with
    ///         exact per-layer amounts; that the defaulted face is exactly principal plus grid
    ///         interest; and then writes the whole face off and reconciles the life of the
    ///         facility to the wei, quantifying the fee claim retained on interest the borrower
    ///         never paid (ADR-0038 Q4: fees are charged on accrual).
    function test_atk_defaultDeclarationCloseAllocatesRoundingLossInOrder() public onFork {
        uint256 id = _fundDustFacility();
        Model memory m = _model(id, uint64(block.timestamp));
        Close memory c;
        Layers memory l;
        (uint256 off, uint256 loss) = _firstLossOffset(m);
        _warp(off);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        c.owed = reserves.accruedDebt(id).interest;
        c.loss = loss;
        c.full = c.owed + c.loss;
        c.streamed = reserves.accrualSnapshot().gross;
        c.fee = Math.mulDiv(c.full, waterfall.protocolFeeBps(), Config.BPS);
        assertEq(c.full, Math.mulDiv(m.segmentAmount, off, m.end - m.start), "interpolated recognition at the stop");
        l.curator = c.loss / 3;
        l.backstop = c.loss / 3 + 7;
        l.senior = c.loss - l.curator - l.backstop;
        _postFirstLossOps(l.curator);
        _fundCoverageOps(l.backstop);
        emit log_named_uint("A6 offset seconds", off);
        emit log_named_uint("A6 contractual grid interest at the stop", c.owed);
        emit log_named_uint("A6 interpolated recognition at the stop", c.full);
        emit log_named_uint("A6 rounding loss allocated inside the declaration", c.loss);

        // ATTACK: carol can neither stop the clock nor declare the default.
        bytes32 evidence = keccak256("a6-default-evidence");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, address(defaultManager), carol
            )
        );
        reserves.stopAccruingLoan(id);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.declareDefault(id, evidence);
        assertTrue(reserves.accruedDebt(id).active, "the clock still runs after the rejected calls");
        assertEq(reserves.deployedTo(id), PRINCIPAL + c.streamed, "no face was posted by the rejected calls");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "still Active");

        // LEGITIMATE: the attested declaration. The events must appear in cascade order.
        c.supply0 = usdfr.totalSupply();
        c.vault0 = usdfr.balanceOf(address(vault));
        c.feeSink0 = usdfr.balanceOf(waterfall.feeRecipient());
        l.reserveBal = usdfr.balanceOf(address(reserves));
        uint256 rateBefore = vault.currentExchangeRate();
        _attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidence)));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualMaterialized(1, uint64(block.timestamp), 1, c.full - c.fee, 0);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccruedLoanPosted(id, USDC, c.full, PRINCIPAL + c.full);
        vm.expectEmit(true, true, true, true, address(curator));
        emit LossAbsorbed(FILM, c.loss, l.curator, c.loss - l.curator);
        vm.expectEmit(true, true, true, true, address(sGrove));
        emit ShortfallCovered(address(reserves), c.loss - l.curator, l.backstop);
        vm.expectEmit(true, true, true, true, address(controller));
        emit LossBurned(address(reserves), l.curator + l.backstop);
        vm.expectEmit(true, true, true, true, address(controller));
        emit LossBurned(address(vault), l.senior);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualRoundingAllocated(id, 1, c.loss, 0, l.curator, l.backstop, l.senior, 0, 0);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualLoanAligned(id, 1, uint64(block.timestamp), 0, c.loss, true);
        vm.expectEmit(true, true, false, false, address(defaultManager));
        emit DefaultDeclared(id, FILM, bytes32(0));
        vm.prank(ops);
        defaultManager.declareDefault(id, evidence);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "Defaulted");
        {
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            assertFalse(d.active, "the contractual clock is permanently stopped");
            assertEq(d.principal, PRINCIPAL, "principal untouched by the stop");
            assertEq(d.interest, c.owed, "stopped interest is exactly the grid figure");
        }
        assertEq(
            reserves.deployedTo(id),
            PRINCIPAL + c.owed,
            "defaulted face is principal plus grid interest: the over-recognition was written off, not defaulted"
        );
        assertEq(reserves.accrualSnapshot().unposted, 0, "nothing virtual is left in face after the stop");
        assertEq(reserves.accrualSnapshot().gross, c.full, "gross recognised is the interpolated figure");
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0, "the senior claim was made physical before the burn");
        assertEq(reserves.accrualSnapshot().feeUnissued, c.fee, "the fee claim stays virtual and intact");
        assertEq(reserves.roundingLossUnabsorbed(), 0, "nothing unabsorbed");
        assertEq(curator.poolBalance(FILM), 0, "layer 1 consumed first, in full");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 consumed second, in full");
        assertEq(usdfr.balanceOf(address(reserves)), l.reserveBal, "reserve balance unchanged: junior draws burned");
        assertEq(
            usdfr.balanceOf(address(vault)) - c.vault0,
            c.full - c.fee - l.senior,
            "vault: senior claim made physical, then only the residual burned"
        );
        assertEq(usdfr.totalSupply() - c.supply0, c.full - c.fee - c.loss, "supply: senior leg minus the whole loss");
        assertEq(usdfr.balanceOf(waterfall.feeRecipient()), c.feeSink0, "the fee recipient received nothing physical");
        assertEq(defaultManager.defaultedContribution(id), PRINCIPAL + c.owed, "impairment pool carries the grid face");
        assertEq(
            defaultManager.declaredDefaultedPrincipal(FILM), PRINCIPAL + c.owed, "class pool carries the grid face"
        );
        assertEq(
            defaultManager.performanceFeeImpairment(), PRINCIPAL + c.owed, "performance mark carries the grid face"
        );
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "the conservative exit mark is live");
        assertLt(vault.currentExchangeRate(), rateBefore, "the declaration is the loss event that lowers the rate");
        _assertBacked(id, "after the declaration");

        // THE LOST HALF: write the whole defaulted face off. Both junior layers are empty now,
        // so the vault bears it all; the write-off must retire the loan and the fee claim on
        // interest that was never collected must survive as the fee recipient's.
        uint256 face = PRINCIPAL + c.owed;
        bytes32 lossEvidence = _attestLoss(id, face, keccak256("a6-loss-evidence"));
        vm.expectEmit(true, true, true, true, address(controller));
        emit LossBurned(address(vault), face);
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit LossRealized(id, FILM, face, 0, 0, face);
        vm.prank(ops);
        defaultManager.realizeLoss(id, face, lossEvidence);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "Resolved");
        assertEq(reserves.deployedTo(id), 0, "no face remains");
        {
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            assertEq(d.principal + d.interest, 0, "no contractual debt remains");
            assertFalse(d.active, "retired");
        }
        assertEq(defaultManager.defaultedContribution(id), 0, "impairment pool released");
        assertEq(reserves.accrualSnapshot().feeUnissued, c.fee, "the fee claim survives the write-off");
        _assertBacked(id, "after the write-off");
        {
            vm.prank(carol);
            (uint256 sEnd, uint256 fEnd) = reserves.materializeAccrued(3);
            assertEq(sEnd, 0, "no senior claim remains");
            assertEq(fEnd, c.fee, "the fee recipient sweeps floor(feeBps of the interpolated gross)");
        }
        assertEq(reserves.accrualSnapshot().unissued, 0, "nothing virtual remains");
        assertEq(controller.totalUSDfr(), usdfr.totalSupply(), "effective supply equals physical supply once swept");
        assertEq(
            c.supply0 - usdfr.totalSupply(),
            PRINCIPAL,
            "over the whole life supply fell by exactly the principal: every wei of recognised interest was either burned as dust or written off, and the fee on it re-minted"
        );
        assertEq(
            c.vault0 - usdfr.balanceOf(address(vault)),
            PRINCIPAL + c.fee - l.curator - l.backstop,
            "the vault lost principal plus the fee on uncollected interest, less what the junior layers absorbed"
        );
        assertEq(usdfr.balanceOf(waterfall.feeRecipient()) - c.feeSink0, c.fee, "the fee recipient holds the fee");
        // DOCUMENTED DESIGN (ADR-0038 Q4, "Consequences": fees become economically due on interest
        // that may never arrive; the owner chose accrual). Quantified so the transfer from the
        // senior tranche to the fee recipient at default is visible rather than assumed.
        emit log_named_uint(
            "A6 fee claim on interest the borrower never paid, retained by the fee recipient (by design)", c.fee
        );
        _assertBacked(id, "after the final sweep");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A7. FEE RECIPIENT ALIASED TO THE VAULT (I1, I2, I4, I5)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the branch every fee-recipient comparison flips when governance names the
    ///         senior vault itself as the fee recipient: `VaultAccrualLib.entryAssets` (the vault
    ///         owns the virtual fee), `ReserveRoundingLib._unissuedVaultAssets` and
    ///         `prepareNativeLoss` (both legs must be physical before a burn), and the delivery
    ///         proof's `vaultMinted` (both legs land on one address). The switch itself must pay
    ///         the old recipient's earned claim first: a wei of it reaching the vault would be the
    ///         old recipient's money handed to senior holders. After the switch every
    ///         materialization and crystallisation must be price-neutral, the vault must own the
    ///         whole recognised gross, and a rounding close must deliver both legs before the burn
    ///         and leave the vault holding exactly the contractual grid interest.
    function test_atk_feeRecipientAliasedToVaultDeliversBothLegsNeutrally() public onFork {
        uint256 id = _fundDustFacility();
        Model memory m = _model(id, uint64(block.timestamp));
        Alias memory a;
        a.oldSink = waterfall.feeRecipient();
        assertTrue(a.oldSink != address(vault), "deployed default keeps a separate fee recipient");
        assertTrue(controller.isYieldSink(address(vault)), "the vault is an authorised yield sink (Deploy.s.sol)");
        Tally memory t;
        t.supply0 = usdfr.totalSupply();
        t.vault0 = usdfr.balanceOf(address(vault));
        t.fee0 = usdfr.balanceOf(a.oldSink);

        // Step 0: senior leg only, so the old recipient's fee claim is left virtual for the switch.
        {
            uint256 off0 = _oddOffset(0);
            _warp(off0);
            t.elapsed += off0;
            vm.prank(carol);
            reserves.checkpointAccrual(32);
            vm.prank(carol);
            (uint256 s0, uint256 f0) = reserves.materializeAccrued(1);
            assertEq(f0, 0, "fee leg not selected");
            t.senior += s0;
            a.oldClaim = reserves.accrualSnapshot().feeUnissued;
            assertEq(a.oldClaim, Math.mulDiv(m.rate * t.elapsed, 1000, Config.BPS), "old claim is floor(10% of gross)");
            assertGt(a.oldClaim, 0, "precondition: the old recipient is owed something at the switch");
        }

        // ATTACK: carol cannot alias the fee to the vault on either host.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        waterfall.setFeeRecipient(address(vault));
        vm.prank(carol);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotWaterfall.selector);
        reserves.setAccrualFee(1000, address(vault));
        assertEq(reserves.accrualSnapshot().feeRecipient, a.oldSink, "recipient unchanged by the rejected calls");

        // LEGITIMATE: governance aliases the fee to the vault. The old claim is delivered first,
        // the epoch closes, and the vault's price does not move.
        a.rate0 = vault.currentExchangeRate();
        a.assets0 = vault.totalAssets();
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualMaterialized(2, uint64(block.timestamp), 2, 0, a.oldClaim);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualFeeConfigured(1000, address(vault), uint64(block.timestamp));
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit FeeRecipientSet(address(vault));
        vm.prank(ops);
        waterfall.setFeeRecipient(address(vault));
        t.fee += a.oldClaim;
        assertEq(
            usdfr.balanceOf(a.oldSink) - t.fee0, a.oldClaim, "the old recipient was paid its whole claim, to the wei"
        );
        assertEq(reserves.accrualSnapshot().feeRecipient, address(vault), "the book now names the vault");
        assertEq(reserves.accrualSnapshot().unissued, 0, "epoch closed: nothing of the old epoch is owed to anyone");
        assertEq(vault.currentExchangeRate(), a.rate0, "the switch is price-neutral");
        assertEq(vault.totalAssets(), a.assets0, "the switch moves no vault asset");
        assertEq(usdfr.balanceOf(address(vault)) - t.vault0, t.senior, "the vault holds only its senior leg so far");
        a.grossAtChange = reserves.accrualSnapshot().gross;
        a.lastRate = a.rate0;
        emit log_named_uint("A7 old recipient's claim delivered at the switch", a.oldClaim);
        emit log_named_uint("A7 gross at the switch", a.grossAtChange);

        // Under the alias: eight odd steps over every leg selection. The vault owns everything
        // recognised since the switch, physical or virtual, and no delivery moves its price.
        uint8[8] memory legs = [3, 1, 2, 3, 2, 1, 3, 3];
        for (uint256 i; i < legs.length; ++i) {
            _aliasStep(id, m, t, a, i, legs[i]);
        }
        assertEq(usdfr.balanceOf(a.oldSink) - t.fee0, a.oldClaim, "the old recipient received nothing after the switch");

        // A rounding close under the alias: `prepare` must deliver BOTH legs (legs = 3) before
        // `allocate` will run, then the loss burns from the vault alone, and the vault ends up
        // holding exactly the contractual grid interest recognised since the switch.
        Close memory c;
        {
            (uint256 offL, uint256 loss) = _firstLossOffsetFrom(m, t.elapsed, 1);
            _warp(offL);
            t.elapsed += offL;
            c.loss = loss;
        }
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        c.owed = reserves.accruedDebt(id).interest;
        c.full = c.owed + c.loss;
        c.streamed = reserves.accrualSnapshot().gross;
        assertEq(c.full, Math.mulDiv(m.segmentAmount, t.elapsed, m.end - m.start), "interpolated recognition at close");
        c.vault0 = usdfr.balanceOf(address(vault));
        c.supply0 = usdfr.totalSupply();
        uint256 expSeniorClose;
        uint256 expFeeClose;
        {
            IContinuousAccrual.Snapshot memory pre = reserves.accrualSnapshot();
            uint256 feeFull = a.oldClaim + Math.mulDiv(c.full - a.grossAtChange, 1000, Config.BPS);
            uint256 feeStreamed = a.oldClaim + Math.mulDiv(c.streamed - a.grossAtChange, 1000, Config.BPS);
            expSeniorClose = (c.full - feeFull) - ((c.streamed - feeStreamed) - pre.seniorUnissued);
            expFeeClose = feeFull - (feeStreamed - pre.feeUnissued);
        }
        emit log_named_uint("A7 rounding loss at the aliased close", c.loss);
        IWaterfallEngine.Payment memory p = _prepPayment(id, c.owed, 0, "a7-exact");
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualMaterialized(3 + legs.length, uint64(block.timestamp), 3, expSeniorClose, expFeeClose);
        vm.expectEmit(true, true, true, true, address(controller));
        emit LossBurned(address(vault), c.loss);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualRoundingAllocated(id, 1, c.loss, 0, 0, 0, c.loss, 0, 0);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualLoanAligned(id, 1, uint64(block.timestamp), 0, c.loss, false);
        _settle(p);

        assertEq(
            usdfr.balanceOf(address(vault)) - c.vault0,
            expSeniorClose + expFeeClose - c.loss,
            "vault: both legs made physical, then the loss burned"
        );
        assertEq(
            usdfr.balanceOf(address(vault)) - t.vault0,
            c.owed - a.oldClaim,
            "the vault holds exactly the contractual grid interest less the old recipient's claim: whole gross minus the burned dust"
        );
        assertEq(
            usdfr.totalSupply() - c.supply0, expSeniorClose + expFeeClose - c.loss, "supply: both legs minus the burn"
        );
        assertEq(reserves.accrualSnapshot().unissued, 0, "nothing virtual remains after an aliased close");
        assertEq(reserves.roundingLossUnabsorbed(), 0, "nothing unabsorbed");
        assertEq(reserves.accruedDebt(id).interest, 0, "the exact receipt settled all interest");
        assertEq(reserves.deployedTo(id), PRINCIPAL, "deployed face is exactly the principal");
        assertEq(usdfr.balanceOf(a.oldSink) - t.fee0, a.oldClaim, "the old recipient received nothing at the close");
        _assertBacked(id, "after the aliased close");
    }

    /// @dev One A7 step under the alias: warp an odd offset, assert the rate rose and the vault
    ///      owns the whole gross since the switch, materialize the selected legs as carol, and
    ///      assert both legs landed on the vault with no price movement.
    function _aliasStep(uint256 id, Model memory m, Tally memory t, Alias memory a, uint256 i, uint8 leg) internal {
        uint256 off = _oddOffset(i + 1);
        _warp(off);
        t.elapsed += off;
        uint256 r1 = vault.currentExchangeRate();
        assertGt(r1, a.lastRate, "the fee-net rate rises with the whole gross under the alias");
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        assertEq(vault.currentExchangeRate(), r1, "a checkpoint is exactly price-neutral");
        IContinuousAccrual.Snapshot memory b = reserves.accrualSnapshot();
        assertEq(b.gross, m.rate * t.elapsed, "gross is the integer slope times elapsed");
        assertEq(
            usdfr.balanceOf(address(vault)) - t.vault0 + b.unissued,
            b.gross - a.oldClaim,
            "vault physical + virtual == every recognised wei except what the old recipient was paid"
        );
        assertEq(
            vault.totalAssets(),
            usdfr.balanceOf(address(vault)) + b.seniorUnissued + b.feeUnissued,
            "entryAssets counts both virtual legs for the aliased vault"
        );
        uint256 expSenior = (leg & 1) == 0 ? 0 : b.seniorUnissued;
        uint256 expFee = (leg & 2) == 0 ? 0 : b.feeUnissued;
        assertGt(expSenior + expFee, 0, "every step delivers something");
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualMaterialized(3 + i, uint64(block.timestamp), leg, expSenior, expFee);
        vm.prank(carol);
        (uint256 s, uint256 f) = reserves.materializeAccrued(leg);
        assertEq(s, expSenior, "senior leg issued iff selected");
        assertEq(f, expFee, "fee leg issued iff selected");
        t.senior += s;
        t.fee += f;
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, s + f, "both legs landed on the vault");
        assertEq(vault.currentExchangeRate(), r1, "materialization of either leg is price-neutral under the alias");
        if (i % 2 == 1) {
            vm.prank(carol);
            vault.accrueFees();
            assertEq(vault.currentExchangeRate(), r1, "fee crystallisation creates no second price jump (ADR-0031)");
        }
        _assertBacked(id, "alias step");
        a.lastRate = r1;
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Deposit base liquidity, stake most of it so the senior vault is non-empty, then
    ///      originate and fund the dust facility through the real m-of-n mint gate.
    function _fundDustFacility() internal returns (uint256 id) {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        id = _originateAndFund(PRINCIPAL);
        assertEq(reserves.deployedTo(id), PRINCIPAL, "funded at exactly the principal");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertTrue(d.known && d.active && !d.pik, "facility is registered as an active cash loan");
        assertEq(d.interest, 0, "no interest at funding");
    }

    /// @dev Builds the first technical segment from the pure libraries, independently of the book.
    function _model(uint256 id, uint64 fundedAt) internal view returns (Model memory m) {
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        m.terms = AccrualSegments.Terms({
            basis: PRINCIPAL,
            yearSeconds: YEAR,
            scale: SCALE,
            cap: d.balanceCeiling - PRINCIPAL,
            periodStart: fundedAt,
            periodEnd: d.maturity,
            maturity: d.maturity,
            rateBps: RATE_BPS
        });
        AccrualSegments.Segment memory seg = AccrualSegments.plan(m.terms, fundedAt);
        require(seg.end > seg.start && seg.amount != 0, "ATK: model segment is empty");
        m.start = seg.start;
        m.end = seg.end;
        m.segmentAmount = seg.amount;
        m.rate = seg.amount / (seg.end - seg.start);
        m.remainder = seg.amount % (seg.end - seg.start);
    }

    /// @dev Deterministic odd offsets between 1 second and 6 days, derived from the step index.
    function _oddOffset(uint256 i) internal pure returns (uint256) {
        return (uint256(keccak256(abi.encode("atk-accrual-dust", i))) % 6 days) | 1;
    }

    /// @dev The restated backing invariant (ADR-0038 point 6): physical and effective supply are
    ///      both within backing, and backing reconciles to idle plus THIS facility's face. The
    ///      aggregate side (`totalBackingValue`, `deployedPrincipal`) is carried by the book's
    ///      total clock and total posted counter; the per-facility side (`deployedTo`) by the
    ///      entry's own clock and posted counter. With one facility in the book the two
    ///      accumulators must agree to the wei (reserve accounting reconciles to its parts).
    function _assertBacked(uint256 id, string memory ctx) internal view {
        uint256 backing = reserves.totalBackingValue();
        assertLe(usdfr.totalSupply(), backing, string.concat("physical supply within backing: ", ctx));
        assertLe(controller.totalUSDfr(), backing, string.concat("effective supply within backing: ", ctx));
        assertEq(
            backing,
            reserves.normalizeUSDC(reserves.idleUSDC()) + reserves.deployedTo(id) - reserves.totalPrincipalImpairment(),
            string.concat("backing reconciles to idle + this facility's recorded and unposted face - impairment: ", ctx)
        );
    }

    /// @dev Attests a receipt of exactly `interest` + `principal` (18-dec) with the USDC leg on the
    ///      floor of the grid, funds and approves the borrower, and returns the payment. The
    ///      attested `nextPaymentDue` advances one interval from the facility's current due date.
    function _prepPayment(uint256 id, uint256 interest, uint256 principal, string memory tag)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = (interest + principal) / SCALE;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 nextDue = f.nextPaymentDue + f.paymentInterval;
        bytes32 paymentId = keccak256(abi.encode(tag, id, interest, principal));
        _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, USDC, borrower, stableAmount, interest, principal, nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: nextDue
        });
    }

    /// @dev A servicer attempt that must revert with exactly `err`; the borrower's USDC is asserted
    ///      untouched. Attestation happens first so the revert is the engine's, not the gate's.
    ///      The attempt runs inside a state snapshot: a rejected receipt leaves its attested fact
    ///      unconsumed, and the oracle refuses a second pending fact of the same kind
    ///      (`Oracle_UnconsumedFact`), so every attempt is made from the identical state.
    function _attemptInterestPayment(uint256 id, uint256 interest, string memory tag, bytes memory err) internal {
        uint256 snap = vm.snapshotState();
        IWaterfallEngine.Payment memory p = _prepPayment(id, interest, 0, tag);
        uint256 borrowerUSDC = IERC20(USDC).balanceOf(borrower);
        vm.prank(ops);
        vm.expectRevert(err);
        waterfall.distribute(p);
        assertEq(IERC20(USDC).balanceOf(borrower), borrowerUSDC, "a rejected receipt pulls no USDC");
        require(vm.revertToState(snap), "ATK: snapshot revert failed");
    }

    /// @dev A servicer settlement of an already attested payment that must succeed and pull
    ///      exactly the attested USDC. Callers arm `vm.expectEmit` immediately before this.
    function _settle(IWaterfallEngine.Payment memory p) internal {
        uint256 borrowerUSDC = IERC20(USDC).balanceOf(borrower);
        vm.prank(ops);
        waterfall.distribute(p);
        assertEq(
            borrowerUSDC - IERC20(USDC).balanceOf(borrower),
            (p.interest + p.principal) / SCALE,
            "exactly the attested USDC was pulled"
        );
    }

    /// @dev Post curator first-loss (layer 1) for FILM as the anchor curator (`ops`).
    function _postFirstLossOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, 1_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    /// @dev Fund sGROVE coverage (layer 2). Coverage funding is permissionless.
    function _fundCoverageOps(uint256 usdfrAmount) internal {
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }
}
