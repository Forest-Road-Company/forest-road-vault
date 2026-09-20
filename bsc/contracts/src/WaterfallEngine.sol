// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimBridge} from "./ClaimBridge.sol";
import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {IDefaultManager} from "./interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {IWaterfallEngine} from "./interfaces/IWaterfallEngine.sol";
import {IContinuousAccrual} from "./interfaces/IContinuousAccrual.sol";
import {IAccrualExposure} from "./interfaces/IAccrualExposure.sol";
import {
    IAccrualLifecycle,
    IAccrualReceipts,
    IAccrualFeeConfig,
    IAccrualRounding
} from "./interfaces/IAccrualLifecycle.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";
import {WaterfallLegacyLib} from "./libraries/WaterfallLegacyLib.sol";
import {WaterfallAccrualLib} from "./libraries/WaterfallAccrualLib.sol";

/// @title WaterfallEngine - funding out, repayments in (brief Part 5 section 9)
/// @notice Every attested repayment is routed with EXACT conservation (CLAUDE.md section 1.3):
///         `interest == fee + toVault + withheld` and `principal` fully returns to
///         reserve accounting with the matching exposure decrease - nothing created,
///         nothing destroyed, nothing routed by hand.
///
///         `withheld` IS NOT ZERO IN GENERAL, AND THE OLD `interest == fee + toVault` FORM OF THIS
///         SENTENCE WAS STALE (audit ADV-1). Interest can be retained as backing rather than minted
///         for two structurally different reasons - the R16-M5 headroom clamp and the ADV-1
///         senior-impairment fee withholding - each of which publishes its own event, so the
///         three-way split is reconstructable from logs alone. Nothing is destroyed: the withheld
///         cash is already in the reserve and simply has no USDfr minted against it, which is why
///         it reads as over-collateralisation rather than as a leak.
///
///         SENIORITY: the senior claim (`sUSDfr`) receives all interest after the
///         protocol fee. Curator (junior) capital is never paid from repayments - it is
///         only released as exposure falls (CuratorModule
///         headroom), so senior is never subordinated to junior.
///
///         FUNDS PRECONDITION (dual-record sync): the stables for a distribution must
///         already sit in the treasury in the same transaction. The interest leg is
///         enforced on-chain - `mintYield` asserts the ADR-0012 backing invariant, so
///         minting yield against stables that never arrived reverts. The principal leg
///         shifts backing composition (deployed -> idle) and is reconciled by attested
///         receipts (ADR-0007) plus the Phase E integration suite.
///
///         CONTINUOUS MODE: once the permanent reserve is enabled, income and its fee are
///         recognized before receipt. A receipt only exchanges the existing claim for measured
///         cash. `Distributed` then reports zero newly minted fee/yield and
///         `AccruedReceiptSettled` identifies that settlement explicitly.
contract WaterfallEngine is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IWaterfallEngine
{
    /// @custom:storage-location erc7201:forestroad.storage.WaterfallEngine
    struct WaterfallStorage {
        ClaimBridge bridge;
        ICollateralRegistry registry;
        IReserveManager reserves;
        IMintRedeemController controller;
        address vault; // sUSDfr - the senior yield destination
        address feeRecipient;
        uint16 protocolFeeBps;
        // -- append-only (upgrade safety) ----------------------------------
        mapping(uint256 classId => uint16) originationFeeBps; // ADR-0019
        IAttestationOracle oracle; // payment gate (Phase G, ADR-0020)
        IDefaultManager defaultManager; // ADR-0022 impairment-pool resolve hook (optional)
        // -- PIK capitalisation (docs/SPEC_INTEREST_ACCRUAL.md), appended 2026-09-08 -----------
        mapping(uint256 tokenId => PikCursor) pikCursor;
        mapping(uint256 tokenId => uint256) pikCapitalisedTotal; // cumulative, disclosure only
        // -- continuous pre-receipt accrual; permanent native reserve binding ----------------
        address accrualReserve;
    }

    /// @notice Seconds in an Actual/360 interest year: 360 days of 86,400 seconds.
    /// @dev NOT 365. Actual/360 divides actual elapsed days by a 360-day year, which is why a full
    ///      calendar year at a nominal 10% pays 10.139%. That is the convention the facility signed,
    ///      so it is the convention the protocol must compute, not a rounding to be tidied away.
    uint256 internal constant _ACTUAL360_YEAR = 360 days;

    /// @dev Refuses a PIK facility funded so late in its first period that the first capitalisation
    ///      would round to nothing on the facility asset's grid.
    ///
    ///      WHY IT EXISTS. Forest Road decided on 2026-09-10 that the first PIK period accrues from
    ///      FUNDING. Once it does, a short enough window rounds to zero, `_planPik` reverts
    ///      `Waterfall_PikBelowScaleGrid` at zero, and because `ClaimBridge.nextPaymentDue` advances
    ///      ONLY inside `capitalizePik` the facility would be frozen for life by its own first crank -
    ///      the exact shape the whole PIK liveness family fights. Refusing it at `fund` fails closed
    ///      before any value moves, and the remedy is the operator's: amend the schedule, or fund
    ///      sooner.
    ///
    ///      UNREACHABLE AT REALISTIC SCALE, which is why it is a guard and not a redesign: a
    ///      1,000,000e18 facility at 1,400 bps needs a sub-millisecond window to round to nothing.
    ///      The grid is the asset's own, read from the same `assetRecord(asset).scale` `_planPik`
    ///      uses, because this instance is multi-asset.
    ///
    ///      IT IS A SEPARATE FUNCTION FOR A COMPILER REASON, NOT A STYLE ONE. See the note at the
    ///      call site: inline, `fund` exceeds solc's stack limit on this tree.
    function _requireFirstPikPeriodIsExpressible(
        WaterfallStorage storage $,
        uint256 tokenId,
        ClaimBridge.Facility memory f,
        address asset,
        uint64 fundedAt
    ) private view {
        if (!f.pik) return;
        if (f.principal > type(uint176).max) revert Waterfall_PikExposureCapacity(tokenId);
        uint256 window = uint256(f.nextPaymentDue) - uint256(fundedAt);
        uint256 grid = $.reserves.assetRecord(asset).scale;
        uint256 accrual =
            Math.mulDiv(f.principal, uint256(f.interestRateBps) * window, uint256(Config.BPS) * _ACTUAL360_YEAR);
        if (accrual < grid) revert Waterfall_PikFirstPeriodBelowScaleGrid(tokenId, window, grid);
    }

    /// @notice The planner, exposed so `pikCrankBlockedByProtocol` can ASK it rather than
    ///         re-implement its refusals. Reverts exactly as `capitalizePik` would.
    /// @dev External only because `try/catch` cannot be applied to an internal call. It is a
    ///      `view`, so `this.planPik(...)` is a staticcall to self and can mutate nothing.
    function planPik(uint256 tokenId) external view returns (PikPlan memory) {
        if (_accrualEnabled(_storage())) revert Waterfall_AccrualManagedPik(tokenId);
        return _planPik(_storage(), tokenId);
    }

    /// @notice True when the PIK crank WOULD RUN right now: the period has elapsed and the planner
    ///         accepts it, so the facility is current on its own terms and the only thing missing is
    ///         that nobody has turned the crank.
    ///
    /// @dev ADDED BY ROUND SEVEN, 2026-09-10. `pikCrankBlockedByProtocol` answers "is the crank
    ///      blocked", and returns FALSE for two states that are nothing alike: the crank would run,
    ///      and the crank is refused for a borrower-side reason. `DefaultManager.markPastDue` treated
    ///      both as permission to mark, so a PIK facility whose `capitalizePik` would succeed in the
    ///      SAME BLOCK was permissionlessly markable - for a period the protocol was ready to settle
    ///      and that the marker themselves could have settled for gas. Verified medium.
    ///
    ///      THE REMEDY IS TO CRANK, NOT TO MARK, and that is what makes refusing the mark here safe
    ///      rather than a shelter. Anyone at all can call `capitalizePik`; the state is exited by one
    ///      permissionless transaction that either advances the schedule (the borrower is current) or
    ///      reveals the next blocker. It is categorically different from a protocol-side block, which
    ///      the caller cannot clear at any price.
    ///
    ///      IT IS STILL BOUNDED, and the bound is the same one. `markPastDue` applies its capped
    ///      grace extension to this answer too, so if this view is WRONG - and it can be, because
    ///      `_planPik` is a `view` that never touches the seven external calls `capitalizePik` makes
    ///      after it, which is round seven's registry-blindness finding - the mistake costs one grace
    ///      window and then the facility is markable regardless. A tri-state bounded by elapsed time
    ///      cannot be turned into a permanent shelter by a view that is merely incomplete.
    function pikCrankIsDue(uint256 tokenId) external view returns (bool) {
        // THE PAUSE, FIRST, BECAUSE `_planPik` CANNOT SEE IT. `planPik` is a plain `view` with no
        // `whenNotPaused`, so without this line the function returned TRUE while `capitalizePik`
        // reverted `EnforcedPause` - its name and NatSpec were false, and `markPastDue` was relying
        // on the ORDER of its two limbs to mask it. Round eight found it and both verifiers
        // reproduced it. Fixing it here makes the two limbs order-independent and makes the view mean
        // what it says, which matters because it is public and a keeper or integrator would build on
        // it. The residual blindness to the three MODULE pauses and to the seven write-path calls
        // `capitalizePik` makes after planning is a known, recorded imprecision, bounded by
        // `markPastDue`'s capped grace extension; the engine's own pause was free to fix.
        if (paused()) return false;
        WaterfallStorage storage $ = _storage();
        if (_accrualEnabled($)) {
            if (_reentrancyGuardEntered()) return false;
            (bool due,) = WaterfallAccrualLib.status($.accrualReserve, address($.bridge), tokenId);
            return due;
        }
        if (!$.bridge.facility(tokenId).pik) return false;
        try this.planPik(tokenId) returns (PikPlan memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice True when the PIK crank is refused for a reason the PROTOCOL created, rather than
    ///         anything the borrower did or failed to do.
    ///
    /// @dev WHY THIS EXISTS. `ClaimBridge.nextPaymentDue` advances for a PIK facility in exactly one
    ///      place, `capitalizePik`, so anything that refuses the crank stops the schedule and turns
    ///      a borrower performing exactly as contracted into a permissionlessly markable past-due
    ///      facility. `DefaultManager.markPastDue` consults this so it can decline to manufacture a
    ///      credit event out of the protocol's own refusal.
    ///
    ///      IT ASKS THE PLANNER INSTEAD OF ENUMERATING ITS REFUSALS, AND THAT REWRITE IS THE POINT.
    ///      The first version listed the protocol-side blockers it knew about. That list was wrong
    ///      TWICE IN ONE NIGHT, both times found by the round attacking it: it omitted the
    ///      unsupported rate-type and day-count refusals, and it carried the post-maturity carve-out
    ///      on one limb and not the other, which left a facility that reached the BALANCE CAP and
    ///      then matured without paying unmarkable for ever, with 3,000,000e18 of deployed principal
    ///      at risk and `pendingSeniorImpairment()` reading zero. An enumeration has to be
    ///      re-derived every time `_planPik` gains a refusal, and nothing makes anyone do that.
    ///
    ///      Running the real planner inverts the maintenance burden: any refusal `_planPik` gains is
    ///      covered from the moment it is written. What must be maintained instead is the SHORT,
    ///      CLOSED list of refusals that are NOT the protocol's doing.
    ///
    ///      THE EXCLUSIONS, and why none of them is a protocol-side block:
    ///        - `Waterfall_PikPastDue` and `Waterfall_PikNotPerforming` are BORROWER-side. Reporting
    ///          them would shelter a facility that is already marked or already defaulted, which is
    ///          the under-marking direction D5-03 names as the dangerous one.
    ///        - `Waterfall_PikIntervalNotElapsed`: the period is not due yet, so nothing is blocked.
    ///        - `Waterfall_PikNothingOutstanding`: the facility owes nothing.
    ///        - `Waterfall_PikNotFunded`: there is no live schedule to stop.
    ///      Everything else `_planPik` can raise is the protocol declining to service terms it
    ///      accepted, and shelters.
    ///
    ///      THERE IS NO MATURITY TEST IN THIS FUNCTION ANY MORE, AND ITS ABSENCE IS THE FIX.
    ///      Three consecutive adversarial rounds found three defects here and every one of them was
    ///      an argument about where a maturity test sits relative to a shelter: round five had the
    ///      carve-out on one limb and not its sibling; round six had `if (paused()) return true;`
    ///      above the post-maturity return, which made two NatSpec paragraphs, a test comment and a
    ///      handover line false as shipped; round seven then showed the PREMISE under both fixes was
    ///      wrong, because `distribute` is itself `whenNotPaused`, so after maturity a pause refuses
    ///      the borrower's balloon as well as the crank and "why the crank stopped has no bearing on
    ///      whether the borrower paid" was simply untrue. Reproduced to the wei by two independent
    ///      verifiers on 2026-09-10.
    ///
    ///      So this view answers ONE question and carries no bound at all: IS THE CRANK BLOCKED BY
    ///      THE PROTOCOL RIGHT NOW. `DefaultManager.markPastDue` owns the bound, and owns it as a
    ///      capped grace extension measured in elapsed time rather than as a test against any
    ///      movable field - `maturity` is movable by `amendTerms`, which is how round seven composed
    ///      four rolls into a 2,919-day shelter against the previous design. A bound in elapsed time
    ///      cannot be reached through a predicate nobody enumerated, which is what each of the three
    ///      defects above actually was. See the long note at that call site.
    ///
    ///      CONSEQUENCE FOR CALLERS: a `true` from this function no longer means "not markable". It
    ///      means "the crank cannot run", which buys the borrower one class grace window and nothing
    ///      more. A caller that treats it as a veto is reintroducing the unbounded shelter.
    function pikCrankBlockedByProtocol(uint256 tokenId) external view returns (bool) {
        WaterfallStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (!f.pik) return false;
        if (paused()) return true;
        if (_accrualEnabled($)) {
            if (_reentrancyGuardEntered()) return true;
            (, bool blocked) = WaterfallAccrualLib.status($.accrualReserve, address($.bridge), tokenId);
            return blocked;
        }

        // THE TWO CLOCKS MUST AGREE, AND ONLY AN AMENDMENT CAN MAKE THEM DISAGREE.
        // `fund` anchors the cursor so that `cur.lastAt + cur.interval == f.nextPaymentDue`
        // (:240-245), and `capitalizePik` preserves that equality on every crank. Nothing else in
        // this contract writes `pikCursor`, and no other contract references it at all.
        //
        // `ClaimBridge.amendTerms` writes `paymentInterval` and `nextPaymentDue` and touches the
        // cursor not at all, so it can break the equality, and the two consumers then read
        // DIFFERENT CLOCKS: `_planPik` takes the period's due date from the cursor, while
        // `DefaultManager.markPastDue` takes it from the facility. An amendment that moves
        // `nextPaymentDue` EARLIER therefore makes a performing PIK facility markable while this
        // engine still considers the period un-elapsed and refuses to crank. The borrower cannot
        // act either way: under PIK the capitalisation IS the payment, and only the crank makes it.
        //
        // Reporting the disagreement as protocol-side is the sheltering half of the fix, and it is
        // bounded by `markPastDue`'s capped grace extension - one class grace window, whatever the
        // blocker - so it can never hide a non-payer for longer than that, matured or not. It used to
        // be bounded by a post-maturity return in this function; round seven showed that bound was
        // both movable (`amendTerms` writes `maturity`) and premised on a falsehood (`distribute` is
        // `whenNotPaused` too), so the bound moved out of here entirely. The DEEPER fix is to stop the
        // state arising, by having an amendment re-anchor the cursor the way `fund` does; that needs a
        // cross-module call ClaimBridge does not have today and is recorded as open rather than
        // invented here. Found by an adversarial round on 2026-09-10.
        PikCursor memory cur = $.pikCursor[tokenId];
        if (cur.lastAt != 0 && cur.interval != 0) {
            if (uint256(cur.lastAt) + uint256(cur.interval) != uint256(f.nextPaymentDue)) return true;
        }

        try this.planPik(tokenId) returns (PikPlan memory) {
            return false; // the crank would run
        } catch (bytes memory err) {
            return !_isBorrowerSideRefusal(err);
        }
    }

    /// @dev The closed list of `_planPik` refusals that are NOT the protocol declining to service
    ///      the facility. A revert this cannot decode (an out-of-gas bubble, a panic, an error added
    ///      later) counts as protocol-side and therefore reports blocked; that direction is bounded by
    ///      `markPastDue`'s capped grace extension rather than by anything in this function. Two
    ///      earlier versions of this sentence claimed a post-maturity return in this function carried
    ///      the bound; the first was false as shipped (round six) and the second rested on a false
    ///      premise (round seven). There is no bound here now, by design, and a caller that reads a
    ///      `true` from this view as a veto rather than as a one-window delay reintroduces the
    ///      unbounded shelter all three rounds kept finding.
    function _isBorrowerSideRefusal(bytes memory err) private pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(err, 0x20))
        }
        return selector == IWaterfallEngine.Waterfall_PikPastDue.selector
            || selector == IWaterfallEngine.Waterfall_PikNotPerforming.selector
            || selector == IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector
            || selector == IWaterfallEngine.Waterfall_PikNothingOutstanding.selector
            || selector == IWaterfallEngine.Waterfall_PikNotFunded.selector;
    }

    /// @notice Where a facility's PIK capitalisation has reached, and at what rate the next one runs.
    /// @dev ONE SLOT. `lastAt` advances by exactly `paymentInterval` per capitalisation rather than
    ///      to `block.timestamp`, so a facility that goes uncranked for a year catches up one
    ///      interval per call and the schedule never drifts.
    ///
    ///      `rateBps` IS SNAPSHOTTED, AND THAT IS WHAT MAKES AMENDMENTS FORWARD-ONLY. `amendTerms`
    ///      is `ORIGINATOR_ROLE` and may raise `interestRateBps` up to `MAX_INTEREST_RATE_BPS`,
    ///      which is 100% a year. If capitalisation read the LIVE rate it would apply a raised rate
    ///      to the whole elapsed period, minting retroactively against a term that was not in force
    ///      when the period ran. Accruing at the snapshot and refreshing it afterwards means a rate
    ///      change takes effect from the interval AFTER it lands. The cost is that the interval
    ///      spanning an amendment runs at the old rate; anyone may crank immediately before an
    ///      amendment to shrink that window to nothing, because the entry point is permissionless.
    struct PikCursor {
        uint64 lastAt;
        uint16 rateBps;
        /// @dev The balance the NEXT interval accrues on: the facility's balance as at the last
        ///      capitalisation. Accruing on the balance read at CRANK time instead made the amount
        ///      depend on whether a repayment happened to land before or after the crank, which
        ///      breaks the path-independence the fixed interval exists to guarantee.
        ///
        ///      CORRECTED 2026-09-09. This used to say the accrual base was `min(basis, outstanding)`.
        ///      That formula was a NO-OP and is gone: every writer of `deployed[]` either raises it
        ///      and re-syncs `basis` or lowers it, so `outstanding <= basis` invariantly and the min
        ///      was identically the crank-time balance. It is `cur.basis` now, and while a backlog
        ///      stands the basis compounds from itself rather than adopting the live balance.
        uint176 basis;
        /// @dev THE CONTRACTUAL INTERVAL THE SETTLED PERIOD RAN AT, snapshotted for exactly the
        ///      reason `rateBps` is. Reading it live let an amendment reprice periods that had
        ///      already elapsed: lengthening collapsed N compounding periods into one simple-interest
        ///      period and jumped the cursor by the whole new interval, shortening raised the
        ///      compounding frequency retroactively. Measured on three elapsed 30-day intervals
        ///      doubled to 60 days: 23,333.33e18 against 35,409.92e18. TAIL-APPENDED 2026-09-09,
        ///      which pushes the cursor to a second slot; that is the baselineable class and the
        ///      mapping holds no pre-existing entry, since every facility funded before PIK has a
        ///      zero `lastAt` and is refused by the migration guard.
        uint64 interval;
        /// @dev THE BLOCK THE FACILITY WAS FUNDED AT, and the FIRST period accrues from it rather
        ///      than from the schedule anchor. TAIL-APPENDED 2026-09-10 on Forest Road direction.
        ///
        ///      THE DEFECT IT CLOSES. `fund` anchors `lastAt` at `nextPaymentDue - paymentInterval`
        ///      so the two clocks agree, and `checkFundable` permits funding any time strictly
        ///      before `nextPaymentDue`. So the anchor can precede funding by almost a whole
        ///      interval - the source's own example is originate at t0, fund at t0+25d with a 30-day
        ///      interval - while the accrual charged a WHOLE interval regardless. The first crank
        ///      therefore capitalised interest for days on which no principal was drawn and minted
        ///      the difference to the senior vault as yield: a receivable the borrower does not owe,
        ///      which is the same phantom-receivable shape the PIK designation gate exists to
        ///      prevent. Found by an adversarial round 2026-09-10 and confirmed medium by two
        ///      independent verifiers.
        ///
        ///      FOREST ROAD DECIDED THE MECHANIC, NOT THIS CODE. The question was whether the first
        ///      PIK period accrues from the SIGNED SCHEDULE ANCHOR or from FUNDING - both are real
        ///      commercial conventions, the attesters sign `nextPaymentDue` and `paymentInterval`,
        ///      and guessing a financial mechanic is a directive-5 stop. The answer was FUNDING.
        ///
        ///      IT AFFECTS THE FIRST PERIOD ONLY, by construction rather than by a flag. The accrual
        ///      window is `dueAt - max(lastAt, fundedAt)`; after the first crank `lastAt` is the
        ///      previous `dueAt`, which is always later than `fundedAt`, so `max` selects `lastAt`
        ///      and every later period runs a full contractual interval again.
        ///
        ///      ZERO MEANS A PRE-FEATURE FACILITY and falls back to the full interval. Every
        ///      facility funded before this field existed reads zero here, exactly as it reads zero
        ///      `lastAt` before PIK shipped, and the migration guard already refuses those. The
        ///      fallback is therefore unreachable for a live facility and is defensive.
        uint64 fundedAt;
    }

    /// @dev Everything one capitalisation needs, determined before any state moves. Memory-only.
    struct PikPlan {
        uint256 amount;
        uint256 balanceAfter;
        /// @dev THE BASE THE NEXT PERIOD ACCRUES ON, which is NOT always `balanceAfter`.
        ///      While a backlog stands they differ, and that difference is the whole point:
        ///      see the catch-up note in `_planPik`.
        uint256 nextBasis;
        /// @dev The interval the NEXT period runs at. Refreshed under the same catch-up predicate
        ///      as the rate and the basis, so an amendment is forward-only across a backlog.
        uint64 nextInterval;
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        address asset;
        uint64 dueAt;
        uint64 interval;
        uint64 previousDue;
        uint64 maturity;
        uint16 periodRateBps;
        uint16 nextRateBps;
    }

    /// @dev Keeps the receipt's pre-operation facts together without exceeding the non-IR stack.
    struct ReceiptContext {
        ClaimBridge.Facility facility;
        uint256 deficitBefore;
        uint256 roundingBefore;
        bool continuous;
        bool performing;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.WaterfallEngine")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WATERFALL_STORAGE_LOCATION =
        0xcf0c34fc0be88a30eafd83d03dde401c38c60299c8a6f87d9915e05fa29cdd00;

    /// @notice Emitted when the DefaultManager resolve hook is wired or cleared (ADR-0022).
    /// @param manager The DefaultManager address, or zero when the hook is disabled.
    event DefaultManagerSet(address indexed manager);

    /// @notice The native reserve was permanently bound as the servicing accounting source.
    event AccrualReserveSet(address indexed reserve);
    /// @notice An attested receipt discharged already recognized debt without issuing new yield.
    event AccruedReceiptSettled(uint256 indexed tokenId, bytes32 indexed paymentId, uint256 outstanding);
    /// @notice Bounded maintenance advanced the portfolio and possibly this loan's PIK principal.
    event AccrualCheckpointed(uint256 indexed tokenId, uint256 processed, bool fresh, uint256 capitalized);

    /// @notice A continuous accounting source is already permanently bound.
    error Waterfall_AccrualAlreadyBound();
    /// @notice A servicing operation is already in progress in this waterfall.
    error Waterfall_AccrualOperationInProgress();
    /// @notice A governed route change would contradict the permanent source identities.
    error Waterfall_AccrualModuleMismatch();
    /// @notice The reserve's book owns this facility's continuous schedule and debt quotation.
    error Waterfall_AccrualManagedPik(uint256 tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Wiring bundle for `initialize` (flat addresses exceed stack depth).
    struct InitModules {
        address bridge; // facility register (states + metadata)
        address registry; // collateral registry (exposure decreases on principal return)
        address reserves; // canonical-USDC treasury
        address controller; // mint controller (yield mints; asserts backing)
        address vault; // the sUSDfr vault (senior yield destination)
        address feeRecipient; // protocol fee destination (Forest Road treasury)
        address oracle; // attestation oracle (payment gate; ADR-0007 trust)
    }

    /// @notice Initializes the engine with the launch-default protocol fee.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param m The wired protocol modules (see `InitModules` field docs).
    function initialize(address admin, address guardian, address upgrader, InitModules calldata m)
        external
        initializer
    {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || m.bridge == address(0)
                || m.registry == address(0) || m.reserves == address(0) || m.controller == address(0)
                || m.vault == address(0) || m.feeRecipient == address(0) || m.oracle == address(0)
        ) revert Waterfall_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        WaterfallStorage storage $ = _storage();
        $.bridge = ClaimBridge(m.bridge);
        $.registry = ICollateralRegistry(m.registry);
        $.reserves = IReserveManager(m.reserves);
        $.controller = IMintRedeemController(m.controller);
        $.vault = m.vault;
        $.feeRecipient = m.feeRecipient;
        $.oracle = IAttestationOracle(m.oracle);
        $.protocolFeeBps = uint16(Config.DEFAULT_PROTOCOL_FEE_BPS);
        emit ProtocolFeeSet(uint16(Config.DEFAULT_PROTOCOL_FEE_BPS));
        emit FeeRecipientSet(m.feeRecipient);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.originationFeeBps[classId] = Config.DEFAULT_ORIGINATION_FEE_BPS;
            emit OriginationFeeSet(classId, Config.DEFAULT_ORIGINATION_FEE_BPS);
        }
    }

    // -- Servicing paths --------------------------------------------------

    /// @notice Permanently binds the already configured native reserve after token binding.
    /// @dev All native module identities must already be wired, including the default manager.
    function setAccrualReserve(address reserve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualIdle();
        WaterfallStorage storage $ = _storage();
        if ($.accrualReserve != address(0)) revert Waterfall_AccrualAlreadyBound();
        if (reserve != address($.reserves)) revert WaterfallAccrualLib.WaterfallAccrual_InvalidReserve(reserve);
        WaterfallAccrualLib.validate(
            reserve,
            IContinuousAccrual.Modules({
                token: address(0),
                controller: address($.controller),
                vault: $.vault,
                waterfall: address(this),
                bridge: address($.bridge),
                registry: address($.registry),
                defaultManager: address($.defaultManager)
            }),
            address($.oracle)
        );
        IAccrualExposure(reserve).requireAccrualIdle();
        $.accrualReserve = reserve;
        emit AccrualReserveSet(reserve);
    }

    /// @notice The permanent accounting reserve, or zero before continuous integration.
    function accrualReserve() external view returns (address) {
        return _storage().accrualReserve;
    }

    /// @inheritdoc IWaterfallEngine
    /// @dev Single-shot exact-principal funding: the deployment must equal the
    ///      originated principal precisely, so the position NFT, reserve accounting,
    ///      and registry exposure all describe the same number from day one.
    ///
    ///      ORIGINATION FEE (ADR-0019, OID mechanics): the borrower nets
    ///      `principal - fee`; the fee's stables never leave the treasury, so they are
    ///      capitalized into the facility's deployed principal (the claim is the FULL
    ///      principal) and the fee mints to the protocol fee recipient against that
    ///      raised backing - the mint's backing assertion keeps this exact. The fee is
    ///      floored to a whole stable unit so no dust is taken from the borrower.
    function fund(uint256 tokenId, address asset, uint256 assetAmount)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
        whenNotPaused
    {
        _requireAccrualFresh();
        if (asset == address(0)) revert Waterfall_ZeroAddress();
        WaterfallStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Pending) revert Waterfall_NotFundable(tokenId);
        // AUDIT FIX (M-01): re-validate maturity, class activity, required attestations and
        // marked-to-market freshness/LTV immediately before funds leave the treasury -
        // origination's gate is point-in-time and a pending facility can decay after it.
        $.bridge.checkFundable(tokenId);

        // BSC (ADR-0037 D1): scale is PER-ASSET STORAGE, so the normalisation names the asset.
        // `normalizeUnits` reverts on an unlisted asset, which is the listing gate for this path.
        uint256 value = $.reserves.normalizeUnits(asset, assetAmount);
        if (value != f.principal) revert Waterfall_PrincipalMismatch(tokenId, f.principal, value);

        uint256 feeUnits = Math.mulDiv(assetAmount, $.originationFeeBps[f.classId], Config.BPS);
        uint256 fee = $.reserves.normalizeUnits(asset, feeUnits);

        // THE PIK CLOCK IS ANCHORED TO THE PAYMENT SCHEDULE, NOT TO THE FUNDING BLOCK, and the
        // difference is not cosmetic. Anchoring at `block.timestamp` made the first capitalisation
        // due one interval after FUNDING while `nextPaymentDue` was set one interval after
        // ORIGINATION. Any lag between the two - and `checkFundable` permits up to a whole interval
        // of it - meant the facility passed its payment date before its first interval had elapsed,
        // so any passer-by could `markPastDue` a borrower who had done nothing wrong. That mark then
        // blocks capitalisation permanently, because the past-due gate is only cleared by a servicer
        // cure, a default, or full repayment. Measured: originate at t0 with a 30-day interval, fund
        // at t0+25d, and the facility never capitalises once in its life.
        //
        // Anchoring at `nextPaymentDue - paymentInterval` makes the two clocks agree by
        // construction: the first crank is due exactly when the first payment is, and the crank
        // advances the schedule from there.
        //
        // AND THE FIRST PERIOD ACCRUES FROM HERE, NOT FROM THE ANCHOR (Forest Road, 2026-09-10).
        // `checkFundable` requires `nextPaymentDue > block.timestamp`, so the remaining first-period
        // window is always at least one second; what it does NOT guarantee is that the window is
        // long enough for the interest to be expressible on the FACILITY ASSET's grid, which on this
        // multi-asset instance is per-asset rather than a single USDC scale. `_planPik` rounds the
        // amount down onto that grid and reverts `Waterfall_PikBelowScaleGrid` at zero, and because
        // `nextPaymentDue` advances only inside `capitalizePik`, a facility funded too late in its
        // first period would be frozen for life by its own first crank. Refusing it HERE fails
        // closed before any value moves, and the remedy is in the operator's hands: amend the
        // schedule, or fund sooner. Unreachable at mainnet scale - a 1,000,000e18 facility at
        // 1,400 bps needs a sub-millisecond window to round to nothing - and cheap insurance for the
        // small-principal, low-rate corner where it is not. The grid is the asset's own, read from
        // `assetRecord(asset).scale`, the same source `_planPik` uses.
        //
        // THE CHECK IS A PRIVATE HELPER ON THIS TREE, AND THAT IS LOAD-BEARING. `fund` here takes an
        // `asset` parameter the Ethereum twin does not, so it sits three stack slots closer to the
        // limit: written inline with four named locals it failed to compile with solc's "Stack too
        // deep", and `--via-ir` is not available for this build. Scoping the temporaries in a braced
        // block was not enough either. Do not inline it back.
        uint64 fundedAt = uint64(block.timestamp);
        if (!_accrualEnabled($)) _requireFirstPikPeriodIsExpressible($, tokenId, f, asset, fundedAt);

        $.pikCursor[tokenId] = PikCursor({
            lastAt: f.nextPaymentDue - f.paymentInterval,
            rateBps: f.interestRateBps,
            basis: uint176(f.principal),
            interval: f.paymentInterval,
            fundedAt: fundedAt
        });

        $.reserves.recordDeployment(tokenId, asset, f.fundingRecipient, assetAmount - feeUnits);
        if (fee != 0) {
            $.reserves.recordFeeCapitalization(tokenId, asset, fee); // deployed == full principal
            // AUDIT FIX (R18) - LOAD-BEARING, DO NOT DELETE THE CLAMP. This mint used to be the
            // ONE `mintYield` caller in the tree not sized off `mintableHeadroom()` - `capitalizePik`
            // is now a second unclamped caller, and deliberately so: it CANNOT clamp, because a
            // partial mint would leave backing above supply by the withheld amount and that phantom
            // surplus is absorbed pre-cascade. It reaches the same retention through
            // `beginPairedYield` instead, which makes the check non-worsening for a move that is
            // surplus-neutral by construction. That made
            // `MintRedeemController`'s senior retention a FREEZE ON ORIGINATION. Once any sub-par
            // exit had crystallised a haircut, `Controller_SeniorRetentionBreached` refused this
            // mint - including on a book the protocol publishes as WHOLE or over-backed - so no new
            // facility could be funded. The only cure the retention's own NatSpec named is withheld
            // interest, interest requires a performing facility, and a facility requires this call:
            // finding M5's "permanently inert with no protocol-native cure" restored on the
            // origination axis. The same shape reached it through the pause axis, because
            // `mintableHeadroom()` reads zero while either the controller or USDfr is paused.
            //
            // THE CLAMP IS READ AFTER `recordFeeCapitalization`, ON PURPOSE. That call has already
            // raised backing by exactly `fee`, so whenever the retention is zero and neither pause
            // is engaged `headroom >= fee` holds and the healthy path is BIT-FOR-BIT UNCHANGED -
            // there is no behaviour change to the ordinary origination, only to the states that
            // previously reverted. The withheld part stays in the treasury as unencumbered backing,
            // which is precisely what rebuilds the surplus the retention requires, so the mechanism
            // becomes self-clearing again instead of self-latching.
            //
            // THIS IS THE SAME POSTURE `_routeInterest` ALREADY DOCUMENTS for the interest leg:
            // "Forest Road does not collect a performance fee out of a shortfall". `OriginationFeeCharged`
            // still reports the FULL `fee`, because that is what the borrower was charged and it is
            // capitalised into their principal either way; `OriginationFeeWithheldForBackingRepair`
            // reports the part that was not minted to the fee recipient, so the two events
            // reconstruct the split from logs alone (CLAUDE.md section 3.1). Whether the withheld fee is
            // forgone or deferred is a Forest Road revenue decision (ADR-0019) and is NOT taken
            // here: nothing accrues a claim to it, so today it is forgone.
            uint256 headroom = $.controller.mintableHeadroom();
            uint256 mintable = fee <= headroom ? fee : headroom;
            if (mintable != 0) $.controller.mintYield($.feeRecipient, mintable); // asserts backing post-mint
            if (mintable != fee) {
                emit OriginationFeeWithheldForBackingRepair(tokenId, fee - mintable, $.controller.recognizedDeficit());
            }
            emit OriginationFeeCharged(tokenId, f.classId, fee);
        }
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Active);
        if (_accrualEnabled($)) IAccrualLifecycle($.accrualReserve).registerAccruingLoan(tokenId);
        emit Funded(tokenId, f.fundingRecipient, f.principal);
    }

    /// @inheritdoc IWaterfallEngine
    function distribute(Payment calldata payment) external onlyRole(Roles.SERVICER_ROLE) nonReentrant whenNotPaused {
        _requireAccrualFresh();
        if (payment.interest == 0 && payment.principal == 0) revert Waterfall_ZeroAmount();
        WaterfallStorage storage $ = _storage();
        // AUDIT FIX (R16-M4). Snapshotted for the closing gate below, which is now NON-WORSENING
        // rather than absolute. Read at the very top, before any accounting moves.
        ReceiptContext memory context;
        context.deficitBefore = $.controller.recognizedDeficit();
        context.facility = $.bridge.facility(payment.tokenId);
        context.continuous = _accrualEnabled($);
        if (context.continuous) {
            context.roundingBefore = IAccrualRounding($.accrualReserve).roundingLossUnabsorbed();
        }

        // A PIK FACILITY NEVER SETTLES A PERIOD IN CASH. Without this the same period could be
        // settled twice: the interest leg routes to the vault and advances `nextPaymentDue`, the
        // cursor is untouched, and the permissionless crank then capitalises the period anyway,
        // leaving a receivable nobody owes. Principal is unaffected, which is the leg a PIK facility
        // actually uses, because capitalised interest compounds into principal and comes back that
        // way (spec decision 7). The designation cannot be amended, so this can never be a
        // legitimate transitional state.
        if (context.facility.pik && payment.interest != 0) {
            revert Waterfall_PikCashInterestNotPermitted(payment.tokenId);
        }

        context.performing = context.facility.state == ClaimBridge.LoanState.Active
            || context.facility.state == ClaimBridge.LoanState.Amortizing;
        // The `recovery` half of this test was a named local; it is inlined because R16-M4's
        // `deficitBefore` snapshot pushed this function over the stack limit and `--via-ir` is
        // not an option for the shipped build. Same predicate, same states, no behaviour change.
        if (
            !context.performing && context.facility.state != ClaimBridge.LoanState.Defaulted
                && context.facility.state != ClaimBridge.LoanState.Accelerated
        ) {
            revert Waterfall_NotDistributable(payment.tokenId);
        }

        // the attested-fact gate (Phase G, ADR-0020) and the principal leg's reserve accounting.
        // EXTRACTED, NOT SIMPLIFIED: naming the facility's bound asset adds two words to this
        // frame and `--via-ir` is not an option for the shipped build, so the settlement moves
        // whole into `_settleReceipt`. Every check, and their order, is unchanged.
        uint256 outstanding = _settleReceipt($, payment, context.continuous);
        if (payment.principal != 0 || context.continuous) {
            $.registry.recordExposureDecrease(
                context.facility.classId,
                context.facility.borrowerId,
                context.facility.stateId,
                context.continuous ? payment.principal + payment.interest : payment.principal
            );
        }
        // A bullet schedule can legitimately arrive at its terminal due date while
        // principal remains outstanding. Interest-only and partial-principal receipts
        // at that point must remain serviceable, but there is no later legal due date
        // to write. Treat only the exact, attested maturity-to-maturity case as a
        // terminal no-op; every non-terminal schedule still advances strictly through
        // ClaimBridge.setNextPaymentDue.
        bool terminalDueNoOp = context.facility.nextPaymentDue == context.facility.maturity
            && payment.nextPaymentDue == context.facility.maturity;
        if (
            context.performing && outstanding != 0 && !terminalDueNoOp && (!context.continuous || !context.facility.pik)
        ) {
            $.bridge.setNextPaymentDue(payment.tokenId, payment.nextPaymentDue);
        }

        // -- interest leg: protocol fee -> senior vault --------------------
        uint256 fee = 0;
        uint256 toVault = 0;
        if (payment.interest != 0 && !context.continuous) {
            (fee, toVault) = _routeInterest($, payment.interest);
        } else {
            // Close the prior fee period before any lifecycle impairment change below.
            IsUSDfr($.vault).accrueFees();
        }

        // -- lifecycle: partial principal starts amortization; full repayment closes --
        // AUDIT FIX (M-03): a defaulted/accelerated facility that recovers its full
        // outstanding principal closes out to Resolved (was: it stayed Defaulted with the
        // NFT frozen). A performing facility repaying in full still closes to Repaid.
        if (payment.principal != 0 || context.continuous) {
            if (outstanding == 0) {
                if (!context.continuous && context.performing && context.facility.pik) {
                    uint64 pendingDue =
                        WaterfallAccrualLib.pendingLegacyPik($, payment.tokenId, context.facility.maturity);
                    if (pendingDue != 0) revert Waterfall_PikSettlementRequired(payment.tokenId, pendingDue);
                }
                $.bridge.transitionState(
                    payment.tokenId, context.performing ? ClaimBridge.LoanState.Repaid : ClaimBridge.LoanState.Resolved
                );
                // ADR-0022 (Option Y): a defaulted facility that recovered in FULL leaves the
                // unrealized-impairment pool here. Without this, `pendingSeniorImpairment()`
                // would carry the recovered facility's outstanding forever and permanently
                // depress the conservative redemption NAV after a clean workout. Ordered AFTER
                // the transition because `onDefaultResolved` defensively requires `Resolved`.
                // Optional wiring (zero = disabled) so the engine predates the manager in the
                // deploy/fixture ordering; NOT try/catch - a failure here must fail loudly
                // (CLAUDE.md prime directive 4) rather than silently over-mark impairment.
                IDefaultManager dm = $.defaultManager;
                if (!context.performing && address(dm) != address(0)) dm.onDefaultResolved(payment.tokenId);
                // AUDIT FIX (re-audit MEDIUM): a PERFORMING full repayment of a facility that was
                // past-due-marked (a bystander marked it, then it cured through this ordinary path)
                // must clear the past-due mark, else the conservative NAV stays depressed by the
                // whole mark-time snapshot until a manual `clearPastDue`. No-op if not flagged.
                if (context.performing && address(dm) != address(0)) dm.onPerformingRepayment(payment.tokenId);
                if (context.continuous) IAccrualReceipts($.accrualReserve).retireAccruedLoan(payment.tokenId);
            } else if (context.performing) {
                if (context.facility.state == ClaimBridge.LoanState.Active && payment.principal != 0) {
                    $.bridge.transitionState(payment.tokenId, ClaimBridge.LoanState.Amortizing);
                }
                // AUDIT FIX (re-audit MEDIUM): re-anchor a past-due mark DOWN to live `deployedTo`
                // as the facility amortizes, mirroring the `onDefaultRecovery` re-anchor on the
                // defaulted path - else a past-due partial paydown over-marks by the amount repaid.
                // No-op if not flagged.
                IDefaultManager dm = $.defaultManager;
                if (address(dm) != address(0)) dm.onPerformingRepayment(payment.tokenId);
            } else {
                // AUDIT FIX (H-2): a PARTIAL recovery on a defaulted facility. `deployedTo` just
                // fell by `principal`, but the DefaultManager's impairment contribution was
                // snapshotted at declare and has no other way down - `realizeLoss` is the only
                // one, and a servicer must not write off principal still being collected. Left
                // unsaid, the conservative redemption NAV carried a haircut for money that came
                // back in cash, for the life of the workout and beyond (nothing cleared it).
                // Mirrors the full-recovery `onDefaultResolved` call above: same optional
                // wiring (zero = disabled, so the engine can predate the manager), and NOT
                // try/catch - a failure here fails loudly (CLAUDE.md prime directive 4) rather
                // than silently over-marking impairment.
                IDefaultManager dm = $.defaultManager;
                if (address(dm) != address(0)) dm.onDefaultRecovery(payment.tokenId);
            }
        }

        // AUDIT FIX (M): the principal leg lowers deployed principal (backing) with no
        // mint/burn, so on the interest==0 path nothing else asserts backing. The
        // returning stables MUST have arrived in the treasury this transaction (attested
        // PaymentReceived, ADR-0007); enforce it on-chain rather than trust the input -
        // fail loudly (CLAUDE.md prime directive 4) instead of silently unbacking supply.
        //
        // AUDIT FIX (R16-M4) - NON-WORSENING, NOT ABSOLUTE. This was
        // `if (!$.controller.backingInvariantHolds())`, an ABSOLUTE gate, and it is the third
        // place the same defect appeared: once a loss was recognised anywhere, the whole
        // repayment path shut down, INCLUDING a pure-principal repayment that returns cash and
        // strictly REPAIRS backing. A protocol that refuses to accept its borrowers' money
        // because it is short is the opposite of solvent. Measured the same recognition-aware
        // way as before (`recognizedDeficit()` nets the R4-01 custody shortfall, so a gap opening
        // mid-transaction still reverts) and identical to the old gate whenever the protocol
        // starts the call whole: `deficitBefore == 0` forces `deficitAfter == 0`, which IS
        // `backingInvariantHolds()`.
        _requireReceiptConservation($, payment.tokenId, context);

        if (context.continuous) emit AccruedReceiptSettled(payment.tokenId, payment.paymentId, outstanding);
        _emitDistributed(payment, fee, toVault);
    }

    // -- Governance -------------------------------------------------------

    /// @inheritdoc IWaterfallEngine
    /// @dev AUDIT FIX (SWEEP-2 S2-F1) - THE PERMANENT CEILING. DO NOT DELETE, DO NOT WIDEN BACK TO
    ///      `Config.BPS`. This was the only fee rate in the protocol with no permanent cap: 10,000
    ///      bps was accepted and took the whole senior yield leg, and a shipped unit test asserted
    ///      that outcome as expected behaviour (it is now INVERTED - see
    ///      `test/unit/WaterfallEngine.t.sol`). See `Config.MAX_PROTOCOL_FEE_BPS` for the full
    ///      finding, the measurement, and why timelocked-admin-can-upgrade-anything is not an
    ///      answer: a rate change is a far less visible governance act than a UUPS upgrade, and
    ///      this fee is taken FIRST, off the same senior income stream the vault's PUBLISHED 20%
    ///      performance cap protects.
    function setProtocolFee(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualIdle();
        if (feeBps > Config.MAX_PROTOCOL_FEE_BPS) revert Waterfall_BadFee(feeBps);
        WaterfallStorage storage $ = _storage();
        if (_accrualEnabled($)) IAccrualFeeConfig($.accrualReserve).setAccrualFee(feeBps, $.feeRecipient);
        $.protocolFeeBps = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    /// @notice Capitalises ONE contractual interval of PIK interest into a facility's principal.
    /// @dev PERMISSIONLESS, AND SAFE ONLY BECAUSE OF THE INTERVAL RULE. The amount is a pure
    ///      function of the facility's deployed balance, its signed rate and one `paymentInterval`;
    ///      the caller supplies nothing but a `tokenId` and can choose nothing. That is a stronger
    ///      up-move under ADR-0025 than any keyed assertion, and it matches `markPastDue`, which is
    ///      also permissionless.
    ///
    ///      WHY ONE INTERVAL AND NOT "TIME SINCE LAST CALL". An earlier draft accrued from `lastAt`
    ///      to `block.timestamp`, which handed a permissionless caller a real manipulation:
    ///      capitalisation compounds, so cranking every block compounds continuously and at the
    ///      100% ceiling yields e (2.718x a year) instead of 2x. Fixing the quantum at one
    ///      `paymentInterval` makes the total path-independent, so the frequency of calls cannot
    ///      change what is owed. It is also what the contract actually says: PIK capitalises on the
    ///      payment schedule, not continuously. A facility left uncranked catches up one interval
    ///      per call, and `lastAt` advances by exactly the interval so the schedule never drifts.
    ///
    ///      SURPLUS-NEUTRAL, AND THIS IS THE LOAD-BEARING PROPERTY. Backing rises by `amount` and
    ///      supply rises by the SAME `amount` in the same call, so `backing - supply` is unchanged.
    ///      `ReserveCascadeLib._recognize` absorbs a ratified loss out of that difference BEFORE the
    ///      cascade runs, so a term that raised backing alone would let losses skip the curator draw
    ///      entirely. That exact defect was proved and fixed in this tree on 2026-09-08. THE MINT IS
    ///      NOT CLAMPED TO HEADROOM the way `fund`'s fee mint is: a partial mint would leave backing
    ///      above supply by the withheld amount, which is the very phantom surplus this rule exists
    ///      to prevent. If the mint cannot happen in full the whole capitalisation reverts.
    ///
    ///      SCOPE. Fixed rate and Actual/360 only. `rateIndexRef` has no on-chain resolver, so
    ///      accruing a Variable facility at `interestRateBps` would recognise a rate nobody
    ///      observed, which is a directive-5 stop; `Thirty360` needs the exact civil-date count and
    ///      approximating it as Actual/360 over-accrues by about 1.39% a year, which is a
    ///      fabrication. Both revert rather than approximate.
    /// @param tokenId The facility.
    /// @return capitalised 18-decimal value added to the facility's deployed principal.
    function capitalizePik(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 capitalised) {
        WaterfallStorage storage $ = _storage();
        if (_accrualEnabled($)) {
            uint256 processed;
            bool fresh;
            (capitalised, processed, fresh) =
                WaterfallAccrualLib.checkpoint($.accrualReserve, address($.bridge), tokenId);
            emit AccrualCheckpointed(tokenId, processed, fresh, capitalised);
            return capitalised;
        }
        if ($.accrualReserve != address(0)) IAccrualExposure($.accrualReserve).requireAccrualIdle();
        // THE PLAN IS BUILT IN ITS OWN FRAME, and that is a stack-depth necessity rather than a
        // style choice. `--via-ir` is not available for the shipped build (see `foundry.toml`), and
        // holding the facility struct, the cursor, the ceiling arithmetic and the grid rounding in
        // one frame alongside the four external calls below overflows the stack. Returning a memory
        // struct costs one slot here and frees every local the validation needed.
        PikPlan memory plan = _planPik($, tokenId);

        // OPEN THE PAIRED BASELINE BEFORE ANY ACCOUNTING MOVES. `recordPikCapitalization` below
        // raises backing and `mintYield` further down raises supply by exactly the same amount, so
        // the deficit changes by nothing. `mintYield` used to snapshot for itself, AFTER backing
        // had already risen, and therefore read that neutral pair as a worsening and refused: one
        // USDC unit of conservative mark on an unrelated facility froze every PIK capitalisation in
        // the book, and because `nextPaymentDue` only advances inside this function, that turned
        // performing borrowers into permissionless past-due marks. This records the TRUE
        // pre-operation state so the non-worsening rule is measured properly rather than relaxed.
        $.controller.beginPairedYield();

        // `fundedAt` IS CARRIED, NOT CLEARED. It is a fact about the facility, not about the period,
        // and `_planPik` selects `max(lastAt, fundedAt)` - so once `lastAt` is a real settled due
        // date it dominates and the field stops affecting the accrual on its own. Clearing it would
        // make the cursor indistinguishable from a pre-feature one.
        $.pikCursor[tokenId] = PikCursor({
            lastAt: plan.dueAt,
            rateBps: plan.nextRateBps,
            basis: uint176(plan.nextBasis),
            interval: plan.nextInterval,
            fundedAt: $.pikCursor[tokenId].fundedAt
        });
        $.pikCapitalisedTotal[tokenId] += plan.amount;

        // THE SCHEDULE ADVANCES, BECAUSE A CAPITALISATION IS THE PAYMENT. A PIK facility never pays
        // cash on its interest date, so without this every PIK facility would sail past
        // `nextPaymentDue` and become permanently markable by any passer-by through
        // `DefaultManager.markPastDue` - which then blocks capitalisation for good and marks the
        // book down for a borrower who is performing exactly as contracted. `setNextPaymentDue`
        // refuses a non-advancing or post-maturity date, so a catch-up run that is still behind the
        // clock simply leaves it alone rather than reverting.
        uint64 nextDue = plan.dueAt + plan.interval;
        if (nextDue > plan.previousDue && nextDue <= plan.maturity) {
            $.bridge.setNextPaymentDue(tokenId, nextDue);
        }

        // EXPOSURE IS BOOKED, BUT THE ORIGINATION ADMISSION CHECK IS NOT RE-RUN. A growing PIK
        // balance is still a growing exposure to that borrower, class and state, and it is still
        // recorded in full: keeping registry exposure equal to deployed principal is what keeps the
        // facility WRITEABLE OFF, because `DefaultManager.realizeLoss` pairs the write-down with
        // `recordExposureDecrease`, which reverts `Registry_ExposureUnderflow` if exposure lags.
        //
        // WHAT CHANGED, 2026-09-10. This used to call `recordExposureIncrease`, which opens with
        // `_checkConcentration` and REVERTS on breach. Capitalisation consumes its own headroom, so
        // a PIK book grew into its own limit with no adversary at all and then froze; `_breaches` is
        // a strict `>`, so a facility funded at exactly the published headroom bricked on its FIRST
        // crank. And a frozen crank does not merely fail: `nextPaymentDue` only advances here, so it
        // converts a performing borrower into a permissionless past-due mark. The concentration
        // limit governs ADMISSION, and compounding interest is not an admission decision.
        // `recordCapitalizedExposure` still fires every breach flag and drift event, so the limit
        // keeps its whole observation function. Reproduced by
        // `test_FIXED_PIK_concentrationDoesNotFreezeTheCrank`; the origination path is held to the
        // old behaviour by `test_PIK_concentrationStillRefusesANewOrigination`.
        $.registry.recordCapitalizedExposure(plan.classId, plan.borrowerId, plan.stateId, plan.amount);
        $.reserves.recordPikCapitalization(tokenId, plan.asset, plan.amount);
        // Record the full receivable and issue matching supply. The protocol fee is taken
        // first; the senior net amount enters the normal performance-fee checkpoint.
        // Earned PIK uses the owner's full-accrual fee policy. ADV-1 withholding remains
        // on legacy cash receipts; applying it here would leave unowned receivable surplus
        // ahead of the loss cascade. Both PIK legs therefore share the complete paired mint.
        uint256 protocolFee = Math.mulDiv(plan.amount, $.protocolFeeBps, Config.BPS);
        uint256 seniorIncome = plan.amount - protocolFee;
        // Both fee legs share the same paired increase. The controller checks backing only
        // after issuing the complete total, preserving surplus even when retention is active.
        IsUSDfr($.vault).beginYieldNotification();
        $.controller.mintYieldSplit($.vault, plan.amount, $.feeRecipient, protocolFee);
        IsUSDfr($.vault).notifyYield(seniorIncome);
        IsUSDfr($.vault).accrueFees();

        emit PikInterestCapitalized(
            tokenId, plan.classId, plan.amount, plan.balanceAfter, plan.dueAt, plan.periodRateBps
        );
        return plan.amount;
    }

    /// @dev Everything `capitalizePik` must check and compute, in a frame of its own. Reverts on any
    ///      refusal; returns a fully determined plan otherwise.
    function _planPik(WaterfallStorage storage $, uint256 tokenId) private view returns (PikPlan memory plan) {
        return WaterfallAccrualLib.planLegacyPik($, tokenId);
    }

    /// @notice Next payable completed legacy coupon, independent of whether posting is paused.
    /// @dev Zero means no completed coupon is owed under the signed legacy schedule and asset grid.
    ///      A failing planner is never treated as proof of zero interest. Native books use their
    ///      own checkpoint route and are refused here.
    function pendingLegacyPik(uint256 tokenId) external view returns (uint64 dueAt) {
        WaterfallStorage storage $ = _storage();
        if (_accrualEnabled($)) revert Waterfall_AccrualManagedPik(tokenId);
        return WaterfallAccrualLib.pendingLegacyPik($, tokenId, $.bridge.facility(tokenId).maturity);
    }

    /// @notice Where a facility's PIK capitalisation has reached, and the rate the next one uses.
    function pikCursorOf(uint256 tokenId) external view returns (uint64 lastAt, uint16 rateBps) {
        PikCursor memory c = _storage().pikCursor[tokenId];
        return (c.lastAt, c.rateBps);
    }

    /// @notice Exports the original fixed-period cursor for authenticated prospective migration.
    /// @dev Historical metadata only: a continuously tracked facility uses the reserve's book.
    ///      No caller can select or change the old basis, accrual clock or snapshotted terms.
    function legacyPikCursor(uint256 tokenId)
        external
        view
        returns (uint64 lastAt, uint16 rateBps, uint176 basis, uint64 interval, uint64 fundedAt)
    {
        PikCursor memory c = _storage().pikCursor[tokenId];
        return (c.lastAt, c.rateBps, c.basis, c.interval, c.fundedAt);
    }

    /// @notice Cumulative PIK interest capitalised into a facility over its life. Disclosure only.
    function pikCapitalisedTotalOf(uint256 tokenId) external view returns (uint256) {
        return _storage().pikCapitalisedTotal[tokenId];
    }

    /// @notice The permanent v1 ceiling on the interest protocol fee, in bps.
    /// @dev AUDIT FIX (SWEEP-2 S2-F1). PUBLISHED, exactly as `sUSDfr.maxPerformanceFeeBps()` and
    ///      `maxManagementFeeBps()` are. An unpublished cap is a cap a holder cannot rely on.
    function maxProtocolFeeBps() external pure returns (uint16) {
        return Config.MAX_PROTOCOL_FEE_BPS;
    }

    /// @inheritdoc IWaterfallEngine
    function setOriginationFee(uint256 classId, uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualIdle();
        if (classId == 0 || classId > Config.NUM_CLASSES) revert Waterfall_UnknownClass(classId);
        if (feeBps > Config.MAX_ORIGINATION_FEE_BPS) revert Waterfall_BadFee(feeBps);
        _storage().originationFeeBps[classId] = feeBps;
        emit OriginationFeeSet(classId, feeBps);
    }

    /// @inheritdoc IWaterfallEngine
    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualIdle();
        if (recipient == address(0)) revert Waterfall_ZeroAddress();
        WaterfallStorage storage $ = _storage();
        if (_accrualEnabled($)) IAccrualFeeConfig($.accrualReserve).setAccrualFee($.protocolFeeBps, recipient);
        $.feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Wires the DefaultManager so a clean recovery clears the facility's
    ///         unrealized-impairment contribution (ADR-0022 Option Y).
    /// @dev An admin SETTER rather than an init arg deliberately: the DefaultManager is
    ///      constructed AFTER the WaterfallEngine in both the deploy script and the test
    ///      fixtures, so an init-arg would force a circular ordering. Zero clears the wiring
    ///      (the engine then behaves exactly as it did pre-ADR-0022). The engine must hold
    ///      `CREDIT_ROLE` on the manager for the hook to succeed.
    /// @param manager The DefaultManager address, or zero to disable the hook.
    function setDefaultManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualIdle();
        if (_storage().accrualReserve != address(0) && manager != address(_storage().defaultManager)) {
            revert Waterfall_AccrualModuleMismatch();
        }
        _storage().defaultManager = IDefaultManager(manager);
        emit DefaultManagerSet(manager);
    }

    /// @notice The wired DefaultManager (zero = resolve hook disabled).
    function defaultManager() external view returns (address) {
        return address(_storage().defaultManager);
    }

    // -- Guardian ---------------------------------------------------------

    /// @notice Pauses funding and distribution. Emergency use only.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _requireAccrualIdle();
        _pause();
    }

    /// @notice Unpauses.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _requireAccrualIdle();
        _unpause();
    }

    // -- Views ------------------------------------------------------------

    /// @inheritdoc IWaterfallEngine
    function protocolFeeBps() external view returns (uint16) {
        return _storage().protocolFeeBps;
    }

    /// @inheritdoc IWaterfallEngine
    function feeRecipient() external view returns (address) {
        return _storage().feeRecipient;
    }

    /// @inheritdoc IWaterfallEngine
    function originationFeeBps(uint256 classId) external view returns (uint16) {
        return _storage().originationFeeBps[classId];
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules()
        external
        view
        returns (address bridge, address registry, address reserves, address controller, address vault, address oracle)
    {
        WaterfallStorage storage $ = _storage();
        return (
            address($.bridge),
            address($.registry),
            address($.reserves),
            address($.controller),
            $.vault,
            address($.oracle)
        );
    }

    // -- Internals --------------------------------------------------------

    /// @dev A receipt cannot worsen the recognized deficit except by the source's exact, newly
    ///      allocated sub-unit rounding residual. The monotone source counter cannot authorize
    ///      unrelated loss or caller-selected forgiveness; no absolute deficit gate blocks cures.
    function _requireReceiptConservation(WaterfallStorage storage $, uint256 tokenId, ReceiptContext memory context)
        private
        view
    {
        uint256 allowance;
        if (context.continuous) {
            uint256 after_ = IAccrualRounding($.accrualReserve).roundingLossUnabsorbed();
            if (after_ < context.roundingBefore) revert Waterfall_BackingWouldBreak(tokenId);
            allowance = after_ - context.roundingBefore;
        }
        uint256 afterDeficit = $.controller.recognizedDeficit();
        if (afterDeficit > context.deficitBefore && afterDeficit - context.deficitBefore > allowance) {
            revert Waterfall_BackingWouldBreak(tokenId);
        }
    }

    function _emitDistributed(Payment calldata payment, uint256 fee, uint256 toVault) private {
        emit Distributed(
            payment.tokenId, payment.paymentId, payment.payer, payment.interest, payment.principal, fee, toVault
        );
    }

    /// @dev Spends the receipt's attestation and settles its principal leg against the reserve,
    ///      returning the facility's principal outstanding AFTER the receipt.
    ///
    ///      BSC (ADR-0037 D1): a facility repays in the currency it was FUNDED in. The binding is
    ///      the reserve's, made on the facility's first credit-side act, so this reads it rather
    ///      than letting a servicer choose a currency at repayment time - choosing here would let
    ///      a depegged leg settle a claim booked against the other one.
    /// @param $ The engine's namespaced storage.
    /// @param payment The attested receipt being distributed.
    /// @return outstanding Deployed principal remaining on the facility after this receipt.
    function _settleReceipt(WaterfallStorage storage $, Payment calldata payment, bool continuous)
        private
        returns (uint256 outstanding)
    {
        uint256 total = payment.interest + payment.principal;
        address asset = $.reserves.facilityAssetOf(payment.tokenId);
        if (asset == address(0)) revert Waterfall_FacilityAssetUnbound(payment.tokenId);
        uint256 assetAmount = $.reserves.denormalizeUnits(asset, total);
        _spendPaymentAttestation($, payment, asset, assetAmount);

        if (continuous) {
            return IAccrualReceipts($.accrualReserve).repayAccruingLoan(
                payment.tokenId, payment.payer, payment.principal, payment.interest
            );
        }

        outstanding = $.reserves.deployedTo(payment.tokenId);
        if (payment.principal != 0) {
            if (payment.principal > outstanding) {
                revert Waterfall_PrincipalExceedsOutstanding(payment.tokenId, payment.principal, outstanding);
            }
            outstanding -= payment.principal;
        }
        uint256 received =
            $.reserves.recordPayment(payment.tokenId, asset, payment.payer, assetAmount, payment.principal);
        if (received != total) revert Waterfall_BackingWouldBreak(payment.tokenId);
    }

    /// @dev Verifies a currently-satisfied PaymentReceived attestation whose payload
    ///      commits to exactly (tokenId, interest, principal), then consumes it -
    ///      one attested receipt authorizes exactly one distribution (ADR-0020).
    function _spendPaymentAttestation(
        WaterfallStorage storage $,
        Payment calldata payment,
        address asset,
        uint256 assetAmount
    ) private {
        (bytes32 payload,, bool ok) =
            $.oracle.latestPayload(payment.tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
        bytes32 expected = keccak256(
            abi.encode(
                payment.paymentId,
                payment.tokenId,
                asset,
                payment.payer,
                assetAmount,
                payment.interest,
                payment.principal,
                payment.nextPaymentDue
            )
        );
        if (!ok || payload != expected) {
            revert Waterfall_PaymentNotAttested(payment.tokenId);
        }
        $.oracle.consume(payment.tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
    }

    /// @dev Protocol fee on gross, then every remaining unit goes to the senior vault.
    ///
    ///      AUDIT FIX (R16-M5) - THE DEFICIT WITHHOLDING, LOAD-BEARING, DO NOT DELETE. The cash
    ///      for this interest has ALREADY landed in the reserve (`recordPayment`, above), so
    ///      backing has already risen by `interest`. Minting the whole of it back out as yield
    ///      returns supply to where it was and leaves any standing deficit exactly as large as it
    ///      was. `mintableHeadroom()` is measured after that cash landed, so distributing only
    ///      what fits inside it means the WITHHELD portion stays in the reserve as backing and
    ///      closes the hole. AUDIT FIX (R17): that headroom is now RECOGNITION-AWARE and reads
    ///      zero while the controller is paused, so this clamp covers all three cases - a recorded
    ///      G3 mark, an unreconciled custody shortfall, and a guardian pause - rather than only
    ///      the first. Under a custody hole the recorded basis reported the protocol whole, so the
    ///      clamp withheld ZERO, the fee below was taken on the GROSS out of an open hole, and the
    ///      cure this paragraph advertises did not run at all.
    ///
    ///      THIS IS THE PROTOCOL-NATIVE CURE THE FINDING SAID DID NOT EXIST. A residual deficit
    ///      previously left the protocol permanently inert with no on-chain way out; now ordinary
    ///      loan interest repairs it automatically, every payment, with no governance action, no
    ///      recapitalisation and no keeper - and yield to the vault resumes by itself the moment
    ///      the deficit closes. Deleting the clamp does not just restore the old behaviour: it
    ///      makes `mintYield` REVERT (its deficit rule refuses the mint), taking the borrower's
    ///      whole repayment down with it.
    ///
    ///      SENIORS BEAR THE WITHHOLDING, AND THAT IS THE CORRECT ORDER. `sUSDfr` is cascade
    ///      layer 3; a standing deficit is already their loss. Withholding suspends their YIELD
    ///      while the hole is open, it does not burn their principal - the exchange rate does not
    ///      fall, it merely stops rising. Under THIS clamp the protocol fee is withheld
    ///      PRO-RATA-AND-EQUALLY by construction, because the split is taken on the distributable
    ///      amount and not on the gross.
    ///
    ///      ------------------------------------------------------------------------------------
    ///      AUDIT FIX (ADV-1) - THE SENIOR-IMPAIRMENT FEE WITHHOLDING, LOAD-BEARING, DO NOT DELETE.
    ///      See `_withholdFeeForSeniorImpairment` for the guard itself and for the stock/flow rule.
    ///
    ///      WHAT WAS FALSE ABOVE. The paragraph immediately preceding this one used to end
    ///      "Forest Road does not collect a performance fee out of a shortfall". ADV-1 EXECUTED THE
    ///      COUNTER-EXAMPLE. The clamp above is sized off `mintableHeadroom()`, which nets the
    ///      RECORDED impairment mark, the R4-01 custody shortfall and `seniorSubParShortfall()` -
    ///      and NOTHING from the CREDIT layer. `DefaultManager.declareDefault` never touches
    ///      `ReserveManager`, so a DECLARED default leaves the facility at FACE:
    ///      `recognizedDeficit()` reads 0, headroom is FULL, and the clamp above withholds
    ///      NOTHING IN EXACTLY THE STATE IT WAS WRITTEN FOR. Measured on a 300,000e18 declared
    ///      default with curator pool 0 and sGROVE capacity 0, a 10,000e18 interest receipt paid
    ///      1,000e18 to the fee recipient and 9,000e18 to the vault. The second falsified sentence
    ///      is "SENIORS BEAR THE WITHHOLDING": there was no withholding to bear.
    ///
    ///      WHY THE FEE LEG IS THE PART THAT IS WRONG. The fee recipient is NOT a layer of the
    ///      section 1.3 cascade and holds plain USDfr, so `DefaultManager.realizeLoss` can never reach it -
    ///      layer-3 absorption is bounded by the VAULT's assets. Paying it while an unabsorbed
    ///      senior residual stands therefore makes Forest Road's revenue SENIOR TO ALL THREE
    ///      CASCADE LAYERS, and irreversibly so (`ADV_GateAndCascade::test_P7/test_P9`). That is
    ///      ADR-0034 cascade ordering inverted on the YIELD path rather than the redemption path.
    ///
    ///      WHY THE VAULT LEG IS DELIBERATELY LEFT ALONE, WHICH IS THE PART A REVIEWER WILL PUSH
    ///      ON. `toVault` is bit-for-bit unchanged by this fix, and that is a decision, not an
    ///      omission:
    ///        1. THE VAULT IS INSIDE THE CASCADE AND ALREADY PRICES THE RESIDUAL. `sUSDfr`'s
    ///           redemption NAV nets `pendingSeniorImpairment()` and its performance fee nets
    ///           `performanceFeeImpairment()`, so yield delivered here raises the CONSERVATIVE
    ///           senior base - it is coverage flowing TO the layer that bears the loss, not out of
    ///           it. Forest Road cannot recapture it downstream either, because the vault's
    ///           performance fee is zero while the gross impairment exceeds vault assets.
    ///        2. RETAINING IT INSTEAD WOULD LEAK SENIOR INCOME TO JUNIOR. Retained interest becomes
    ///           unencumbered backing shared pro-rata by EVERY USDfr holder, including unstaked
    ///           holders and the curator's own junior USDfr. Withholding senior yield to
    ///           over-collateralise junior capital inverts the cascade in the opposite direction.
    ///        3. IT WOULD BE PERMISSIONLESSLY GRIEFABLE, AND THE LOSS IS FORGONE NOT DEFERRED.
    ///           `DefaultManager.markPastDue` is PERMISSIONLESS and marks a facility's whole
    ///           principal. Sizing the VAULT leg off this stock would let any address destroy 100%
    ///           of protocol-wide senior yield for the whole window a single facility sits one day
    ///           overdue - and nothing accrues a claim to withheld value, so it never comes back.
    ///           Third-party senior capital's income must not be destructible by an unpermissioned
    ///           call. Forest Road's OWN fee is a different matter: Forest Road sets the marking
    ///           policy, so it is the right party to bear a conservative rule it controls.
    ///        4. UNLIKE THE R16-M5 CLAMP, THIS ONE DOES NOT SELF-CURE. Retained interest closes a
    ///           RECOGNISED deficit and reopens headroom by itself. It does NOT reduce
    ///           `pendingSeniorImpairment()`, which is denominated in declared/past-due PRINCIPAL
    ///           and falls only via `clearPastDue`, `onDefaultRecovery`, `onDefaultResolved`,
    ///           `realizeLoss`, a curator top-up or backstop funding. A non-self-curing clamp on
    ///           the senior leg is an indefinite yield suspension; on the fee leg it is a
    ///           conservative revenue haircut. Only the second is safe to ship unilaterally.
    ///      EXTENDING THE WITHHOLDING TO THE VAULT LEG IS A FOREST ROAD ECONOMICS DECISION (brief
    ///      Part 4 / CLAUDE.md section 0.5) AND IS NAMED HERE AS OUTSTANDING RATHER THAN TAKEN.
    ///
    ///      SO THE ORDER IS NOW FEE-FIRST-AND-ALONE FOR A CREDIT SHORTFALL, AND PRO-RATA FOR A
    ///      RECOGNISED ONE. Fee-first is STRICTLY MORE correct than the pro-rata rule above, not a
    ///      relaxation of it: the out-of-cascade party absorbs before the in-cascade layer. The two
    ///      clamps COMPOSE AS A FLOOR - the R16-M5 clamp shrinks the BASIS (`distributable`) and
    ///      this one caps the FEE drawn off that basis, so whichever binds hardest wins and neither
    ///      can push a mint negative.
    ///
    ///      THE ORIGINATION LEG IS KNOWINGLY LEFT BLIND (`ADV_GateAndCascade::test_P8`). `fund`'s
    ///      R18 clamp exists to stop origination FREEZING, and origination interest is the only
    ///      named cure for `seniorSubParShortfall()`; tightening it is a separate decision recorded
    ///      as MRC residualRisk 5. NOT TOUCHED HERE, and named so it is not mistaken for an
    ///      oversight.
    function _routeInterest(WaterfallStorage storage $, uint256 interest)
        private
        returns (uint256 fee, uint256 toVault)
    {
        return WaterfallLegacyLib.routeInterest($, interest);
    }

    /// @dev Servicing entry already owns the local guard; the source supplies portfolio freshness.
    function _requireAccrualFresh() private view {
        address reserve = _storage().accrualReserve;
        if (reserve != address(0)) IContinuousAccrual(reserve).requireAccrualFresh();
    }

    /// @dev Governance cannot mutate during either a native servicing or source accounting callback.
    function _requireAccrualIdle() private view {
        address reserve = _storage().accrualReserve;
        if (reserve == address(0)) return;
        if (_reentrancyGuardEntered()) revert Waterfall_AccrualOperationInProgress();
        IAccrualExposure(reserve).requireAccrualIdle();
    }

    function _accrualEnabled(WaterfallStorage storage $) private view returns (bool) {
        return $.accrualReserve != address(0) && IContinuousAccrual($.accrualReserve).accrualSnapshot().enabled;
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        _requireAccrualIdle();
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        _requireAccrualIdle();
        return super._revokeRole(role, account);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        _requireAccrualIdle();
    }

    function _storage() private pure returns (WaterfallStorage storage $) {
        assembly {
            $.slot := WATERFALL_STORAGE_LOCATION
        }
    }
}
