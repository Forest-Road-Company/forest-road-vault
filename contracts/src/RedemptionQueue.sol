// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRedemptionQueue} from "./interfaces/IRedemptionQueue.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title RedemptionQueue — epoch FIFO exits for sUSDfr (ADR-0010, the QEV analog)
/// @notice Because deployed capital is illiquid (amortizing facilities), sUSDfr never
///         redeems instantly: exits queue here and settle at epoch close, strictly
///         FIFO, against a liquidity budget snapshotted per settlement — the
///         governance-set share of the treasury's STABLE liquidity only (the
///         reserve-instrument mark is a valuation, not cash). The vault admits this
///         contract as its sole withdraw/redeem caller (`sUSDfr.setRedemptionQueue`).
///
///         BUDGET SEMANTICS (AUDIT NOTE R2-M-01 — honest framing): the settlement budget is
///         a per-epoch THROUGHPUT CAP on how many sUSDfr shares convert to USDfr claims — it
///         is NOT an escrow or a reservation of stablecoins. Queue claimants are paid in
///         USDfr (fully backed) and later convert USDfr→stable via the controller, drawing
///         the SAME unreserved stable pool as direct USDfr redeemers; nothing here earmarks
///         stables for the queue. So a claimant's USDfr is safe (backed), but the *timing* of
///         its stable conversion competes with direct redemptions — the budget bounds
///         issuance of claims, it does not guarantee downstream stable liquidity. A hard
///         reservation is an economic-review item (deliberately not a rushed escrow here).
///
///         SETTLEMENT MODEL: `closeEpoch` is KEEPER-GATED (`SETTLEMENT_KEEPER_ROLE`,
///         superseding ADR-0018 §2 — see the role's NatSpec) and chunked (`maxRequests`
///         per call — no unbounded loops). The first call past the epoch end snapshots
///         the budget; fills proceed head-first, the head request may fill partially,
///         and settlement completes when the queue, the budget, or its dust runs out,
///         or when the head's fill would be worth zero USDfr at the conservative
///         redemption rate (C-1: such a fill is never taken — nothing is ever burned for
///         nothing) — then the next epoch opens. Requests joining mid-settlement queue
///         behind the current tail and are eligible within the same settlement if budget
///         remains (still strictly FIFO).
///
///         C-1 ZERO-VALUE HANDLING (strict FIFO, NO reordering): a head whose fill prices
///         to zero is NEVER burned. It has two causes, both stopping the settlement with the
///         head keeping its FIFO place:
///           (a) the BUDGET cannot buy a nonzero slice of a head that is itself worth
///               something → stop (`Queue_NoLiquidity`); the head settles later at a real price.
///           (b) the head's ENTIRE remaining position prices to zero — worth < 1 wei of USDfr
///               at the conservative exit NAV, i.e. the senior front is not redeemable →
///               settlement stops LOUDLY with `Queue_HeadNotRedeemable`. The heartbeat is not
///               consumed, nothing is burned, and `headValuation()` exposes the state to
///               monitoring. It clears when the mark is cured or realized.
///           A sub-wei "dust" head is NOT deferred/requeued. The `minRedemptionValue` entry
///           floor (default $1, REALIZED rate) bars CHEAP griefing — a $0-cost dust head that
///           blocks real positions. It does NOT by itself bound the CONSERVATIVE-rate value that
///           triggers (b): a large DECLARED (unrealized) impairment can price a legally-entered
///           head to 0 conservative while a materially larger position behind it stays
///           redeemable, so (b) is reachable there, not only under a realized near-total loss.
///           That residual is bounded and self-resolving — the blocked large redeemer would only
///           ever settle at a near-total-loss conservative price anyway, and the halt clears when
///           the mark cures or realizes — so strict FIFO with no reordering, no deferral, and no
///           unbounded array growth remains the right trade. The floor removes the cheap-griefing
///           surface; it is not claimed to make the wedge impossible.
///
///         ADR-0016 NOTE (points): queued shares sit at this contract's address, which
///         is not identity-bound in the PointsModule — participation accrual for the
///         requester STOPS at request time by construction (exit intent is the end of
///         participation), and the queue itself accrues nothing. Asserted in tests.
///
///         §1.3 INVARIANTS OWED HERE (encoded in RedemptionQueueInvariants):
///         distributed assets never exceed the settlement budget; FIFO never inverts
///         (a fill implies every earlier request is fully filled — no reordering); no
///         double-claim.
contract RedemptionQueue is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IRedemptionQueue
{
    using SafeERC20 for IERC20;

    /// @dev LAYOUT-FROZEN: this is an ARRAY element (`requests` below). Array elements
    ///      are laid out contiguously, so adding/reordering ANY field shifts every
    ///      existing element on the deployed proxy → total corruption. NEVER extend
    ///      this struct on an upgrade (unlike mapping-value structs, which are safe to
    ///      tail-extend). Verify with `forge inspect RedemptionQueue storage-layout`.
    struct Request {
        address owner; // 160 bits ┐
        uint64 requestedAt; //      ├─ one slot (160+64+32 = 256): the cooldown clock (ADR-0022)
        uint32 epochRequested; //   ┘  the epoch the request joined (informational)
        uint256 sharesRemaining;
        uint256 assetsClaimable;
    }

    /// @dev Transaction-local G4 pricing session. No quote survives a transaction boundary:
    ///      one post-fee state selects the batch and one aggregate redemption moves value.
    struct PricingBatch {
        uint256[] requestIds;
        uint256[] shares;
        uint256[] quotedAssets;
        uint256 count;
        uint256 aggregateShares;
        uint256 withheld;
        uint256 blockedEligibleAt;
        uint8 stopReason;
    }

    /// @custom:storage-location erc7201:forestroad.storage.RedemptionQueue
    struct QueueStorage {
        IsUSDfr vault; // sUSDfr
        IERC20 usdfr;
        IReserveManager reserves;
        uint64 epochDuration; // settlement HEARTBEAT cadence (ADR-0022 — not the hold)
        uint16 epochLiquidityBps;
        uint256 currentEpoch;
        uint64 epochEndsAt;
        bool settling;
        uint256 settlementBudget; // remaining, in USDfr assets
        uint256 settlementDistributed; // running total for the EpochClosed event
        uint256 head; // first not-fully-filled request
        uint256 totalQueuedShares;
        Request[] requests;
        // ADR-0022 append-only tail-extension (namespaced storage, safe to extend):
        uint64 redeemCooldown; // forced per-request hold before a request may settle
        // C-1 anti-dust-wedge floor (append-only tail-extension): minimum REALIZED value a
        // request must be worth to enter the queue. See `Config.DEFAULT_MIN_REDEMPTION_VALUE`.
        uint256 minRedemptionValue;
        // AUDIT FIX (C-11, append-only tail-extension): the economic floor a LIVE settlement
        // is judged against, captured when that settlement opens so a governance change cannot
        // retroactively make a frozen budget unsatisfiable. Zero is a legitimate value (the
        // floor is disableable), so there is deliberately no sentinel fallback; the contract is
        // fresh-deploy-only under ADR-0030 and carries no in-place upgrade path.
        uint256 settlementMinValue;
        // G4: append-only identifier for explicit transaction-sized pricing sessions.
        uint256 nextPricingSessionId;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.RedemptionQueue")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant QUEUE_STORAGE_LOCATION = 0x6ab51628c59659b156fe1c17eb798f5494ec81abdf0900bd9a414fdd72270800;

    /// @dev Hard ceiling on the governance-set `minRedemptionValue` ($100): the floor exists to
    ///      bar dust, not to gate ordinary redeemers out of the sole exit path, so it can never be
    ///      raised high enough to do the latter.
    uint256 private constant MAX_MIN_REDEMPTION_VALUE = 100e18;

    /// @dev AUDIT FIX (Q-01, HIGH) — minimum conservative VALUE a partial fill must leave behind.
    ///      A partial fill is the only way a request's `sharesRemaining` can become a number the
    ///      queue did not choose, and `previewRedeem(d) == 0` for every `d` below one asset-wei's
    ///      worth of shares (the 6-decimal virtual offset makes that window ~1e6 share units at
    ///      par). A residue inside that window is a permanent wedge: next settlement the head IS
    ///      the residue, the C-1 value guard fires with the whole position priced at zero, and
    ///      `Queue_HeadNotRedeemable` reverts `closeEpoch` WHOLESALE — freezing every request
    ///      behind it, with no cancel/defer path (ADR-0018) and no parameter that cures it.
    ///
    ///      1e12 asset-wei (1e-6 USDfr) is a MARGIN, expressed as a value so it tracks the
    ///      conservative rate automatically: `previewWithdraw` converts it to shares at the same
    ///      rate `previewRedeem` will price the next fill at, so the residue is left worth at
    ///      least 1e12 wei — i.e. 1e12 dead-zone widths, not one. The margin, not merely a
    ///      nonzero test, is what makes the fix hold over TIME: management-fee shares accrue into
    ///      `_feeAdjustedSupply()` and push `previewRedeem` DOWN, so a residue that previews to
    ///      exactly 1 wei today decays to 0 later. At the 200 bps/year fee ceiling this margin
    ///      survives ~1.4e3 years of accrual; it is only exhausted by a declared senior
    ///      impairment of 1 - 1e-12 of the vault, which is the total-loss state where stopping
    ///      loudly is the intended behaviour anyway.
    ///
    ///      WHY WITHHOLDING CANNOT COST A SETTLEMENT ITS FLOOR (read this before touching the
    ///      `+ withheld` credit in the abandon guard — this is the standing argument for keeping
    ///      it). An earlier version of this block argued from a ratio: the constant is 1e-6 of the
    ///      DEFAULT `minRedemptionValue`, so a withholding could miss the floor "by at most one
    ///      part in a million". Both halves of that are now false. `setMinRedemptionValue` admits
    ///      a floor of exactly `MIN_RESIDUE_VALUE`, at which the withholding is 100% of the floor,
    ///      not 1e-6 of it; and "every settlement that commits must already distribute at least
    ///      that floor" is precisely what the credit was added to stop being true.
    ///
    ///      The real guarantee is exact, and it is an identity rather than a bound:
    ///          previewRedeem(fillShares) + withheld == previewRedeem(budgetCappedFill)
    ///      holds in every branch below by construction. So the abandon guard evaluates
    ///      BIT-FOR-BIT the predicate the pre-credit code evaluated on the same state. The
    ///      withholding cannot be the reason a settlement misses its floor because it does not
    ///      move the test at all — not by one part in a million, not by anything. Delete the
    ///      credit and that identity breaks immediately.
    uint256 private constant MIN_RESIDUE_VALUE = 1e12;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the queue; the first epoch opens immediately.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param vault The sUSDfr vault (this contract must be set as its queue).
    /// @param usdfr The underlying asset.
    /// @param reserves Treasury (stable-liquidity source for the budget).
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address vault,
        address usdfr,
        address reserves
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || vault == address(0)
                || usdfr == address(0) || reserves == address(0)
        ) revert Queue_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        QueueStorage storage $ = _storage();
        $.vault = IsUSDfr(vault);
        $.usdfr = IERC20(usdfr);
        $.reserves = IReserveManager(reserves);
        $.epochDuration = Config.DEFAULT_EPOCH_DURATION;
        $.epochLiquidityBps = Config.DEFAULT_EPOCH_LIQUIDITY_BPS;
        $.redeemCooldown = Config.DEFAULT_REDEEM_COOLDOWN;
        $.minRedemptionValue = Config.DEFAULT_MIN_REDEMPTION_VALUE;
        $.currentEpoch = 1;
        $.epochEndsAt = uint64(block.timestamp) + Config.DEFAULT_EPOCH_DURATION;
        emit EpochDurationSet(Config.DEFAULT_EPOCH_DURATION);
        emit EpochLiquidityBpsSet(Config.DEFAULT_EPOCH_LIQUIDITY_BPS);
        emit RedeemCooldownSet(Config.DEFAULT_REDEEM_COOLDOWN);
        emit MinRedemptionValueSet(Config.DEFAULT_MIN_REDEMPTION_VALUE);
    }

    // ── User paths ───────────────────────────────────────────────────────

    /// @inheritdoc IRedemptionQueue
    function requestRedeem(uint256 shares) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert Queue_ZeroAmount();
        QueueStorage storage $ = _storage();
        // Queue admission must value shares after all accrued protocol fees. Otherwise a
        // requester could lock in a pre-fee minimum-value check and push the liability onto
        // holders who remain outside the queue.
        $.vault.accrueFees();
        // AUDIT FIX (N-1, extended for C-1): a request must be worth at least
        // `minRedemptionValue` (default $1, i.e. 1e18) of REALIZED USDfr to enter the queue. Two
        // reasons, one gate:
        //   • anti-griefing: a pure-dust request fills for ~0, takes a FIFO slot ahead of real
        //     redeemers, and wastes keeper gas.
        //   • C-1 anti-wedge (anti-griefing, NOT a hard guarantee): `closeEpoch` never burns a
        //     position worth zero at the conservative mark — it STOPS there (loud
        //     `Queue_HeadNotRedeemable`), so a sub-wei head would otherwise block the real
        //     positions behind it. This floor gates the REALIZED rate, so it does NOT by itself
        //     bound the CONSERVATIVE-rate value that triggers the stop — a large DECLARED
        //     (unrealized) impairment can still price a legally-entered head to 0 conservative
        //     while a materially larger position behind it stays redeemable. But that wedge is
        //     bounded and self-resolving: the blocked large redeemer would only ever settle at a
        //     near-total-loss conservative price anyway, and the halt clears when the mark cures
        //     or realizes. The floor keeps CHEAP griefing (a $0-cost dust head) off the table; it
        //     is not claimed to make the conservative-rate wedge impossible.
        // ADR-0022 note: deliberately the REALIZED rate (`convertToAssets`), not the conservative
        // redemption rate. This is an anti-griefing filter, not a pricing decision — under a
        // declared (unrealized) impairment the conservative rate values requests far below their
        // realized worth, and gating on it would lock users out of the queue exactly when they
        // most want to join it.
        uint256 realizedValue = $.vault.convertToAssets(shares);
        if (realizedValue < $.minRedemptionValue) {
            revert Queue_BelowMinRedemption(realizedValue, $.minRedemptionValue);
        }
        requestId = $.requests.length;
        $.requests.push(
            Request({
                owner: msg.sender,
                // ADR-0022: the forced-cooldown clock starts now. `closeEpoch` will not
                // settle this request until block.timestamp >= requestedAt + redeemCooldown.
                requestedAt: uint64(block.timestamp),
                epochRequested: uint32($.currentEpoch),
                sharesRemaining: shares,
                assetsClaimable: 0
            })
        );
        $.totalQueuedShares += shares;
        // custody of the shares moves here: FIFO position is locked in, participation
        // accrual stops (ADR-0016 note above)
        IERC20(address($.vault)).safeTransferFrom(msg.sender, address(this), shares);
        emit RedemptionRequested(requestId, msg.sender, shares, $.currentEpoch);
    }

    /// @inheritdoc IRedemptionQueue
    function claim(uint256 requestId) external nonReentrant returns (uint256 assets) {
        QueueStorage storage $ = _storage();
        if (requestId >= $.requests.length) revert Queue_UnknownRequest(requestId);
        Request storage r = $.requests[requestId];
        if (r.owner != msg.sender) revert Queue_NotRequestOwner(requestId, msg.sender);
        assets = r.assetsClaimable;
        if (assets == 0) revert Queue_NothingClaimable(requestId);
        r.assetsClaimable = 0; // effects first — no double-claim
        $.usdfr.safeTransfer(r.owner, assets);
        emit Claimed(requestId, r.owner, assets);
    }

    // ── Settlement ───────────────────────────────────────────────────────

    /// @inheritdoc IRedemptionQueue
    /// @dev AUDIT FIX (D7-01 / starvation mirror): gated on `SETTLEMENT_KEEPER_ROLE`. This call
    ///      samples `settlementBudget = availableLiquidity()` on the first chunk and RE-READS
    ///      `availableLiquidity()` on every chunk thereafter. Both reads execute in the caller's
    ///      transaction, so while this was permissionless an attacker could hold a flash loan
    ///      across the sample and the fills, or latch a settlement at a chosen moment. A flash
    ///      loan cannot span two transactions; requiring a role the attacker does not hold means
    ///      they cannot place this call inside their own transaction at all.
    ///
    ///      The modifier ORDER is deliberate: the role check runs BEFORE `whenNotPaused`, so an
    ///      unauthorized caller always gets `AccessControlUnauthorizedAccount` regardless of pause
    ///      state, and pause state is not probeable by an unauthorized caller.
    ///
    ///      NOT CLOSED by this gate: an attacker may still sandwich the keeper's transaction with
    ///      REAL (non-flashed) capital held across it. That requires millions genuinely at risk
    ///      across a block instead of a zero-cost flash loan, and is further closed by submitting
    ///      the keeper call through a private relay. Also unaffected is the
    ///      `Queue_HeadNotRedeemable` clamp channel, which fires whoever calls.
    ///
    ///      SUPERSEDES ADR-0018 §2. See `Roles.SETTLEMENT_KEEPER_ROLE` for the liveness posture
    ///      and the two-holder requirement.
    function closeEpoch(uint256 maxRequests)
        external
        onlyRole(Roles.SETTLEMENT_KEEPER_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (maxRequests == 0) revert Queue_ZeroAmount();
        QueueStorage storage $ = _storage();
        // C-01: the same fail-closed predicate protects both junior curator capital and the
        // sole senior exit. Existing filled claims remain claimable; only new settlement stops.
        if ($.reserves.reserveLossExitsLocked()) revert Queue_ReserveLossSettlementFrozen();
        if (!$.settling) {
            if (block.timestamp < $.epochEndsAt) revert Queue_EpochNotOver($.epochEndsAt);
            $.settling = true;
            $.settlementBudget = availableLiquidity();
            $.settlementDistributed = 0;
            // AUDIT FIX (C-11): capture the economic floor alongside the budget, so a live
            // settlement is judged against the parameters it opened under. Raising
            // `minRedemptionValue` mid-settlement would otherwise make the guards below
            // unsatisfiable against a budget that is already frozen and can only shrink —
            // the RC-01 dead end, reachable through a governance setter instead of a chunk
            // boundary. A change now takes effect on the NEXT settlement.
            $.settlementMinValue = $.minRedemptionValue;
        }

        // H-04: a live cap can only shrink the remaining epoch budget. The pricing session
        // below is transaction-sized, so one read covers its one aggregate redemption.
        uint256 liveCap = availableLiquidity();
        if ($.settlementBudget > liveCap) $.settlementBudget = liveCap;

        // G4/M-2: prepare the optional yield stream against the FULL remaining settlement
        // outflow, never the keeper-selected `maxRequests`. This runs before every preview and
        // performs the one meaningful fee checkpoint for the chunk. When the front is still in
        // cooldown there is no pending outflow yet, so retain the ordinary fee checkpoint
        // without recognizing stream value prematurely.
        if ($.head < $.requests.length && block.timestamp >= uint256($.requests[$.head].requestedAt) + $.redeemCooldown)
        {
            $.vault.prepareRedemptionPricing($.settlementBudget);
        } else {
            $.vault.accrueFees();
        }

        // G4: selection is a quote-only phase. Every selected request sees the same prepared,
        // post-fee numerator and denominator; exactly one vault redemption realizes the batch.
        PricingBatch memory batch = _selectPricingBatch($, maxRequests);
        if (batch.withheld != 0 && batch.count != 0) {
            emit SettlementWithheld($.currentEpoch, batch.requestIds[batch.count - 1], batch.withheld);
        }
        if (batch.aggregateShares != 0) _executePricingBatch($, batch);

        uint8 stopReason = batch.stopReason;
        uint256 withheld = batch.withheld;
        uint256 blockedEligibleAt = batch.blockedEligibleAt;

        // settlement completes when the queue is drained, the budget ran out (stopReason 1 —
        // including the C-1 budget-blocked zero-value fill), the settlement front is not
        // redeemable for any nonzero amount (stopReason 3), or the head is still cooling down
        // (stopReason 2). A bare maxRequests stop mid-queue leaves stopReason 0 and keeps the
        // settlement open for the next chunk.
        bool drained = $.head >= $.requests.length;

        // AUDIT FIX (RC-01): a bare `maxRequests` chunk exit (stopReason 0, queue not
        // drained) COMMITS the settlement with `settling = true`. `settlementDistributed`
        // is cumulative across chunks while `settlementBudget` is snapshotted exactly once
        // (only under `!settling`) and thereafter only shrinks, so `distributed + budget`
        // is pinned to that first snapshot for the life of the settlement. If that total is
        // already below `minRedemptionValue`, NO later chunk can ever satisfy the economic
        // floor below — and because that branch reverts, its own `settling = false` is
        // rolled back with it. Committing here would therefore create an absorbing state:
        // `closeEpoch` reverts forever, refilling the treasury provably cannot help (the
        // budget is never re-snapshotted while settling), and nothing else clears
        // `settling`. Refuse to commit an unsatisfiable settlement; the revert rolls the
        // whole chunk back, leaves `settling` false, and lets the next call re-snapshot
        // against live liquidity.
        //
        // The test is REACHABILITY, not the floor itself: a chunk that has distributed
        // little but still holds enough budget to clear the floor later is a perfectly
        // ordinary partial settlement and must still latch open.
        if (!drained && stopReason == 0 && $.settlementDistributed + $.settlementBudget < $.settlementMinValue) {
            revert Queue_NoLiquidity();
        }

        // AUDIT FIX (A1, permissionless DoS): do NOT burn the heartbeat window on a
        // settlement that distributed NOTHING while requests are still queued. Otherwise
        // anyone resets the clock by atomically zeroing idle liquidity (redeem → snapshot
        // 0-budget → advance → re-mint), starving the sole sUSDfr exit path. ADR-0022
        // extends this to the cooldown: a queue whose head is still cooling down also has
        // nothing to settle yet — abandon without advancing, leaving epochEndsAt untouched
        // so the request settles the instant its cooldown elapses (no compounding with the
        // heartbeat). Both cases: !drained and less than one request's minimum economic
        // value distributed → abandon and roll back, don't advance. This also prevents a
        // dust-sized partial fill from consuming the heartbeat. A drained queue may still
        // close after paying its final dust tail.
        if (drained || stopReason != 0) {
            if (!drained && ($.settlementDistributed == 0 || $.settlementDistributed + withheld < $.settlementMinValue))
            {
                $.settling = false;
                $.settlementBudget = 0;
                if (stopReason == 2) revert Queue_AllInCooldown(blockedEligibleAt);
                // C-1 remediation: distinguish "no money" from "the front of the queue cannot be
                // redeemed for a nonzero amount at the current mark". Monitoring must be able to
                // tell them apart — the second is a valuation state that only clears when the
                // mark cures, and `headValuation()` reports it without sending a transaction.
                // (stopReason 3 implies `$.head` still indexes a live request: it is only set
                // from inside the loop body, which requires `$.head < $.requests.length`.)
                if (stopReason == 3) revert Queue_HeadNotRedeemable($.head, $.requests[$.head].sharesRemaining);
                revert Queue_NoLiquidity();
            }
            uint256 closedEpoch = $.currentEpoch;
            uint256 distributed = $.settlementDistributed;
            uint256 unspent = $.settlementBudget;
            $.settling = false;
            $.settlementBudget = 0;
            $.settlementDistributed = 0;
            $.currentEpoch = closedEpoch + 1;
            $.epochEndsAt = uint64(block.timestamp) + $.epochDuration;
            emit EpochClosed(closedEpoch, distributed + unspent, distributed, $.epochEndsAt);
        }
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @inheritdoc IRedemptionQueue
    function setEpochDuration(uint64 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration == 0) revert Queue_BadParams();
        _storage().epochDuration = duration;
        emit EpochDurationSet(duration);
    }

    /// @inheritdoc IRedemptionQueue
    function setEpochLiquidityBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps == 0 || bps > Config.BPS) revert Queue_BadParams();
        _storage().epochLiquidityBps = bps;
        emit EpochLiquidityBpsSet(bps);
    }

    /// @inheritdoc IRedemptionQueue
    /// @dev ADR-0022 forced hold. Applies uniformly to in-flight requests (eligibility is
    ///      recomputed against the current value), so FIFO-monotonicity is preserved; a
    ///      change should be timelocked. The configured value must remain between
    ///      `DEFAULT_REDEEM_COOLDOWN` and `MAX_REDEEM_COOLDOWN`: shortening below the default or
    ///      disabling the hold would let a queued exit settle before the past-due mark fully ramps.
    function setRedeemCooldown(uint64 cooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cooldown < Config.DEFAULT_REDEEM_COOLDOWN || cooldown > Config.MAX_REDEEM_COOLDOWN) {
            revert Queue_BadParams();
        }
        _storage().redeemCooldown = cooldown;
        emit RedeemCooldownSet(cooldown);
    }

    /// @inheritdoc IRedemptionQueue
    /// @dev C-1 anti-dust-wedge floor. Timelocked governance only. Capped at
    ///      `MAX_MIN_REDEMPTION_VALUE` so it can never be set high enough to lock ordinary
    ///      redeemers out of the sole exit path. Zero is permitted (disables the floor) but is a
    ///      deliberate governance act — it re-exposes the sub-wei dust-wedge surface.
    ///
    ///      AUDIT FIX (Q-01 round 3): the range has a HOLE at `(0, MIN_RESIDUE_VALUE)`, and the
    ///      hole is deliberate — do not "simplify" it to a single `>=` bound.
    ///        • 0 stays legal, but NOT because the abandon guard goes quiet — an earlier draft of
    ///          this note claimed that, reasoning only about the `distributed < minValue` test,
    ///          and it is wrong. The guard is
    ///          `settlementDistributed == 0 || settlementDistributed + withheld < settlementMinValue`.
    ///          At a zero floor the second conjunct is `X < 0`, false for every uint, so the guard
    ///          can fire ONLY through the FIRST conjunct — which is floor-independent and, by
    ///          design, uncreditable. A sub-margin sole head therefore gets a wholesale
    ///          `Queue_NoLiquidity` where the pre-fix build paid it a slice. That is curable by
    ///          liquidity (the head is then paid in FULL) and a zero floor is a deliberate
    ///          non-default governance act, so it is tolerated — see `settlementMinValue`'s C-11
    ///          note. It is tolerated on those grounds, not because the guard cannot bite.
    ///          Record this consequence in the parameter-change runbook before disabling the floor.
    ///        • `>= MIN_RESIDUE_VALUE` is safe because the most the Q-01 branch can withhold from a
    ///          settlement is `MIN_RESIDUE_VALUE`, and the abandon guard credits exactly that back.
    ///        • Strictly between them, the withholding can exceed the whole floor, so the credit
    ///          can no longer guarantee that a deliberate withholding is not itself the reason a
    ///          settlement misses it. That band is refused rather than left to reason about.
    ///      Raising the lower bound to `MIN_RESIDUE_VALUE` outright would remove a documented
    ///      governance capability and break the existing zero-floor tests, including the Q-01 cure
    ///      sweep that proves no parameter rescues an already-wedged queue.
    function setMinRedemptionValue(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value > MAX_MIN_REDEMPTION_VALUE) revert Queue_BadParams();
        if (value != 0 && value < MIN_RESIDUE_VALUE) revert Queue_BadParams();
        _storage().minRedemptionValue = value;
        emit MinRedemptionValueSet(value);
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses new requests and settlement. Already-settled claims remain available.
    ///         Emergency use only.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IRedemptionQueue
    function currentEpoch() external view returns (uint256) {
        return _storage().currentEpoch;
    }

    /// @inheritdoc IRedemptionQueue
    function epochEndsAt() external view returns (uint64) {
        return _storage().epochEndsAt;
    }

    /// @inheritdoc IRedemptionQueue
    function isSettling() external view returns (bool) {
        return _storage().settling;
    }

    /// @inheritdoc IRedemptionQueue
    function settlementBudgetRemaining() external view returns (uint256) {
        return _storage().settlementBudget;
    }

    /// @inheritdoc IRedemptionQueue
    function pricingSessionCount() external view returns (uint256) {
        return _storage().nextPricingSessionId;
    }

    /// @inheritdoc IRedemptionQueue
    function redeemCooldown() external view returns (uint64) {
        return _storage().redeemCooldown;
    }

    /// @inheritdoc IRedemptionQueue
    function minRedemptionValue() external view returns (uint256) {
        return _storage().minRedemptionValue;
    }

    /// @inheritdoc IRedemptionQueue
    function eligibleToSettleAt(uint256 requestId) external view returns (uint256) {
        QueueStorage storage $ = _storage();
        if (requestId >= $.requests.length) revert Queue_UnknownRequest(requestId);
        return uint256($.requests[requestId].requestedAt) + $.redeemCooldown;
    }

    /// @inheritdoc IRedemptionQueue
    /// @dev Canonical-USDC idle liquidity, scaled by the governance share. This is a live SNAPSHOT
    ///      used as a per-epoch throughput cap — it does NOT reserve or escrow any stable
    ///      (see the contract header, R2-M-01). It can move between the snapshot and any
    ///      claimant's later USDfr→stable conversion.
    function availableLiquidity() public view returns (uint256) {
        QueueStorage storage $ = _storage();
        return Math.mulDiv($.reserves.idleReserve(), $.epochLiquidityBps, Config.BPS);
    }

    /// @inheritdoc IRedemptionQueue
    function request(uint256 requestId)
        external
        view
        returns (
            address owner,
            uint256 sharesRemaining,
            uint256 assetsClaimable,
            uint256 epochRequested,
            uint256 requestedAt
        )
    {
        QueueStorage storage $ = _storage();
        if (requestId >= $.requests.length) revert Queue_UnknownRequest(requestId);
        Request storage r = $.requests[requestId];
        return (r.owner, r.sharesRemaining, r.assetsClaimable, r.epochRequested, r.requestedAt);
    }

    /// @inheritdoc IRedemptionQueue
    function totalRequests() external view returns (uint256) {
        return _storage().requests.length;
    }

    /// @inheritdoc IRedemptionQueue
    function head() external view returns (uint256) {
        return _storage().head;
    }

    /// @inheritdoc IRedemptionQueue
    function totalQueuedShares() external view returns (uint256) {
        return _storage().totalQueuedShares;
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules() external view returns (address vault, address usdfr, address reserves) {
        QueueStorage storage $ = _storage();
        return (address($.vault), address($.usdfr), address($.reserves));
    }

    /// @notice C-1 remediation: conservative-NAV valuation of the settlement front, so a
    ///         `Queue_HeadNotRedeemable` block is OBSERVABLE off-chain and can never be mistaken
    ///         for a silent stall. `headValue == 0` with `headShares > 0` is exactly the state in
    ///         which settlement stops loudly; it clears when the declared senior impairment is
    ///         cured or realized. `bookValue` shows whether the queue as a whole is redeemable.
    /// @return requestId The current head (== `totalRequests()` when the queue is empty).
    /// @return headShares The head's unfilled shares (0 when the queue is empty).
    /// @return headValue The head's whole remaining position at the conservative redemption NAV.
    /// @return bookValue Every queued share at the conservative redemption NAV.
    function headValuation()
        external
        view
        returns (uint256 requestId, uint256 headShares, uint256 headValue, uint256 bookValue)
    {
        QueueStorage storage $ = _storage();
        requestId = $.head;
        headShares = requestId < $.requests.length ? $.requests[requestId].sharesRemaining : 0;
        headValue = $.vault.previewRedeem(headShares);
        bookValue = $.vault.previewRedeem($.totalQueuedShares);
    }

    /// @notice Current epoch parameters.
    function epochParams() external view returns (uint64 duration, uint16 liquidityBps) {
        QueueStorage storage $ = _storage();
        return ($.epochDuration, $.epochLiquidityBps);
    }

    // ── Internals ────────────────────────────────────────────────────────

    /// @dev Selects one FIFO batch against a single immutable-in-transaction quote. The helper
    ///      does not mutate requests; a failed aggregate redemption therefore cannot leave a
    ///      partially-accounted batch even before transaction rollback is considered.
    function _selectPricingBatch(QueueStorage storage $, uint256 maxRequests)
        private
        view
        returns (PricingBatch memory batch)
    {
        uint256 remainingRequests = $.requests.length - $.head;
        uint256 limit = maxRequests < remainingRequests ? maxRequests : remainingRequests;
        batch.requestIds = new uint256[](limit);
        batch.shares = new uint256[](limit);
        batch.quotedAssets = new uint256[](limit);
        if (limit == 0) return batch;

        uint256 budgetShares = $.vault.convertToSharesAtRedemption($.settlementBudget);
        if (budgetShares == 0) {
            batch.stopReason = 1;
            return batch;
        }

        uint256 cursor = $.head;
        uint256 cooldown = $.redeemCooldown;
        while (batch.count < limit && cursor < $.requests.length) {
            Request storage r = $.requests[cursor];
            uint256 eligibleAt = uint256(r.requestedAt) + cooldown;
            if (block.timestamp < eligibleAt) {
                batch.stopReason = 2;
                batch.blockedEligibleAt = eligibleAt;
                break;
            }

            uint256 remainingBudgetShares = budgetShares - batch.aggregateShares;
            if (remainingBudgetShares == 0) {
                batch.stopReason = 1;
                break;
            }
            (uint256 fillShares, uint256 withheld) =
                _safeBatchFill($, batch.aggregateShares, remainingBudgetShares, r.sharesRemaining);
            batch.withheld = withheld;

            uint256 quotedAssets = $.vault.previewRedeem(fillShares);
            if (quotedAssets == 0) {
                batch.stopReason = $.vault.previewRedeem(r.sharesRemaining) != 0 ? 1 : 3;
                break;
            }

            batch.requestIds[batch.count] = cursor;
            batch.shares[batch.count] = fillShares;
            batch.quotedAssets[batch.count] = quotedAssets;
            batch.count += 1;
            batch.aggregateShares += fillShares;

            // Q-01 permits a complete head to cross the nominal floor-rounded share cap when
            // the aggregate asset quote still fits the budget. That completion consumes the
            // pricing session: subtracting the now-smaller nominal cap on the next iteration
            // would underflow, and there is no additional budget-denominated share capacity to
            // allocate safely. Stop after recording the valid over-fill.
            if (batch.aggregateShares >= budgetShares) {
                batch.stopReason = 1;
                break;
            }
            if (fillShares != r.sharesRemaining) {
                batch.stopReason = 1;
                break;
            }
            cursor += 1;
        }
    }

    /// @dev Q-01 residue policy expressed on the aggregate quote. Completing above the nominal
    ///      share cap is permitted only when the completed aggregate still fits the asset budget.
    function _safeBatchFill(
        QueueStorage storage $,
        uint256 aggregateShares,
        uint256 remainingBudgetShares,
        uint256 requestedShares
    ) private view returns (uint256 fillShares, uint256 withheld) {
        fillShares = requestedShares < remainingBudgetShares ? requestedShares : remainingBudgetShares;
        if (fillShares == requestedShares) return (fillShares, 0);

        uint256 minResidue = $.vault.previewWithdraw(MIN_RESIDUE_VALUE);
        if (requestedShares - fillShares >= minResidue) return (fillShares, 0);

        uint256 completedAggregate = aggregateShares + requestedShares;
        if (
            $.vault.previewRedeem(remainingBudgetShares) != 0
                && $.vault.previewRedeem(completedAggregate) <= $.settlementBudget
        ) return (requestedShares, 0);

        uint256 budgetCappedAggregate = aggregateShares + fillShares;
        fillShares = requestedShares > minResidue ? requestedShares - minResidue : 0;
        uint256 reducedAggregate = aggregateShares + fillShares;
        withheld = $.vault.previewRedeem(budgetCappedAggregate) - $.vault.previewRedeem(reducedAggregate);
    }

    /// @dev Executes one vault burn for the whole selected pricing session, then assigns the
    ///      exact receipt at the quote used during selection. Individual floor quotes are paid to
    ///      every item except the final item, which deterministically receives aggregate rounding
    ///      dust. Thus claims sum exactly to assets received and no earlier request can subsidize
    ///      a later request through a second vault price.
    function _executePricingBatch(QueueStorage storage $, PricingBatch memory batch) private {
        uint256 quotedAggregateAssets = $.vault.previewRedeem(batch.aggregateShares);
        if (quotedAggregateAssets > $.settlementBudget) {
            revert Queue_PricingBudgetExceeded(quotedAggregateAssets, $.settlementBudget);
        }

        uint256 pricingAssets = $.vault.redemptionTotalAssets();
        uint256 pricingSupply = $.vault.totalSupply();
        bytes32 pricingStateHash = keccak256(
            abi.encode(
                address($.vault),
                $.vault.impairmentSource(),
                pricingAssets,
                pricingSupply,
                $.vault.unvestedYield(),
                $.vault.lastFeeAccrual()
            )
        );

        uint256 assetsReceived = $.vault.redeem(batch.aggregateShares, address(this), address(this));
        if (assetsReceived != quotedAggregateAssets) {
            revert Queue_PricingQuoteChanged(quotedAggregateAssets, assetsReceived);
        }

        _allocateBatchReceipt($, batch, assetsReceived);

        $.totalQueuedShares -= batch.aggregateShares;
        $.settlementBudget -= assetsReceived;
        $.settlementDistributed += assetsReceived;

        uint256 sessionId = $.nextPricingSessionId;
        if (sessionId == type(uint256).max) revert Queue_PricingSessionExhausted();
        sessionId += 1;
        $.nextPricingSessionId = sessionId;
        emit PricingBatchSettled(
            $.currentEpoch,
            sessionId,
            batch.requestIds[0],
            batch.requestIds[batch.count - 1],
            pricingAssets,
            pricingSupply,
            batch.aggregateShares,
            assetsReceived,
            pricingStateHash
        );
    }

    function _allocateBatchReceipt(QueueStorage storage $, PricingBatch memory batch, uint256 assetsReceived) private {
        uint256 allocated;
        for (uint256 i = 0; i < batch.count; ++i) {
            uint256 requestId = batch.requestIds[i];
            if (requestId != $.head) revert Queue_PricingRangeInvalid($.head, requestId);
            Request storage r = $.requests[requestId];
            uint256 fillShares = batch.shares[i];
            uint256 assetsOut = i + 1 == batch.count ? assetsReceived - allocated : batch.quotedAssets[i];
            if (assetsOut == 0 || allocated + assetsOut > assetsReceived) {
                revert Queue_PricingAllocationMismatch(assetsReceived, allocated + assetsOut);
            }

            r.sharesRemaining -= fillShares;
            r.assetsClaimable += assetsOut;
            allocated += assetsOut;
            emit RequestFilled(requestId, fillShares, assetsOut, $.currentEpoch);
            if (r.sharesRemaining == 0) $.head = requestId + 1;
        }
        if (allocated != assetsReceived) {
            revert Queue_PricingAllocationMismatch(assetsReceived, allocated);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (QueueStorage storage $) {
        assembly {
            $.slot := QUEUE_STORAGE_LOCATION
        }
    }
}
