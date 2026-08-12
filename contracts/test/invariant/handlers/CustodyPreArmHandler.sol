// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CuratorModule} from "../../../src/CuratorModule.sol";
import {ICuratorModule} from "../../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../../src/libraries/Config.sol";

/// @title CustodyPreArmHandler — stateful driver for the guardian pre-arm budget/expiry machine
/// @notice AUDIT FIX F3-PA. The R6-CF1 pre-arm shipped with NO stateful coverage at all: every
///         property it claimed was pinned by single-shot unit tests, and three of its four defects
///         (a, b, c) are state-machine defects that only a sequence exposes. This handler exists so
///         that deleting any one of the guards in `preArmCustodyFreeze` /
///         `replenishCustodyPreArmBudget` reds a CAMPAIGN, not merely a hand-written scenario.
///
/// @dev WHAT IS INDEPENDENT HERE, STATED PRECISELY — the distinction matters and the repo has been
///      burned by blurring it before.
///
///        * THE STATE MACHINE (`mExpiry`, `mCount`, the episode reset, and above all the fact that
///          a replenishment does NOT write `mExpiry`) is modelled from THIS HANDLER'S OWN ACTIONS
///          and is never read back from the contract. That is where all three storage-affecting
///          guards live, and `invariant_PA1_*` / `invariant_PA2_*` are what falsify them.
///        * THE DURATION is recomputed from the parameters this handler itself wrote onto the
///          stub governor, not read from `custodyPreArmDuration()`. It is a reimplementation of
///          the derivation, which is weaker than the state machine above — so it is checked
///          SEPARATELY (`invariant_PA5_*`) rather than being allowed to launder a wrong duration
///          into an apparently-agreeing expiry.
///
///      `fail_on_revert = true` is not relaxed: every action either early-returns on a real
///      precondition or fires through try/catch and records the outcome as a counter the
///      invariants assert on. Nothing is pre-filtered away from a guard boundary.
contract CustodyPreArmHandler is Test {
    uint256 internal constant UNIT = 1e18;
    uint32 internal constant MAX_CONSECUTIVE = 2;
    uint64 internal constant MAX_PATH = 60 days;
    uint64 internal constant MAX_DURATION = 90 days;

    /// @dev Governor shapes the campaign points `CuratorModule` at. `SILENT` is the F3-PA-d shape:
    ///      real code, so `setGovernor` accepts it, but every call returns SUCCESS with EMPTY
    ///      returndata.
    uint256 internal constant GOV_NONE = 0;
    uint256 internal constant GOV_WELLFORMED = 1;
    uint256 internal constant GOV_SILENT = 2;

    CuratorModule internal immutable curator;
    address internal immutable admin;
    address internal immutable guardian;
    address internal immutable curatorWallet;
    uint256 internal immutable classId;
    PreArmStubGovernor internal immutable stubGovernor;
    address internal immutable silentGovernor;

    // ── INDEPENDENT MODEL OF THE PRE-ARM STATE MACHINE ───────────────────
    uint256 public mExpiry;
    uint32 public mCount;

    // ── the handler's own governor inputs (the duration is rebuilt from these) ──
    uint256 public govKind;
    uint256 public govDelay;
    uint256 public govPeriod;
    uint256 public govMinDelay;

    // ── ghosts ───────────────────────────────────────────────────────────
    uint256 public fuzzActionEntries;
    uint256 public callCount;

    uint256 public ghostArms;
    uint256 public ghostArmRefusalsBudget;
    /// @dev F3-PA-d: ANY refusal that is not the budget bound is a DISARMED GUARDIAN. Asserted
    ///      zero by `invariant_PA4_noGovernorShapeEverDisarmsTheGuardian`.
    uint256 public ghostArmRefusalsOther;
    uint256 public ghostArmsAcceptedOverBudget;
    uint256 public ghostArmsRefusedWithinBudget;
    uint256 public ghostEpisodeResets;
    uint256 public ghostTruncatedArms;
    uint256 public ghostArmsAgainstSilentGovernor;

    uint256 public ghostReplenishes;
    /// @dev The F3-PA-a shape specifically: budget returned while a pre-arm was STILL STANDING.
    uint256 public ghostReplenishesWhileProtected;
    uint256 public ghostCancels;

    uint256 public ghostFrozenWithdrawRefusals;
    /// @dev THE VIOLATION COUNTER. A curator withdrawal that completed while the model says the
    ///      guardian pre-arm was live.
    uint256 public ghostFrozenWithdrawAccepted;
    uint256 public ghostFreeWithdrawals;
    /// @dev A custody refusal while the model says nothing was armed — the freeze outliving its
    ///      own expiry, i.e. a lock with no exit.
    uint256 public ghostUnexpectedFreeze;
    uint256 public ghostPosts;

    constructor(
        address curator_,
        address admin_,
        address guardian_,
        address curatorWallet_,
        uint256 classId_,
        address silentGovernor_
    ) {
        curator = CuratorModule(curator_);
        admin = admin_;
        guardian = guardian_;
        curatorWallet = curatorWallet_;
        classId = classId_;
        silentGovernor = silentGovernor_;
        stubGovernor =
            new PreArmStubGovernor(Config.GOV_VOTING_DELAY, Config.GOV_VOTING_PERIOD, Config.TIMELOCK_MIN_DELAY);
        govDelay = Config.GOV_VOTING_DELAY;
        govPeriod = Config.GOV_VOTING_PERIOD;
        govMinDelay = Config.TIMELOCK_MIN_DELAY;
        govKind = GOV_NONE;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  MODEL — rebuilt from this handler's own inputs
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The UNBOUNDED governance path the pre-arm is supposed to outlast.
    function mLivePath() public view returns (uint256) {
        uint256 path = uint256(Config.GOV_VOTING_DELAY) + uint256(Config.GOV_VOTING_PERIOD) + Config.TIMELOCK_MIN_DELAY;
        if (govKind == GOV_WELLFORMED) {
            uint256 live = govDelay + govPeriod + govMinDelay;
            if (live > path) path = live;
        }
        return path;
    }

    function mGovernancePath() public view returns (uint64) {
        uint256 path = mLivePath();
        return path > MAX_PATH ? MAX_PATH : uint64(path);
    }

    function mDuration() public view returns (uint64) {
        uint256 bounded = uint256(mGovernancePath());
        uint256 d = bounded + bounded / 2;
        if (d > MAX_DURATION) d = MAX_DURATION;
        if (d <= bounded) d = bounded + 1;
        return uint64(d);
    }

    function mCooldown() public view returns (uint256) {
        return uint256(mDuration()) * MAX_CONSECUTIVE;
    }

    /// @notice MODEL view of the guardian pre-arm limb of `custodyFreezeActive()`.
    function mPreArmActive() public view returns (bool) {
        return block.timestamp < mExpiry;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  FUZZ ACTIONS (every one must appear in the `targetSelector` list)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The guardian arms. Fired UNCONDITIONALLY — including when the model says the budget
    ///         is spent, which is the illegal region the budget bound exists to refuse. Filtering
    ///         that case out would make the bound invisible to the campaign.
    function guardianPreArm() external {
        fuzzActionEntries++;
        _arm();
        callCount++;
    }

    /// @notice Governance returns the guardian's budget. THE F3-PA-a LEVER. The model deliberately
    ///         does NOT touch `mExpiry` here: if the contract does, `invariant_PA1` and
    ///         `invariant_PA2` both red on the very next evaluation.
    function governanceReplenishBudget() external {
        fuzzActionEntries++;
        bool shouldSucceed = mCount != 0;
        bool wasProtected = mPreArmActive();
        vm.prank(admin);
        try curator.replenishCustodyPreArmBudget() {
            mCount = 0;
            ghostReplenishes++;
            if (wasProtected) ghostReplenishesWhileProtected++;
            if (!shouldSucceed) ghostArmsAcceptedOverBudget++; // an accepted no-op replenishment
        } catch {
            // A refusal with budget spent would be a liveness bug; the model equality catches the
            // state consequence and `afterInvariant` proves the accepted branch was reached.
        }
        callCount++;
    }

    /// @notice Governance declares a FALSE ALARM: both limbs of the pre-arm cleared.
    function governanceCancelPreArm() external {
        fuzzActionEntries++;
        vm.prank(admin);
        try curator.cancelCustodyPreArm() {
            mExpiry = 0;
            mCount = 0;
            ghostCancels++;
        } catch {
            // Reverts only when nothing has ever been armed; that is the documented behaviour.
        }
        callCount++;
    }

    /// @notice Time passes. Bounded wide enough to reach BOTH the lapse of a pre-arm and the end of
    ///         the cooldown that follows it — the two boundaries the episode reset sits between.
    function warp(uint256 dtSeed) external {
        fuzzActionEntries++;
        vm.warp(block.timestamp + bound(dtSeed, 1 hours, 45 days));
        callCount++;
    }

    /// @notice The curator tries to leave. Fired at the guard on every call, frozen or not, so both
    ///         the refusal and the free branch are real campaign states.
    function curatorWithdraw(uint256 amountSeed) external {
        fuzzActionEntries++;
        bool frozen = mPreArmActive();
        uint256 posted = curator.postedOf(classId, curatorWallet);
        uint256 amount = posted == 0 ? UNIT : bound(amountSeed, 1, posted < 5_000 * UNIT ? posted : 5_000 * UNIT);

        vm.prank(curatorWallet);
        try curator.withdrawFirstLoss(classId, amount) {
            if (frozen) ghostFrozenWithdrawAccepted++;
            else ghostFreeWithdrawals++;
        } catch (bytes memory reason) {
            if (reason.length >= 4 && bytes4(reason) == ICuratorModule.Curator_CustodyLossFrozen.selector) {
                ghostFrozenWithdrawRefusals++;
                if (!frozen) ghostUnexpectedFreeze++;
            }
        }
        callCount++;
    }

    /// @notice Layer-1 capital is topped up, so the withdrawal probe keeps meeting a funded pool
    ///         for the whole run instead of degenerating into a zero-stake no-op.
    function curatorPost(uint256 amountSeed) external {
        fuzzActionEntries++;
        uint256 amount = bound(amountSeed, UNIT, 10_000 * UNIT);
        vm.prank(curatorWallet);
        try curator.postFirstLoss(classId, amount) {
            ghostPosts++;
        } catch {
            // out of pre-minted USDfr; a legitimate end state for this handler
        }
        callCount++;
    }

    /// @notice Governance RETUNES the three parameters the pre-arm duration is derived from. This
    ///         is the F3-PA-c lever: it drives the derivation across the covered regime, the
    ///         boundary, and the truncating regime beyond `CUSTODY_PRE_ARM_MAX_PATH`.
    function retuneGovernance(uint256 dSeed, uint256 pSeed, uint256 mSeed) external {
        fuzzActionEntries++;
        uint256 d = bound(dSeed, 0, 120 days);
        uint256 p = bound(pSeed, 0, 120 days);
        uint256 m = bound(mSeed, 0, 120 days);
        stubGovernor.setSchedule(d, p);
        stubGovernor.setMinDelay(m);
        govDelay = d;
        govPeriod = p;
        govMinDelay = m;
        callCount++;
    }

    /// @notice Governance re-points the governor, including at the F3-PA-d shape that used to
    ///         revert `custodyPreArmDuration()` outright and disarm the guardian.
    function pointGovernorAt(uint256 kindSeed) external {
        fuzzActionEntries++;
        uint256 kind = kindSeed % 3;
        address target =
            kind == GOV_NONE ? address(0) : (kind == GOV_WELLFORMED ? address(stubGovernor) : silentGovernor);
        vm.prank(admin);
        try curator.setGovernor(target) {
            govKind = kind;
        } catch {
            // `setGovernor` only rejects an EOA, and none of the three targets is one.
        }
        callCount++;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  DETERMINISTIC SEED (called once from the suite's setUp; NOT a selector)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Drives one of every shape the anti-vacuity floors assert.
    /// @dev House pattern: forge restarts every run from the post-`setUp` state and
    ///      `afterInvariant` samples ONE run, so a single run's fuzz reach is not a safe floor for
    ///      a narrow conjunction (an episode that lapses AND cools AND is re-armed). The seed
    ///      guarantees every run is evaluated against a state where each shape exists;
    ///      `fuzzActionEntries` stays the wiring tooth and is never touched here.
    function seedPreArmShapes() external {
        // (1) a full episode, spent
        _arm();
        _arm();
        // (2) the budget bound refusing an arm
        _arm();
        // (3) a refused withdrawal while armed
        _probeWithdraw();
        // (4) a replenishment WHILE PROTECTED — the F3-PA-a shape — then an arm on the new budget
        vm.prank(admin);
        curator.replenishCustodyPreArmBudget();
        mCount = 0;
        ghostReplenishes++;
        ghostReplenishesWhileProtected++;
        _arm();
        // (5) lapse, cool down, and open a NEW episode: the F3-PA-b shape
        vm.warp(mExpiry + mCooldown());
        _probeWithdraw(); // a FREE withdrawal in the enforced unfrozen window
        _arm();
        // (6) a cancel
        _cancel();
        // (7) the F3-PA-d governor shape, armed against
        vm.prank(admin);
        curator.setGovernor(silentGovernor);
        govKind = GOV_SILENT;
        _arm();
        _cancel();
        // (8) the F3-PA-c truncating regime, armed against
        vm.prank(admin);
        curator.setGovernor(address(stubGovernor));
        govKind = GOV_WELLFORMED;
        stubGovernor.setSchedule(60 days, 60 days);
        stubGovernor.setMinDelay(60 days);
        govDelay = 60 days;
        govPeriod = 60 days;
        govMinDelay = 60 days;
        _arm();
        // leave the campaign in the launch configuration
        _cancel();
        vm.prank(admin);
        curator.setGovernor(address(0));
        govKind = GOV_NONE;
        stubGovernor.setSchedule(Config.GOV_VOTING_DELAY, Config.GOV_VOTING_PERIOD);
        stubGovernor.setMinDelay(Config.TIMELOCK_MIN_DELAY);
        govDelay = Config.GOV_VOTING_DELAY;
        govPeriod = Config.GOV_VOTING_PERIOD;
        govMinDelay = Config.TIMELOCK_MIN_DELAY;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INTERNALS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev THE MODELLED ARM. Every guard under test is a line in the prediction below:
    ///        - the episode reset (`count != 0 && now >= expiry + cooldown`) — F3-PA-b;
    ///        - the `+ cooldown` term inside it — the safety half of F3-PA-b;
    ///        - the budget bound itself.
    ///      The prediction is committed to the model BEFORE the outcome is known, so a contract
    ///      that resets differently diverges immediately and `invariant_PA1` reds.
    function _arm() private {
        uint64 d = mDuration();
        uint32 c = mCount;
        bool reset = (c != 0 && block.timestamp >= mExpiry + mCooldown());
        if (reset) c = 0;
        c += 1;
        bool shouldSucceed = c <= MAX_CONSECUTIVE;

        vm.prank(guardian);
        try curator.preArmCustodyFreeze() {
            if (!shouldSucceed) ghostArmsAcceptedOverBudget++;
            if (reset) ghostEpisodeResets++;
            mCount = c;
            mExpiry = block.timestamp + uint256(d);
            ghostArms++;
            if (govKind == GOV_SILENT) ghostArmsAgainstSilentGovernor++;
            if (uint256(d) <= mLivePath()) ghostTruncatedArms++;
        } catch (bytes memory reason) {
            if (reason.length >= 4 && bytes4(reason) == ICuratorModule.Curator_PreArmBudgetExhausted.selector) {
                ghostArmRefusalsBudget++;
                if (shouldSucceed) ghostArmsRefusedWithinBudget++;
            } else {
                // F3-PA-d. A governor shape, a gas budget, a decode — nothing may disarm the
                // guardian. Asserted zero.
                ghostArmRefusalsOther++;
            }
        }
    }

    /// @dev The seed's cancels go through the same try/catch discipline as the fuzz actions. THIS
    ///      IS NOT COSMETIC: if a mutation disarms the guardian, the arm that precedes a cancel is
    ///      refused and a RAW cancel would revert in `setUp`, taking the whole campaign down before
    ///      a single invariant could be evaluated. The campaign must survive to report WHICH
    ///      property broke — `invariant_PA4c` — rather than collapsing into an opaque setup revert.
    function _cancel() private {
        vm.prank(admin);
        try curator.cancelCustodyPreArm() {
            mExpiry = 0;
            mCount = 0;
            ghostCancels++;
        } catch {}
    }

    function _probeWithdraw() private {
        bool frozen = mPreArmActive();
        vm.prank(curatorWallet);
        try curator.withdrawFirstLoss(classId, UNIT) {
            if (frozen) ghostFrozenWithdrawAccepted++;
            else ghostFreeWithdrawals++;
        } catch (bytes memory reason) {
            if (reason.length >= 4 && bytes4(reason) == ICuratorModule.Curator_CustodyLossFrozen.selector) {
                ghostFrozenWithdrawRefusals++;
                if (!frozen) ghostUnexpectedFreeze++;
            }
        }
    }
}

/// @dev Governance-parameter source for the campaign. Not a model of governance behaviour.
contract PreArmStubGovernor {
    uint256 public votingDelay;
    uint256 public votingPeriod;
    address public timelock;

    constructor(uint256 delay_, uint256 period_, uint256 minDelay_) {
        votingDelay = delay_;
        votingPeriod = period_;
        timelock = address(new PreArmStubTimelock(minDelay_));
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function setSchedule(uint256 delay_, uint256 period_) external {
        votingDelay = delay_;
        votingPeriod = period_;
    }

    function setMinDelay(uint256 minDelay_) external {
        PreArmStubTimelock(timelock).setMinDelay(minDelay_);
    }
}

contract PreArmStubTimelock {
    uint256 public getMinDelay;

    constructor(uint256 minDelay_) {
        getMinDelay = minDelay_;
    }

    function setMinDelay(uint256 v) external {
        getMinDelay = v;
    }
}

/// @dev THE F3-PA-d SHAPE: real code, every call succeeds with EMPTY returndata.
contract PreArmSilentGovernor {
    fallback() external {}
}
