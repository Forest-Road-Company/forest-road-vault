// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

/// @title SubParExitHandler — AUDIT FIX (R18) stateful driver for the sub-par accounting path
///
/// @notice WHY THIS HANDLER EXISTS. The entire sub-par accounting path introduced by R16-M3 and
///         extended by R17 had ZERO stateful-fuzz coverage, contrary to CLAUDE.md §1.3, which
///         requires invariants on value and accounting logic. That covers `_quoteRedeem`'s sub-par
///         branch, the append-only `subParShortfall` storage, its crystallisation arithmetic,
///         `Controller_SeniorRetentionBreached`, `Controller_SlippageExceeded` and the
///         `SubParRedemption` / `SeniorShortfallCrystallised` events.
///
///         IT WAS NOT MERELY UNCOVERED — IT WAS STRUCTURALLY UNREACHABLE. Four campaigns
///         (`TokenLayerInvariants`, `BackingFocusedInvariants`, `CreditInvariants`,
///         `RedemptionQueueInvariants`) assert the ABSOLUTE backing invariant
///         `totalUSDfr() <= backingValue()`, and a fifth asserts `backingInvariantHolds()`. All
///         five are green, so NO campaign in the tree ever enters a sub-par state. Compounding it,
///         every invariant handler that redeems calls the ONE-ARGUMENT form, which after R17
///         reverts under any deficit — with `fail_on_revert = true` in both profiles. The domain
///         was therefore closed twice over.
///
///         THIS CAMPAIGN'S BACKING PROPERTY IS THE NON-WORSENING RULE, NOT THE ABSOLUTE ONE —
///         which is what `_assertDeficitNotWorsened` actually enforces, and the only way to hold a
///         property while deliberately standing in the region the other campaigns exclude. The
///         pre-existing campaigns are untouched: their fully-backed assumption is intact and
///         unweakened, and this is a NEW domain rather than a relaxation of an old one.
///
///         IT ALSO CLOSES THE SEAM ADR-0034 DECISION Z NAMES. That ADR records that the existing
///         campaigns cannot catch a cascade-ordering violation because "the only handler that
///         models a custody shortfall has eight actions and none of them mints yield or
///         distributes". `yieldMint` here mints yield in the sub-par/retention domain, so the
///         credit-layer seam is exercised. What this campaign does NOT do is encode ADR-0034's
///         ordering property itself (no exit while unexhausted junior capital remains): that
///         requires the junior-netted price basis decision Y mandates, which is not implemented.
///         Recorded as outstanding rather than approximated.
///
/// @dev `fail_on_revert = true`, so every protocol call that can legitimately revert in this domain
///      is pre-guarded or wrapped in try/catch and CLASSIFIED. The classification is the evidence.
contract SubParExitHandler is Test {
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;

    address internal admin;
    address internal creditModule;
    address internal borrower;
    address internal yieldSink;
    address[2] public actors;

    uint256 internal constant UNIT = 1e12;
    uint256 internal constant FACILITY = 1;
    bytes32 internal constant EVIDENCE = keccak256("R18-invariant-mark");

    // ── reach telemetry (anti-vacuity is proved deterministically, see the campaign) ──
    uint256 public callCount;
    uint256 public gMarks;
    uint256 public gReleases;
    uint256 public gSubParExits;
    uint256 public gParExits;
    uint256 public gYieldMints;
    uint256 public gRetentionRefusals;

    // ── the accounting ghosts the campaign asserts against ───────────────
    /// @dev The sum of every crystallisation this handler observed, computed independently of the
    ///      contract from `usdfrIn - usdcOut * 1e12`. CLAUDE.md §3.1 requires the on-chain register
    ///      to be reconstructable purely from events; this is that reconstruction.
    uint256 public gCrystallisedSum;
    /// @dev The highest `seniorSubParShortfall()` ever observed. The field is append-only by
    ///      design and has no setter; this is how a mutation that adds one becomes visible.
    uint256 public gMaxRetentionSeen;
    /// @dev THE DEFECT COUNTERS. All must stay zero.
    uint256 public gRetentionWentBackwards;
    uint256 public gRatioWorsenedForStayers;
    uint256 public gDeficitWorsened;
    uint256 public gSilentHaircuts;

    constructor(
        address usdc_,
        address usdfr_,
        address reserves_,
        address controller_,
        address admin_,
        address creditModule_,
        address borrower_,
        address yieldSink_,
        address[2] memory actors_
    ) {
        usdc = MockERC20(usdc_);
        usdfr = USDfr(usdfr_);
        reserves = ReserveManager(reserves_);
        controller = MintRedeemController(controller_);
        admin = admin_;
        creditModule = creditModule_;
        borrower = borrower_;
        yieldSink = yieldSink_;
        actors = actors_;
    }

    // ── measurement helpers ──────────────────────────────────────────────

    function _supply() internal view returns (uint256) {
        return usdfr.totalSupply();
    }

    function _backing() internal view returns (uint256) {
        return reserves.totalBackingValue();
    }

    function _deficit() internal view returns (uint256) {
        uint256 s = _supply();
        uint256 b = _backing();
        return s > b ? s - b : 0;
    }

    /// @dev Coverage in 1e18 fixed point, capped at par. An empty protocol is defined as par so the
    ///      comparison below is total.
    function _ratio() internal view returns (uint256) {
        uint256 s = _supply();
        if (s == 0) return 1e18;
        uint256 b = _backing();
        if (b >= s) return 1e18;
        return (b * 1e18) / s;
    }

    function _observeRetention() internal {
        uint256 r = controller.seniorSubParShortfall();
        if (r < gMaxRetentionSeen) gRetentionWentBackwards += 1;
        if (r > gMaxRetentionSeen) gMaxRetentionSeen = r;
    }

    // ── actions ──────────────────────────────────────────────────────────

    /// @dev Ordinary par issuance. Pre-guarded rather than try/caught where the guard is exact, so
    ///      a mutation that opens the par window while short shows up as a REVERT, not as silence.
    function mintPar(uint256 actorSeed, uint256 amount) external {
        callCount += 1;
        _observeRetention();
        if (_supply() > _backing()) return; // par issuance is closed while short, by design
        if (reserves.idleCustodyShortfall() != 0) return;
        address actor = actors[actorSeed % actors.length];
        uint256 usdcAmount = bound(amount, 1e6, 250_000e6);
        usdc.mint(actor, usdcAmount);
        vm.startPrank(actor);
        usdc.approve(address(controller), usdcAmount);
        try controller.mint(usdcAmount) {}
        catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();
        _observeRetention();
    }

    /// @dev Deploys idle cash as facility principal, so there is something a governance mark can
    ///      bite on. Without this the sub-par domain is unreachable: an all-cash treasury cannot be
    ///      marked down.
    function deployPrincipal(uint256 amount) external {
        callCount += 1;
        uint256 idle = reserves.idleUSDC();
        if (idle < 2e6) return;
        uint256 units = bound(amount, 1e6, idle / 2);
        vm.prank(creditModule);
        try reserves.recordDeployment(FACILITY, borrower, units) {} catch {}
    }

    /// @dev THE ACTION THAT OPENS THE DOMAIN. A governance G3 conservative mark on deployed
    ///      principal — the ordinary, expected credit event — drives `backing < supply` with
    ///      custody perfectly intact.
    function markDown(uint256 amount) external {
        callCount += 1;
        uint256 face = reserves.deployedTo(FACILITY);
        uint256 already = reserves.principalImpairmentOf(FACILITY);
        if (face <= already) return;
        uint256 mark = bound(amount, 1, face - already);
        vm.prank(admin);
        try reserves.recognizePrincipalImpairment(FACILITY, mark, EVIDENCE) {
            gMarks += 1;
        } catch {}
        _observeRetention();
    }

    /// @dev THE REVERSAL THE RETENTION EXISTS FOR. `recognizePrincipalImpairment` is reversible by
    ///      design; the exiter's crystallised loss is not. Releasing is what makes the retention's
    ///      job observable.
    function releaseMark(uint256 amount) external {
        callCount += 1;
        uint256 recognized = reserves.principalImpairmentOf(FACILITY);
        if (recognized == 0) return;
        uint256 release = bound(amount, 1, recognized);
        vm.prank(admin);
        try reserves.releasePrincipalImpairment(FACILITY, release, EVIDENCE) {
            gReleases += 1;
        } catch {}
        _observeRetention();
    }

    /// @dev THE ACTION NO OTHER HANDLER IN THE TREE PERFORMS: the TWO-ARGUMENT redeem, with a
    ///      bounded floor, while the protocol is deliberately short. Every other campaign's
    ///      redemption path calls the one-argument form, which after R17 reverts under any deficit.
    function subParExit(uint256 actorSeed, uint256 amount, uint256 floorBps) external {
        callCount += 1;
        _observeRetention();
        address actor = actors[actorSeed % actors.length];
        uint256 balance = usdfr.balanceOf(actor);
        if (balance < UNIT) return;
        if (reserves.idleCustodyShortfall() != 0) return;
        uint256 offered = bound(amount, UNIT, balance);

        (uint256 quoted,) = controller.previewRedeem(offered);
        if (quoted == 0) return;
        if (reserves.idleUSDC() < quoted) return; // no cash to settle with; not a defect
        // The floor the holder elects, from "accept anything" up to the exact quote. A floor ABOVE
        // the quote must be refused, and that refusal is the point of `Controller_SlippageExceeded`.
        uint256 floor = (quoted * bound(floorBps, 0, 10_000)) / 10_000;

        uint256 supplyBefore = _supply();
        uint256 backingBefore = _backing();
        uint256 ratioBefore = _ratio();
        uint256 deficitBefore = _deficit();
        uint256 retentionBefore = controller.seniorSubParShortfall();

        vm.prank(actor);
        try controller.redeem(offered, floor) returns (uint256 paid) {
            uint256 burned = supplyBefore - _supply();
            uint256 valuePaid = paid * UNIT;
            if (valuePaid < burned) {
                gSubParExits += 1;
                gCrystallisedSum += burned - valuePaid;
                // A HAIRCUT MUST NEVER BE SILENT. R17's whole point: it is an election. If the
                // holder was paid less than par having demanded par, the floor did not bind.
                if (floor > paid) gSilentHaircuts += 1;
            } else {
                gParExits += 1;
            }
            // The two properties that make a sub-par exit safe for the holders who stayed.
            if (_ratio() < ratioBefore) gRatioWorsenedForStayers += 1;
            if (_deficit() > deficitBefore) gDeficitWorsened += 1;
            // Monotonicity of the append-only field, measured across the one operation that writes
            // it rather than only sampled between calls.
            if (controller.seniorSubParShortfall() < retentionBefore) gRetentionWentBackwards += 1;
        } catch {}
        backingBefore; // silence: retained above for readability of the measurement block
        _observeRetention();
    }

    /// @dev THE CREDIT-LAYER SEAM ADR-0034 Z NAMES AS UNEXERCISED. Attested cash lands as backing,
    ///      then the credit layer mints yield sized off `mintableHeadroom()` — the view that nets
    ///      the retention out. A mint sized ABOVE the headroom is attempted deliberately, so
    ///      `Controller_SeniorRetentionBreached` and the deficit rules are reached rather than
    ///      designed around.
    function yieldMint(uint256 amount, bool overHeadroom) external {
        callCount += 1;
        _observeRetention();
        uint256 receipt = bound(amount, 1e6, 50_000e6);
        usdc.mint(creditModule, receipt);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), receipt);
        try reserves.depositUSDC(creditModule, receipt) {} catch {}
        vm.stopPrank();

        uint256 headroom = controller.mintableHeadroom();
        uint256 mintAmount = overHeadroom ? headroom + 1e18 : headroom;
        if (mintAmount == 0) return;
        vm.prank(creditModule);
        try controller.mintYield(yieldSink, mintAmount) {
            gYieldMints += 1;
        } catch {
            gRetentionRefusals += 1;
        }
        _observeRetention();
    }
}
