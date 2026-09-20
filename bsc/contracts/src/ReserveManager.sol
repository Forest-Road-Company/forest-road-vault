// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IContinuousAccrual} from "./interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "./interfaces/IAccrualLifecycle.sol";
import {ReserveAccrualCreditLib} from "./libraries/ReserveAccrualCreditLib.sol";
import {ReserveAccrualStorageLib} from "./libraries/ReserveAccrualStorageLib.sol";
import {ReserveMigrationLib} from "./libraries/ReserveMigrationLib.sol";
import {IAccrualMigration} from "./interfaces/IAccrualMigration.sol";
import {ReserveAccrualLib} from "./libraries/ReserveAccrualLib.sol";
import {LossEventIds} from "./libraries/LossEventIds.sol";
import {ReserveArmLib} from "./libraries/ReserveArmLib.sol";
import {ReserveBasketLib} from "./libraries/ReserveBasketLib.sol";
import {ReserveCreditLib} from "./libraries/ReserveCreditLib.sol";
import {ReserveCascadeLib} from "./libraries/ReserveCascadeLib.sol";
import {ReserveStorageLib} from "./libraries/ReserveStorageLib.sol";
import {ReserveWiringLib} from "./libraries/ReserveWiringLib.sol";
import {ReserveViewsLib} from "./libraries/ReserveViewsLib.sol";
import {ReserveAccrualServiceLib} from "./libraries/ReserveAccrualServiceLib.sol";
import {ReserveRoundingLib} from "./libraries/ReserveRoundingLib.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ReserveManager - BSC instance, multi-asset reserve
/// @notice Custodies a governed registry of reserve stablecoins and records conservatively marked
///         deployed principal. A redeemer is paid their OWN recorded assets first, capped by what
///         they themselves deposited, and the pro-rata basket in kind for everything beyond it.
/// @dev THE THREE RULES THIS CONTRACT IS ORGANISED AROUND.
///
///      1. THE SOLVENCY PATH READS STORAGE ONLY. `totalBackingValue` performs no `decimals()`, no
///         `balanceOf` and no oracle call, and stays O(1) across n assets through two aggregate
///         caches whose sole writer is `ReserveStorageLib.writeAsset`. External reads live at the
///         deposit and release EDGES, where a failure is local to one asset.
///
///      2. BACKING MOVES DOWN ON AUTHORITY AND UP ONLY ON PROOF. A tally rises in exactly five
///         places and every one is a MEASURED RECEIPT: `depositAsset`, `recordPayment`,
///         `recapitalize` (balance deltas), `cureCustodyShortfall` (measured surplus, ceilinged by
///         the latch it cures) and `creditRecoveredIdleUnits` (measured surplus, ceilinged by the
///         arm's ratified write-down). There is no setter that raises a tally, and none may be
///         added: it would let an admin assert backing that is not there and therefore mint
///         unbacked USDfr. That matters more here than on Ethereum, because with no Governor the
///         whole governance root sits on one Safe. ADR-0038 ADDS NO SETTER EITHER: there is no
///         `setAssetPrice`, for the same reason and one step earlier, because a price setter is an
///         authority path to a higher CREDIT per deposited unit. A price enters storage only
///         through `syncAssetPrice`, whose input is an m-of-n signed record.
///
///      4. THE SOLVENCY PATH READS NO PRICE. The reserve now stores one, at the mint EDGE only.
///         `totalBackingValue` is par-valued and storage-only exactly as before, and no function
///         that reads a `ReserveAsset` reads a price: the price lives in a sibling mapping so that
///         is a structural fact rather than a convention.
///
///      3. A REVERTING, PAUSED OR FROZEN ASSET MUST NEVER FREEZE A PAYOUT IN A DIFFERENT ASSET.
///         Custody observation is per asset and permissionless, so a token that reverts produces no
///         latch and freezes nothing. A basket leg that cannot be delivered degrades to a deferred
///         leg for that asset alone, and a recorded draw the tally cannot fund degrades to a
///         pending claim on that asset alone. The one deliberately GLOBAL gate is
///         `ReserveStorageLib.requireCustodied`, and it is a LOSS predicate, not a token-liveness
///         predicate: nobody exits at par while an adjudicated loss is unallocated.
///
///      Unexpected direct transfers are donations and do not increase reported backing, except when
///      governance attributes a measured surplus to a previously written-down custody incident
///      under that arm's immutable recovery ceiling.
contract ReserveManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IReserveManager
{
    using SafeERC20 for IERC20;
    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;

    /// @dev Keeps all native ledger/wiring mutations outside an accrual callback window.
    modifier accrualIdle() {
        _requireNativeIdle();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the reserve's roles. It lists no asset.
    /// @dev There is deliberately NO asset argument. Genesis assets are listed by
    ///      `addReserveAsset` in the same deployment transaction, so admission has exactly one code
    ///      path and the post-deploy validator asserts one set of events. An `initialize` that
    ///      lists an asset and an `addReserveAsset` that lists an asset are two admission paths,
    ///      and a second path is where a mis-recorded asset enters.
    /// @param admin Holder of DEFAULT_ADMIN_ROLE; the governance timelock in production.
    /// @param reserveAdmin Holder of RESERVE_ADMIN_ROLE; the governance timelock in production.
    /// @param guardian Holder of GUARDIAN_ROLE.
    /// @param upgrader Holder of UPGRADER_ROLE.
    function initialize(address admin, address reserveAdmin, address guardian, address upgrader)
        external
        accrualIdle
        initializer
    {
        if (admin == address(0) || reserveAdmin == address(0) || guardian == address(0) || upgrader == address(0)) {
            revert ReserveManager_ZeroAddress();
        }
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.RESERVE_ADMIN_ROLE, reserveAdmin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        ReserveStorageLib.layout().guardianReserveLossArmsEnabled = true;
    }

    // ------------------------------- registry ------------------------------

    /// @inheritdoc IReserveManager
    function addReserveAsset(
        address asset,
        uint8 expectedDecimals,
        uint256 cap,
        uint16 mintFeeBps,
        bytes32 admissionEvidenceHash
    ) external accrualIdle onlyRole(Roles.RESERVE_ADMIN_ROLE) {
        ReserveWiringLib.addAsset(asset, expectedDecimals, cap, mintFeeBps, admissionEvidenceHash);
    }

    /// @inheritdoc IReserveManager
    function setReserveAssetCap(address asset, uint256 newCap, uint256 approvedMaxLoss, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(Roles.RESERVE_ADMIN_ROLE)
    {
        ReserveWiringLib.setCap(asset, newCap, approvedMaxLoss, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function setReserveAssetMintFee(address asset, uint16 mintFeeBps)
        external
        accrualIdle
        onlyRole(Roles.RESERVE_ADMIN_ROLE)
    {
        ReserveWiringLib.setMintFee(asset, mintFeeBps);
    }

    /// @inheritdoc IReserveManager
    /// @dev Guardian freezes DOWN, instantly. The lift is a separate, timelocked entry point.
    function freezeReserveAsset(address asset, bool mint, bool redeem)
        external
        accrualIdle
        onlyRole(Roles.GUARDIAN_ROLE)
    {
        ReserveWiringLib.setFreeze(asset, mint, redeem, true);
    }

    /// @inheritdoc IReserveManager
    function unfreezeReserveAsset(address asset, bool mint, bool redeem)
        external
        accrualIdle
        onlyRole(Roles.RESERVE_ADMIN_ROLE)
    {
        ReserveWiringLib.setFreeze(asset, mint, redeem, false);
    }

    // ------------------------------- custody -------------------------------

    /// @inheritdoc IReserveManager
    /// @dev Fee-on-transfer is closed at source: the credited amount is a measured balance delta
    ///      and must equal the requested amount exactly. The cap is enforced HERE, on the credited
    ///      value, because this is the voluntary mint-side door the ceiling exists to bound.
    function depositAsset(address asset, address from, uint256 amount)
        external
        accrualIdle
        nonReentrant
        whenNotPaused
        returns (uint256 credited)
    {
        return _deposit(asset, from, address(0), amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev ADR-0038 / Forest Road direction 2026-09-07. Identical to `depositAsset` in every
    ///      custody check, plus one write: `holder`'s deposit record grows by the units that
    ///      actually arrived. `holder` is a SEPARATE PARAMETER from `from` because on the mint path
    ///      they differ - the controller is `from`, the minter is `holder` - and crediting the
    ///      record to `from` there would credit every mint to the controller and leave real
    ///      depositors with no record at all.
    function depositAssetFor(address asset, address from, address holder, uint256 amount)
        external
        accrualIdle
        nonReentrant
        whenNotPaused
        returns (uint256 credited)
    {
        if (holder == address(0)) revert ReserveManager_ZeroAddress();
        return _deposit(asset, from, holder, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev THERE IS STILL NO `releaseAsset(asset, to, amount)` AND NONE MAY BE ADDED - the warning
    ///      is rewritten rather than deleted (Forest Road direction 2026-09-07). Handing a holder
    ///      the free choice of leg reopens the free option this design exists to close.
    ///      `releaseRecorded` is not that function: it pays a holder only the assets that holder
    ///      themselves deposited, capped by their own record, and the cap is what closes the option.
    function releaseBasket(address to, uint256 usdfrValue)
        external
        accrualIdle
        onlyRole(Roles.CONTROLLER_ROLE)
        returns (address[] memory, uint256[] memory, uint256)
    {
        _returnBasketResult(_releaseBasketResult(to, usdfrValue, false));
    }

    /// @inheritdoc IReserveManager
    /// @dev THE RECORD CAP IS THE SECURITY PROPERTY. See `ReserveBasketLib.releaseRecorded` for the
    ///      three passes and why the unfunded residue becomes a claim on the same asset rather than
    ///      a basket payment.
    function releaseRecorded(address to, uint256 usdfrValue)
        external
        accrualIdle
        onlyRole(Roles.CONTROLLER_ROLE)
        returns (address[] memory, uint256[] memory, uint256)
    {
        _returnBasketResult(_releaseBasketResult(to, usdfrValue, true));
    }

    /// @inheritdoc IReserveManager
    /// @dev Deliberately NOT `whenNotPaused`, for the same reason `claimDeferredLeg` is not: the
    ///      claim's value left backing when the claim was written, so these units are already the
    ///      holder's property in the ledger and a pause must not strand them.
    function claimPendingUnits(address asset) external accrualIdle nonReentrant returns (uint256 amount) {
        return ReserveBasketLib.claimPending(ReserveStorageLib.layout(), msg.sender, asset);
    }

    /// @inheritdoc IReserveManager
    /// @dev Deliberately NOT `whenNotPaused`. The tally was already debited when the leg was
    ///      allocated, so these units are the holder's property sitting in escrow, not protocol
    ///      backing. A pause must not be able to strand them.
    function claimDeferredLeg(address asset) external accrualIdle nonReentrant returns (uint256 amount) {
        return ReserveBasketLib.claimLeg(ReserveStorageLib.layout(), msg.sender, asset);
    }

    /// @inheritdoc IReserveManager
    /// @dev PERMISSIONLESS custody observation at the selected asset boundary. A
    ///      token that reverts, is paused, or gas-bombs makes only its own call fail: it produces
    ///      no latch and therefore freezes nothing - not backing, not mint, not the cascade, not
    ///      the interlock, not another asset's leg. That removes the brick class as a class.
    ///
    ///      Deferred legs count as OWED, not as surplus. Without that subtraction an undelivered
    ///      holder claim would read as protocol surplus and could be credited as backing.
    function reconcileIdleUnits(address asset) external accrualIdle nonReentrant returns (uint256 shortfall) {
        return ReserveWiringLib.reconcileIdleUnits(asset);
    }

    /// @inheritdoc IReserveManager
    /// @dev PERMISSIONLESS and UP ONLY ON PROOF: the ceiling is the latch itself, the amount is a
    ///      measured surplus, and no caller asserts anything. This restores the reversibility a
    ///      purely observational predicate had - returning the missing units clears the condition -
    ///      without granting anyone authority. It may NOT touch a ratified loss: once
    ///      `ratifyAndOpen` has moved the latch into an arm's recovery ceiling the latch is zero,
    ///      and recovery goes exclusively through the arm-bound `creditRecoveredIdleUnits`.
    function cureCustodyShortfall(address asset) external accrualIdle nonReentrant returns (uint256 credited) {
        return ReserveWiringLib.cureCustodyShortfall(asset);
    }

    /// @inheritdoc IReserveManager
    /// @dev THE CEILING IS ENFORCED HERE, and it has to be. This comment used to read "cure of a
    ///      ceiling is not enforced here... over-cap units are simply not recognised until the cap
    ///      is raised or the tally falls", and that second sentence was the ONLY bound on this
    ///      function. It was true only because `ReserveStorageLib.contribution` clamped to the cap.
    ///      When the clamp was removed on 2026-09-08 the sentence silently became false and left
    ///      this - a function with NO role, NO pause gate and NO compliance gate - able to create
    ///      unbounded par-valued backing from any listed token, including one governance had closed
    ///      at cap zero and fully marked down.
    ///
    ///      THE CONSEQUENCE WAS A LOSS-CASCADE BYPASS, which is a CLAUDE.md section 1.3 invariant.
    ///      `ReserveCascadeLib._recognize` absorbs a ratified loss out of `backing - supply` surplus
    ///      before it reaches the cascade, so a donated phantom surplus made the next custody loss
    ///      vanish: no curator first-loss draw, no backstop, no senior burn. Reproduced in both
    ///      directions and regressed by `test_FIXED_recapitalizeCannotCreateUnboundedBacking`.
    ///
    ///      GATING IT IS FAITHFUL TO THE DIRECTION THAT REMOVED THE CLAMP: "the cap should only be
    ///      relevant to deposits". A voluntary, permissionless donation IS the deposit door - it is
    ///      inbound value someone chose to send. `recordPayment` is not, and stays ungated, because
    ///      refusing a borrower's contractual repayment for an exposure ceiling would brick the
    ///      credit layer. The cure this function exists for is still available: raise the cap, which
    ///      restores no backing by itself, then recapitalize.
    function recapitalize(address asset, uint256 amount) external accrualIdle nonReentrant returns (uint256 credited) {
        return ReserveWiringLib.recapitalize(asset, amount);
    }

    // ---------------------------- custody arms -----------------------------

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveArmLib.arm`; this method keeps the role check, the guard and the pause.
    ///      The arm state machine moved out whole for EIP-170 and its reasoning went with it.
    function armReserveLossFreeze(address asset, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(Roles.GUARDIAN_ROLE)
        returns (uint256 armId, uint256 incidentId)
    {
        return ReserveArmLib.arm(ReserveStorageLib.layout(), asset, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveArmLib.cancel`. Only an UNRATIFIED arm may be cancelled, and only while
    ///      no loss condition is live; the interlock check is stated there.
    function cancelAndDisable(address asset, uint256 expectedArmId, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveArmLib.cancel(ReserveStorageLib.layout(), asset, expectedArmId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function cancelUnratifiedArm(address asset, uint256 expectedArmId, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveArmLib.cancelUnratified(ReserveStorageLib.layout(), asset, expectedArmId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveArmLib.ratify`. Refreshes the selected asset before reading its loss
    ///      latch and enforcing the approved ceiling. Further tranches retain the same arm.
    function ratifyAndOpen(address asset, uint256 expectedArmId, bytes32 evidenceHash, uint256 approvedMaxLoss)
        external
        accrualIdle
        nonReentrant
        returns (uint256 incidentId, uint256 actualLoss)
    {
        _requireReserveLossAdmin();
        ReserveAccrualLib.prepareNativeLoss();
        return ReserveArmLib.ratify(ReserveStorageLib.layout(), asset, expectedArmId, evidenceHash, approvedMaxLoss);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveArmLib.creditRecovered`. The asset is read from the arm record and the
    ///      credit is bounded by tokens actually held; see that function.
    function creditRecoveredIdleUnits(uint256 armId, bytes32 evidenceHash)
        external
        accrualIdle
        nonReentrant
        returns (uint256 credited)
    {
        _requireReserveLossAdmin();
        return ReserveArmLib.creditRecovered(ReserveStorageLib.layout(), armId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveArmLib.finalize`. It cannot close over a live shortfall or uncredited
    ///      returned units, and it disables guardian arms globally; both are argued there.
    function finalizeAndDisable(address asset, uint256 expectedArmId, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveArmLib.finalize(ReserveStorageLib.layout(), asset, expectedArmId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function setGuardianReserveLossArmsEnabled(bool enabled) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorageLib.layout().guardianReserveLossArmsEnabled = enabled;
        emit GuardianReserveLossArmsEnabled(enabled);
    }

    /// @inheritdoc IReserveManager
    function resolveReserveDeficit(bytes32 evidenceHash) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveCascadeLib.resolveDeficit(ReserveStorageLib.layout(), evidenceHash);
    }

    // ----------------------------- credit path -----------------------------

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveCreditLib.deploy`. The facility's asset is bound on its first
    ///      credit-side act, the cap does NOT gate a deployment, and deployed principal stays a
    ///      single 18-decimal aggregate; all three are argued there.
    function recordDeployment(uint256 facilityId, address asset, address to, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
    {
        ReserveCreditLib.deploy(ReserveStorageLib.layout(), facilityId, asset, to, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveCreditLib.capitalizePik`. No cash moves and, unlike the fee twin, no
    ///      cash was retained either: what stands behind it is the borrower's obligation and the
    ///      curator first-loss beneath it. Every bound lives in `WaterfallEngine.capitalizePik`.
    function recordPikCapitalization(uint256 facilityId, address asset, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        whenNotPaused
    {
        ReserveCreditLib.capitalizePik(ReserveStorageLib.layout(), facilityId, asset, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveCreditLib.capitalizeFee`. No cash moves: the fee joins the receivable
    ///      and the idle tally is untouched.
    function recordFeeCapitalization(uint256 facilityId, address asset, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        whenNotPaused
    {
        ReserveCreditLib.capitalizeFee(ReserveStorageLib.layout(), facilityId, asset, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev BODY IN `ReserveCreditLib.pay`. THE CAP IS NOT ENFORCED ON A REPAYMENT, deliberately:
    ///      refusing a borrower's cash because an exposure ceiling is full would brick the credit
    ///      layer for a limit that exists to bound VOLUNTARY MINT-SIDE exposure. Over-cap units are
    ///      RECOGNISED IN FULL since 2026-09-08; the receipt is measured by `pullExact`. Both are
    ///      argued there.
    function recordPayment(uint256 facilityId, address asset, address payer, uint256 amount, uint256 principal)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 receivedValue)
    {
        return ReserveCreditLib.pay(ReserveStorageLib.layout(), facilityId, asset, payer, amount, principal);
    }

    /// @inheritdoc IReserveManager
    function recordPrincipalWritedown(uint256 facilityId, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
    {
        if (ReserveAccrualStorageLib.state().enabled) ReserveAccrualCreditLib.writeDown(facilityId, amount);
        ReserveCascadeLib.writeDownPrincipal(ReserveStorageLib.layout(), facilityId, amount);
    }

    /// @inheritdoc IReserveManager
    function recognizePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ReserveAccrualStorageLib.state().enabled) ReserveAccrualCreditLib.post(facilityId);
        ReserveCascadeLib.recognizeImpairment(ReserveStorageLib.layout(), facilityId, amount, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function releasePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveCascadeLib.releaseImpairment(ReserveStorageLib.layout(), facilityId, amount, evidenceHash);
    }

    // ------------------------------- wiring --------------------------------

    /// @inheritdoc IReserveManager
    /// @dev PERMISSIONLESS. The signatures are the authority; the relayer has none. The oracle read
    ///      is the ONE external read on the price path and it is at the edge, so an unreachable or
    ///      reverting oracle makes only this call fail.
    ///
    ///      THERE IS DELIBERATELY NO `setAssetPrice(asset, price)`, AND NONE MAY BE ADDED. This
    ///      contract already says of the tally that "there is no setter that raises a tally, and
    ///      none may be added: it would let an admin assert backing that is not there". The same
    ///      sentence governs the price, for the same reason and one step earlier: a direct price
    ///      setter is an authority path to a HIGHER CREDIT, letting a key holder mint more USDfr per
    ///      deposited unit than any attester quorum signed for. Governance sets the GUARDS
    ///      (`maxAge`, `maxDeviationBps`, the per-asset floor) and every one of those moves the
    ///      credit DOWN or CLOSED, never up.
    function syncAssetPrice(address asset) external accrualIdle nonReentrant {
        ReserveWiringLib.syncAssetPrice(asset);
    }

    /// @inheritdoc IReserveManager
    function setReservePriceGuards(address oracle, uint64 maxAge, uint16 maxDeviationBps)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveWiringLib.setPriceGuards(oracle, maxAge, maxDeviationBps);
    }

    /// @inheritdoc IReserveManager
    function setReserveAssetPriceFloor(address asset, uint256 floor)
        external
        accrualIdle
        onlyRole(Roles.RESERVE_ADMIN_ROLE)
    {
        ReserveWiringLib.setAssetPriceFloor(asset, floor);
    }

    /// @inheritdoc IReserveManager
    function setLossController(address controller_) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveWiringLib.bindController(controller_);
    }

    /// @inheritdoc IReserveManager
    function setLossAbsorber(address absorber) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveWiringLib.bindAbsorber(absorber);
    }

    /// @inheritdoc IReserveManager
    function setReserveLossModules(address curator, address vault, address timelock)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveWiringLib.bindModules(curator, vault, timelock);
    }

    // --------------------------- prepayment ledger -------------------------

    /// @inheritdoc IReserveManager
    function recordExitPrepayment(uint256 amount) external accrualIdle {
        ReserveCascadeLib.recordExitPrepayment(amount);
    }

    /// @inheritdoc IReserveManager
    function consumeExitPrepayment(uint256 facilityId, uint256 loss) external accrualIdle returns (uint256 used) {
        return ReserveCascadeLib.consumeExitPrepayment(facilityId, loss);
    }

    // --------------------------------- pause -------------------------------

    /// @notice Pauses routine reserve deposits, releases, deployments, and payments.
    function pause() external accrualIdle onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Resumes routine reserve deposits, releases, deployments, and payments.
    function unpause() external accrualIdle onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // --------------------------------- views -------------------------------

    /// @inheritdoc IReserveManager
    function reserveAssets() external view returns (address[] memory) {
        _returnEncodedView(ReserveViewsLib.assetsData());
    }

    /// @inheritdoc IReserveManager
    function assetCount() external view returns (uint256) {
        return ReserveStorageLib.layout().assetList.length;
    }

    /// @inheritdoc IReserveManager
    function isListed(address asset) external view returns (bool) {
        return ReserveStorageLib.layout().assets[asset].listed;
    }

    /// @inheritdoc IReserveManager
    function assetRecord(address asset) external view returns (ReserveAssetView memory) {
        _returnEncodedView(ReserveViewsLib.assetRecord(asset));
    }

    /// @inheritdoc IReserveManager
    function assetRecords() external view returns (ReserveAssetView[] memory) {
        _returnEncodedView(ReserveViewsLib.assetRecords());
    }

    /// @inheritdoc IReserveManager
    /// @dev STORAGE ONLY, and it never reverts for a listed asset however broken that token is.
    function payableValueOf(address asset) external view returns (uint256) {
        return ReserveViewsLib.payableValue(asset);
    }

    /// @inheritdoc IReserveManager
    function assetAdjudicationPending(address asset) external view returns (bool) {
        return ReserveViewsLib.adjudicationPending(asset);
    }

    /// @inheritdoc IReserveManager
    function deferredLegOf(address holder, address asset) external view returns (uint256) {
        return ReserveStorageLib.layout().deferredLegs[holder][asset];
    }

    /// @inheritdoc IReserveManager
    function recordOf(address holder, address asset) external view returns (uint256, uint256, uint256, uint256) {
        _returnEncodedView(ReserveViewsLib.recordData(holder, asset));
    }

    /// @inheritdoc IReserveManager
    /// @dev STORAGE ONLY, and it never reverts for a listed asset. Published through its OWN view
    ///      rather than folded into `ReserveAssetView`, because that struct is decoded positionally
    ///      by the controller's basket path - and, more importantly, because NO FUNCTION THAT READS
    ///      A `ReserveAsset` MAY EVER READ A PRICE.
    ///
    ///      IT RETURNS RATHER THAN REVERTS, deliberately: the reserve publishes ONE predicate and
    ///      the controller raises the decoded error the user sees, so there is one enumeration of
    ///      liveness and the refusal is decoded in the contract the caller is talking to.
    function mintPriceQuote(address asset) external view returns (uint256, bool, uint8, uint256, uint64, uint256) {
        _returnEncodedView(ReserveViewsLib.mintPriceQuote(asset));
    }

    /// @inheritdoc IReserveManager
    function reservePriceGuards() external view returns (address oracle, uint64 maxAge, uint16 maxDeviationBps) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        return ($.priceOracle, $.priceMaxAge, $.priceMaxDeviationBps);
    }

    /// @inheritdoc IReserveManager
    /// @dev Operator and monitor surface only. NO protocol path consumes it, which is why keeping
    ///      the live read here is safe: a revert is the caller's problem and nobody else's.
    function observeIdleUnits(address asset) external view returns (uint256, uint256, uint256, uint256, uint256) {
        _returnEncodedView(ReserveViewsLib.observeIdleUnits(asset));
    }

    /// @inheritdoc IReserveManager
    /// @dev The deferred subtraction is load-bearing: without it an undelivered holder claim reads
    ///      as protocol surplus and could be credited as backing on a recovery ceiling.
    function unrecordedUnits(address asset) external view returns (uint256) {
        return ReserveViewsLib.unrecordedUnits(asset);
    }

    /// @inheritdoc IReserveManager
    function idleCustodyShortfall() public view returns (uint256) {
        return ReserveStorageLib.layout().totalCustodyShortfallValue;
    }

    /// @inheritdoc IReserveManager
    function idleCustodyShortfallOf(address asset) external view returns (uint256) {
        return ReserveViewsLib.custodyShortfall(asset);
    }

    /// @inheritdoc IReserveManager
    function recognizedBackingValue() external view returns (uint256) {
        return ReserveViewsLib.backing(true);
    }

    /// @inheritdoc IReserveManager
    /// @dev PAYABLE, not total: its one protocol consumer is the queue's epoch budget, which must
    ///      count only what a basket can actually pay. A redeem-frozen leg lowers LIQUIDITY and not
    ///      SOLVENCY, which is the truthful statement - the units exist, they are stuck.
    ///
    ///      ADR-0038: units already promised to a pending claim are subtracted, because a basket may
    ///      not allocate them. The subtraction is on the AGGREGATE while the cache already excludes
    ///      frozen legs, so a claim standing against a frozen asset is subtracted twice and this
    ///      figure UNDER-states liquidity. Under-stating a budget is the safe direction: the queue
    ///      schedules less than it could, rather than scheduling an epoch the release then refuses.
    function idleReserve() external view returns (uint256) {
        return ReserveViewsLib.idleReserve();
    }

    /// @inheritdoc IReserveManager
    function totalIdleValue() external view returns (uint256) {
        return ReserveStorageLib.layout().totalIdleBackingValue;
    }

    /// @inheritdoc IReserveManager
    function idleUnits(address asset) external view returns (uint256) {
        return ReserveStorageLib.layout().assets[asset].units;
    }

    /// @inheritdoc IReserveManager
    function unappliedCustodyLossOf(address asset) external view returns (uint256 units, uint256 pendingUnits) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        return ($.assets[asset].unappliedCustodyLossUnits, $.pendingUnappliedCustodyLossUnits[asset]);
    }

    /// @inheritdoc IReserveManager
    function totalUnappliedCustodyLossValue() external view returns (uint256) {
        return ReserveStorageLib.layout().totalUnappliedCustodyLossValue;
    }

    /// @inheritdoc IReserveManager
    function unappliedCustodyLossForArm(uint256 armId) external view returns (uint256) {
        return ReserveStorageLib.layout().armUnappliedCustodyLossUnits[armId];
    }

    /// @inheritdoc IReserveManager
    function deployedPrincipal() external view returns (uint256) {
        return ReserveViewsLib.deployed(0, true);
    }

    /// @inheritdoc IReserveManager
    function totalBackingValue() external view returns (uint256) {
        return ReserveViewsLib.backing(false);
    }

    /// @inheritdoc IReserveManager
    function totalPrincipalImpairment() external view returns (uint256) {
        return ReserveStorageLib.layout().totalPrincipalImpairment;
    }

    /// @inheritdoc IReserveManager
    function principalImpairmentOf(uint256 facilityId) external view returns (uint256) {
        return ReserveStorageLib.layout().principalImpairment[facilityId];
    }

    /// @inheritdoc IReserveManager
    function deployedTo(uint256 facilityId) external view returns (uint256) {
        return ReserveViewsLib.deployed(facilityId, false);
    }

    /// @notice Configures immutable counterparties before all modules bind and recognition starts.
    function configureContinuousAccrual(IContinuousAccrual.Modules calldata modules_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        // The static seven-address tuple is decoded once by the linked library.
        bytes calldata encoded;
        assembly ("memory-safe") {
            encoded.offset := modules_
            encoded.length := 224
        }
        ReserveAccrualLib.configureEncoded(encoded);
    }

    /// @notice Starts prospective recognition after compatible consumer bindings are verified.
    function enableContinuousAccrual() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ReserveAccrualLib.enable();
    }

    /// @notice Executes one governed opening-import preparation step.
    /// @dev The complete step encoding is defined by IAccrualMigration.
    function prepareContinuousAccrualMigration(bytes calldata step)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        ReserveMigrationLib.prepare(ReserveStorageLib.layout(), step);
    }

    /// @notice Constant-time status for the frozen roster; a partial book is never quoted here.
    function accrualMigration() external view returns (IAccrualMigration.Progress memory) {
        _returnEncodedView(ReserveMigrationLib.progressData());
    }

    /// @notice The bound waterfall synchronizes its fee rate and destination prospectively.
    function setAccrualFee(uint16 feeBps, address recipient) external nonReentrant {
        ReserveAccrualLib.setFee(feeBps, recipient);
    }

    /// @notice The cumulative part of proved sub-unit losses for which native capital was unavailable.
    function roundingLossUnabsorbed() external view returns (uint256) {
        return ReserveAccrualStorageLib.state().roundingUnabsorbed;
    }

    /// @notice Consumes only the controller's exact current rounding-burn continuation.
    /// @dev Deliberately inside the outer reserve guard; the library authenticates its single caller.
    function consumeAccrualLossBurn(address caller, address from, uint256 amount) external returns (bool) {
        return ReserveRoundingLib.consumeBurn(caller, from, amount);
    }

    /// @notice Module identities for this independently backed reserve instance.
    function accrualModules() external view returns (IContinuousAccrual.Modules memory) {
        _returnEncodedView(ReserveAccrualLib.modulesData());
    }

    /// @notice Constant-time effective recognition and outstanding posting/issuance claims.
    function accrualSnapshot() external view returns (IContinuousAccrual.Snapshot memory) {
        _returnEncodedView(ReserveAccrualLib.snapshotData());
    }

    /// @notice Current exact delivery permit and coherent accounting prices, or inactive zeros.
    function accrualDelivery() external view returns (IContinuousAccrual.Delivery memory) {
        _returnEncodedView(ReserveAccrualLib.deliveryData());
    }

    /// @notice Authoritative admission gate for every price-sensitive consumer.
    function requireAccrualFresh() external view {
        ReserveAccrualLib.requireFresh();
    }

    /// @notice Converts selected accrued senior/fee claims into physical USDfr, including while paused.
    function materializeAccrued(uint8 legs) external nonReentrant returns (uint256 senior, uint256 fee) {
        return ReserveAccrualLib.materialize(legs);
    }

    /// @notice Clock-independent callback admission used by bound accounting consumers.
    function requireAccrualIdle() external view {
        // Consumer continuations check the accrual window independently of the host guard.
        ReserveAccrualLib.requireNativeIdle(false);
    }

    /// @notice Unposted earned exposure by total, class, borrower or state; reads no facility list.
    function accrualExposure(uint8 kind, bytes32 identity) external view returns (uint256) {
        return ReserveAccrualCreditLib.exposure(kind, identity);
    }

    /// @notice Additional maximum future face already reserved by funded contractual schedules.
    function accrualReservedExposure() external view returns (uint256) {
        return ReserveAccrualCreditLib.reservedExposure();
    }

    /// @notice The bound waterfall registers its authenticated just-funded facility.
    function registerAccruingLoan(uint256 facilityId) external nonReentrant {
        ReserveAccrualCreditLib.register(facilityId);
    }

    /// @notice Permissionless chronological maintenance; at most 32 due events per transaction.
    function checkpointAccrual(uint256 maximum) external nonReentrant returns (uint256 processed, bool fresh) {
        return ReserveAccrualCreditLib.checkpoint(maximum);
    }

    /// @notice Advances only zero-work contractual PIK dates in constant time.
    function serviceAccruedLoan(uint256 facilityId) external nonReentrant returns (uint256 capitalized) {
        return ReserveAccrualServiceLib.service(facilityId);
    }

    /// @notice Discloses whether a known facility has a positive queued accrual segment.
    function accrualLoanScheduled(uint256 facilityId) external view returns (bool) {
        return ReserveAccrualServiceLib.scheduled(facilityId);
    }

    /// @notice Posts a single existing virtual receivable before a native impairment or lifecycle act.
    function postAccruedLoan(uint256 facilityId) external nonReentrant returns (uint256 amount) {
        return ReserveAccrualCreditLib.post(facilityId);
    }

    /// @notice The bound waterfall delivers an exact attested repayment of an existing streamed claim.
    function repayAccruingLoan(uint256 facilityId, address payer, uint256 principal, uint256 interest)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 outstanding)
    {
        return ReserveAccrualCreditLib.repay(facilityId, payer, principal, interest);
    }

    /// @notice Releases the finite active-book slot after full repayment/loss and all native risk hooks.
    function retireAccruedLoan(uint256 facilityId) external nonReentrant {
        ReserveAccrualCreditLib.retire(facilityId);
    }

    /// @notice The bridge forwards a consumed signed amendment, effective only from this block.
    function amendAccruingLoan(uint256 facilityId, IAccrualLifecycle.Terms calldata terms) external nonReentrant {
        ReserveAccrualCreditLib.amend(facilityId, terms);
    }

    /// @notice The bound default manager closes the full earned claim before declaring default.
    function stopAccruingLoan(uint256 facilityId) external nonReentrant {
        ReserveAccrualCreditLib.stop(facilityId);
    }

    /// @notice The default manager controls growing past-due cohort membership.
    function setAccrualPastDue(uint256 facilityId, bool marked) external nonReentrant {
        ReserveAccrualCreditLib.setPastDue(facilityId, marked);
    }

    /// @notice Canonical debt disclosure; reserve backing continues to use its streamed carrier.
    function accruedDebt(uint256 facilityId) external view returns (IAccrualLifecycle.Debt memory) {
        _returnEncodedView(ReserveViewsLib.debt(facilityId));
    }

    /// @notice Unposted growth in the default manager's marked cohort of one class.
    function accruedPastDue(uint256 classId) external view returns (uint256 amount) {
        return ReserveAccrualCreditLib.pastDue(classId);
    }

    /// @notice Facility contribution to the reserve's virtual receivable carrier.
    function unpostedAccruedLoan(uint256 facilityId) external view returns (uint256 amount) {
        return ReserveViewsLib.unpostedLoan(facilityId);
    }

    /// @inheritdoc IReserveManager
    function facilityAssetOf(uint256 facilityId) external view returns (address) {
        return ReserveStorageLib.layout().facilityAsset[facilityId];
    }

    /// @inheritdoc IReserveManager
    /// @dev `view`, not `pure`: scale is per-asset STORAGE, never a constant. OVERFLOW BOUND: at
    ///      scale 1 there is no multiplication and the bound is vacuous; at scale 1e12 the
    ///      previously derived bound is unchanged. Re-derive per asset when a new scale is listed.
    function normalizeUnits(address asset, uint256 amount) external view returns (uint256) {
        return ReserveViewsLib.convertUnits(asset, amount, false);
    }

    /// @inheritdoc IReserveManager
    function denormalizeUnits(address asset, uint256 value) external view returns (uint256) {
        return ReserveViewsLib.convertUnits(asset, value, true);
    }

    /// @inheritdoc IReserveManager
    function lossAbsorber() external view returns (address) {
        return address(ReserveStorageLib.layout().lossAbsorber);
    }

    /// @inheritdoc IReserveManager
    function lossController() external view returns (address) {
        return address(ReserveStorageLib.layout().lossController);
    }

    /// @inheritdoc IReserveManager
    function reserveLossModules() external view returns (address curator, address vault, address timelock) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        return (address($.lossCurator), address($.lossVault), $.lossTimelock);
    }

    /// @inheritdoc IReserveManager
    function reserveDeficit() external view returns (uint256) {
        return ReserveStorageLib.layout().reserveDeficit;
    }

    /// @inheritdoc IReserveManager
    function recognizedReserveLoss()
        external
        view
        returns (uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired)
    {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        return ($.recognizedBackingReduction, $.recognizedSurplusAbsorbed, $.recognizedSupplyReduction);
    }

    /// @inheritdoc IReserveManager
    function reserveLossArm(address asset) external view returns (uint256, uint256, bytes32, ArmState, bool) {
        _returnEncodedView(ReserveViewsLib.armData(asset));
    }

    /// @inheritdoc IReserveManager
    function reserveLossRecoveryCapacity(uint256 armId) external view returns (uint256 nativeUnits) {
        return ReserveStorageLib.layout().arms[armId].recoveryCapacityUnits;
    }

    /// @inheritdoc IReserveManager
    function openArmCount() external view returns (uint256) {
        return ReserveStorageLib.layout().openArmCount;
    }

    /// @inheritdoc IReserveManager
    function reserveLossExitsLocked() external view returns (bool) {
        return ReserveViewsLib.exitsLocked();
    }

    /// @inheritdoc IReserveManager
    function curatorWithdrawalsLocked() external view returns (bool) {
        return ReserveViewsLib.exitsLocked();
    }

    /// @inheritdoc IReserveManager
    function custodyLossUnabsorbed() external view returns (bool) {
        return ReserveViewsLib.custodyLossUnabsorbed();
    }

    /// @inheritdoc IReserveManager
    function exitPrepaidAbsorption() external view returns (uint256) {
        return ReserveStorageLib.layout().exitPrepaidAbsorption;
    }

    // ---------------------------- internal helpers -------------------------

    /// @dev Both basket variants complete their guarded scope before the external result is
    ///      forwarded. In particular, the assembly return cannot skip the reentrancy cleanup.
    function _releaseBasketResult(address to, uint256 value, bool recorded)
        private
        nonReentrant
        whenNotPaused
        returns (bytes memory)
    {
        return ReserveBasketLib.releaseData(to, value, recorded);
    }

    /// @dev Only receives a compiler-encoded result from the fixed linked basket library after
    ///      its guarded host call returns. It forwards no caller-supplied target or raw data.
    function _returnBasketResult(bytes memory data) private pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }

    /// @dev THE SINGLE DEPOSIT BODY behind `depositAsset` and `depositAssetFor`. A zero `holder`
    ///      means "credit no deposit record", which is the correct behaviour for a credit-side
    ///      repayment: nobody deposited those units against a USDfr claim, so nobody may withdraw
    ///      them under the record cap.
    /// @dev THE SINGLE DEPOSIT ENTRY. The role check stays HERE, proxy-side, because a library
    ///      reached by `delegatecall` may never be relied on for authority; the body lives in
    ///      `ReserveWiringLib.deposit` for EIP-170 room.
    function _deposit(address asset, address from, address holder, uint256 amount) private returns (uint256 credited) {
        if (!hasRole(Roles.CONTROLLER_ROLE, msg.sender) && !hasRole(Roles.CREDIT_ROLE, msg.sender)) {
            revert ReserveManager_NotDepositor(msg.sender);
        }
        return ReserveWiringLib.deposit(asset, from, holder, amount);
    }

    function _requireReserveLossAdmin() private view {
        if (!hasRole(Roles.RESERVE_ADMIN_ROLE, msg.sender)) {
            revert ReserveManager_ReserveLossCallerNotAdmin(msg.sender);
        }
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        _requireNativeIdle();
    }

    /// @dev Role writes cannot alter the authority matrix inside a frozen accounting operation.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        _requireNativeIdle();
        return super._grantRole(role, account);
    }

    /// @dev Includes renunciation, which delegates to this same inherited writer.
    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        _requireNativeIdle();
        return super._revokeRole(role, account);
    }

    /// @dev The pre-loss fee checkpoint is coherent but already inside the reserve's receipt
    ///      guard. Its optional share callback must not change native wiring, policy or roles.
    ///      Consumer read/continuation gates deliberately remain independent of this host guard.
    function _requireNativeIdle() private view {
        ReserveAccrualLib.requireNativeIdle(_reentrancyGuardEntered());
    }

    /// @dev The linked view library uses Solidity's abi.encode for the unchanged external
    ///      return type. Forward that exact bounded buffer instead of decoding and re-encoding
    ///      the same large tuple in the proxy implementation. This cannot forward a caller's
    ///      arbitrary target or data, and the compiler still enforces the view-only library call.
    function _returnEncodedView(bytes memory data) private pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }
}
