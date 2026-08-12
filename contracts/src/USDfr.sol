// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IPointsModule} from "./interfaces/IPointsModule.sol";
import {IUSDfr} from "./interfaces/IUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {PointsHookGas} from "./libraries/PointsHookGas.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title USDfr — the Forest Road synthetic dollar
/// @notice Fully-backed ERC-20 (brief Part 4). It does not itself yield. Supply may only
///         change through the MintRedeemController (MINTER_ROLE), which enforces the
///         backing invariant `totalSupply <= backingValue` (ADR-0012); the loss cascade
///         burns are also performed by that controller. Transfers consult an optional
///         compliance module (capability per ADR-0011 — policy is set by governance/
///         counsel; holding/transfer is permissionless unless governance restricts).
/// @dev Nothing in this contract or its documentation characterizes USDfr under
///      securities law; that determination is counsel's (brief Part 0.5).
contract USDfr is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IUSDfr
{
    /// @custom:storage-location erc7201:forestroad.storage.USDfr
    struct USDfrStorage {
        IComplianceRegistry complianceModule;
        // ── append-only (upgrade safety) ──────────────────────────────────
        // Participation-points hook (ADR-0016 / 2026-07-14 directive): USDfr holders accrue
        // points at a governance multiple of the sUSDfr rate, in lieu of yield. Optional;
        // fail-open so a points failure can never block a USDfr transfer.
        IPointsModule pointsModule;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.USDfr")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant USDFR_STORAGE_LOCATION = 0xc3fcf06498ffe1eac01a14cc645fb1e6aacc447c7b2a7d46a005df569b521500;

    error USDfr_ZeroAddress();

    /// @notice The proposed participation-points module has no code (an EOA, a precompile, or
    ///         an address that has not been deployed yet).
    /// @dev AUDIT FIX (C4-USDFR-01). Installing one is a ONE-TRANSACTION TOTAL BRICK of the
    ///      token — see `setPointsModule` for why the fail-open `try` cannot save it.
    error USDfr_PointsModuleNotAContract(address module);

    /// @notice The compliance registry may not be unwired while the token is paused.
    /// @dev AUDIT FIX (C4-USDFR-03). The registry is also the protocol-module directory the
    ///      emergency-pause carve-out is keyed off — see `setComplianceModule`.
    error USDfr_ComplianceModuleRequiredWhilePaused();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the token.
    /// @param admin Governance timelock (DEFAULT_ADMIN_ROLE).
    /// @param minter The MintRedeemController (sole MINTER_ROLE holder).
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (the timelock).
    function initialize(address admin, address minter, address guardian, address upgrader) external initializer {
        if (admin == address(0) || minter == address(0) || guardian == address(0) || upgrader == address(0)) {
            revert USDfr_ZeroAddress();
        }
        __ERC20_init(Config.USDFR_NAME, Config.USDFR_SYMBOL);
        __ERC20Permit_init(Config.USDFR_NAME);
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.MINTER_ROLE, minter);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
    }

    // ── Supply (controller / cascade only) ───────────────────────────────

    /// @inheritdoc IUSDfr
    function mint(address to, uint256 amount) external onlyRole(Roles.MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IUSDfr
    function burn(address from, uint256 amount) external {
        _checkRole(Roles.MINTER_ROLE, msg.sender);
        _burn(from, amount);
    }

    // ── Compliance ───────────────────────────────────────────────────────

    /// @inheritdoc IUSDfr
    function complianceModule() external view returns (address) {
        return address(_storage().complianceModule);
    }

    /// @inheritdoc IUSDfr
    /// @dev AUDIT FIX (C4-USDFR-03) — DO NOT DELETE THE PAUSED CHECK, AND DO NOT RESTORE THE
    ///      OLD "zero = no restriction" CLAIM. The registry is not only a restriction layer:
    ///      it is ALSO the only on-chain directory of protocol modules, and `_update`'s
    ///      emergency-pause carve-out is keyed off that directory. Clearing it therefore does
    ///      the OPPOSITE of removing a restriction — while paused it deletes every exemption
    ///      at once and silently converts a targeted pause into a total freeze of the loss
    ///      cascade. Clearing remains legal while the token is live (that is the documented
    ///      capability, and it does disable the sanctions gate); it is refused only in the one
    ///      state where its effect inverts. Replacing one registry with another stays legal in
    ///      every state, so this can never strand governance.
    function setComplianceModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0) && paused()) revert USDfr_ComplianceModuleRequiredWhilePaused();
        _storage().complianceModule = IComplianceRegistry(module);
        emit ComplianceModuleUpdated(module);
    }

    // ── Points (ADR-0016 / 2026-07-14 directive) ─────────────────────────

    /// @notice The participation-points hook (zero disables it).
    function pointsModule() external view returns (address) {
        return address(_storage().pointsModule);
    }

    /// @notice Sets the participation-points hook (zero disables it). Timelocked governance only.
    /// @dev AUDIT FIX (C4-USDFR-01) — DO NOT DELETE THE CODE CHECK. `IPointsModule.onUSDfrTransfer`
    ///      returns no data, so solc emits an `extcodesize` guard BEFORE the call, and that guard
    ///      reverts OUTSIDE the `try` in `_update`. A CODELESS module — an operator wallet pasted
    ///      by mistake, a precompile, or a module address recorded before it is deployed —
    ///      therefore turns the FAIL-OPEN hook into a FAIL-CLOSED one and bricks EVERY USDfr
    ///      transfer, mint and burn, including the loss cascade's burn leg, in a single
    ///      governance transaction. Recovery would need a second timelocked call. Same guard and
    ///      same reason as `GroveVotesAggregator._requireTimestampClock`.
    ///      `Fix_C4USDfr_PointsBrickAndPauseOutflow.t.sol` pins the bricked state this prevents.
    /// @param module The points ledger, or zero to disable the hook entirely.
    function setPointsModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module != address(0) && module.code.length == 0) revert USDfr_PointsModuleNotAContract(module);
        _storage().pointsModule = IPointsModule(module);
        emit PointsModuleUpdated(module);
    }

    // ── Guardian pause ───────────────────────────────────────────────────

    /// @notice Emergency pause. While paused, USDfr moves ONLY between governance-listed
    ///         protocol modules, and burns ONLY out of one — every user leg is closed in BOTH
    ///         directions (transfer, mint, and the redemption burn), and no mint of any kind is
    ///         permitted. See `_update` for the rule and the reasoning behind each half.
    /// @dev AUDIT FIX (C4-USDFR-02) corrected this NatSpec: it previously read "Protocol-internal
    ///      transfers and burns remain live", which described a code path that let ANY burn
    ///      through, user redemptions included.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @inheritdoc IUSDfr
    /// @dev AUDIT FIX (R18) — this override exists only to put `paused()` on the `IUSDfr` ABI so
    ///      `MintRedeemController.mintableHeadroom()` can READ this pause. It changes no behaviour
    ///      (it is `PausableUpgradeable.paused()` verbatim). The reason it is needed: a token pause
    ///      refuses every MINT here, so before R18 one un-timelocked `USDfr.pause()` reverted
    ///      `MintRedeemController.mintYield` and, because `WaterfallEngine.distribute` is atomic,
    ///      every borrower repayment with it — the harm R17's headroom clamp was built to prevent,
    ///      through the one pause the clamp could not see. Reached through a typed interface rather
    ///      than a locally declared ad-hoc one so the dependency is visible to an auditor.
    function paused() public view virtual override(PausableUpgradeable, IUSDfr) returns (bool) {
        return super.paused();
    }

    /// @notice Unpauses transfers.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Internals ────────────────────────────────────────────────────────

    /// @dev EMERGENCY-PAUSE RULE (AUDIT FIX C4-USDFR-02 — DO NOT WEAKEN, DO NOT RE-ADD A
    ///      `to == address(0)` SHORT-CIRCUIT). While paused, a USDfr balance change is permitted
    ///      only when it is WHOLLY INTERNAL to the protocol: `from` must be a governance-listed
    ///      protocol module, and `to` must be either another listed module or the burn address.
    ///      That is precisely what keeps the loss cascade alive under a pause — `DefaultManager`
    ///      burns from itself or from the vault, and both are listed at deploy (`Deploy.s.sol`
    ///      `setProtocolExempt`, asserted by `Validate.s.sol`).
    ///
    ///      WHAT WAS WRONG: the previous rule skipped the whole branch when `to == address(0)`,
    ///      so it permitted ANY burn. Burns are the protocol's OUTFLOW leg —
    ///      `MintRedeemController.redeem` burns a holder's USDfr and releases the USDC behind
    ///      it, and the controller has its OWN pause, so pausing the token alone left that path
    ///      open. A guardian pausing USDfr in an emergency was therefore closing the inflow
    ///      while first movers kept draining the reserve at par: strictly worse for the holders
    ///      who stayed than not pausing at all.
    ///
    ///      THE REMAINING ASYMMETRY IS DELIBERATE: mints stay closed even to a listed module,
    ///      because a pause must never permit supply EXPANSION. `WaterfallEngine.mintYield` is
    ///      consequently unavailable while the token is paused — that was already true before
    ///      this fix and is retained on purpose.
    ///
    ///      WITH NO REGISTRY WIRED there is no directory, so nothing is exempt and the pause is
    ///      TOTAL, cascade included. That is the safe direction; it is recoverable without
    ///      unpausing (wire a registry), and `setComplianceModule` refuses to unwire one while
    ///      paused so the state cannot be entered by accident.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        USDfrStorage storage $ = _storage();
        IComplianceRegistry module = $.complianceModule;
        if (paused()) {
            bool protocolLeg = from != address(0) && address(module) != address(0) && module.isProtocolExempt(from)
                && (to == address(0) || module.isProtocolExempt(to));
            if (!protocolLeg) revert EnforcedPause();
        }
        if (address(module) != address(0) && !module.canTransfer(address(this), from, to)) {
            revert USDfr_TransferNotAllowed(from, to);
        }
        super._update(from, to, value);
        // Participation-points hook (ADR-0016 / 2026-07-14 directive), FAIL-OPEN: USDfr
        // holders accrue points in lieu of yield, but a points-module failure must never
        // block a USDfr transfer, mint, or burn.
        IPointsModule points = $.pointsModule;
        if (address(points) != address(0)) {
            // F-18-02: caller-selected underfunding is fail-closed. Without a floor, EIP-150
            // can exhaust the hook after its first accounting leg while retaining just enough
            // gas for this catch, committing the financial transfer with both hook writes
            // rolled back. The shared policy also reserves the catch/telemetry epilogue.
            uint256 hookGas = PointsHookGas.hookGasLimit();
            // FAIL-OPEN, but emit telemetry (P-04) so a dropped transition is observable and
            // can be repaired via PointsModule.reconcile.
            try points.onUSDfrTransfer{gas: hookGas}(from, to, value) {}
            catch {
                emit PointsHookFailed(from, to, value);
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (USDfrStorage storage $) {
        assembly {
            $.slot := USDFR_STORAGE_LOCATION
        }
    }
}
