// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveManager} from "../ReserveManager.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IContinuousAccrual, IAccrualToken, IAccrualController, IAccrualVault
} from "../interfaces/IContinuousAccrual.sol";
import {IWaterfallEngine} from "../interfaces/IWaterfallEngine.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccrualBook} from "./AccrualBook.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {AccrualCeiling} from "./AccrualCeiling.sol";
import {Config} from "./Config.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveAccrualLib
/// @notice Reserve-owned continuous accounting configuration, views and exact physical delivery.
/// @dev Public library methods execute in the reserve. Its host retains governance and reentrancy
///      guards. All backing proofs use this reserve's own storage, independently of cached views.
library ReserveAccrualLib {
    /// @notice Preserves the credit adapter's existing cash-capacity error selector.
    error AccrualCredit_ExposureCapacity();

    /// @notice Capacity for the full signed obligation, with fixed cash or scheduled PIK terms.
    /// @dev Shares one call encoding in the size-constrained credit adapter. For cash,
    ///      frozenBasis is present principal and face additionally includes already-earned interest.
    function loanCeiling(AccrualCeiling.Terms memory terms, bool pik) public pure returns (uint256 ceiling) {
        if (pik) return AccrualCeiling.pik(terms);
        uint256 principal = terms.frozenBasis;
        if (principal > AccrualLoans.MAX_BASIS || terms.face < principal || terms.face > AccrualLoans.MAX_BASIS) {
            revert AccrualCredit_ExposureCapacity();
        }
        if (terms.maturity <= terms.at) revert AccrualLoans.AccrualLoans_InvalidSchedule();
        uint256 units =
            Math.mulDiv(principal * terms.rateBps, terms.maturity - terms.at, terms.yearSeconds * 10_000 * terms.scale);
        ceiling = terms.face;
        if (units > (AccrualLoans.MAX_BASIS - ceiling) / terms.scale) revert AccrualCredit_ExposureCapacity();
        return ceiling + units * terms.scale;
    }

    using AccrualBook for AccrualBook.Book;
    using AccrualLoans for AccrualLoans.State;
    using ReserveStorageLib for ReserveManager.ReserveStorage;

    /// @notice Configuration is permanent and cannot replace existing obligations or nonce space.
    error ReserveAccrual_AlreadyConfigured();
    /// @notice Every bound address must be a compatible module of this instance.
    error ReserveAccrual_WrongModules();
    /// @notice Continuous accounting is not enabled yet.
    error ReserveAccrual_NotEnabled();
    /// @notice A coherent accounting operation is already in progress.
    error ReserveAccrual_OperationInProgress();
    /// @notice Activation cannot silently omit an existing deployed receivable.
    error ReserveAccrual_MigrationRequired(uint256 deployed);
    /// @notice Activation requires every frozen positive-face row to be imported and reconciled.
    error ReserveAccrual_MigrationIncomplete(uint32 imported, uint32 expected);
    /// @notice The configured interest fee exceeds its existing permanent limit.
    error ReserveAccrual_InvalidFee(uint16 feeBps);
    /// @notice The requested selected-claim mask must be senior=1, fee=2 or both=3.
    error ReserveAccrual_InvalidLegs(uint8 legs);
    /// @notice Vault share/fee accounting currently cannot admit neutral delivery.
    error ReserveAccrual_VaultBusy();
    /// @notice A delivery nonce cannot wrap or be reused.
    error ReserveAccrual_NonceOverflow();
    /// @notice Delivery must leave enough gas for the reserve's independent closing proofs.
    error ReserveAccrual_InsufficientDeliveryGas(uint256 available);
    /// @notice Actual physical or economic deltas did not match the exact permit.
    error ReserveAccrual_DeliveryMismatch(uint8 measurement, uint256 expected, uint256 actual);
    /// @notice Only the permanently bound waterfall can synchronize its configured interest fee.
    error ReserveAccrual_NotWaterfall();

    /// @notice Immutable module identities were configured before activation.
    event AccrualConfigured(address indexed token, address indexed controller, address indexed vault);
    /// @notice Prospective continuous recognition was enabled at this timestamp and fee rate.
    event AccrualEnabled(uint64 indexed at, uint16 feeBps, address feeRecipient);
    /// @notice Selected existing senior/fee claims were physically delivered with exact delta proofs.
    event AccrualMaterialized(uint256 indexed nonce, uint64 indexed at, uint8 legs, uint256 senior, uint256 fee);
    /// @notice The old fee epoch closed before this rate or recipient became effective.
    event AccrualFeeConfigured(uint16 feeBps, address indexed recipient, uint64 indexed at);

    /// @notice Installs immutable identities; the reserve host authenticates governance.
    function configure(ReserveManager.ReserveStorage storage native, IContinuousAccrual.Modules memory m) public {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        requireIdle();
        if (s.modules.token != address(0)) revert ReserveAccrual_AlreadyConfigured();
        if (
            m.token.code.length == 0 || m.controller.code.length == 0 || m.vault.code.length == 0
                || m.waterfall.code.length == 0 || m.bridge.code.length == 0 || m.registry.code.length == 0
                || m.defaultManager.code.length == 0
        ) revert ReserveAccrual_WrongModules();
        if (
            address(native.lossController) != m.controller || address(native.lossAbsorber) != m.defaultManager
                || address(native.lossVault) != m.vault || address(native.lossUSDfr) != m.token
        ) revert ReserveAccrual_WrongModules();
        _validateRoutes(m, native);
        if (
            abi.decode(_reply(m.defaultManager, abi.encodeWithSignature("backstop()"), 32), (uint256))
                != uint256(uint160(address(native.lossBackstop)))
        ) revert ReserveAccrual_WrongModules();
        s.modules = m;
        emit AccrualConfigured(m.token, m.controller, m.vault);
    }

    /// @notice Activates an empty book or a complete, reconciled opening import.
    /// @dev A delayed import may have scheduled work due. Existing freshness gates continue to
    ///      refuse financial entry until the normal keeper has processed those boundaries.
    function enable(ReserveManager.ReserveStorage storage native) public {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.busy || s.delivery.active) revert ReserveAccrual_OperationInProgress();
        if (s.enabled) revert ReserveAccrual_AlreadyConfigured();
        IContinuousAccrual.Modules memory m = s.modules;
        requireConsumers(m);
        uint256 deployed = native.totalDeployedPrincipal;
        bool migrating = s.migration.active;
        if (!migrating && deployed != 0) revert ReserveAccrual_MigrationRequired(deployed);
        if (
            migrating
                && (
                    s.migration.expected == 0 || s.migration.imported != s.migration.expected
                        || s.migration.importedOriginalFace != s.migration.originalFace || s.recordedFace != deployed
                )
        ) {
            revert ReserveAccrual_MigrationIncomplete(s.migration.imported, s.migration.expected);
        }
        uint16 feeBps = IWaterfallEngine(m.waterfall).protocolFeeBps();
        if (feeBps > Config.MAX_PROTOCOL_FEE_BPS) revert ReserveAccrual_InvalidFee(feeBps);
        address recipient = IWaterfallEngine(m.waterfall).feeRecipient();
        if (recipient == address(0)) revert ReserveAccrual_WrongModules();
        uint64 at = ReserveAccrualStorageLib.now64();
        if (migrating) {
            if (feeBps != s.migration.feeBps || recipient != s.feeRecipient) revert ReserveAccrual_WrongModules();
            s.migration.active = false;
        } else {
            s.loans.initialize(at, feeBps);
            s.feeRecipient = recipient;
        }
        s.enabled = true;
        emit AccrualEnabled(at, feeBps, recipient);
    }

    /// @notice Every bound consumer must point back to this native reserve before preparation.
    function requireConsumers(IContinuousAccrual.Modules memory m) internal view {
        if (
            m.token == address(0) || IAccrualToken(m.token).accrualReserve() != address(this)
                || IAccrualVault(m.vault).accrualReserve() != address(this)
                || IAccrualVault(m.controller).accrualReserve() != address(this)
                || IAccrualVault(m.waterfall).accrualReserve() != address(this)
                || IAccrualVault(m.bridge).accrualReserve() != address(this)
                || IAccrualVault(m.registry).accrualReserve() != address(this)
                || IAccrualVault(m.defaultManager).accrualReserve() != address(this)
        ) revert ReserveAccrual_WrongModules();
    }

    /// @notice Synchronizes both fee fields prospectively, delivering an old recipient's claim first.
    /// @dev The waterfall updates its own fields after this returns. A failure rolls back both sides.
    function setFee(ReserveManager.ReserveStorage storage native, uint16 feeBps, address recipient) public {
        requireFresh();
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (msg.sender != s.modules.waterfall) revert ReserveAccrual_NotWaterfall();
        if (!s.enabled) revert ReserveAccrual_NotEnabled();
        if (feeBps > Config.MAX_PROTOCOL_FEE_BPS) revert ReserveAccrual_InvalidFee(feeBps);
        if (recipient == address(0) || !IMintRedeemController(s.modules.controller).isYieldSink(recipient)) {
            revert ReserveAccrual_WrongModules();
        }
        if (recipient != s.feeRecipient) materialize(native, 2);
        uint64 at = ReserveAccrualStorageLib.now64();
        s.loans.book.setFee(feeBps, at);
        s.feeRecipient = recipient;
        emit AccrualFeeConfigured(feeBps, recipient, at);
    }

    /// @notice Delivers the vault's existing claims before a native cascade can burn its assets.
    /// @dev A separate fee recipient retains its fully earned claim for permissionless delivery;
    ///      restrictions on that recipient cannot hold an unrelated loss or repayment hostage.
    ///      If the vault owns the fee too, both legs belong to its loss-absorbing assets. The
    ///      native loss manager retains its established pre-loss performance-fee checkpoint.
    function prepareNativeLoss(ReserveManager.ReserveStorage storage native) public {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.enabled) materialize(native, s.feeRecipient == s.modules.vault ? 3 : 1);
    }

    /// @dev Verify all forward routes before the permanent tuple can strand a consumer binding.
    ///      Consumer reverse bindings are necessarily installed afterwards and checked at activation.
    function _validateRoutes(IContinuousAccrual.Modules memory m, ReserveManager.ReserveStorage storage native)
        private
        view
    {
        uint256[3] memory c = abi.decode(_reply(m.controller, abi.encodeWithSignature("modules()"), 96), (uint256[3]));
        if (c[0] != uint256(uint160(m.token)) || c[1] > type(uint160).max || c[2] != uint256(uint160(address(this)))) {
            revert ReserveAccrual_WrongModules();
        }
        if (abi.decode(_reply(m.vault, abi.encodeCall(IERC4626.asset, ()), 32), (uint256)) != uint256(uint160(m.token)))
        {
            revert ReserveAccrual_WrongModules();
        }
        uint256[2] memory b = abi.decode(_reply(m.bridge, abi.encodeWithSignature("modules()"), 64), (uint256[2]));
        if (b[0] != uint256(uint160(m.registry)) || b[1] > type(uint160).max || address(uint160(b[1])).code.length == 0)
        {
            revert ReserveAccrual_WrongModules();
        }
        uint256[6] memory w = abi.decode(_reply(m.waterfall, abi.encodeWithSignature("modules()"), 192), (uint256[6]));
        if (
            w[0] != uint256(uint160(m.bridge)) || w[1] != uint256(uint160(m.registry))
                || w[2] != uint256(uint160(address(this))) || w[3] != uint256(uint160(m.controller))
                || w[4] != uint256(uint160(m.vault)) || w[5] != b[1]
                || abi.decode(_reply(m.waterfall, abi.encodeWithSignature("defaultManager()"), 32), (uint256))
                    != uint256(uint160(m.defaultManager))
        ) revert ReserveAccrual_WrongModules();
        uint256[8] memory d =
            abi.decode(_reply(m.defaultManager, abi.encodeWithSignature("modules()"), 256), (uint256[8]));
        if (
            d[0] != uint256(uint160(m.bridge)) || d[1] != uint256(uint160(m.registry))
                || d[2] != uint256(uint160(address(this))) || d[3] != uint256(uint160(m.controller))
                || d[4] != uint256(uint160(address(native.lossCurator))) || d[5] != b[1]
                || d[6] != uint256(uint160(m.vault)) || d[7] > type(uint160).max || address(uint160(d[7])).code.length == 0
        ) revert ReserveAccrual_WrongModules();
    }

    function _reply(address target, bytes memory request, uint256 length) private view returns (bytes memory data) {
        bool ok;
        (ok, data) = target.staticcall(request);
        if (!ok || data.length != length) revert ReserveAccrual_WrongModules();
    }

    /// @notice The authoritative price-write admission gate, including non-delivery host operations.
    function requireFresh() public view {
        requireIdle();
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.enabled) s.loans.book.requireFresh(ReserveAccrualStorageLib.now64());
    }

    /// @notice Refuses an overlapping accounting operation without blocking clock-independent recovery.
    function requireIdle() internal view {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.busy || s.delivery.active || s.migration.active) revert ReserveAccrual_OperationInProgress();
    }

    /// @notice Public coherent snapshot; off mode is zero and fresh.
    function snapshot() internal view returns (IContinuousAccrual.Snapshot memory result) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.migration.active) revert ReserveAccrual_OperationInProgress();
        if (s.delivery.active) return s.deliverySnapshot;
        uint64 at = ReserveAccrualStorageLib.now64();
        result.feeRecipient = s.feeRecipient;
        result.enabled = s.enabled;
        result.fresh = true;
        result.accruedThrough = at;
        if (!s.enabled) return result;
        AccrualBook.Snapshot memory book = s.loans.book.snapshot(at);
        result.gross = book.gross;
        result.unposted = book.unposted;
        result.unissued = book.unissued;
        result.seniorUnissued = book.seniorUnissued;
        result.feeUnissued = book.feeUnissued;
        result.accruedThrough = book.accruedThrough;
        result.fresh = book.fresh;
    }

    /// @notice Compiler-encoded public snapshot, forwarded by the host without a redundant decode.
    function snapshotData() public view returns (bytes memory) {
        return abi.encode(snapshot());
    }

    /// @notice Compiler-encoded immutable module tuple for the host's existing external ABI.
    function modulesData() public view returns (bytes memory) {
        return abi.encode(ReserveAccrualStorageLib.state().modules);
    }

    /// @notice Compiler-encoded delivery tuple; inactive delivery retains its all-zero ABI shape.
    function deliveryData() public view returns (bytes memory) {
        IContinuousAccrual.Delivery memory result;
        IContinuousAccrual.Delivery storage delivery = ReserveAccrualStorageLib.state().delivery;
        if (delivery.active) result = delivery;
        return abi.encode(result);
    }

    /// @notice Converts selected previously recognized liabilities into physical token balances.
    /// @dev No vault write callback, facility scan, new recognition or headroom clamp occurs.
    function materialize(ReserveManager.ReserveStorage storage native, uint8 legs)
        public
        returns (uint256 senior, uint256 fee)
    {
        requireFresh();
        if (legs == 0 || legs > 3) revert ReserveAccrual_InvalidLegs(legs);
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (!s.enabled) revert ReserveAccrual_NotEnabled();
        IContinuousAccrual.Snapshot memory beforeBook = snapshot();
        senior = (legs & 1) == 0 ? 0 : beforeBook.seniorUnissued;
        fee = (legs & 2) == 0 ? 0 : beforeBook.feeUnissued;
        if (senior == 0 && fee == 0) return (0, 0);
        IContinuousAccrual.Delivery memory d;
        d.pricing = IAccrualVault(s.modules.vault).accrualPricingState();
        if (!d.pricing.materializationAllowed) revert ReserveAccrual_VaultBusy();
        if (s.nonce == type(uint256).max) revert ReserveAccrual_NonceOverflow();
        d.nonce = ++s.nonce;
        d.senior = senior;
        d.fee = fee;
        d.controller = s.modules.controller;
        d.vault = s.modules.vault;
        d.feeRecipient = s.feeRecipient;
        d.accruedThrough = beforeBook.accruedThrough;
        d.legs = legs;
        d.active = true;
        uint256[3] memory rawBefore = _rawBalances(s.modules.token, d.vault, d.feeRecipient);
        d.effectiveSupply = rawBefore[0] + beforeBook.unissued;
        (d.backing, d.recognizedBacking) = rawBacking(native);
        s.delivery = d;
        s.deliverySnapshot = beforeBook;
        s.busy = true;
        s.loans.book.takeIssuance(legs, beforeBook.accruedThrough);
        _deliver(d.controller, d.nonce);
        _proveDelivery(s, native, d, rawBefore);
        delete s.delivery;
        delete s.deliverySnapshot;
        s.busy = false;
        emit AccrualMaterialized(d.nonce, d.accruedThrough, legs, senior, fee);
    }

    /// @notice Independently reads native accounting; delivery snapshots are deliberately ignored.
    function rawBacking(ReserveManager.ReserveStorage storage native)
        internal
        view
        returns (uint256 backing, uint256 recognized)
    {
        backing = native.backingValue();
        uint256 live = native.usdcToken.balanceOf(address(this));
        uint256 shortfall = native.idleUSDCUnits > live ? ReserveStorageLib.normalize(native.idleUSDCUnits - live) : 0;
        recognized = backing > shortfall ? backing - shortfall : 0;
    }

    function _rawBalances(address token, address vault, address feeRecipient)
        private
        view
        returns (uint256[3] memory values)
    {
        IERC20 usdfr = IERC20(token);
        values[0] = usdfr.totalSupply();
        values[1] = usdfr.balanceOf(vault);
        values[2] = feeRecipient == vault ? values[1] : usdfr.balanceOf(feeRecipient);
    }

    /// @dev A failed optional token hook must not consume the caller's proof/cleanup budget.
    ///      This reserves continuation gas; it does not impose a fixed cap on token work.
    function _deliver(address controller, uint256 nonce) private {
        uint256 available = gasleft();
        uint256 retained = available >> 3;
        if (retained < 350_000) retained = 350_000;
        if (available <= retained + 200_000) revert ReserveAccrual_InsufficientDeliveryGas(available);
        IAccrualController(controller).mintAccrued{gas: available - retained}(nonce);
    }

    function _proveDelivery(
        ReserveAccrualStorageLib.State storage s,
        ReserveManager.ReserveStorage storage native,
        IContinuousAccrual.Delivery memory d,
        uint256[3] memory before_
    ) private view {
        uint256[3] memory after_ = _rawBalances(s.modules.token, d.vault, d.feeRecipient);
        _equal(0, before_[0] + d.senior + d.fee, after_[0]);
        uint256 vaultMinted = d.senior + (d.feeRecipient == d.vault ? d.fee : 0);
        _equal(1, before_[1] + vaultMinted, after_[1]);
        if (d.feeRecipient != d.vault) _equal(2, before_[2] + d.fee, after_[2]);
        AccrualBook.Snapshot memory book = s.loans.book.snapshot(d.accruedThrough);
        _equal(3, d.effectiveSupply, after_[0] + book.unissued);
        uint256 owned = book.seniorUnissued + (d.feeRecipient == d.vault ? book.feeUnissued : 0);
        _equal(4, d.pricing.entryAssets, after_[1] + owned);
        (uint256 backing, uint256 recognized) = rawBacking(native);
        _equal(5, d.backing, backing);
        _equal(6, d.recognizedBacking, recognized);
    }

    function _equal(uint8 measurement, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert ReserveAccrual_DeliveryMismatch(measurement, expected, actual);
    }
}
