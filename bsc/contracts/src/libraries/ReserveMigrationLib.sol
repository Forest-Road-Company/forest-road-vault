// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ClaimBridge} from "../ClaimBridge.sol";
import {ReserveStorageLib as Native} from "./ReserveStorageLib.sol";
import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IContinuousAccrual} from "../interfaces/IContinuousAccrual.sol";
import {IAccrualRegistry, IAccrualBridge} from "../interfaces/IAccrualLifecycle.sol";
import {IAccrualMigration, IAccrualMigrationRisk} from "../interfaces/IAccrualMigration.sol";
import {IWaterfallEngine} from "../interfaces/IWaterfallEngine.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {AccrualBook} from "./AccrualBook.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {AccrualCeiling} from "./AccrualCeiling.sol";
import {AccrualMath} from "./AccrualMath.sol";
import {Config} from "./Config.sol";
import {Roles} from "./Roles.sol";
import {ReserveAccrualLib} from "./ReserveAccrualLib.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @notice Governed, bounded import of existing receivables without exposing a partial senior NAV.
/// @dev The host retains its admin and reentrancy guards. A complete sorted positive-face roster
///      is frozen before signatures are collected. Each row's native record, session and complete
///      opening are authenticated before its face and risk are increased. No tokens move on import.
library ReserveMigrationLib {
    using AccrualBook for AccrualBook.Book;
    using AccrualLoans for AccrualLoans.State;

    uint256 internal constant MAX_BATCH = 8;
    bytes32 internal constant OPENING_TYPEHASH = keccak256("AccrualOpening(bytes32 frozenRecord,bytes32 opening)");

    struct Row {
        ClaimBridge.Facility facility;
        address asset;
        uint256 scale;
        uint256 recorded;
        bytes32 commitment;
    }

    error AccrualMigration_InvalidAction(uint8 action);
    error AccrualMigration_InvalidRoster();
    error AccrualMigration_InvalidFacility(uint256 facilityId);
    error AccrualMigration_UnsupportedTerms(uint256 facilityId);
    error AccrualMigration_AlreadyStarted();
    error AccrualMigration_NotStarted();
    error AccrualMigration_InvalidBatch();
    error AccrualMigration_RecordChanged(uint256 facilityId);
    error AccrualMigration_AttestationRequired(uint256 facilityId);
    error AccrualMigration_OracleNotReady(address oracle);
    error AccrualMigration_CannotCancelImportedDebt();
    error AccrualMigration_ExposureCapacity();
    error AccrualMigration_InexactOpening(uint256 facilityId);
    error AccrualMigration_NonceOverflow();

    /// @notice All native servicing is frozen at cutoff against this complete roster commitment.
    event AccrualMigrationBegun(
        uint256 indexed nonce, bytes32 indexed sessionKey, uint64 cutoff, uint32 expected, uint256 originalFace
    );
    /// @notice The opening was consumed once, posted to deployed face and reconciled into native risk.
    event AccrualOpeningImported(
        uint256 indexed nonce,
        uint256 indexed facilityId,
        uint256 recordedBefore,
        uint256 principal,
        uint256 interest,
        uint256 income,
        bool permanentlyStopped,
        bool pastDue
    );
    /// @notice A session with no imported debt was cancelled; its nonce can never be reused.
    event AccrualMigrationCancelled(uint256 indexed nonce, bytes32 indexed sessionKey);

    /// @notice Decodes one explicitly authorized preparation step; every failed batch is atomic.
    function prepare(Native.ReserveStorage storage native, bytes calldata step) public {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.busy || s.delivery.active) revert ReserveAccrualLib.ReserveAccrual_OperationInProgress();
        if (s.enabled) revert ReserveAccrualLib.ReserveAccrual_AlreadyConfigured();
        (uint8 action, bytes memory body) = abi.decode(step, (uint8, bytes));
        if (action == 0) {
            _begin(native, s, abi.decode(body, (uint256[])));
        } else if (action == 1) {
            _import(native, s, abi.decode(body, (IAccrualMigration.Opening[])));
        } else if (action == 2) {
            if (body.length != 0) revert AccrualMigration_InvalidBatch();
            _cancel(s);
        } else {
            revert AccrualMigration_InvalidAction(action);
        }
    }

    /// @notice Compiler-encoded preparation status, forwarded by the host's view-only return helper.
    function progressData() public view returns (bytes memory) {
        ReserveAccrualStorageLib.Migration storage m = ReserveAccrualStorageLib.state().migration;
        return abi.encode(
            IAccrualMigration.Progress({
                nonce: m.nonce,
                sessionKey: m.sessionKey,
                cutoff: m.cutoff,
                expected: m.expected,
                imported: m.imported,
                originalFace: m.originalFace,
                importedOriginalFace: m.importedOriginalFace,
                nextFacilityId: m.imported < m.expected ? m.facilityIds[m.imported] : 0,
                active: m.active
            })
        );
    }

    function _begin(
        Native.ReserveStorage storage native,
        ReserveAccrualStorageLib.State storage s,
        uint256[] memory ids
    ) private {
        if (s.migration.active) revert AccrualMigration_AlreadyStarted();
        if (ids.length == 0 || ids.length > AccrualBook.MAX_FACILITIES) revert AccrualMigration_InvalidRoster();
        IContinuousAccrual.Modules memory modules_ = s.modules;
        ReserveAccrualLib.requireConsumers(modules_);
        _oracle(modules_.bridge);
        uint16 feeBps = IWaterfallEngine(modules_.waterfall).protocolFeeBps();
        if (feeBps > Config.MAX_PROTOCOL_FEE_BPS) revert ReserveAccrualLib.ReserveAccrual_InvalidFee(feeBps);
        address recipient = IWaterfallEngine(modules_.waterfall).feeRecipient();
        if (recipient == address(0)) revert ReserveAccrualLib.ReserveAccrual_WrongModules();
        // Close the pre-migration fee epoch before hiding preparation from financial entry points.
        IsUSDfr(modules_.vault).accrueFees();
        ReserveAccrualStorageLib.Migration storage m = s.migration;
        if (m.nonce == type(uint256).max) revert AccrualMigration_NonceOverflow();
        ++m.nonce;
        m.cutoff = ReserveAccrualStorageLib.now64();
        m.expected = uint32(ids.length);
        m.feeBps = feeBps;
        s.feeRecipient = recipient;
        m.sessionKey = keccak256(
            abi.encode(
                block.chainid, address(this), m.nonce, m.cutoff, keccak256(abi.encode(ids)), modules_, feeBps, recipient
            )
        );
        m.active = true;
        uint256 total;
        uint256 work;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id == 0 || (i != 0 && id <= ids[i - 1])) revert AccrualMigration_InvalidRoster();
            Row memory row = _row(native, s, id);
            total += row.recorded;
            if (!_stopped(row.facility) && row.facility.maturity > m.cutoff && row.facility.interestRateBps != 0) {
                uint256 interval = row.facility.paymentInterval;
                work += row.facility.pik
                    ? AccrualLoans.YEAR / interval + (AccrualLoans.YEAR % interval == 0 ? 0 : 1) + 4
                    : 4;
            }
            m.facilityIds.push(id);
            m.frozenRecords[id] = row.commitment;
        }
        if (total != native.totalDeployedPrincipal) revert AccrualMigration_InvalidRoster();
        if (work > AccrualLoans.MAX_ANNUAL_WORK) revert AccrualLoans.AccrualLoans_WorkCapacity(work);
        m.originalFace = total;
        emit AccrualMigrationBegun(m.nonce, m.sessionKey, m.cutoff, m.expected, total);
    }

    function _import(
        Native.ReserveStorage storage native,
        ReserveAccrualStorageLib.State storage s,
        IAccrualMigration.Opening[] memory openings
    ) private {
        ReserveAccrualStorageLib.Migration storage m = s.migration;
        if (!m.active) revert AccrualMigration_NotStarted();
        if (openings.length == 0 || openings.length > MAX_BATCH || openings.length > m.expected - m.imported) {
            revert AccrualMigration_InvalidBatch();
        }
        if (m.imported == 0) s.loans.initialize(m.cutoff, m.feeBps);
        IAttestationOracle oracle = _oracle(s.modules.bridge);
        s.busy = true;
        for (uint256 i; i < openings.length; ++i) {
            IAccrualMigration.Opening memory opening = openings[i];
            uint256 id = opening.facilityId;
            if (id != m.facilityIds[m.imported] || s.identities[id].known) revert AccrualMigration_InvalidBatch();
            Row memory row = _row(native, s, id);
            if (row.commitment != m.frozenRecords[id]) revert AccrualMigration_RecordChanged(id);
            _consume(oracle, m.cutoff, row.commitment, opening);
            _importRow(native, s, row, opening);
            m.importedOriginalFace += row.recorded;
            ++m.imported;
        }
        s.busy = false;
    }

    function _importRow(
        Native.ReserveStorage storage native,
        ReserveAccrualStorageLib.State storage s,
        Row memory row,
        IAccrualMigration.Opening memory opening
    ) private {
        uint256 id = opening.facilityId;
        AccrualLoans.Opening memory imported = _loan(row, opening, s.migration.cutoff);
        uint256 ceiling = imported.terms.balanceCeiling;
        uint256 effective = ICollateralRegistry(s.modules.registry).totalBookExposure();
        uint256 reserved = s.reservedCeilings - s.recordedFace;
        uint256 extra = ceiling - row.recorded;
        if (
            effective > AccrualLoans.MAX_BASIS || reserved > AccrualLoans.MAX_BASIS - effective
                || extra > AccrualLoans.MAX_BASIS - effective - reserved
        ) revert AccrualMigration_ExposureCapacity();
        uint256 income = s.loans.importOpening(id, imported);
        uint256 posting = s.loans.book.takePosting(id, s.migration.cutoff);
        assert(posting == income);
        s.identities[id] = ReserveAccrualStorageLib.Identity({
            asset: row.asset,
            classId: row.facility.classId,
            borrowerId: row.facility.borrowerId,
            stateId: row.facility.stateId,
            reservedCeiling: ceiling,
            known: true
        });
        native.deployed[id] += income;
        native.totalDeployedPrincipal += income;
        s.recordedFace += row.recorded + income;
        s.reservedCeilings += ceiling;
        if (income != 0) {
            IAccrualRegistry(s.modules.registry).recordAccruedExposure(
                row.facility.classId, row.facility.borrowerId, row.facility.stateId, income
            );
        }
        // Importing completed historical coupons must also advance the native servicing date.
        // The attested opening supplies the coupon; an already later servicing date stays in place.
        if (
            row.facility.pik && !imported.permanentlyStopped && opening.nextCapitalization > row.facility.nextPaymentDue
        ) {
            IAccrualBridge(s.modules.bridge).setAccruedPaymentDue(id, opening.nextCapitalization);
        }
        bool marked = IAccrualMigrationRisk(s.modules.defaultManager).onAccrualOpening(id, income);
        if (marked) s.loans.book.setPastDue(id, true, s.migration.cutoff);
        emit AccrualOpeningImported(
            s.migration.nonce,
            id,
            row.recorded,
            opening.principal,
            opening.interest,
            income,
            imported.permanentlyStopped,
            marked
        );
    }

    function _loan(Row memory row, IAccrualMigration.Opening memory opening, uint64 cutoff)
        private
        pure
        returns (AccrualLoans.Opening memory result)
    {
        ClaimBridge.Facility memory f = row.facility;
        uint256 id = opening.facilityId;
        if (
            opening.principal % row.scale != 0 || opening.interest % row.scale != 0
                || opening.frozenPikBasis % row.scale != 0
        ) revert AccrualMigration_InexactOpening(id);
        if (!f.pik && (opening.principal > row.recorded || opening.nextCapitalization != 0)) {
            revert AccrualMigration_InvalidFacility(id);
        }
        if (opening.principal > AccrualLoans.MAX_BASIS || opening.interest > AccrualLoans.MAX_BASIS - opening.principal)
        {
            revert AccrualMigration_ExposureCapacity();
        }
        uint256 face = opening.principal + opening.interest;
        if (face < row.recorded || opening.periodStart > cutoff || opening.periodStart >= f.maturity) {
            revert AccrualMigration_InvalidFacility(id);
        }
        uint32 yearSeconds = _year(f, id);
        uint256 ceiling = face;
        bool stopped = _stopped(f);
        if (!stopped && cutoff < f.maturity) {
            if (f.pik) {
                // The quorum authenticates the pending coupon and its frozen epoch. Legacy
                // receipts can advance the bridge's servicing date independently of that coupon.
                ceiling = AccrualCeiling.pik(
                    AccrualCeiling.Terms({
                        face: face,
                        frozenBasis: opening.frozenPikBasis == 0 ? opening.principal : opening.frozenPikBasis,
                        scale: row.scale,
                        yearSeconds: yearSeconds,
                        rateBps: f.interestRateBps,
                        at: cutoff,
                        nextCapitalization: opening.nextCapitalization,
                        paymentInterval: f.paymentInterval,
                        maturity: f.maturity
                    })
                );
            } else {
                uint256 end = AccrualMath.earnedInterest(
                    opening.principal, f.interestRateBps, f.maturity - opening.periodStart, yearSeconds
                ) / row.scale;
                uint256 previous = AccrualMath.earnedInterest(
                    opening.principal, f.interestRateBps, cutoff - opening.periodStart, yearSeconds
                ) / row.scale;
                uint256 remaining = (end - previous) * row.scale;
                if (remaining > AccrualLoans.MAX_BASIS - face) revert AccrualMigration_ExposureCapacity();
                ceiling += remaining;
            }
        }
        result = AccrualLoans.Opening({
            terms: AccrualLoans.Funding({
                principal: opening.principal,
                balanceCeiling: ceiling,
                scale: row.scale,
                yearSeconds: yearSeconds,
                rateBps: f.interestRateBps,
                fundedAt: cutoff,
                nextPaymentDue: f.pik ? opening.nextCapitalization : f.nextPaymentDue,
                paymentInterval: f.paymentInterval,
                maturity: f.maturity,
                pik: f.pik,
                keys: ReserveAccrualStorageLib.keys(f.classId, f.borrowerId, f.stateId),
                frozenPikBasis: opening.frozenPikBasis
            }),
            recordedFace: row.recorded,
            interest: opening.interest,
            periodStart: opening.periodStart,
            permanentlyStopped: stopped
        });
    }

    function _row(Native.ReserveStorage storage native, ReserveAccrualStorageLib.State storage s, uint256 id)
        private
        view
        returns (Row memory row)
    {
        row.facility = ClaimBridge(s.modules.bridge).facility(id);
        row.recorded = native.deployed[id];
        (row.asset, row.scale) = _asset(native, id);
        ClaimBridge.Facility memory f = row.facility;
        if (
            row.recorded == 0 || row.recorded > AccrualLoans.MAX_BASIS || row.asset.code.length == 0 || f.principal == 0
                || f.paymentInterval == 0 || f.maturity == 0 || f.nextPaymentDue == 0 || f.nextPaymentDue > f.maturity
                || (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing && !_stopped(f))
        ) revert AccrualMigration_InvalidFacility(id);
        _year(f, id);
        ICollateralRegistry(s.modules.registry).classParams(f.classId);
        row.commitment =
            keccak256(abi.encode(s.migration.sessionKey, id, row.asset, row.recorded, keccak256(abi.encode(f))));
    }

    function _asset(Native.ReserveStorage storage native, uint256 id) private view returns (address, uint256) {
        address asset = native.facilityAsset[id];
        return (asset, ReserveStorageLib.requireListed(native, asset).scale);
    }

    function _year(ClaimBridge.Facility memory f, uint256 id) private pure returns (uint32) {
        if (f.rateType != ClaimBridge.RateType.Fixed || f.interestRateBps > 10_000) {
            revert AccrualMigration_UnsupportedTerms(id);
        }
        if (f.dayCountConvention == ClaimBridge.DayCountConvention.Actual360) return uint32(360 days);
        if (!f.pik && f.dayCountConvention == ClaimBridge.DayCountConvention.Actual365) return uint32(365 days);
        revert AccrualMigration_UnsupportedTerms(id);
    }

    function _stopped(ClaimBridge.Facility memory f) private pure returns (bool) {
        return f.state == ClaimBridge.LoanState.Defaulted || f.state == ClaimBridge.LoanState.Accelerated;
    }

    function _oracle(address bridge) private view returns (IAttestationOracle oracle) {
        (, address target) = ClaimBridge(bridge).modules();
        oracle = IAttestationOracle(target);
        if (
            target.code.length == 0 || oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening) < 2
                || !IAccessControl(target).hasRole(Roles.CREDIT_ROLE, address(this))
        ) {
            revert AccrualMigration_OracleNotReady(target);
        }
    }

    function _consume(
        IAttestationOracle oracle,
        uint64 cutoff,
        bytes32 record,
        IAccrualMigration.Opening memory opening
    ) private {
        bytes32 expected = keccak256(abi.encode(OPENING_TYPEHASH, record, keccak256(abi.encode(opening))));
        (bytes32 payload, uint64 asOf, bool satisfied) =
            oracle.latestPayload(opening.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
        if (!satisfied || asOf != cutoff || payload != expected) {
            revert AccrualMigration_AttestationRequired(opening.facilityId);
        }
        oracle.consume(opening.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
    }

    function _cancel(ReserveAccrualStorageLib.State storage s) private {
        ReserveAccrualStorageLib.Migration storage m = s.migration;
        if (!m.active) revert AccrualMigration_NotStarted();
        if (m.imported != 0) revert AccrualMigration_CannotCancelImportedDebt();
        emit AccrualMigrationCancelled(m.nonce, m.sessionKey);
        m.active = false;
        m.cutoff = 0;
        m.expected = 0;
        m.feeBps = 0;
        m.originalFace = 0;
        m.sessionKey = bytes32(0);
        delete m.facilityIds;
        s.feeRecipient = address(0);
    }
}
