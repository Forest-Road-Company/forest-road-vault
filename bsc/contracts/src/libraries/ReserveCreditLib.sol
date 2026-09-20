// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {ReserveCascadeLib} from "./ReserveCascadeLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";
import {ReserveAccrualCreditLib} from "./ReserveAccrualCreditLib.sol";

/// @title ReserveCreditLib - the credit arm's four state transitions, hoisted out of `ReserveManager`
///
/// @notice EVERY FUNCTION HERE WAS A `ReserveManager` FUNCTION BODY and is reached only through the
///         proxy method of the same name, which keeps the role check, the reentrancy guard and the
///         pause gate. Nothing was added, removed or reordered in the move; this is an EIP-170
///         measure, not a redesign. `ReserveManager` had 575 bytes of margin against the 24,576-byte
///         limit before this split and 4,674 after it.
///
/// @dev WHY A LIBRARY AND NOT AN INTERNAL FUNCTION. These are `public`, so they are DELEGATECALLED
///      from a separately deployed library rather than inlined, which is the whole point: the bytes
///      live at another address and stop counting against the proxy's runtime size. The consequence
///      is that `address(this)` here is still the `ReserveManager` proxy, `msg.sender` is still the
///      original caller, and the storage they write is the proxy's ERC-7201 namespace passed in as
///      `$`. Reading any of those as if they belonged to the library would be wrong.
///
///      Continuous/legacy admission runs first inside each legacy credit transition. These
///      predicates are internal and inline here; they introduce no additional library link.
///      Host role, pause and reentrancy checks still run before the delegatecall.
///
///      THE GUARDS DO NOT LIVE HERE, AND THAT IS DELIBERATE. Access control, `nonReentrant` and the
///      pause check stay on the proxy method. A library function cannot be called directly by an
///      external account - a delegatecall target has no independent entry point on this path - so
///      duplicating the checks would add bytes to buy nothing. If a future caller reaches one of
///      these from anywhere other than its own proxy method, that guarantee is gone and the guards
///      have to come with it.
library ReserveCreditLib {
    using SafeERC20 for IERC20;
    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;

    /// @notice A measured receipt replaced an existing accrued principal/interest claim with cash.
    /// @dev Neither component is newly recognized income. Original attested legs remain in the waterfall event.
    event AccruedPaymentReceived(
        uint256 indexed facilityId,
        address indexed asset,
        address indexed payer,
        uint256 nativeAmount,
        uint256 principalReduction,
        uint256 interestReduction
    );

    /// @notice Ties a facility to the single asset it is denominated in, on its first credit act.
    /// @dev THE BINDING IS WHAT LETS `pay` REFUSE A REPAYMENT IN THE WRONG CURRENCY. It is set on
    ///      the first act that funds the facility and is immutable thereafter; `allowBind` is false
    ///      on the repayment path precisely so a payment can never create the binding it is supposed
    ///      to be checked against. Re-binding to the same asset is a no-op rather than an error, so
    ///      an ordinary second deployment into a live facility is not a special case.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility.
    /// @param asset The asset this act is denominated in.
    /// @param allowBind Whether this act may CREATE the binding, or only satisfy it.
    function bindFacilityAsset(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        bool allowBind
    ) internal {
        address bound = $.facilityAsset[facilityId];
        if (bound == asset) return;
        if (bound != address(0) || !allowBind) {
            revert IReserveManager.ReserveManager_FacilityAssetMismatch(facilityId, bound, asset);
        }
        $.facilityAsset[facilityId] = asset;
        emit IReserveManager.FacilityAssetBound(facilityId, asset);
    }

    /// @notice Moves idle custody out to a borrower as deployed principal.
    /// @dev THE CAP DOES NOT GATE A DEPLOYMENT, because a deployment LOWERS the tally; the ceiling
    ///      bounds voluntary mint-side exposure and this is the opposite direction. Deployed
    ///      principal stays a single 18-decimal aggregate rather than a per-asset tally because a
    ///      facility is a dollar claim and not a token balance, which is what keeps
    ///      `totalBackingValue` O(1) across a governed multi-asset registry.
    ///
    ///      UNITS ALREADY PROMISED TO A PENDING CLAIM ARE NOT DEPLOYABLE. The deployable figure nets
    ///      known unapplied custody loss and `claimedUnits` out of the tally, because ADR-0038's record-capped exit reserves rather
    ///      than debits: the tokens are physically held and already owed to a named holder, so
    ///      lending them out would fund a facility with a redeemer's money.
    ///
    ///      BACKING DOES NOT MOVE. Cash becomes a receivable of exactly equal value, which is why
    ///      this is a composition shift and not a solvency event.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility being funded.
    /// @param asset The listed asset to deploy.
    /// @param to The borrower.
    /// @param amount Native units to send.
    function deploy(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        address to,
        uint256 amount
    ) public {
        ReserveAccrualCreditLib.requireUnregisteredFunding(facilityId);
        if (to == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (to == address(this)) revert IReserveManager.ReserveManager_SelfDeployment();
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        ReserveStorageLib.ReserveAsset storage r = $.requireListed(asset);
        bindFacilityAsset($, facilityId, asset, true);
        $.requireCustodied();
        {
            uint256 reserved = $.claimedUnits[asset];
            uint256 held = ReserveStorageLib.idleAfterCustodyLoss(r);
            uint256 deployable = held > reserved ? held - reserved : 0;
            if (amount > deployable) {
                revert IReserveManager.ReserveManager_InsufficientIdleValue(amount * r.scale, deployable * r.scale);
            }
        }
        uint256 value = amount * r.scale;
        $.writeAsset(r, r.units - amount, r.cap, r.recognizedCapLoss, r.frozenRedeem);
        $.deployed[facilityId] += value;
        $.totalDeployedPrincipal += value;
        IERC20(asset).safeTransfer(to, amount);
        emit IReserveManager.PrincipalDeployed(facilityId, asset, amount, value);
    }

    /// @notice Books an accrued fee as deployed principal without moving a token.
    /// @dev NO CASH MOVES AND NONE MAY. The fee is already owed by the borrower, so it is added to
    ///      the receivable and the idle tally is untouched; a version of this that debited idle
    ///      would be paying the fee out of holders' cash. The idle-value check is therefore a
    ///      SOLVENCY bound rather than a funding one - it refuses to capitalise more than the
    ///      reserve could have deployed in the first place.
    ///
    ///      EXACTNESS ON THE ASSET'S OWN GRID. A value that is not a whole multiple of the asset's
    ///      scale is refused rather than rounded, because a fee that cannot be expressed in the
    ///      currency the facility is denominated in is a mis-specified fee.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility.
    /// @param asset The facility's asset.
    /// @param amount 18-decimal value to capitalise.
    function capitalizeFee(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        uint256 amount
    ) public {
        ReserveAccrualCreditLib.requireUnregisteredFunding(facilityId);
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        ReserveStorageLib.ReserveAsset storage r = $.requireListed(asset);
        bindFacilityAsset($, facilityId, asset, true);
        uint256 scale = r.scale;
        if ((amount / scale) * scale != amount) revert IReserveManager.ReserveManager_ValueNotExact(asset, amount);
        uint256 idleValue = ReserveStorageLib.idleAfterCustodyLoss(r) * scale;
        if (amount > idleValue) revert IReserveManager.ReserveManager_InsufficientIdleValue(amount, idleValue);
        $.deployed[facilityId] += amount;
        $.totalDeployedPrincipal += amount;
        emit IReserveManager.FeeCapitalized(facilityId, asset, amount);
    }

    /// @notice Capitalises contractually accrued PIK interest into a facility's deployed principal.
    /// @dev THE TWIN OF `capitalizeFee`, AND THE DIFFERENCE IS THE WHOLE OF THE RISK. `capitalizeFee`
    ///      is sound because the fee's cash NEVER LEFT: `fund` deploys `principal - fee`, so backing
    ///      rises against RETAINED CASH. There is no retained cash behind a PIK capitalisation. What
    ///      stands behind it is the borrower's contractual obligation to repay a larger balance, and
    ///      beneath that the curator first-loss layer. That substitution is a Forest Road decision
    ///      recorded in `docs/SPEC_INTEREST_ACCRUAL.md`, not an engineering one.
    ///
    ///      CONSEQUENTLY THERE IS NO IDLE-VALUE CHECK HERE, and its absence is deliberate rather
    ///      than an omission. `capitalizeFee` bounds the booking by `r.units * scale` because the
    ///      cash it books against is sitting in idle custody. A PIK capitalisation books against a
    ///      receivable, so an idle bound would be meaningless: it would refuse a legitimate
    ///      capitalisation on a facility whose asset happens to be drawn down, and admit one on a
    ///      facility whose asset happens to be flush.
    ///
    ///      THE CALLER CARRIES THE BOUNDS. `WaterfallEngine.capitalizePik` is the only caller and it
    ///      enforces the rate, the day count, the performing state, the 3x per-facility ceiling, the
    ///      concentration re-check through `CollateralRegistry.recordExposureIncrease`, and the
    ///      matching mint that keeps the act surplus-neutral. This function is the ledger write and
    ///      nothing else. Do not call it from anywhere that does not carry all six.
    ///
    ///      `allowBind` IS FALSE. A facility must already be bound to its asset, which means it must
    ///      already have been funded. There is no PIK on an unfunded facility.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility.
    /// @param asset The facility's bound asset.
    /// @param amount 18-decimal value to capitalise, already rounded to the asset's scale grid.
    function capitalizePik(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        uint256 amount
    ) public {
        ReserveAccrualCreditLib.requireLegacy(facilityId);
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        ReserveStorageLib.ReserveAsset storage r = $.requireListed(asset);
        bindFacilityAsset($, facilityId, asset, false);
        uint256 scale = r.scale;
        if ((amount / scale) * scale != amount) revert IReserveManager.ReserveManager_ValueNotExact(asset, amount);
        $.deployed[facilityId] += amount;
        $.totalDeployedPrincipal += amount;
        emit IReserveManager.PikCapitalized(facilityId, asset, amount, $.deployed[facilityId]);
    }

    /// @notice Takes a borrower's payment into custody and reduces the receivable by its principal
    ///         leg.
    /// @dev THE CAP IS NOT ENFORCED ON A REPAYMENT, deliberately. Refusing a borrower's cash because
    ///      an exposure ceiling is full would brick the credit layer for a limit that exists to bound
    ///      VOLUNTARY MINT-SIDE exposure, and a repayment is not that door.
    ///
    ///      SINCE 2026-09-08 THE OVER-CAP UNITS ARE ALSO RECOGNISED IN FULL. This comment used to
    ///      end "over-cap units are simply not recognised: the capped contribution clamps them", and
    ///      that clamp was a defect - a fully repaid, fully solvent facility left the protocol
    ///      reporting itself under-backed by the repaid principal with every loss ledger at zero. On
    ///      Forest Road direction `ReserveStorageLib.contribution` no longer clamps, so cash that
    ///      arrives here reaches backing whatever the ceiling says. Governance can still mark the
    ///      asset down, through `recognizedCapLoss`, which is an explicit written act.
    ///
    ///      THE RECEIPT IS MEASURED. `pullExact` requires the balance delta to equal the requested
    ///      amount exactly, so a fee-on-transfer or skimming token cannot credit a facility with
    ///      value that did not arrive.
    ///
    ///      THE PRINCIPAL LEG IS BOUNDED TWICE: by the payment actually received, and by the
    ///      facility's outstanding face. Anything above the principal leg is interest, which stays
    ///      in custody and is distributed by the waterfall rather than reducing the receivable.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility being repaid.
    /// @param asset The facility's bound asset.
    /// @param payer The address the cash is pulled from.
    /// @param amount Native units to pull.
    /// @param principal 18-decimal principal portion of the payment.
    /// @return receivedValue 18-decimal value of what actually arrived.
    function pay(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        address payer,
        uint256 amount,
        uint256 principal
    ) public returns (uint256 receivedValue) {
        ReserveAccrualCreditLib.requireLegacy(facilityId);
        receivedValue = _pay($, facilityId, asset, payer, amount, principal);
        emit IReserveManager.PaymentReceived(facilityId, asset, payer, amount, principal);
    }

    /// @notice Converts both components of an existing continuous claim to measured cash, without new yield.
    function payAccrued(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        address payer,
        uint256 amount,
        uint256 principalReduction,
        uint256 interestReduction
    ) public returns (uint256 receivedValue) {
        receivedValue = _pay($, facilityId, asset, payer, amount, principalReduction + interestReduction);
        emit AccruedPaymentReceived(facilityId, asset, payer, amount, principalReduction, interestReduction);
    }

    /// @dev Shared measured custody/face body. Callers emit their distinct, correctly labelled receipt event.
    function _pay(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        address asset,
        address payer,
        uint256 amount,
        uint256 principal
    ) private returns (uint256 receivedValue) {
        if (payer == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        ReserveStorageLib.ReserveAsset storage r = $.requireListed(asset);
        bindFacilityAsset($, facilityId, asset, false);
        uint256 received = ReserveStorageLib.pullExact(asset, payer, amount);
        receivedValue = received * r.scale;
        if (principal > receivedValue) {
            revert IReserveManager.ReserveManager_PrincipalExceedsPayment(principal, receivedValue);
        }
        uint256 deployed = $.deployed[facilityId];
        if (principal > deployed) {
            revert IReserveManager.ReserveManager_InsufficientDeployedPrincipal(facilityId, principal, deployed);
        }
        $.writeAsset(r, r.units + received, r.cap, r.recognizedCapLoss, r.frozenRedeem);
        if (principal != 0) {
            uint256 remainingFace = deployed - principal;
            $.deployed[facilityId] = remainingFace;
            $.totalDeployedPrincipal -= principal;
            ReserveCascadeLib.clampImpairment($, facilityId, remainingFace);
        }
    }
}
