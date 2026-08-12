// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {IMintRedeemController} from "../../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../../src/interfaces/IReserveManager.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

/// @title CustodyShortfallHandler — AUDIT FIX (R4-01) stateful driver
/// @notice THIS HANDLER EXISTS TO WALK INTO THE ILLEGAL REGION ON PURPOSE, and it is the direct
///         answer to the campaign-5 lesson that a pre-filtered handler makes an invariant
///         decoration. Every other campaign in this repository holds
///         `reserves.idleUSDC() <= USDC.balanceOf(reserves)` as an invariant
///         (`BackingFocusedInvariants.invariant_backing_idleLedgerNeverExceedsCustody`) and that
///         assertion is TRUE THERE ONLY BECAUSE NO ACTION IN THOSE HANDLERS CAN BREAK IT — none of
///         them can move USDC out of the treasury without a matching ledger entry. The region in
///         which the ledger over-claims custody was therefore unreachable, and the R4-01 defect —
///         par redemption against a reserve the contract can see is short — was invisible to every
///         stateful campaign that existed.
///
///         `custodyDrain` breaks that ledger/custody equality out of band, which is exactly what a
///         custody incident, a token-level seizure or a compromised operator does. It is a
///         NEW-domain handler, deliberately not bolted onto `CreditHandler`: the campaigns that
///         assume a fully-custodied treasury keep that assumption intact and unweakened.
///
/// @dev `fail_on_revert = true`. Every protocol call that can legitimately revert in this domain
///      is wrapped in try/catch and CLASSIFIED, because the classification is the evidence:
///      an exit that SUCCEEDS while a shortfall stands is the defect
///      (`gExitsWhileShort`), and an exit that fails with the token's raw
///      `ERC20InsufficientBalance` rather than a protocol error is the defect's tail
///      (`gRawTokenRevertsOnExit`). Both ghosts are asserted zero by the campaign.
contract CustodyShortfallHandler is Test {
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;

    address internal admin;
    address internal creditModule;
    address internal borrower;
    address internal sink;
    address[2] public actors;

    uint256 internal constant UNIT = 1e12;
    uint256 internal nextFacilityId = 1;

    // ── ghost state ──────────────────────────────────────────────────────
    uint256 public callCount;
    /// @dev Reach telemetry: how often the campaign actually stood in the illegal region.
    uint256 public gDrains;
    uint256 public gRestores;
    uint256 public gExitAttemptsWhileShort;
    uint256 public gMintAttemptsWhileShort;
    /// @dev AUDIT FIX (MA-1) reach telemetry for the SECOND USDC out-door — `recordDeployment`.
    uint256 public gDeployAttemptsWhileShort;
    /// @dev THE DEFECT COUNTERS. Both must remain zero. Delete either R4-01 guard and they move.
    uint256 public gExitsWhileShort;
    uint256 public gMintsWhileShort;
    uint256 public gRawTokenRevertsOnExit;
    /// @dev AUDIT FIX (MA-1) DEFECT COUNTERS. `ReserveManager` has TWO doors that move USDC out —
    ///      `_release` (guarded by R4-01) and `recordDeployment` (the CREDIT door, which was not).
    ///      Delete `_requireIdleFullyCustodied` from `recordDeployment` and both of these move off
    ///      zero, which is the reachability proof for that guard.
    uint256 public gDeploymentsWhileShort;
    uint256 public gUSDCDeployedWhileShort;
    /// @dev AUDIT FIX (MA-2) reach telemetry: states in which the SOLVENCY predicate and the
    ///      PERFORMING-CREDIT predicate disagree. That divergence is the entire subject of MA-2;
    ///      a campaign that never reached it would prove nothing about the separation.
    uint256 public gPredicatesDiverged;
    /// @dev Anti-vacuity: the campaign must also prove ordinary par business still WORKS, or a
    ///      contract that reverted every exit unconditionally would pass every assertion above.
    uint256 public gExitsWhileWhole;
    uint256 public gMintsWhileWhole;
    /// @dev AUDIT FIX (MA-1) anti-vacuity: deployment must WORK on a whole treasury, or blocking
    ///      it on a short one proves nothing. A `recordDeployment` that reverted unconditionally
    ///      would satisfy `gDeploymentsWhileShort == 0` while being a total liveness failure.
    uint256 public gDeploymentsWhileWhole;
    /// @dev Total USDC actually paid out to redeemers, and total ever custodied, so the campaign
    ///      can check that redeemers were never collectively paid out of a hole.
    uint256 public gUSDCPaidToRedeemers;

    constructor(
        address usdc_,
        address usdfr_,
        address reserves_,
        address controller_,
        address vault_,
        address admin_,
        address creditModule_,
        address borrower_,
        address[2] memory actors_
    ) {
        usdc = MockERC20(usdc_);
        usdfr = USDfr(usdfr_);
        reserves = ReserveManager(reserves_);
        controller = MintRedeemController(controller_);
        vault = SUSDfr(vault_);
        admin = admin_;
        creditModule = creditModule_;
        borrower = borrower_;
        actors = actors_;
        sink = makeAddr("r4-01-custody-sink");
    }

    // ── views the campaign reads ─────────────────────────────────────────

    function shortfallUnits() public view returns (uint256) {
        (,, uint256 s) = reserves.observeIdleUSDC();
        return s;
    }

    // ── actions ──────────────────────────────────────────────────────────

    /// @notice Ordinary KYC-gated par issuance.
    function mintPar(uint256 actorSeed, uint256 units) external {
        _attemptMint(actors[actorSeed % 2], bound(units, 1, 250_000e6));
        callCount++;
    }

    /// @notice Stake into the senior vault, so the campaign carries a real junior/senior structure
    ///         rather than a treasury of pure idle cash.
    function stake(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 2];
        uint256 bal = usdfr.balanceOf(actor);
        if (bal < UNIT) return;
        if (vault.maxDeposit(actor) == 0) return;
        uint256 amount = bound(amountSeed, UNIT, bal);
        vm.prank(actor);
        usdfr.approve(address(vault), amount);
        vm.prank(actor);
        try vault.deposit(amount, actor) {} catch {}
        callCount++;
    }

    /// @notice THE ACTION THAT ENTERS THE ILLEGAL REGION. USDC leaves the treasury with no ledger
    ///         entry behind it, so `idleUSDC()` over-claims custody by exactly `amount`.
    /// @dev It probes the SAME exit on BOTH SIDES of the same drain, with the same actor, in this
    ///      one call. The whole-side probe must succeed and the short-side probe must not: a
    ///      contract that simply reverted every exit would fail the whole-side anti-vacuity
    ///      assertion, and a contract that paid par regardless would fail the short-side invariant.
    ///      Doing it here rather than leaving it to the fuzzer to order a `parExit` between a
    ///      `custodyDrain` and a `custodyRestore` is what makes the illegal region reached on EVERY
    ///      drain instead of on a lucky ordering — the difference between a campaign that searches
    ///      the region and one that reports green because it never arrived.
    function custodyDrain(uint256 seed, uint256 exitSeed) external {
        if (shortfallUnits() == 0) {
            _ensureParExitFeasible();
            _attemptParExit(exitSeed);
            // AUDIT FIX (MA-1). The whole-treasury half of the deployment probe, so the campaign
            // proves the credit door still WORKS before it proves it closes.
            _attemptDeployment(seed);
        }
        uint256 live = usdc.balanceOf(address(reserves));
        if (live == 0) return;
        uint256 amount = bound(seed, 1, live);
        vm.prank(address(reserves));
        usdc.transfer(sink, amount);
        gDrains++;
        // AUDIT FIX (MA-2). Record that the campaign actually stood in the region where the
        // SOLVENCY predicate and the PERFORMING-CREDIT predicate disagree — the whole subject of
        // MA-2. Asserted non-zero by the campaign's anti-vacuity check.
        if (controller.creditServicingBackingHolds() && !controller.backingInvariantHolds()) gPredicatesDiverged++;
        _attemptParExit(exitSeed);
        // AUDIT FIX (MA-1) — THE SECOND OUT-DOOR, probed on EVERY drain rather than left to the
        // fuzzer to order a `deployPrincipal` between a drain and a restore. Same reasoning as the
        // exit probe above: this is the difference between a campaign that searches the illegal
        // region and one that reports green because it never arrived there.
        _attemptDeployment(seed ^ exitSeed);
        callCount++;
    }

    /// @notice A direct `releaseUSDC` by a CONTROLLER_ROLE holder, which is the surface
    ///         `ReserveManager._requireIdleFullyCustodied` actually protects.
    /// @dev The reserve must be honest about its own custody regardless of which role-holder is
    ///      asking — relying on the caller to have pre-checked is exactly the assumption that made
    ///      the exhausted-reserve path surface a bare `ERC20InsufficientBalance`. Probed only while
    ///      short, because on the clean build it can only revert there and so leaves no state
    ///      behind; on a build with the guard deleted it succeeds and the campaign says so.
    function directRelease(uint256 seed) external {
        if (shortfallUnits() == 0) return;
        uint256 idle = reserves.idleUSDC();
        if (idle == 0) return;
        uint256 units = bound(seed, 1, idle);
        gExitAttemptsWhileShort++;
        vm.prank(address(controller));
        try reserves.releaseUSDC(actors[0], units) {
            // R4-01: the reserve handed out cash it could see it was not holding.
            gExitsWhileShort++;
        } catch (bytes memory err) {
            if (_selector(err) == IERC20Errors.ERC20InsufficientBalance.selector) gRawTokenRevertsOnExit++;
        }
        callCount++;
    }

    /// @notice Recapitalisation / recovery of the missing custody. Permissionless on purpose: the
    ///         R4-01 recognition must clear symmetrically, with no role and no incident, or the
    ///         guard is a latch and the protocol is bricked by anyone who can move a token.
    /// @dev Restores IN FULL on roughly half its calls and partially otherwise, so the campaign
    ///      reaches three distinct states rather than latching into one: fully custodied, partially
    ///      recovered but still short, and fully short. Without the full-recovery branch the first
    ///      drain would make every later call a short-state call, and the campaign could never
    ///      demonstrate that ordinary par business still WORKS — which is exactly what stops
    ///      "everything reverts" from passing these invariants.
    function custodyRestore(uint256 seed, uint256 exitSeed) external {
        uint256 short_ = shortfallUnits();
        if (short_ == 0) return;
        uint256 amount = seed % 2 == 0 ? short_ : bound(seed, 1, short_);
        usdc.mint(address(reserves), amount);
        gRestores++;
        if (shortfallUnits() == 0) _ensureParExitFeasible();
        _attemptParExit(exitSeed);
        callCount++;
    }

    /// @notice A par exit at a fuzzer-chosen moment, short or whole.
    function parExit(uint256 actorSeed, uint256 amountSeed) external {
        // Self-seed ONLY while the treasury is whole, so seeding can never mask the defect: while
        // short, the exit is attempted exactly as the state left it.
        if (shortfallUnits() == 0) _ensureParExitFeasible();
        actorSeed; // the probe always takes the largest holder, so the seed only picks the amount
        _attemptParExit(amountSeed);
        callCount++;
    }

    /// @notice Deploy idle principal to a borrower, so `totalBackingValue()` carries a deployed leg
    ///         and the recognition identity is checked against a non-degenerate balance sheet.
    /// @dev AUDIT FIX (MA-1): this is also THE SECOND USDC OUT-DOOR. It is a fuzzer-ordered probe;
    ///      `custodyDrain` probes the same door deterministically on both sides of every drain.
    function deployPrincipal(uint256 seed) external {
        _attemptDeployment(seed);
        callCount++;
    }

    /// @notice Repay principal in cash, so deployed principal can fall again and the campaign is
    ///         not a one-way ratchet into an all-deployed balance sheet.
    function repayPrincipal(uint256 idSeed, uint256 seed) external {
        if (nextFacilityId <= 1) return;
        uint256 id = (idSeed % (nextFacilityId - 1)) + 1;
        uint256 outstanding = reserves.deployedTo(id);
        if (outstanding < UNIT) return;
        uint256 units = bound(seed, 1, outstanding / UNIT);
        usdc.mint(borrower, units);
        vm.prank(borrower);
        usdc.approve(address(reserves), units);
        vm.prank(creditModule);
        try reserves.recordPayment(id, borrower, units, units * UNIT) {} catch {}
        callCount++;
    }

    // ── internals ────────────────────────────────────────────────────────

    /// @dev AUDIT FIX (MA-1) — THE MEASUREMENT FOR THE SECOND OUT-DOOR. `ReserveManager` moves USDC
    ///      out through exactly two functions (`grep -n safeTransfer src/ReserveManager.sol`):
    ///      `_release`, which R4-01 guarded, and `recordDeployment`, which it did not. A deployment
    ///      that SUCCEEDS while a shortfall stands hands the frozen holders' last live dollars to a
    ///      borrower and turns them into an illiquid receivable — strictly worse than the par exit
    ///      R4-01 closed, because it pays no holder at all.
    ///
    ///      Sized so it COULD succeed against live custody — an amount bounded to always revert
    ///      would prove nothing. While SHORT it deliberately asks for every live dollar, because
    ///      taking the last one is the finding; while WHOLE it takes a small slice so the campaign
    ///      never starves its own par-exit liquidity and the anti-vacuity assertions stay
    ///      behavioural rather than sequence-dependent.
    function _attemptDeployment(uint256 seed) internal {
        uint256 idle = reserves.idleUSDC();
        uint256 live = usdc.balanceOf(address(reserves));
        uint256 cap = idle < live ? idle : live;
        if (cap == 0) return;
        bool shortBefore = shortfallUnits() != 0;
        uint256 units = shortBefore ? bound(seed, 1, cap) : bound(seed, 1, cap / 8 + 1);
        if (shortBefore) gDeployAttemptsWhileShort++;
        vm.prank(creditModule);
        try reserves.recordDeployment(nextFacilityId++, borrower, units) {
            if (shortBefore) {
                // MA-1: live custody left a reserve the contract could see was short.
                gDeploymentsWhileShort++;
                gUSDCDeployedWhileShort += live - usdc.balanceOf(address(reserves));
            } else {
                gDeploymentsWhileWhole++;
            }
        } catch {}
    }

    /// @dev Guarantees that the NEXT whole-state par exit can actually be paid: a holder with at
    ///      least one whole USDfr, and idle USDC to pay it from. Called only while the treasury is
    ///      whole, where issuance is legal, so it can never manufacture a state the guard is
    ///      supposed to forbid. This exists because the anti-vacuity assertions in the campaign
    ///      ("par exit still WORKS") were otherwise sequence-dependent and would pass or fail on
    ///      the fuzzer's ordering rather than on the contract's behaviour.
    function _ensureParExitFeasible() internal {
        _attemptMint(actors[0], 10_000e6);
    }

    /// @dev Every issuance in this campaign — fuzzed or seeded — funnels through here and is
    ///      classified, so a mint that slipped through while the reserve was short could not hide
    ///      in a seeding helper.
    function _attemptMint(address actor, uint256 units) internal {
        bool shortBefore = shortfallUnits() != 0;
        if (shortBefore) gMintAttemptsWhileShort++;
        usdc.mint(actor, units);
        vm.prank(actor);
        usdc.approve(address(controller), units);
        vm.prank(actor);
        try controller.mint(units) {
            if (shortBefore) {
                // R4-01: a new claim was sold at par into a reserve the protocol could see was
                // short. This is the defect, not a modelling artefact.
                gMintsWhileShort++;
            } else {
                gMintsWhileWhole++;
            }
        } catch {}
    }

    /// @dev The measurement that matters. Sizes the exit so it COULD succeed against live custody
    ///      — deliberately, because an exit bounded to always fail would prove nothing — then
    ///      classifies the outcome.
    function _attemptParExit(uint256 seed) internal {
        address actor = usdfr.balanceOf(actors[0]) >= usdfr.balanceOf(actors[1]) ? actors[0] : actors[1];
        uint256 bal = usdfr.balanceOf(actor);
        if (bal < UNIT) return;
        uint256 liveValue = usdc.balanceOf(address(reserves)) * UNIT;
        uint256 cap = bal < liveValue ? bal : liveValue;
        // When custody is fully drained there is nothing an exit could be paid from; probe the
        // minimum anyway, because THAT is the path that used to surface the raw token revert.
        uint256 amount = cap < UNIT ? UNIT : bound(seed, UNIT, cap);
        amount -= amount % UNIT;
        if (amount == 0) return;

        bool shortBefore = shortfallUnits() != 0;
        if (shortBefore) gExitAttemptsWhileShort++;
        uint256 usdcBefore = usdc.balanceOf(actor);

        vm.prank(actor);
        try controller.redeem(amount) returns (uint256 usdcOut) {
            gUSDCPaidToRedeemers += usdcOut;
            assertEq(usdc.balanceOf(actor) - usdcBefore, usdcOut, "redeem reported more than it paid");
            if (shortBefore) {
                // R4-01: par exit executed against a reserve the contract could see was short.
                gExitsWhileShort++;
            } else {
                gExitsWhileWhole++;
            }
        } catch (bytes memory err) {
            if (_selector(err) == IERC20Errors.ERC20InsufficientBalance.selector) {
                // R4-01 tail: a bare ERC-20 revert on the exit path, with no protocol meaning.
                gRawTokenRevertsOnExit++;
            }
        }
    }

    function _selector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(err, 32))
        }
    }
}
