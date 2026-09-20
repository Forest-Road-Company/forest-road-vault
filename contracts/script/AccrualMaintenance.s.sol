// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IContinuousAccrual} from "../src/interfaces/IContinuousAccrual.sol";

/// @notice The existing permissionless chronological maintenance entrypoint on either reserve.
interface IAccrualCheckpointSource is IContinuousAccrual {
    /// @notice Complete at most maximum scheduled events, reporting whether the book is current.
    function checkpointAccrual(uint256 maximum) external returns (uint256 processed, bool fresh);
}

/// @notice Bounded keeper maintenance for each independently configured Ethereum or BSC reserve.
/// @dev Invoke run(reserve, expectedChainId, maximum, maxBatches) periodically. Each checkpoint
///      is a separate Foundry transaction. A partial report requests another run and preserves
///      completed work. The selected signer needs no protocol role. Forge simulates by default;
///      submitting its transactions is an operator action outside this script's tests.
contract AccrualMaintenance is Script {
    /// @notice The RPC's chain differs from the chain explicitly selected by the operator.
    error AccrualMaintenance_WrongChain(uint256 actual, uint256 expected);
    /// @notice Both limits must be between one and 32, inclusive.
    error AccrualMaintenance_InvalidLimits(uint256 maximum, uint256 maxBatches);
    /// @notice The configured reserve address has no runtime code.
    error AccrualMaintenance_NoCode(address reserve);
    /// @notice The reserve has not activated continuous recognition.
    error AccrualMaintenance_NotEnabled();
    /// @notice Recognition cannot extend into the future or claim freshness before the current time.
    error AccrualMaintenance_InvalidSnapshot(uint64 accruedThrough, bool fresh);
    /// @notice A checkpoint reports more work than its transaction limit permits.
    error AccrualMaintenance_InvalidProgress(uint256 processed, uint256 maximum);
    /// @notice An incomplete checkpoint completed no event, so retrying cannot make progress.
    error AccrualMaintenance_NoProgress();
    /// @notice The checkpoint's return value disagrees with its subsequent public snapshot.
    error AccrualMaintenance_IncoherentResult(bool returnedFresh, bool observedFresh);
    /// @notice The reserve's recognition frontier moved backwards during maintenance.
    error AccrualMaintenance_ClockMovedBackwards(uint64 previous, uint64 current);

    /// @notice Completed work and the remaining maintenance posture at the end of this run.
    struct Report {
        uint256 batches;
        uint256 processed;
        uint64 accruedThrough;
        bool fresh;
    }

    /// @notice Process due work within explicit transaction and invocation budgets.
    /// @param reserve The reserve whose public snapshot and chronological queue are maintained.
    /// @param expectedChainId Required connected chain; prevents using an address on another chain.
    /// @param maximum Maximum due events in each transaction, from one to 32.
    /// @param maxBatches Maximum transactions in this invocation, from one to 32.
    /// @return report Actual completed work; fresh=false means further invocations are needed.
    function run(address reserve, uint256 expectedChainId, uint256 maximum, uint256 maxBatches)
        external
        returns (Report memory report)
    {
        if (block.chainid != expectedChainId) {
            revert AccrualMaintenance_WrongChain(block.chainid, expectedChainId);
        }
        if (maximum == 0 || maximum > 32 || maxBatches == 0 || maxBatches > 32) {
            revert AccrualMaintenance_InvalidLimits(maximum, maxBatches);
        }
        if (reserve.code.length == 0) revert AccrualMaintenance_NoCode(reserve);
        IAccrualCheckpointSource source = IAccrualCheckpointSource(reserve);
        IContinuousAccrual.Snapshot memory snapshot = source.accrualSnapshot();
        _checkSnapshot(snapshot);
        report.accruedThrough = snapshot.accruedThrough;
        report.fresh = snapshot.fresh;
        while (!report.fresh && report.batches < maxBatches) {
            (uint256 processed, bool fresh) = _checkpoint(source, maximum);
            if (processed > maximum) revert AccrualMaintenance_InvalidProgress(processed, maximum);
            if (processed == 0 && !fresh) revert AccrualMaintenance_NoProgress();
            snapshot = source.accrualSnapshot();
            _checkSnapshot(snapshot);
            if (fresh != snapshot.fresh) revert AccrualMaintenance_IncoherentResult(fresh, snapshot.fresh);
            if (snapshot.accruedThrough < report.accruedThrough) {
                revert AccrualMaintenance_ClockMovedBackwards(report.accruedThrough, snapshot.accruedThrough);
            }
            ++report.batches;
            report.processed += processed;
            report.accruedThrough = snapshot.accruedThrough;
            report.fresh = fresh;
        }
        console2.log("Accrual maintenance batches:", report.batches);
        console2.log("Completed boundary events:", report.processed);
        console2.log("Recognized through:", uint256(report.accruedThrough));
        console2.log("Accrual current:", report.fresh);
    }

    /// @dev Keep each stateful checkpoint separate in Foundry's transaction list. The override
    ///      seam lets the loop's unit properties run without collecting broadcast records.
    function _checkpoint(IAccrualCheckpointSource source, uint256 maximum)
        internal
        virtual
        returns (uint256 processed, bool fresh)
    {
        vm.broadcast();
        return source.checkpointAccrual(maximum);
    }

    function _checkSnapshot(IContinuousAccrual.Snapshot memory snapshot) private view {
        if (!snapshot.enabled) revert AccrualMaintenance_NotEnabled();
        if (
            uint256(snapshot.accruedThrough) > block.timestamp
                || (snapshot.fresh && uint256(snapshot.accruedThrough) != block.timestamp)
        ) {
            revert AccrualMaintenance_InvalidSnapshot(snapshot.accruedThrough, snapshot.fresh);
        }
    }
}
