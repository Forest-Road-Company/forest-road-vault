// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IContinuousAccrual} from "../src/interfaces/IContinuousAccrual.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {USDfr} from "../src/USDfr.sol";
import {MintRedeemController} from "../src/MintRedeemController.sol";
import {SUSDfr} from "../src/sUSDfr.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {ClaimBridge} from "../src/ClaimBridge.sol";
import {WaterfallEngine} from "../src/WaterfallEngine.sol";
import {DefaultManager} from "../src/DefaultManager.sol";

interface IAccrualBoundConsumer {
    /// @notice The reserve this consumer uses for continuous recognition.
    function accrualReserve() external view returns (address);
}

/// @notice Fresh-deployment wiring and independent checks for continuous recognition.
/// @dev Internal script functions preserve the bootstrap caller at every module call.
library ContinuousAccrualDeployment {
    /// @notice Continuous recognition has not been activated.
    error AccrualDeployment_Disabled();
    /// @notice The reserve names a different consumer bundle.
    error AccrualDeployment_WrongModules();
    /// @notice A consumer does not point back to the expected reserve.
    error AccrualDeployment_WrongConsumer(address consumer, address actual, address expected);
    /// @notice A scheduled accounting boundary still needs a checkpoint.
    error AccrualDeployment_Stale(uint64 accruedThrough);
    /// @notice The accrual book and waterfall name different protocol fee recipients.
    error AccrualDeployment_WrongFeeRecipient(address actual, address expected);
    /// @notice Receipt vesting is incompatible with continuous recognition.
    error AccrualDeployment_VestingEnabled();

    /// @notice Bind all consumers before enabling the empty native reserve book.
    /// @dev The reserve refuses activation while deployed receivables still require migration.
    function configure(address reserve, IContinuousAccrual.Modules memory m) internal {
        bind(reserve, m);
        ReserveManager(reserve).enableContinuousAccrual();
        validate(reserve, m);
    }

    /// @notice Install the permanent routes before empty-book activation or an attested opening.
    /// @dev This performs no activation; the caller must complete its selected preparation path.
    function bind(address reserve, IContinuousAccrual.Modules memory m) internal {
        ReserveManager(reserve).configureContinuousAccrual(m);
        USDfr(m.token).setAccrualReserve(reserve);
        MintRedeemController(m.controller).enableContinuousAccrual();
        SUSDfr(m.vault).setAccrualReserve(reserve);
        CollateralRegistry(m.registry).setAccrualReserve(reserve);
        ClaimBridge(m.bridge).setAccrualReserve(reserve);
        WaterfallEngine(m.waterfall).setAccrualReserve(reserve);
        DefaultManager(m.defaultManager).setAccrualReserve(reserve);
    }

    /// @notice Check both directions of every binding and the current recognition posture.
    function validate(address reserve, IContinuousAccrual.Modules memory expected) internal view {
        IContinuousAccrual source = IContinuousAccrual(reserve);
        IContinuousAccrual.Snapshot memory snapshot = source.accrualSnapshot();
        if (!snapshot.enabled) revert AccrualDeployment_Disabled();
        if (keccak256(abi.encode(source.accrualModules())) != keccak256(abi.encode(expected))) {
            revert AccrualDeployment_WrongModules();
        }
        address[7] memory consumers = [
            expected.token,
            expected.controller,
            expected.vault,
            expected.waterfall,
            expected.bridge,
            expected.registry,
            expected.defaultManager
        ];
        for (uint256 i; i < consumers.length; ++i) {
            address actual = IAccrualBoundConsumer(consumers[i]).accrualReserve();
            if (actual != reserve) revert AccrualDeployment_WrongConsumer(consumers[i], actual, reserve);
        }
        (, address reserveBackstop,,,) = ReserveManager(reserve).reserveLossModules();
        if (DefaultManager(expected.defaultManager).backstop() != reserveBackstop) {
            revert AccrualDeployment_WrongModules();
        }
        if (!snapshot.fresh) revert AccrualDeployment_Stale(snapshot.accruedThrough);
        address recipient = WaterfallEngine(expected.waterfall).feeRecipient();
        if (snapshot.feeRecipient != recipient) {
            revert AccrualDeployment_WrongFeeRecipient(snapshot.feeRecipient, recipient);
        }
        if (SUSDfr(expected.vault).yieldVestingPeriod() != 0) revert AccrualDeployment_VestingEnabled();
    }
}
