// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @title GuardProbe
/// @notice STRUCTURAL REMEDY for AUDIT FINDING G11/G12 — "the mandatory invariant tier proves the
///         happy path".
///
///         THE ROOT CAUSE. `foundry.toml` sets `invariant.fail_on_revert = true`. That setting is
///         correct and must stay: a handler that reverts is a handler bug, and tolerating reverts
///         silently converts a campaign into a no-op. But it imposes a duty on every handler to
///         PRE-FILTER its fuzzed inputs so that no call can revert — and pre-filtering is
///         precisely a description of the guard the invariant exists to police. The campaign is
///         therefore systematically steered AWAY from every guard boundary. Three concrete
///         casualties were found in this repository:
///           * `QueueHandler.request` bounded shares into the admissible band and then asserted
///             the entry floor held — restating its own bound (finding G12.2);
///           * no handler ever attempted `WaterfallEngine.fund` on a facility with no NFT, so the
///             §1.3 "escrow cannot release without the NFT" clause was never entered (G12.3);
///           * the access-control probes were a 29-entry hand-written sample of a 130-guard
///             surface (G12.1).
///
///         THE FIX, AND WHY IT IS THIS SHAPE. Rather than turn `fail_on_revert` off (which would
///         blind every existing suite to genuine handler bugs), this base inverts the duty. A
///         handler no longer filters an out-of-band input away; it FIRES the raw input through
///         `_fireAtGuard` and the REFUSAL BECOMES THE ASSERTED PROPERTY. The handler itself still
///         never reverts, so `fail_on_revert = true` keeps all of its teeth, while the campaign
///         now spends its calls exactly where the guards live.
///
///         A probe needs no rollback machinery: when the guard holds, the call reverts and the
///         EVM has already undone everything, so the campaign's state trajectory is untouched.
///         `guardAdmissions` is what carries a bypass out to the invariant. See the long comment
///         inside `_fireAtGuard` for the snapshot-based version that was tried first and why it
///         silently produced a fully vacuous campaign.
///
///         REACH LEDGER. Every probe is registered up front and its outcomes are counted, so a
///         suite can prove — not hope — that the campaign entered the branch. `reachReport()`
///         prints the per-guard reached / NOT-REACHED table that finding G11/G12 asks for. An
///         invariant whose guard shows `attempts = 0` is passing vacuously and must be treated as
///         a failure, not as assurance.
///
/// @dev DO NOT "improve" `_fireAtGuard` by pre-checking whether the call will succeed. That turns
///      the probe back into the pre-filter that caused this finding, and it is the single change
///      that would make every suite built on this base vacuous again.
///
/// @dev READING A FAILING CAMPAIGN. `console2.log` output printed under a failed invariant comes
///      from Foundry's REPLAY of the shrunk sequence, not from the run whose assertion failed —
///      the numbers in the logs are routinely smaller than the numbers in the assertion message,
///      and the ASSERTION MESSAGE is the truthful one. Reading the logs as if they were the real
///      end-of-campaign state leads straight to "the campaign did nothing", which is wrong.
abstract contract GuardProbe is Test {
    /// @notice How a single unfiltered probe came out.
    enum Verdict {
        /// @dev The call SUCCEEDED. For a negative probe this means the guard did not hold.
        Admitted,
        /// @dev Refused with exactly the selector the guard is specified to raise.
        RefusedAsSpecified,
        /// @dev Refused, but by something else — the probe did not reach the guard under test.
        ///      Not a violation, but a VACUITY signal: it must not be the only outcome.
        RefusedOtherwise
    }

    struct GuardReach {
        uint256 attempts;
        uint256 admitted;
        uint256 refusedAsSpecified;
        uint256 refusedOtherwise;
        bytes4 expected;
        bytes4 lastSelector;
        bool registered;
        string label;
    }

    bytes32[] private _guardIds;
    mapping(bytes32 => GuardReach) private _reach;

    /// @notice Total guard bypasses across every registered guard. An invariant asserts this is
    ///         zero; it is the single number that carries every probe's verdict out of the
    ///         handler, because the state change that produced it has been rolled back.
    uint256 public guardAdmissions;
    /// @notice The guard whose bypass is being reported, for the failure message.
    bytes32 public lastAdmittedGuard;
    /// @notice Total unfiltered probes fired. `afterInvariant` asserts this is nonzero — a
    ///         campaign that never probed a boundary proves nothing about the boundary.
    uint256 public guardProbeAttempts;

    /// @notice Declares a guard boundary and the exact selector its refusal must carry.
    /// @dev Registration is separate from firing so `reachReport()` can list a guard that was
    ///      NEVER reached. A guard that only appears when it is first hit could never be shown
    ///      as not-reached, which is the exact vacuity this ledger exists to expose.
    function _registerGuard(bytes32 guardId, bytes4 expectedSelector, string memory label) internal {
        GuardReach storage r = _reach[guardId];
        require(!r.registered, "GuardProbe: guard registered twice");
        r.registered = true;
        r.expected = expectedSelector;
        r.label = label;
        _guardIds.push(guardId);
    }

    function guardLabel(bytes32 guardId) public view returns (string memory) {
        return _reach[guardId].label;
    }

    /// @notice Fire `data` at `target` from `caller` WITHOUT pre-filtering, and classify the
    ///         guard's verdict.
    /// @dev The whole point is that the caller does NOT check whether the call will succeed
    ///      first. That is what a pre-filtering handler does, and it is what makes an invariant
    ///      restate its own bound instead of testing the contract.
    function _fireAtGuard(bytes32 guardId, address caller, address target, bytes memory data)
        internal
        returns (Verdict verdict)
    {
        require(_reach[guardId].registered, "GuardProbe: unregistered guard");
        bytes4 expected = _reach[guardId].expected;

        // NO `vm.snapshotState()` / `vm.revertToState()` WRAPPER HERE, DELIBERATELY.
        // A negative probe does not need one. When the guard holds, the call REVERTS and the EVM
        // has already undone every effect, so the campaign's state trajectory is untouched and
        // the probe cannot mask another invariant. When the guard does NOT hold, the call does
        // change state — but that is a violation, `guardAdmissions` records it, and the very next
        // invariant evaluation fails on it, so containing the change buys nothing and would cost
        // a full state snapshot on every probe.
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        bytes4 sel = _selectorOf(ret);

        GuardReach storage r = _reach[guardId];
        r.attempts++;
        r.lastSelector = ok ? bytes4(0) : sel;
        guardProbeAttempts++;
        if (ok) {
            r.admitted++;
            guardAdmissions++;
            lastAdmittedGuard = guardId;
            return Verdict.Admitted;
        }
        if (sel == expected) {
            r.refusedAsSpecified++;
            return Verdict.RefusedAsSpecified;
        }
        r.refusedOtherwise++;
        return Verdict.RefusedOtherwise;
    }

    /// @notice Records the verdict of a BEHAVIOURAL guard — one whose refusal is not a revert.
    ///
    /// @dev AUDIT FINDING (campaign 5, 2 x HIGH: "both arms of the Q-01 fix are deletable with
    ///      every stateful campaign green"). `_fireAtGuard` above can only police guards that
    ///      REVERT. The Q-01 residue-margin guard and its COMPLETE-branch conjunct do not revert:
    ///      they change WHAT GETS FILLED. Deleting either leaves `closeEpoch` succeeding, every
    ///      custody/FIFO/backing invariant reconciling, and the campaign green — which is exactly
    ///      how both survived thirteen campaigns.
    ///
    ///      So the same discipline is extended one step: the caller drives the settlement
    ///      DELIBERATELY into the state the guard exists for, evaluates the guard's specified
    ///      post-condition itself, and reports the verdict here. `held == false` is a bypass and
    ///      routes into the SAME `guardAdmissions` counter a reverting probe uses, so one
    ///      invariant carries every guard's verdict out of the handler.
    ///
    /// @dev THE VERDICT MUST NOT BE COMPUTED FROM THE CONTRACT'S OWN BRANCH. If `held` is derived
    ///      by re-running the implementation's condition, this records a tautology and the guard
    ///      is decoration again. Each call site derives `held` from the SPECIFIED post-condition
    ///      (e.g. "a partial fill leaves at least MIN_RESIDUE_VALUE behind"), stated in value
    ///      terms against the vault's public views.
    ///
    /// @dev Register a behavioural guard with `bytes4(0)` as its expected selector: it never
    ///      passes through `_fireAtGuard`, so there is nothing for that field to match, and
    ///      `bytes4(0)` cannot collide with a real refusal (an undecodable revert is reported as
    ///      `0xffffffff`).
    ///
    /// @param guardId The registered guard.
    /// @param held True if the guard's specified post-condition was observed to hold.
    function _recordBehaviouralGuard(bytes32 guardId, bool held) internal {
        GuardReach storage r = _reach[guardId];
        require(r.registered, "GuardProbe: unregistered guard");
        r.attempts++;
        guardProbeAttempts++;
        if (held) {
            r.refusedAsSpecified++;
            return;
        }
        r.admitted++;
        guardAdmissions++;
        lastAdmittedGuard = guardId;
    }

    // ── reach ledger views ───────────────────────────────────────────────

    function guardCount() external view returns (uint256) {
        return _guardIds.length;
    }

    function guardIdAt(uint256 i) external view returns (bytes32) {
        return _guardIds[i];
    }

    function guardAttempts(bytes32 guardId) public view returns (uint256) {
        return _reach[guardId].attempts;
    }

    function guardAdmitted(bytes32 guardId) public view returns (uint256) {
        return _reach[guardId].admitted;
    }

    function guardRefusedAsSpecified(bytes32 guardId) public view returns (uint256) {
        return _reach[guardId].refusedAsSpecified;
    }

    function guardRefusedOtherwise(bytes32 guardId) public view returns (uint256) {
        return _reach[guardId].refusedOtherwise;
    }

    function guardLastSelector(bytes32 guardId) external view returns (bytes4) {
        return _reach[guardId].lastSelector;
    }

    /// @notice The per-guard reached / NOT-REACHED table finding G11/G12 requires. Printed at
    ///         `-vv`; never asserted here, because each suite decides which of its guards must be
    ///         reached on EVERY run and which are campaign-wide claims.
    function reachReport() public view {
        console2.log("-- GuardProbe reach table (guard | attempts | refused-as-specified | other | ADMITTED) --");
        for (uint256 i = 0; i < _guardIds.length; ++i) {
            GuardReach storage r = _reach[_guardIds[i]];
            console2.log(r.label);
            console2.log("   attempts / as-specified", r.attempts, r.refusedAsSpecified);
            console2.log("   other / ADMITTED       ", r.refusedOtherwise, r.admitted);
            if (r.attempts == 0) console2.log("   *** NOT REACHED - this guard's property is VACUOUS ***");
        }
    }

    /// @dev `bytes4(0)` is never used as an "expected" selector, so an undecodable revert cannot
    ///      collide with a real expectation and be miscounted as a specified refusal.
    function _selectorOf(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0xffffffff);
        assembly ("memory-safe") {
            sel := mload(add(err, 0x20))
        }
    }
}
