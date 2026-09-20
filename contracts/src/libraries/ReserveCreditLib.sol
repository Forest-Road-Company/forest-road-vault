// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {ReserveManager} from "../ReserveManager.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveCreditLib — the ReserveManager's credit-path bodies
///
/// @notice EXTRACTED 2026-09-09 FOR EIP-170, mirroring BSC commit `9438be1`. The live mainnet
///         `ReserveManager` shipped with 9 bytes of runtime margin, so it was frozen against any
///         new function; adding `recordPikCapitalization` put it 184 bytes over the 24,576 limit
///         even after the fee and PIK twins were made to share one private body.
///
/// @dev EVERY FUNCTION HERE IS `public` AND THAT IS THE WHOLE POINT. A `public` library function is
///      deployed as its own contract and reached by delegatecall, so its bytecode leaves the
///      caller's runtime; an `internal` one is inlined and saves nothing. The library therefore
///      needs LINKING at deploy time, which is new for this repository.
///
/// @dev THE CALLER KEEPS THE GUARDS. `ReserveManager` retains every `onlyRole`, `nonReentrant` and
///      `whenNotPaused` modifier on the external entry points, because a delegatecall runs in the
///      proxy's context and a library cannot see the caller's modifiers. Do not call anything here
///      from a path that does not carry them.
///
/// @dev DELEGATECALL MEANS `address(this)` IS THE PROXY, which is what keeps `safeTransfer`,
///      `balanceOf(address(this))` and the self-deployment guard meaning exactly what they meant
///      when these bodies lived in the contract.
library ReserveCreditLib {
    /// @notice Principal and previously recognized interest discharged by measured canonical USDC.
    event AccruedPaymentReceived(
        uint256 indexed facilityId,
        address indexed asset,
        address indexed payer,
        uint256 nativeUnits,
        uint256 principalReduction,
        uint256 interestReduction
    );

    using SafeERC20 for IERC20;
    using ReserveStorageLib for ReserveManager.ReserveStorage;

    /// @dev Body of `ReserveManager.recordDeployment`.
    function deploy(ReserveManager.ReserveStorage storage $, uint256 facilityId, address to, uint256 usdcAmount)
        public
    {
        if (to == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (to == address(this)) revert IReserveManager.ReserveManager_SelfDeployment();
        if (usdcAmount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        // MA-1/R4-01: a live custody shortfall freezes the facility-funding USDC out-door.
        $.requireIdleFullyCustodied();
        uint256 value = ReserveStorageLib.normalize(usdcAmount);
        uint256 idleValue = ReserveStorageLib.normalize($.idleUSDCUnits);
        if (value > idleValue) revert IReserveManager.ReserveManager_InsufficientIdleValue(value, idleValue);
        $.idleUSDCUnits -= usdcAmount;
        $.deployed[facilityId] += value;
        $.totalDeployedPrincipal += value;
        $.usdcToken.safeTransfer(to, usdcAmount);
        emit IReserveManager.PrincipalDeployed(facilityId, value);
    }

    /// @dev Shared body of `recordFeeCapitalization` and `recordPikCapitalization`. `requireIdle`
    ///      is the fee twin's solvency bound; PIK has no cash behind it and passes false.
    ///
    ///      The fee twin is sound because the fee's cash NEVER LEFT: `fund` deploys
    ///      `principal - fee`, so backing rises against RETAINED CASH and bounding it by idle is
    ///      meaningful. There is no retained cash behind a PIK capitalisation; what stands behind
    ///      it is the borrower's obligation to repay a larger balance and, beneath that, the
    ///      curator first-loss layer. Bounding a receivable by idle cash would refuse a legitimate
    ///      capitalisation on a drawn-down book and admit one on a flush book.
    ///
    ///      EVERY OTHER BOUND ON PIK LIVES IN `WaterfallEngine.capitalizePik`.
    function capitalize(ReserveManager.ReserveStorage storage $, uint256 facilityId, uint256 amount, bool requireIdle)
        public
    {
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        uint256 units = ReserveStorageLib.denormalize(amount);
        if (ReserveStorageLib.normalize(units) != amount) {
            revert IReserveManager.ReserveManager_ValueNotUSDCExact(amount);
        }
        if (requireIdle) {
            uint256 idleValue = ReserveStorageLib.normalize($.idleUSDCUnits);
            if (amount > idleValue) revert IReserveManager.ReserveManager_InsufficientIdleValue(amount, idleValue);
        }
        // The borrower owes the full face amount while the OID cash stays in the treasury (fee
        // path) or while the interest compounds into principal (PIK path). Both are additional
        // receivable; only the fee path has retained cash standing behind it.
        $.deployed[facilityId] += amount;
        $.totalDeployedPrincipal += amount;
        if (requireIdle) {
            emit IReserveManager.FeeCapitalized(facilityId, amount);
        } else {
            emit IReserveManager.PikCapitalized(facilityId, amount, $.deployed[facilityId]);
        }
    }

    /// @dev Body of `ReserveManager.recordPayment`.
    function pay(
        ReserveManager.ReserveStorage storage native,
        uint256 facilityId,
        address payer,
        uint256 usdcAmount,
        uint256 principal
    ) public returns (uint256 receivedValue) {
        receivedValue = _pay(native, facilityId, payer, usdcAmount, principal);
        emit IReserveManager.PaymentReceived(facilityId, payer, usdcAmount, principal);
    }

    /// @notice A measured receipt replaces already recognized cash or PIK receivable, without new income.
    function payAccrued(
        ReserveManager.ReserveStorage storage native,
        uint256 facilityId,
        address payer,
        uint256 usdcAmount,
        uint256 principalReduction,
        uint256 interestReduction
    ) public returns (uint256 receivedValue) {
        receivedValue = _pay(native, facilityId, payer, usdcAmount, principalReduction + interestReduction);
        emit AccruedPaymentReceived(
            facilityId, address(native.usdcToken), payer, usdcAmount, principalReduction, interestReduction
        );
    }

    function _pay(
        ReserveManager.ReserveStorage storage $,
        uint256 facilityId,
        address payer,
        uint256 usdcAmount,
        uint256 principal
    ) private returns (uint256 receivedValue) {
        if (payer == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (usdcAmount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        uint256 beforeBalance = $.usdcToken.balanceOf(address(this));
        $.usdcToken.safeTransferFrom(payer, address(this), usdcAmount);
        uint256 received = $.usdcToken.balanceOf(address(this)) - beforeBalance;
        if (received != usdcAmount) {
            revert IReserveManager.ReserveManager_UnexpectedUSDCReceipt(usdcAmount, received);
        }
        receivedValue = ReserveStorageLib.normalize(received);
        if (principal > receivedValue) {
            revert IReserveManager.ReserveManager_PrincipalExceedsPayment(principal, receivedValue);
        }
        uint256 deployedFace = $.deployed[facilityId];
        if (principal > deployedFace) {
            revert IReserveManager.ReserveManager_InsufficientDeployedPrincipal(facilityId, principal, deployedFace);
        }
        $.idleUSDCUnits += received;
        if (principal != 0) {
            uint256 remainingFace = deployedFace - principal;
            $.deployed[facilityId] = remainingFace;
            $.totalDeployedPrincipal -= principal;
            // H-1: cash collection does not prove that a governance-adjudicated impairment
            // was recovered. Preserve the mark unless the smaller remaining face can no longer
            // support it; only that arithmetically unavoidable excess is released. Treating
            // every repayment dollar as recovery made backing depend on repayment/write-down
            // ordering and could silently reopen par exits against the still-impaired claim.
            $.clampImpairmentToRemainingFace(facilityId, remainingFace);
        }
    }

    /// @dev Body of `ReserveManager.recordPrincipalWritedown`. Extracted with the credit path
    ///      because it shares the impairment helpers with `pay`.
    function writeDown(ReserveManager.ReserveStorage storage $, uint256 facilityId, uint256 amount) public {
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        uint256 deployedFace = $.deployed[facilityId];
        if (amount > deployedFace) {
            revert IReserveManager.ReserveManager_InsufficientDeployedPrincipal(facilityId, amount, deployedFace);
        }
        $.deployed[facilityId] = deployedFace - amount;
        $.totalDeployedPrincipal -= amount;
        // A write-down is the realization of loss, so the mark already carried against that
        // loss must be consumed to avoid counting the same dollar twice.
        $.realizeImpairmentOnWriteDown(facilityId, amount);
        emit IReserveManager.PrincipalWrittenDown(facilityId, amount);
    }
}
