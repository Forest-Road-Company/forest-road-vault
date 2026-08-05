// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimBridge} from "./ClaimBridge.sol";
import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {IDefaultManager} from "./interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {IWaterfallEngine} from "./interfaces/IWaterfallEngine.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title WaterfallEngine — funding out, repayments in (brief Part 5 §9)
/// @notice Every attested repayment is routed with EXACT conservation (CLAUDE.md §1.3):
///         `interest == fee + toVault` and `principal` fully returns to
///         reserve accounting with the matching exposure decrease — nothing created,
///         nothing destroyed, nothing routed by hand.
///
///         SENIORITY: the senior claim (`sUSDfr`) receives all interest after the
///         protocol fee. Curator (junior) capital is never paid from repayments — it is
///         only released as exposure falls (CuratorModule
///         headroom), so senior is never subordinated to junior.
///
///         FUNDS PRECONDITION (dual-record sync): the stables for a distribution must
///         already sit in the treasury in the same transaction. The interest leg is
///         enforced on-chain — `mintYield` asserts the ADR-0012 backing invariant, so
///         minting yield against stables that never arrived reverts. The principal leg
///         shifts backing composition (deployed → idle) and is reconciled by attested
///         receipts (ADR-0007) plus the Phase E integration suite.
contract WaterfallEngine is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IWaterfallEngine
{
    /// @custom:storage-location erc7201:forestroad.storage.WaterfallEngine
    struct WaterfallStorage {
        ClaimBridge bridge;
        ICollateralRegistry registry;
        IReserveManager reserves;
        IMintRedeemController controller;
        address vault; // sUSDfr — the senior yield destination
        address feeRecipient;
        uint16 protocolFeeBps;
        // ── append-only (upgrade safety) ──────────────────────────────────
        mapping(uint256 classId => uint16) originationFeeBps; // ADR-0019
        IAttestationOracle oracle; // payment gate (Phase G, ADR-0020)
        IDefaultManager defaultManager; // ADR-0022 impairment-pool resolve hook (optional)
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.WaterfallEngine")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WATERFALL_STORAGE_LOCATION =
        0xcf0c34fc0be88a30eafd83d03dde401c38c60299c8a6f87d9915e05fa29cdd00;

    /// @notice Emitted when the DefaultManager resolve hook is wired or cleared (ADR-0022).
    /// @param manager The DefaultManager address, or zero when the hook is disabled.
    event DefaultManagerSet(address indexed manager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Wiring bundle for `initialize` (flat addresses exceed stack depth).
    struct InitModules {
        address bridge; // facility register (states + metadata)
        address registry; // collateral registry (exposure decreases on principal return)
        address reserves; // canonical-USDC treasury
        address controller; // mint controller (yield mints; asserts backing)
        address vault; // the sUSDfr vault (senior yield destination)
        address feeRecipient; // protocol fee destination (Forest Road treasury)
        address oracle; // attestation oracle (payment gate; ADR-0007 trust)
    }

    /// @notice Initializes the engine with the launch-default protocol fee.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param m The wired protocol modules (see `InitModules` field docs).
    function initialize(address admin, address guardian, address upgrader, InitModules calldata m)
        external
        initializer
    {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || m.bridge == address(0)
                || m.registry == address(0) || m.reserves == address(0) || m.controller == address(0)
                || m.vault == address(0) || m.feeRecipient == address(0) || m.oracle == address(0)
        ) revert Waterfall_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        WaterfallStorage storage $ = _storage();
        $.bridge = ClaimBridge(m.bridge);
        $.registry = ICollateralRegistry(m.registry);
        $.reserves = IReserveManager(m.reserves);
        $.controller = IMintRedeemController(m.controller);
        $.vault = m.vault;
        $.feeRecipient = m.feeRecipient;
        $.oracle = IAttestationOracle(m.oracle);
        $.protocolFeeBps = uint16(Config.DEFAULT_PROTOCOL_FEE_BPS);
        emit ProtocolFeeSet(uint16(Config.DEFAULT_PROTOCOL_FEE_BPS));
        emit FeeRecipientSet(m.feeRecipient);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.originationFeeBps[classId] = Config.DEFAULT_ORIGINATION_FEE_BPS;
            emit OriginationFeeSet(classId, Config.DEFAULT_ORIGINATION_FEE_BPS);
        }
    }

    // ── Servicing paths ──────────────────────────────────────────────────

    /// @inheritdoc IWaterfallEngine
    /// @dev Single-shot exact-principal funding: the deployment must equal the
    ///      originated principal precisely, so the position NFT, reserve accounting,
    ///      and registry exposure all describe the same number from day one.
    ///
    ///      ORIGINATION FEE (ADR-0019, OID mechanics): the borrower nets
    ///      `principal - fee`; the fee's stables never leave the treasury, so they are
    ///      capitalized into the facility's deployed principal (the claim is the FULL
    ///      principal) and the fee mints to the protocol fee recipient against that
    ///      raised backing — the mint's backing assertion keeps this exact. The fee is
    ///      floored to a whole stable unit so no dust is taken from the borrower.
    function fund(uint256 tokenId, uint256 usdcAmount)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
        whenNotPaused
    {
        WaterfallStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Pending) revert Waterfall_NotFundable(tokenId);
        // AUDIT FIX (M-01): re-validate maturity, class activity, required attestations and
        // marked-to-market freshness/LTV immediately before funds leave the treasury —
        // origination's gate is point-in-time and a pending facility can decay after it.
        $.bridge.checkFundable(tokenId);

        uint256 value = $.reserves.normalizeUSDC(usdcAmount);
        if (value != f.principal) revert Waterfall_PrincipalMismatch(tokenId, f.principal, value);

        uint256 feeUSDC = Math.mulDiv(usdcAmount, $.originationFeeBps[f.classId], Config.BPS);
        uint256 fee = $.reserves.normalizeUSDC(feeUSDC);

        $.reserves.recordDeployment(tokenId, f.fundingRecipient, usdcAmount - feeUSDC);
        if (fee != 0) {
            $.reserves.recordFeeCapitalization(tokenId, fee); // deployed == full principal
            $.controller.mintYield($.feeRecipient, fee); // asserts backing post-mint
            emit OriginationFeeCharged(tokenId, f.classId, fee);
        }
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Active);
        emit Funded(tokenId, f.fundingRecipient, f.principal);
    }

    /// @inheritdoc IWaterfallEngine
    function distribute(Payment calldata payment) external onlyRole(Roles.SERVICER_ROLE) nonReentrant whenNotPaused {
        if (payment.interest == 0 && payment.principal == 0) revert Waterfall_ZeroAmount();
        WaterfallStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(payment.tokenId);

        bool performing = f.state == ClaimBridge.LoanState.Active || f.state == ClaimBridge.LoanState.Amortizing;
        bool recovery = f.state == ClaimBridge.LoanState.Defaulted || f.state == ClaimBridge.LoanState.Accelerated;
        if (!performing && !recovery) revert Waterfall_NotDistributable(payment.tokenId);

        // the attested-fact gate (Phase G, ADR-0020): a distribution spends ONE
        // PaymentReceived attestation committing to exactly this receipt
        uint256 total = payment.interest + payment.principal;
        uint256 usdcAmount = $.reserves.denormalizeUSDC(total);
        _spendPaymentAttestation($, payment, usdcAmount);

        // ── principal leg: reserve accounting + exposure release ──────────
        uint256 outstanding = $.reserves.deployedTo(payment.tokenId);
        if (payment.principal != 0) {
            if (payment.principal > outstanding) {
                revert Waterfall_PrincipalExceedsOutstanding(payment.tokenId, payment.principal, outstanding);
            }
            outstanding -= payment.principal;
        }
        uint256 received = $.reserves.recordPayment(payment.tokenId, payment.payer, usdcAmount, payment.principal);
        if (received != total) revert Waterfall_BackingWouldBreak(payment.tokenId);
        if (payment.principal != 0) {
            $.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, payment.principal);
        }
        // A bullet schedule can legitimately arrive at its terminal due date while
        // principal remains outstanding. Interest-only and partial-principal receipts
        // at that point must remain serviceable, but there is no later legal due date
        // to write. Treat only the exact, attested maturity-to-maturity case as a
        // terminal no-op; every non-terminal schedule still advances strictly through
        // ClaimBridge.setNextPaymentDue.
        bool terminalDueNoOp = f.nextPaymentDue == f.maturity && payment.nextPaymentDue == f.maturity;
        if (performing && outstanding != 0 && !terminalDueNoOp) {
            $.bridge.setNextPaymentDue(payment.tokenId, payment.nextPaymentDue);
        }

        // ── interest leg: protocol fee → senior vault ────────────────────
        uint256 fee = 0;
        uint256 toVault = 0;
        if (payment.interest != 0) {
            (fee, toVault) = _routeInterest($, payment.interest);
        } else {
            // Close the prior fee period before any lifecycle impairment change below.
            IsUSDfr($.vault).accrueFees();
        }

        // ── lifecycle: partial principal starts amortization; full repayment closes ──
        // AUDIT FIX (M-03): a defaulted/accelerated facility that recovers its full
        // outstanding principal closes out to Resolved (was: it stayed Defaulted with the
        // NFT frozen). A performing facility repaying in full still closes to Repaid.
        if (payment.principal != 0) {
            if (outstanding == 0) {
                $.bridge.transitionState(
                    payment.tokenId, performing ? ClaimBridge.LoanState.Repaid : ClaimBridge.LoanState.Resolved
                );
                // ADR-0022 (Option Y): a defaulted facility that recovered in FULL leaves the
                // unrealized-impairment pool here. Without this, `pendingSeniorImpairment()`
                // would carry the recovered facility's outstanding forever and permanently
                // depress the conservative redemption NAV after a clean workout. Ordered AFTER
                // the transition because `onDefaultResolved` defensively requires `Resolved`.
                // Optional wiring (zero = disabled) so the engine predates the manager in the
                // deploy/fixture ordering; NOT try/catch — a failure here must fail loudly
                // (CLAUDE.md prime directive 4) rather than silently over-mark impairment.
                IDefaultManager dm = $.defaultManager;
                if (!performing && address(dm) != address(0)) dm.onDefaultResolved(payment.tokenId);
                // AUDIT FIX (re-audit MEDIUM): a PERFORMING full repayment of a facility that was
                // past-due-marked (a bystander marked it, then it cured through this ordinary path)
                // must clear the past-due mark, else the conservative NAV stays depressed by the
                // whole mark-time snapshot until a manual `clearPastDue`. No-op if not flagged.
                if (performing && address(dm) != address(0)) dm.onPerformingRepayment(payment.tokenId);
            } else if (performing) {
                if (f.state == ClaimBridge.LoanState.Active) {
                    $.bridge.transitionState(payment.tokenId, ClaimBridge.LoanState.Amortizing);
                }
                // AUDIT FIX (re-audit MEDIUM): re-anchor a past-due mark DOWN to live `deployedTo`
                // as the facility amortizes, mirroring the `onDefaultRecovery` re-anchor on the
                // defaulted path — else a past-due partial paydown over-marks by the amount repaid.
                // No-op if not flagged.
                IDefaultManager dm = $.defaultManager;
                if (address(dm) != address(0)) dm.onPerformingRepayment(payment.tokenId);
            } else {
                // AUDIT FIX (H-2): a PARTIAL recovery on a defaulted facility. `deployedTo` just
                // fell by `principal`, but the DefaultManager's impairment contribution was
                // snapshotted at declare and has no other way down — `realizeLoss` is the only
                // one, and a servicer must not write off principal still being collected. Left
                // unsaid, the conservative redemption NAV carried a haircut for money that came
                // back in cash, for the life of the workout and beyond (nothing cleared it).
                // Mirrors the full-recovery `onDefaultResolved` call above: same optional
                // wiring (zero = disabled, so the engine can predate the manager), and NOT
                // try/catch — a failure here fails loudly (CLAUDE.md prime directive 4) rather
                // than silently over-marking impairment.
                IDefaultManager dm = $.defaultManager;
                if (address(dm) != address(0)) dm.onDefaultRecovery(payment.tokenId);
            }
        }

        // AUDIT FIX (M): the principal leg lowers deployed principal (backing) with no
        // mint/burn, so on the interest==0 path nothing else asserts backing. The
        // returning stables MUST have arrived in the treasury this transaction (attested
        // PaymentReceived, ADR-0007); enforce it on-chain rather than trust the input —
        // fail loudly (CLAUDE.md prime directive 4) instead of silently unbacking supply.
        if (!$.controller.backingInvariantHolds()) revert Waterfall_BackingWouldBreak(payment.tokenId);

        _emitDistributed(payment, fee, toVault);
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @inheritdoc IWaterfallEngine
    function setProtocolFee(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > Config.BPS) revert Waterfall_BadFee(feeBps);
        _storage().protocolFeeBps = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    /// @inheritdoc IWaterfallEngine
    function setOriginationFee(uint256 classId, uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert Waterfall_UnknownClass(classId);
        if (feeBps > Config.MAX_ORIGINATION_FEE_BPS) revert Waterfall_BadFee(feeBps);
        _storage().originationFeeBps[classId] = feeBps;
        emit OriginationFeeSet(classId, feeBps);
    }

    /// @inheritdoc IWaterfallEngine
    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert Waterfall_ZeroAddress();
        _storage().feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Wires the DefaultManager so a clean recovery clears the facility's
    ///         unrealized-impairment contribution (ADR-0022 Option Y).
    /// @dev An admin SETTER rather than an init arg deliberately: the DefaultManager is
    ///      constructed AFTER the WaterfallEngine in both the deploy script and the test
    ///      fixtures, so an init-arg would force a circular ordering. Zero clears the wiring
    ///      (the engine then behaves exactly as it did pre-ADR-0022). The engine must hold
    ///      `CREDIT_ROLE` on the manager for the hook to succeed.
    /// @param manager The DefaultManager address, or zero to disable the hook.
    function setDefaultManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _storage().defaultManager = IDefaultManager(manager);
        emit DefaultManagerSet(manager);
    }

    /// @notice The wired DefaultManager (zero = resolve hook disabled).
    function defaultManager() external view returns (address) {
        return address(_storage().defaultManager);
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses funding and distribution. Emergency use only.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IWaterfallEngine
    function protocolFeeBps() external view returns (uint16) {
        return _storage().protocolFeeBps;
    }

    /// @inheritdoc IWaterfallEngine
    function feeRecipient() external view returns (address) {
        return _storage().feeRecipient;
    }

    /// @inheritdoc IWaterfallEngine
    function originationFeeBps(uint256 classId) external view returns (uint16) {
        return _storage().originationFeeBps[classId];
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules()
        external
        view
        returns (address bridge, address registry, address reserves, address controller, address vault, address oracle)
    {
        WaterfallStorage storage $ = _storage();
        return (
            address($.bridge),
            address($.registry),
            address($.reserves),
            address($.controller),
            $.vault,
            address($.oracle)
        );
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _emitDistributed(Payment calldata payment, uint256 fee, uint256 toVault) private {
        emit Distributed(
            payment.tokenId, payment.paymentId, payment.payer, payment.interest, payment.principal, fee, toVault
        );
    }

    /// @dev Verifies a currently-satisfied PaymentReceived attestation whose payload
    ///      commits to exactly (tokenId, interest, principal), then consumes it —
    ///      one attested receipt authorizes exactly one distribution (ADR-0020).
    function _spendPaymentAttestation(WaterfallStorage storage $, Payment calldata payment, uint256 usdcAmount)
        private
    {
        (bytes32 payload,, bool ok) =
            $.oracle.latestPayload(payment.tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
        bytes32 expected = keccak256(
            abi.encode(
                payment.paymentId,
                payment.tokenId,
                $.reserves.usdc(),
                payment.payer,
                usdcAmount,
                payment.interest,
                payment.principal,
                payment.nextPaymentDue
            )
        );
        if (!ok || payload != expected) {
            revert Waterfall_PaymentNotAttested(payment.tokenId);
        }
        $.oracle.consume(payment.tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
    }

    /// @dev Protocol fee on gross, then every remaining unit goes to the senior vault.
    function _routeInterest(WaterfallStorage storage $, uint256 interest)
        private
        returns (uint256 fee, uint256 toVault)
    {
        fee = Math.mulDiv(interest, $.protocolFeeBps, Config.BPS);
        toVault = interest - fee;

        // Close the prior fee period and acquire the VAULT's persistent operation lock
        // before either mint. WaterfallEngine's own nonReentrant slot cannot protect a
        // different contract from a callback between mintYield and notifyYield.
        if (toVault != 0) {
            IsUSDfr($.vault).beginYieldNotification();
        } else {
            IsUSDfr($.vault).accrueFees();
        }

        // Each mint is asserted against backing by the controller — interest that
        // never physically arrived in the treasury cannot be distributed.
        if (fee != 0) $.controller.mintYield($.feeRecipient, fee);
        if (toVault != 0) {
            $.controller.mintYield($.vault, toVault);
            // The assets are now in the vault. `notifyYield` either recognizes them and
            // checkpoints performance fees immediately (the zero-period launch policy), or
            // starts optional ADR-0023 vesting. The same-transaction vault lock prevents an
            // observer from checkpointing against the delivery window in either mode.
            IsUSDfr($.vault).notifyYield(toVault);
            // Every realized interest payment ends with an explicit fee checkpoint. With
            // the zero-period launch policy this crystallizes performance immediately;
            // under optional streaming it records only the fee classes already due.
            IsUSDfr($.vault).accrueFees();
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (WaterfallStorage storage $) {
        assembly {
            $.slot := WATERFALL_STORAGE_LOCATION
        }
    }
}
