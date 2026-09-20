// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IMintRedeemController, IPausableModule} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {ISeniorExitDrawSource} from "./interfaces/ISeniorExitDrawSource.sol";
import {IUSDfr} from "./interfaces/IUSDfr.sol";
import {IContinuousAccrual} from "./interfaces/IContinuousAccrual.sol";
import {ControllerAccrualLib} from "./libraries/ControllerAccrualLib.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title MintRedeemController
/// @notice The only mint/burn path for USDfr, and the enforcement point of the backing
///         invariant (ADR-0012). Mint/redeem is KYC-gated (ADR-0011); yield-mint and
///         loss-burn are credit-layer paths.
///
/// @dev THIS IS THE BNB SMART CHAIN INSTANCE. READ ADR-0037 BEFORE COMPARING IT WITH THE ETHEREUM
///      FILE, because three structural decisions change what several of the arguments below can
///      mean, and inheriting an Ethereum justification that no longer holds is itself the defect
///      class this file has recorded against itself three times.
///
///      (i) THERE IS NO `SCALE` CONSTANT AND NO WHOLE-UNIT GRID. Scale is PER ASSET and lives in
///          the reserve's ADR-0037 section 4.4 registry as STORAGE, recorded at listing. Both genesis
///          assets are 18-decimal, so their scale is 1 and every grid expression the Ethereum file
///          documents - `usdfrAmount / SCALE`, `(usdfrAmount / SCALE) * SCALE`, `usdcOut * SCALE`,
///          `valueOut / SCALE` - is the IDENTITY FUNCTION here. The paragraphs that justified the
///          grid ("sub-unit dust is never burned", "the precision loss is the POINT") are DELETED
///          rather than ported. They would be stale justifications on a value path, and the next
///          engineer prunes a guard once they discover the reason given for it is untrue.
///          What replaces the grid's holder-protection property is stronger and lives per leg:
///          `units_i = legValue_i / scale_i`, so no leg ever pays out a fraction of that asset's
///          smallest unit, and the difference stays with the holder as UN-BURNED USDfr rather than
///          being taken from them.
///
///      (ii) REDEMPTION IS RECORD-CAPPED, THEN PRO-RATA (D5(d) as amended by ADR-0038 and by the
///          Forest Road direction of 2026-09-07). The reserve pays IN KIND, and it pays THE ASSETS
///          THE REDEEMER THEMSELVES DEPOSITED first, capped by that redeemer's own deposit record;
///          value beyond the record settles as the PRO-RATA BASKET.
///
///          THE WARNING THAT USED TO STAND HERE IS REWRITTEN, NOT DELETED, AND IT CARRIES ITS
///          CONDITION FORWARD. It said there is no function by which a redeemer elects one asset and
///          none may be added, because leg election IS the free option ADR-0037 section 4.1 exists to
///          close. That reasoning is unchanged and FREE ELECTION IS STILL FORBIDDEN. What exists now
///          is not election: the redeemer names nothing, and the reserve pays them back the units
///          they put in, capped by their own record, which is why no round trip can convert an
///          impaired asset into a sound one at the expense of the holders who stay. The CAP is the
///          security property. The record does not move when USDfr is transferred, so a market buyer
///          acquires no record. A recorded asset the reserve cannot fund becomes a DEFERRED CLAIM ON
///          THAT ASSET rather than a basket payment, because paying the basket there would reopen
///          exactly the transfer the cap closes.
///
///          A redeemer who wants a DIFFERENT asset from what they are owed swaps the legs through
///          `BasketRedeemRouter`, a separate, NON-UPGRADEABLE periphery contract, in the redeemer's
///          own transaction, on tokens already in their own wallet. THE PROTOCOL NEVER CALLS A
///          MARKET. This contract holds no router address, no allowance to a router and no
///          single-asset release door, and that absence is a property to be TESTED, not merely
///          observed (`test_FO4_...`).
///
///          THE PRICE THIS CONTRACT NOW READS IS AN ENTRY-SIDE INPUT ONLY. It is read at the mint
///          edge, from reserve STORAGE, through one predicate, and it enters no exit path and no
///          solvency figure. `totalBackingValue()` reads no price and may never read one (ADR-0025,
///          preserved verbatim by ADR-0038's own header).
///
///      (ii-a) THE FREE-OPTION PROPERTY, WRITTEN AS A TESTABLE INVARIANT because ADR-0037 section 4.4 asks
///          for it as a named negative test and an unfalsifiable claim is worth nothing.
///
///            invariant_A38_theRoundTripIsNeverProfitable
///            For any actor A and any interleaving of `mint`, `redeem` and permissioned price
///            pushes, valuing every token movement at the effective price the protocol itself had
///            latched at the moment of that movement:
///                sum value received by A  <=  sum value deposited by A
///
///          It rests on three independent supports, and the test suite must falsify each of them
///          separately by neutralising it and observing the invariant go red:
///            1. THE PAR CAP. `effective = min(latched, 1e18)`, applied in exactly one place in
///               `ReserveStorageLib.effectiveMintPrice`, so the credit `c = floor(g * e / 1e18)`
///               satisfies `c <= g` where `g` is the par value that entered backing.
///            2. THE RECORD CAP. A redeemer draws at most the units they themselves deposited, so
///               no round trip changes WHICH asset A holds, only how much.
///            3. THE PROPORTIONAL REMAINDER. Value beyond the record is paid in the reserve's own
///               mix, which involves no choice and therefore shifts no currency risk.
///          Support 1 is defence in depth on the remainder path and NOT the primary control; the
///          record cap is. Anyone proposing to delete the price as redundant should read support 3
///          again: an over-credited deposit can still extract value through the remainder, and the
///          price is what bounds that.
///
///      (iii) THERE IS NO CASCADE LAYER TWO (D3a(ii)). No sGROVE, no GROVE, no backstop. The
///          junior draw is curator first-loss and nothing else; what it declines is borne by the
///          exiting holder at their own settlement price. Every clause below that reads "curator
///          first-loss and the sGROVE backstop" on the Ethereum instance reads "curator
///          first-loss" here, and the ordering theorem is correspondingly weaker - see
///          `ISeniorExitDrawSource`, which writes it out rather than inheriting it.
///
/// @dev THE SOLVENCY MODEL, IN ONE PLACE. The contract once had exactly ONE solvency predicate,
///      the absolute inequality `totalSupply <= backingValue`, asserted identically after mint,
///      redeem, mintYield and burnLoss. An absolute inequality has only two states and both are
///      wrong once a loss is recognised:
///        - PRETEND. Nothing had recognised the loss yet, so the predicate reported TRUE and the
///          protocol went on issuing and honouring par claims against a hole (R4-01).
///        - FREEZE. Once the loss WAS recognised the predicate reported FALSE and stayed false, and
///          because every supply-affecting path asserted it, EVERY path reverted at once - taking
///          `WaterfallEngine.fund` and `distribute` down with them. Worse, `burnLoss` is the
///          cascade's OWN instrument for absorbing that loss, so the freeze disabled the only
///          mechanism that could have ended it.
///
///      THE REPLACEMENT IS ONE PREDICATE, NOT FOUR. Every supply-affecting path asserts
///      `_assertDeficitNotWorsened`: an operation may not INCREASE
///      `deficit = max(0, totalSupply - backingValue)`.
///        - while the protocol is whole (`deficit == 0`) it reduces EXACTLY to ADR-0012's
///          `totalSupply <= backingValue`, and still reverts `Controller_BackingInvariantViolated`;
///        - while the protocol is short it permits precisely the operations that repair or preserve
///          holders' position and refuses the ones that dilute it.
///      `mint`, `redeem` and `mintYield` all assert it; `burnLoss` is the one path that cannot
///      violate it in any reachable state (see its NatSpec - that is stated as a proof, not
///      asserted as an unfalsifiable guard).
///
/// @dev SUB-PAR REDEMPTION IS THE POINT, AND THE PAR FORM STILL NEVER HAIRCUTS. Freezing
///      redemption was justified on the ground that par exits out of a short pool are a run. That
///      is true of PAR exits and false of exits generally. The three-argument form pays the
///      junior-drawn price, which is at least the coverage ratio: at `backing/supply == 0.97` a
///      holder who names a floor of 0.97 or lower gets 97 cents, and the ratio left behind for
///      everyone who did not redeem is unchanged to the wei-rounding, which always favours the
///      holders who stayed. The one-argument form NEVER pays 97 cents: it settles at PAR or reverts
///      `Controller_ParExitNotAvailable`. On this instance par is expressed as the RELATION
///      `valuePaid == usdfrIn` rather than as a number, because a numeric floor derived from the
///      requested amount cannot survive per-leg flooring across a basket.
///
///      WHILE JUNIOR CAPITAL STANDS, THE PAR FORM SETTLES AT PAR OUT OF THAT CAPITAL.
///      `_drawJuniorForExit` draws curator first-loss forward IN THE SAME TRANSACTION to fund the
///      cascade-ordered price (ADR-0034 Y-bis), so the short state does not by itself close the par
///      exit; it closes only once the draw cannot reach par.
///
///      MINT STAYS CLOSED WHILE SHORT. It is not symmetric with redeem and must not be made so:
///      redeeming at the ratio is the holder's own money at an honest price, whereas minting at par
///      into a short book sells a NEW holder a claim worth less than the dollar they paid, and
///      minting at the ratio would let an insolvent protocol keep issuing. Closed is the only
///      honest answer, and it is the R4-01 finding restated. NOTE THE BASIS: on this instance that
///      gate is measured on `recognizedBackingValue()`, not on the recorded ledger, because the
///      custody predicate is now PER ASSET - see `mint`.
///
/// @dev WHAT THE MEASUREMENTS ARE, AND WHY THEY ARE DELTAS. The non-worsening rule is a BACKSTOP,
///      not the primary measurement: it is a level rule, so a discrepancy is caught only for the
///      part EXCEEDING the standing surplus. The PRIMARY measurements are LEVEL-FREE DELTA
///      EQUALITIES on the operations themselves, and no standing surplus can pay for any of them:
///        - `Controller_DepositNotCustodied`   - the reserve's own token balance really rose;
///        - `Controller_DepositNotRecognized`  - the reserve BOOKED it as backing;
///        - `Controller_MintSupplyNotRecognized` - supply rose by exactly the recognised gross, so
///          the fee is provably CARVED from the credit rather than minted on top;
///        - `Controller_CashStrandedOnController` - the controller is value-neutral at rest;
///        - `Controller_BasketValueMismatch`   - the reserve's own `valuePaid` equals the par value
///          of the units it says it moved, recomputed from the controller's own cached scales.
///
/// @dev THE FAIL-OPEN POINTS HOOK IS A GENERAL HAZARD, AND THE RULE IT PRODUCED IS BINDING.
///      `USDfr._update` fires the participation-points hook inside every mint and every burn. The
///      token wraps it in `try/catch` under a protocol-wide rule that a points-module failure must
///      never block a transfer, mint or burn - but a revert in a CALLER's strict-equality balance
///      window happens OUTSIDE that `try/catch`. One wei moved by that hook once bricked every
///      redemption. GENERAL RULE, for anyone extending this file: no call a redeemer or a
///      governance-set module can influence may sit inside any before/after balance pair. The burn
///      is hoisted above every settlement window for exactly that reason.
///
/// @dev THE COMPOSITE VIEWS REVERT MID-TRANSITION RATHER THAN LYING. `_redeem` burns (supply down)
///      BEFORE the reserve releases (backing down), and `DefaultManager.realizeLoss` burns before
///      it writes backing down. An observer receiving control inside a USDfr balance change read
///      `mintableHeadroom()` as the entire realised loss of a cascade, `backingInvariantHolds()` as
///      TRUE on a short book, and `previewRedeem` as PAR on the same book. Every COMPOSITE view is
///      gated by `_requireSettledState`; the RAW delegating views are deliberately not, because
///      each is a single live read of one module and is true whenever it is read.
///
/// @dev EIP-7702 IS LIVE ON THIS CHAIN. BNB Smart Chain enabled it in the Pascal hard fork
///      (March 2025), so a delegated EOA carries a 23-byte `0xef0100`-prefixed code field on chain
///      56 exactly as it does on L1, and EIP-3541's ban on deploying leading-`0xEF` code holds
///      there too. `setLossSource`'s designator check therefore carries across unchanged and must
///      not be deleted as an L1-only concern.
contract MintRedeemController is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IMintRedeemController
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:forestroad.storage.MintRedeemControllerBSC
    /// @dev THE NAMESPACE IS DELIBERATELY NOT THE ETHEREUM ONE. `MintRedeemControllerBSC` resolves
    ///      to a DIFFERENT ERC-7201 slot, so no tool that reads either deployment by slot can
    ///      confuse one instance's storage for the other's, and a cross-instance layout fixture is
    ///      forced to compare fields rather than accidentally comparing addresses.
    /// @dev Fields are APPEND-ONLY from genesis. This instance may lay the struct out freely once,
    ///      here, and never again: from the first deployment onward a field may only be TAIL
    ///      APPENDED. `tools/check-storage-layout.mjs` must register this namespace.
    struct ControllerStorage {
        IUSDfr usdfr;
        IComplianceRegistry compliance;
        IReserveManager reserves;
        /// @dev Addresses `mintYield` may credit.
        mapping(address account => bool) yieldSink;
        /// @dev Addresses `burnLoss` may burn from.
        mapping(address account => bool) lossSource;
        /// @dev Cumulative value crystallised out of the senior layer by sub-par exits, in
        ///      18-decimal USD. Monotonically non-decreasing. See `seniorSubParShortfall`.
        uint256 subParShortfall;
        // -- BSC tail (ADR-0037 section 4.4) --------------------------------------
        /// @dev Recipient of the per-asset mint fee. The RATE is per-asset reserve storage; only
        ///      the destination is controller-level. See `setMintFeeRecipient`.
        address mintFeeRecipient;
        // ── PAIRED-YIELD BASELINE (2026-09-09) ───────────────────────────
        // APPENDED AFTER `mintFeeRecipient`, WHICH IS THE TRUE TAIL ON THIS INSTANCE. The first
        // attempt put these above it, mirroring the Ethereum tree where `subParShortfall` IS the
        // tail, and that displaced the BSC-only field by four slots.
        // `test_controllerLayoutMatchesLiveStorage` caught it immediately, reading
        // `mintFeeRecipient` as the zero address. The two trees' tails differ (ADR-0037 section
        // 4.4); append to THIS one's.
        /// @dev The CREDIT_ROLE caller that opened a paired-yield operation, or zero.
        ///
        ///      THIS IS NOT A SAME-TRANSACTION LOCK, and an earlier version of this note wrongly
        ///      called it one. Nothing in the EVM clears persistent storage at transaction end, so a
        ///      baseline opened and not consumed OUTLIVES its transaction, and because the deficit is
        ///      not monotone a baseline taken while a mark stood is a strictly LOOSER baseline for a
        ///      later mint. An adversarial review demonstrated one surviving 5,000 blocks and 30 days.
        ///
        ///      WHAT MAKES IT SAFE TODAY is the wiring, not the storage: `WaterfallEngine` is the
        ///      only CREDIT_ROLE holder on this contract, `capitalizePik` is the only opener, and it
        ///      contains no try/catch and reaches `mintYield` unconditionally, so no baseline can
        ///      survive its transaction. That is an argument about the CALLER, so it must be
        ///      re-made if CREDIT_ROLE is ever granted to anything else.
        ///
        ///      AND NOTHING ENFORCES EXCLUSIVITY. An earlier version of this note said
        ///      "`Validate.s.sol` asserts the holder set", which is not true and cannot be: no
        ///      contract in `src/` inherits `AccessControlEnumerable`, so role membership is not
        ///      enumerable on chain at all. `Validate.s.sol` asserts one positive (the engine holds
        ///      it) and three named negatives. A single `grantRole` to a fourth address would
        ///      restore the hazard and no gate would notice. EIP-1153 transient storage is the
        ///      structural answer and is the right fix the day solc's 2394 composability warning
        ///      can be triaged without blanket-suppressing it for every future `tstore`; suppressing
        ///      it now would stop `deny_warnings` catching any future misuse.
        address pairedYieldCaller;
        /// @dev Supply, recorded backing and recognised backing as at the START of the paired
        ///      operation, BEFORE the caller moved backing.
        uint256 pairedSupplyBefore;
        uint256 pairedBackingBefore;
        uint256 pairedRecognizedBefore;
        /// @dev Explicit, one-time opt-in to the bound reserve's continuous accounting.
        IContinuousAccrual accrual;
        /// @dev Retention requirement when the current paired operation opened; append-only.
        uint256 pairedRetentionBefore;
    }

    /// @notice Economic and physical measurements at an ordinary deposit's start.
    struct MintBaseline {
        uint256 supply;
        uint256 backing;
        uint256 rawSupply;
    }

    /// @notice Continuous accounting can be bound only once.
    error Controller_AccrualAlreadyBound();
    /// @notice Delivery cannot overlap a legacy paired-yield operation.
    error Controller_AccrualDuringPairedYield();
    /// @notice This controller has opted into its configured reserve's accrual accounting.

    event ContinuousAccrualBound(address indexed reserve);
    /// @notice A reserve-owned delivery permit was relayed to USDfr.
    event AccruedDeliveryRelayed(uint256 indexed nonce);

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.MintRedeemControllerBSC")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONTROLLER_STORAGE_LOCATION =
        0x5d4a57a5a7d4ad5440b982e7b9ce31a13be87e4a3f36d6c009e37d56362e8300;

    /// @dev Basis-point denominator for the per-asset mint fee.
    uint256 private constant BPS = 10_000;

    /// @dev Par, in the protocol's 18-decimal value language, and the denominator of the priced
    ///      mint. It is the SAME constant `ReserveStorageLib.effectiveMintPrice` caps against; the
    ///      cap itself is applied THERE and never here, so this contract can multiply by a price it
    ///      knows is already at or below par and cannot skip the cap by arithmetic of its own.
    uint256 private constant ONE = 1e18;

    /// @notice Cached reserve and holder-record values used by quote and settlement checks.
    /// @dev All inputs come from storage-backed reserve getters, without reading token contracts.
    /// @param tokens The full registry in listing order.
    /// @param scale Per-asset normalization recorded at listing.
    /// @param payableValue Per-leg payable value; reviewed currencies have zero weight. During
    ///        review, outstanding pending claims are also reserved out of this liquidity snapshot.
    /// @param totalPayable Sum of the permitted liquidity values.
    /// @param grossPayable Normal basket's gross idle value, including frozen legs. For an admitted
    ///        recorded exit during review it equals totalPayable, avoiding a pooled-claim haircut.
    /// @param pendingAsset The first reviewed currency when admission is refused, otherwise zero.
    /// @param recordUnits The caller's remaining deposit records during review, otherwise empty.
    /// @param recordValue Value of the records collected by the admission check.
    struct Basket {
        address[] tokens;
        uint256[] scale;
        uint256[] payableValue;
        uint256 totalPayable;
        uint256 grossPayable;
        address pendingAsset;
        uint256[] recordUnits;
        uint256 recordValue;
    }

    /// @dev THE IMPLEMENTATION INITIALISER LOCK - LOAD-BEARING, DO NOT DELETE. Without it the
    ///      logic contract behind the proxy is initialisable by anyone, which is finding A-01's
    ///      shape and the house convention every other implementation in `contracts/src` follows.
    ///      AUDIT NOTE (R18): R17's 63-guard deletion campaign did NOT enumerate this line, and it
    ///      survived the full non-fork suite when deleted - which also falsified R17's claim, made
    ///      on `mint`, that "every other guard in this file reds".
    ///      `test_R18_G64_theImplementationInitialiserIsLocked` is the falsifier that was missing.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the controller.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param usdfr The USDfr token (this contract must hold its MINTER_ROLE).
    /// @param compliance The compliance registry (KYC gate).
    /// @param reserves The ReserveManager (this contract must hold its CONTROLLER_ROLE).
    /// @param feeRecipient Destination for the per-asset mint fee (ADR-0037 section 4.4).
    /// @dev THE FEE RECIPIENT IS AN INITIALISER ARGUMENT, NOT A LATER SETTER CALL, so a freshly
    ///      initialized controller is never in a state where a non-zero per-asset fee has nowhere to
    ///      go. `mint` fails CLOSED on an unset recipient rather than silently skipping the fee, and
    ///      a fail-closed mint on a fresh deployment is a worse first impression than a required
    ///      constructor argument.
    /// @dev The credit-layer endpoint maps (`setYieldSink`, `setLossSource`) start EMPTY, so a
    ///      freshly initialized controller can mint no yield and burn no loss until governance
    ///      names the endpoints. That is deliberate fail-closed wiring (CLAUDE.md prime
    ///      directive 4). `Validate` asserts the production wiring post-deploy, including
    ///      `modules()` and this recipient - Cantina 3.1.2 (codeless module wiring) is NOT closed by
    ///      adding code checks here; its mitigation is the deployment manifest and post-deploy
    ///      validation.
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address usdfr,
        address compliance,
        address reserves,
        address feeRecipient
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr == address(0)
                || compliance == address(0) || reserves == address(0) || feeRecipient == address(0)
        ) revert Controller_ZeroAddress();
        // CANTINA 3.1.2. Non-zero was not enough; see `Controller_ModuleNotResponding`.
        _requireModuleResponds(usdfr, abi.encodeWithSignature("totalSupply()"));
        _requireModuleResponds(reserves, abi.encodeWithSignature("recognizedBackingValue()"));
        _requireModuleResponds(compliance, abi.encodeWithSignature("isAllowed(address)", address(0)));
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        ControllerStorage storage $ = _storage();
        $.usdfr = IUSDfr(usdfr);
        $.compliance = IComplianceRegistry(compliance);
        $.reserves = IReserveManager(reserves);
        $.mintFeeRecipient = feeRecipient;
        emit MintFeeRecipientUpdated(address(0), feeRecipient);
    }

    // -- User paths (KYC-gated) -------------------------------------------

    /// @inheritdoc IMintRedeemController
    /// @dev THE ORDER OF CHECKS IS NORMATIVE AND THE STEP LABELS BELOW ARE THE SPECIFICATION. Read
    ///      the body against them; a reordering that looks harmless is usually not.
    ///
    ///      M6 MEASURES THE LEVEL GATE ON THE RECOGNITION-AWARE BASIS, AND THE CHANGE IS NOT
    ///      COSMETIC - DO NOT "ALIGN" IT WITH `_supplyAndBacking`'s RECORDED READING. The custody
    ///      predicate on this instance is PER ASSET (M4), because ADR-0037 section 4.4 requires that a
    ///      paused or broken secondary token cannot brick the sound asset's door - the R2-M-03 brick
    ///      class. But once the predicate is per asset, a shortfall in asset B is no longer caught
    ///      ANYWHERE on a mint of asset A, and minting into a book with a hole in it is R4-01
    ///      verbatim ("sells a new claim on a hole"). Measuring the level gate on
    ///      `recognizedBackingValue()` nets EVERY asset's observed shortfall, so a global hole closes
    ///      mint in every asset while the per-asset predicate closes the specific asset. That is
    ///      exactly the separation ADR-0037 section 4.4 demands between "accepted for mint" and "recognized
    ///      backing value". M12 stays on the RECORDED basis because it is a DELTA equality on the
    ///      quantity the reserve actually moved; mixing bases across a delta would make the guard
    ///      fire on an unrelated asset's shortfall moving inside the window.
    ///
    ///      M7 MUST PRECEDE THE DEPOSIT, AND ITS REASON CHANGED ON 2026-09-08. It used to be an
    ///      ordering trap: backing counted `min(tally, cap)`, so a deposit past the cap raised
    ///      `totalBackingValue()` by LESS than `grossValue` and M12's recognition equality would
    ///      fire on the HONEST path unless M7 refused first. That clamp is gone - backing now counts
    ///      `tally - recognizedCapLoss` - so an over-cap deposit would be recognised in full and M12
    ///      would be satisfied. M7 IS NOT THEREFORE REDUNDANT: it is now the ONLY thing enforcing
    ///      the ceiling on the mint side, which is the whole of what the ceiling still means. It
    ///      stays ahead of the deposit so the refusal is a named cap error rather than a rollback
    ///      diagnosed one module away.
    ///
    ///      A KNOWN, DECODED-ELSEWHERE EDGE, STATED RATHER THAN PAPERED OVER. The reserve carries
    ///      `recognizedCapLoss` per asset (a cap cut below the standing tally, recognised as a
    ///      permanent mark that a later cap RAISE does not restore). If redemptions then drain that
    ///      asset's tally below its recognised cap loss, a fresh deposit raises the asset's BACKING
    ///      CONTRIBUTION by less than the credited value, and this mint is refused by M12's
    ///      `Controller_DepositNotRecognized` rather than by a named cap error. The refusal is
    ///      correct and fail-closed - the protocol declines to mint a claim it has not recognised -
    ///      but the diagnosis is one module away, and the cure (a recapitalisation that restores the
    ///      tally, or governance releasing the mark) belongs to the reserve.
    ///
    ///      THE INDEPENDENT DELIVERY CHECK - DO NOT DELETE. `mint` must not derive BOTH sides of its
    ///      own safety check from the same module. A reserve that credited its ledger without taking
    ///      custody of the cash - a skimming implementation, a fee-on-transfer or blocklisting token,
    ///      a botched upgrade - would satisfy both sides with the money missing. The controller
    ///      measures the RESERVE'S OWN TOKEN BALANCE across the call, which is a fact no reserve
    ///      function can report about itself.
    ///
    ///      RECOGNITION IS MEASURED TOO - DO NOT DELETE `Controller_DepositNotRecognized`. Custody
    ///      and the reported credit say nothing about whether the reserve BOOKED the deposit as
    ///      backing, and the only thing that would otherwise cover recognition is the NON-WORSENING
    ///      rule, which silently pays for any gap up to the standing surplus.
    ///
    ///      SUPPLY IS MEASURED TOO, AND THAT GUARD IS NEW HERE - DO NOT DELETE
    ///      `Controller_MintSupplyNotRecognized`. M13 issues TWO mints where the Ethereum path
    ///      issues one, and nothing above it measures SUPPLY. `USDfr._update` fires the deliberately
    ///      fail-open participation-points hook inside every mint, and a fail-open hook inside a
    ///      measurement window changes what the window means. One `totalSupply()` delta equality
    ///      across both mints makes "the fee is carved, not added" falsifiable in one line rather
    ///      than an inference from reading two `mint` calls.
    ///
    ///      THE ALLOWANCE IS ZEROED, AND IT IS NOT A FALSIFIABLE GUARD - READ IT AS HYGIENE. The
    ///      guard that catches a reserve sourcing the deposit elsewhere is the zero-DELTA check on
    ///      this contract's own balance (`Controller_CashStrandedOnController`), not the
    ///      `forceApprove(..., 0)`. The zeroing is kept for one reason only: so that tokens DONATED to
    ///      this contract after the fact cannot be pulled out by the reserve on a stale approval.
    ///      Do not dress it up as protection; that distinction is the whole of finding M6.
    ///
    ///      SLITHER `reentrancy-balance` FIRES HERE AND IS ACCEPTED: a balance read straddles an
    ///      external call and gates a state change, which IS the guard, not an accident. Three
    ///      things bound it - the function is `nonReentrant`; both genesis assets are plain ERC-20s
    ///      with no transfer callback; and the check is an EQUALITY, so the manipulation direction is
    ///      fail-CLOSED (an unsolicited donation to the reserve mid-call makes `delivered` EXCEED
    ///      `assetAmount` and the mint reverts). The only manipulation that passes is one in which
    ///      the attacker funds the missing cash themselves, which is not an attack. This paragraph
    ///      IS the triage and must be transcribed into `STATE.md` at merge (CLAUDE.md section 3.2).
    function mint(address asset, uint256 assetAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdfrOut, uint256 feeOut)
    {
        return _mint(asset, assetAmount, 0, true);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE CANONICAL FORM. Both bounds are required and neither substitutes for the other:
    ///      `minUsdfrOut` bounds the PRICE, `deadline` bounds the TIME. The deadline is checked
    ///      FIRST, above every other read, so an expired call costs the caller nothing beyond
    ///      calldata.
    /// @dev THE TWO-ARGUMENT `mint(address,uint256,uint256)` IS NOT SHIPPED, for the same reason the
    ///      two-argument `redeem` is not: a price-bounded but not time-bounded operation is Cantina
    ///      3.1.5's shape, and a new instance has no caller written against it, so not shipping it
    ///      closes that finding BY CONSTRUCTION rather than by disclosure. Do not add it.
    function mint(address asset, uint256 assetAmount, uint256 minUsdfrOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdfrOut, uint256 feeOut)
    {
        // M1b - first, so an expired call reverts before any read.
        if (block.timestamp > deadline) revert Controller_DeadlinePassed(deadline, block.timestamp);
        return _mint(asset, assetAmount, minUsdfrOut, false);
    }

    /// @dev THE SINGLE MINT BODY behind both external forms. `requirePar` selects the equality form
    ///      (settle at par or revert) over the bounded form; it is the entry-side mirror of
    ///      `_redeem`'s own `requirePar`, and the two are deliberately the same shape.
    ///
    ///      THE RECOGNITION EQUALITY, WRITTEN AS THE PROOF IT IS. This is the property that makes a
    ///      wrong price a griefing problem rather than a solvency break, so it is stated here, at
    ///      the site, with the line that makes each step true.
    ///
    ///        Claim. For every successful mint, `delta totalSupply == c` and `delta totalBackingValue == g`
    ///        and `c <= g`, hence `delta totalSupply <= delta totalBackingValue`. THE CREDIT CAN NEVER
    ///        EXCEED THE INCREASE IN BACKING.
    ///
    ///        Step 1, `delta totalBackingValue == g`, MEASURED and not assumed. `_custodyDeposit`
    ///        asserts that the reserve credited exactly `g` (`Controller_DepositNotCustodied`) and
    ///        then measures `backingAfter - backingBefore == g`
    ///        (`Controller_DepositNotRecognized`). Both are equalities, so both fail closed in BOTH
    ///        directions: an under-booking reserve and an over-booking reserve are equally refused.
    ///        `totalBackingValue()` is storage-only and contains no price term, which is what makes
    ///        `g` the correct par figure.
    ///
    ///        Step 2, `c <= g`. `e = min(latched, 1e18)` by the par cap applied inside
    ///        `effectiveMintPrice` and nowhere else, so `e <= ONE`. `Math.mulDiv(g, e, ONE)` is the
    ///        exact `floor(g * e / 1e18)` on a 512-bit intermediate and is monotone in its second
    ///        argument, so `c <= floor(g * ONE / ONE) = g`. There is no overflow path by which `c`
    ///        could exceed `g`: `mulDiv` reverts rather than wrapping.
    ///
    ///        Step 3, `delta totalSupply == c`. M13 measures the supply delta across BOTH mints and
    ///        reverts unless it equals `c`. It is a measurement, not an inference, and that matters
    ///        because `USDfr._update` fires the deliberately fail-open points hook inside every
    ///        mint: a hook that minted or burned inside the window breaks the equality and reverts.
    ///
    ///        Step 4. `delta deficit = c - g <= 0`, so a mint weakly REDUCES the deficit and M14 holds
    ///        on the honest path as a tautology.
    ///
    ///        Step 5, what a wrong price can and cannot do. TOO LOW: `c < g`, the depositor is
    ///        under-credited and the difference stays in the reserve as backing with no matching
    ///        supply, so every standing holder is better off. That is a fairness and griefing
    ///        problem, bounded below by the per-asset floor, which refuses the mint outright rather
    ///        than crediting an absurd fraction. TOO HIGH: `e` is capped at par, so `c == g` and the
    ///        mint is bit-for-bit the behaviour every existing test already proves safe. The par cap
    ///        is therefore not merely a bound; it makes the price a NON-CRITICAL input on the mint
    ///        path, so extending the attester set's authority to it does not extend it in the
    ///        solvency direction.
    ///
    ///        Step 6, the mutations this proof depends on, each of which needs its own falsifier:
    ///        removing the par cap; applying the cap after the multiply; minting the fee ON TOP of
    ///        `c` rather than carving it out; changing M12 to compare against `c` instead of `g`.
    ///
    ///      DO NOT CHANGE M12 TO COMPARE AGAINST THE PRICED CREDIT. Someone will propose it on the
    ///      reasonable-sounding ground that the mint should recognise what it credited. It is a
    ///      defect twice over. First it would red the HONEST path, because the reserve genuinely
    ///      books the deposit at PAR: `depositAssetFor` credits `amount * scale` and backing counts
    ///      every asset at par by construction (ADR-0037 D4, which ADR-0038's own header leaves
    ///      standing). Second, and worse, it would destroy the inequality the whole design rests on:
    ///      the safety property is `c <= deltabacking`, and turning the measurement into `deltabacking == c`
    ///      collapses the slack that IS the protection. The slack is not an accounting discrepancy
    ///      to be tidied away; it is the depositor's discount accruing to the protocol.
    ///
    ///      THE ONE GUARD WHOSE EXPECTED VALUE CHANGES IS M13, from `grossValue` to `priced`.
    ///      `Controller_DepositNotCustodied`'s `credited != grossValue` limb stays on `grossValue`:
    ///      it measures token custody, which has nothing to do with price.
    ///
    ///      THE PRICE MULTIPLIES THE 18-DECIMAL VALUE, NEVER THE NATIVE UNITS. `g = a * scale`
    ///      absorbs the asset's scale BEFORE the price is applied, so no new per-asset scale
    ///      interaction is created and the pricing arithmetic is identical at every decimals
    ///      setting. Anyone writing `a * p / 1e18` reintroduces the class of bug `BscConfig`
    ///      records against itself, where an Ethereum-shaped constant would have credited a
    ///      thousand billion times the deposited value on the first mint.
    ///
    ///      WHY M2 AND M7b ARE TWO STATICCALLS AND THAT IS ACCEPTABLE HERE. This file's doctrine is
    ///      that N reads across N calls can observe N different states. Both of these read the SAME
    ///      contract's storage, back to back, inside a `nonReentrant` function, BEFORE any external
    ///      token call, so there is no interleaving point at which reserve storage could change
    ///      between them. The alternative, folding the price into `ReserveAssetView`, was rejected
    ///      because it changes the `assetRecords()` ABI that `_payableBasket` and the dashboard
    ///      decode positionally, and because no function that reads a `ReserveAsset` may read a
    ///      price at all. Do not "fix" this in either direction without reading both reasons.
    function _mint(address asset, uint256 assetAmount, uint256 minUsdfrOut, bool requirePar)
        private
        returns (uint256 usdfrOut, uint256 feeOut)
    {
        ControllerStorage storage $ = _storage();
        _requireAccrualFresh($);
        // M1
        _requireKYC($, msg.sender);
        // M2 - one staticcall, cached in memory, so the cap, the scale and the fee are all read
        // from ONE state and cannot be composed across two.
        IReserveManager.ReserveAssetView memory row = $.reserves.assetRecord(asset);
        if (!row.listed) revert Controller_AssetNotListed(asset);
        // M3
        if (row.frozenMint) revert Controller_AssetMintFrozen(asset);
        // M4 - PER ASSET. See this function's NatSpec and `_requireCustodiedAsset`.
        _requireCustodiedAsset($, asset);
        // M5
        if (assetAmount == 0) revert Controller_ZeroAmount();

        // M6
        MintBaseline memory before_ = _mintBaseline($);
        {
            uint256 recognizedBefore = $.reserves.recognizedBackingValue();
            if (before_.supply > recognizedBefore) {
                revert Controller_MintClosedWhileUnderBacked(before_.supply, recognizedBefore);
            }
        }

        // M7 - the per-asset cap, on the PAR-VALUED tally, BEFORE the deposit.
        uint256 grossValue = assetAmount * row.scale;
        {
            uint256 parBefore = row.units * row.scale;
            if (parBefore + grossValue > row.cap) {
                revert Controller_AssetCapExceeded(asset, parBefore, grossValue, row.cap);
            }
        }

        // M7b - THE PRICE, read from reserve STORAGE through the reserve's single predicate. It
        // sits AFTER the cap because the cap is a property of the par-valued tally and is entirely
        // independent of price: a mint that would breach the cap should say so whatever the price
        // is. It sits BEFORE the fee because the fee's base changes, and BEFORE custody above all,
        // because a dead price must refuse before the minter's tokens are pulled rather than
        // leaving the whole deposit frame to unwind for a condition knowable in advance.
        uint256 effective;
        {
            bool live;
            uint8 reason;
            (effective, live, reason,,,) = $.reserves.mintPriceQuote(asset);
            // NEVER A FALLBACK TO PAR. Every breach is a refusal; see the error's own NatSpec.
            if (!live) revert Controller_ReservePriceNotLive(asset, reason, effective);
        }

        // M7c - the priced credit. `effective` is already capped at par inside the reserve, so this
        // multiplication can only ever reduce the credit relative to the par value that entered
        // backing. Floors, as every value-side rounding in this file floors: the wei goes to the
        // holders who stayed.
        uint256 priced = Math.mulDiv(grossValue, effective, ONE);
        if (priced == 0) revert Controller_MintTooSmallAfterPricing(assetAmount, effective);
        // The par form supplies an EQUALITY, not a number: it settles only at par, which is what
        // makes it safe without a deadline.
        if (requirePar && priced != grossValue) revert Controller_ParMintNotAvailable(asset, effective);

        // M8 - the fee is CARVED from the PRICED CREDIT. Rounded UP, toward the protocol and the
        // holders who stayed: down-rounding would let a dust mint be fee-free and let a splitter
        // mint N times to pay nothing, and up-rounding costs the minter at most one wei.
        //
        // THE BASE IS `priced`, NOT `grossValue`, AND THAT IS NOT A PREFERENCE. It keeps M13 an
        // equality on ONE basis, so "the fee is carved, not added" stays falsifiable in one line;
        // charging on the gross while crediting the priced amount would assemble the supply delta
        // from two bases, which is the defect shape this file names elsewhere. It is also the only
        // honest base: charging on the gross makes the EFFECTIVE fee rate rise as the asset falls,
        // which nothing decided and nobody could explain to a depositor.
        feeOut = Math.mulDiv(priced, row.mintFeeBps, BPS, Math.Rounding.Ceil);
        usdfrOut = priced - feeOut;
        if (usdfrOut == 0) revert Controller_MintTooSmallAfterFee(assetAmount, feeOut);
        address recipient = $.mintFeeRecipient;
        if (feeOut != 0 && recipient == address(0)) revert Controller_MintFeeRecipientUnset();
        // M8b - the caller's own price bound, checked BEFORE custody. One check is correct here and
        // a post-settlement sibling would have no state it could catch: `usdfrOut` is COMPUTED from
        // values all read above, and nothing between here and M13 can change it. What proves the
        // computed number was actually issued is M13, which is a MEASUREMENT. The asymmetry with
        // `_redeem`, where R14 is the binding check, is deliberate and is explained there.
        if (!requirePar && usdfrOut < minUsdfrOut) revert Controller_SlippageExceeded(usdfrOut, minUsdfrOut);

        // M9-M12 - custody, stranding and recognition, all measured. Extracted into its own frame
        // so the measurement locals do not compete with the pricing locals for stack slots; the
        // ORDER and the checks are unchanged. See `_custodyDeposit`.
        _custodyDeposit($, asset, assetAmount, grossValue, before_.backing);

        // M13 - the two mints, then the SUPPLY delta equality that proves the fee was carved.
        $.usdfr.mint(msg.sender, usdfrOut);
        if (feeOut != 0) $.usdfr.mint(recipient, feeOut);
        {
            uint256 supplyAfter = $.usdfr.totalSupply();
            uint256 supplyRise = supplyAfter < before_.rawSupply ? 0 : supplyAfter - before_.rawSupply;
            // THE EXPECTED VALUE IS THE PRICED CREDIT, and this is the ONLY guard in the function
            // whose expected value moved under ADR-0038. See this function's NatSpec, step 3.
            if (supplyRise != priced) revert Controller_MintSupplyNotRecognized(priced, supplyRise);
        }

        // M14 - the backstop. On the honest path backing rose by `grossValue` and supply by
        // `priced <= grossValue`, so the deficit is unchanged or SMALLER. It was a tautology before
        // pricing and it is a weak inequality now; either way it can only fire on a defect.
        _assertDeficitNotWorsened($, before_.supply, before_.backing);
        // M15 - the effective price is carried so an indexer can still reconstruct the credit:
        // `assetIn * scale` is what entered backing, `usdfrOut + feeOut` is what entered supply, and
        // under ADR-0038 those differ.
        emit Minted(msg.sender, asset, assetAmount, usdfrOut, feeOut, effective);
        if (feeOut != 0) emit MintFeeCharged(msg.sender, asset, feeOut, recipient);
    }

    /// @dev M9-M12 OF `mint`, IN THEIR OWN FRAME - EXTRACTED FOR STACK DEPTH, NOT SIMPLIFIED. Every
    ///      check and every ordering is exactly as `mint`'s NatSpec sets them out; read that block,
    ///      not this one, for why each exists. The extraction is safe because this helper takes no
    ///      decision: it either completes the deposit leg or reverts.
    /// @param $ Controller storage.
    /// @param asset The listed reserve asset.
    /// @param assetAmount Native units to pull from the minter.
    /// @param grossValue `assetAmount * scale`, the value the reserve must credit AND recognise.
    /// @param backingBefore `totalBackingValue()` read before this leg, on the RECORDED basis.
    function _custodyDeposit(
        ControllerStorage storage $,
        address asset,
        uint256 assetAmount,
        uint256 grossValue,
        uint256 backingBefore
    ) private {
        // M9
        IERC20 token = IERC20(asset);
        uint256 custodyBefore = token.balanceOf(address($.reserves));
        // A DELTA, NOT AN ABSOLUTE BALANCE, AND THE DIFFERENCE IS LOAD-BEARING. Anyone can send a
        // reserve asset to this contract at any time, so a guard written as `balanceOf(this) != 0`
        // would let one wei of donated cash brick `mint` for everyone, permanently.
        uint256 selfBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), assetAmount);
        token.forceApprove(address($.reserves), assetAmount);
        // THE RECORD IS CREDITED TO THE MINTER, NEVER TO THIS CONTRACT, AND THE TWO ADDRESSES ARE
        // SEPARATE PARAMETERS PRECISELY BECAUSE THEY DIFFER HERE. `from` is the transfer leg, which
        // on the mint path is the controller holding the pulled units for one call; `holder` is the
        // depositor whose record grows. Passing `address(this)` for both would credit every mint's
        // record to the controller and leave real depositors with none, which would silently turn
        // the record-capped exit into a pure basket exit for everybody and hand the controller a
        // record it must never have.
        uint256 credited = $.reserves.depositAssetFor(asset, address(this), msg.sender, assetAmount);
        // Stale-approval hygiene, not protection. See `mint`'s NatSpec.
        token.forceApprove(address($.reserves), 0);

        // M10 - the clamp is not decoration: a reserve that takes the charge and forwards MORE than
        // it took makes its own balance FALL across the call, and without the clamp that state is an
        // arithmetic panic instead of a named error.
        uint256 custodyAfter = token.balanceOf(address($.reserves));
        uint256 delivered = custodyAfter < custodyBefore ? 0 : custodyAfter - custodyBefore;
        if (delivered != assetAmount || credited != grossValue) {
            revert Controller_DepositNotCustodied(asset, assetAmount, delivered, credited);
        }
        // M11 - an EQUALITY on the delta, so it is fail-closed in BOTH directions: the charge
        // staying here is refused, and so is the reserve pulling MORE out of this contract than it
        // was approved for.
        uint256 selfAfter = token.balanceOf(address(this));
        if (selfAfter != selfBefore) revert Controller_CashStrandedOnController(asset, selfBefore, selfAfter);

        // M12 - the RECOGNITION leg, a DELTA equality no standing surplus can absorb, fail-closed in
        // both directions so an OVER-booking reserve is refused too.
        uint256 backingAfter = $.reserves.totalBackingValue();
        uint256 recognised = backingAfter < backingBefore ? 0 : backingAfter - backingBefore;
        if (recognised != grossValue) revert Controller_DepositNotRecognized(asset, grossValue, recognised);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev IT ANSWERS `(0, 0)` FOR EVERY STATE IN WHICH THE MINT CANNOT EXECUTE, which is the same
    ///      contract `previewRedeem` publishes and exists for the same reason: a view that quotes a
    ///      settleable-looking number for a call that reverts is the contract contradicting itself
    ///      inside one block (Cantina 3.1.3's class, and R4-01's standard). It deliberately does NOT
    ///      read `msg.sender`'s KYC status - the quote is a property of the protocol, not of the
    ///      caller, and a frontend asks the compliance registry directly.
    function previewMint(address asset, uint256 assetAmount) external view returns (uint256 usdfrOut, uint256 feeOut) {
        _requireSettledState();
        ControllerStorage storage $ = _storage();
        if (!_accrualAvailable($) || paused() || $.usdfr.paused() || assetAmount == 0) return (0, 0);
        IReserveManager.ReserveAssetView memory row = $.reserves.assetRecord(asset);
        if (!row.listed || row.frozenMint) return (0, 0);
        if ($.reserves.idleCustodyShortfallOf(asset) != 0) return (0, 0);
        uint256 scale = row.scale;
        uint256 grossValue = assetAmount * scale;
        if (row.units * scale + grossValue > row.cap) return (0, 0);
        if (_effectiveSupply($) > $.reserves.recognizedBackingValue()) return (0, 0);
        // THE SAME PREDICATE THE MINT CONSUMES, in the same order as the mint body. It must never
        // grow a second liveness test of its own: two enumerations of one predicate are two places
        // for the quote and the settlement to disagree, which is the contract contradicting itself
        // inside one block.
        (uint256 effective, bool live,,,,) = $.reserves.mintPriceQuote(asset);
        if (!live) return (0, 0);
        uint256 priced = Math.mulDiv(grossValue, effective, ONE);
        if (priced == 0) return (0, 0);
        feeOut = Math.mulDiv(priced, row.mintFeeBps, BPS, Math.Rounding.Ceil);
        usdfrOut = priced - feeOut;
        if (usdfrOut == 0) return (0, 0);
        if (feeOut != 0 && $.mintFeeRecipient == address(0)) return (0, 0);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THIS IS THE PAR FORM AND IT SUPPLIES AN EQUALITY, NOT A NUMBER - DO NOT "SIMPLIFY" IT TO
    ///      `_redeem(usdfrAmount, 0, false)`. On the Ethereum instance the par floor is the number
    ///      `usdfrAmount / SCALE`, and that form is safe there because the payout can never exceed
    ///      `usdfrIn / SCALE`, so the floor equals the maximum achievable payout. THAT PROOF DOES
    ///      NOT SURVIVE THE BASKET: per-leg flooring means `valuePaid` can fall a few wei short of
    ///      `usdfrIn` on a perfectly healthy book, so a numeric par floor derived from the REQUESTED
    ///      amount would revert the ordinary par exit. Par is therefore expressed as the relation it
    ///      actually is - the caller received, in value, exactly what they burned - and asserted as
    ///      `valuePaid == usdfrIn` after settlement.
    /// @dev NO DEADLINE ON THIS FORM, AND THE REASON IS THE SAME ONE ADR-0034 GIVES: a held
    ///      transaction sells no option when any downward move REVERTS rather than settling worse.
    ///      The three-argument form is the one that accepts a worse price and therefore the one that
    ///      needs a time bound.
    function redeem(uint256 usdfrAmount)
        external
        nonReentrant
        whenNotPaused
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valuePaid)
    {
        return _redeem(usdfrAmount, 0, true);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE DEADLINE (ADR-0034 W) - LOAD-BEARING, DO NOT DELETE, AND THIS IS THE CANONICAL FORM.
    ///      A minimum-out bounds the PRICE but not the TIME: a transaction that sits in the mempool
    ///      executes at whatever ratio holds whenever a builder chooses to include it, and every
    ///      path that moves that ratio down is UNTIMELOCKED and publicly visible before it lands -
    ///      `recordPrincipalWritedown` (CREDIT_ROLE, keeper-driven), `reconcileIdleUnits`
    ///      (permissionless), and a timelock's own `recognizePrincipalImpairment`, whose ready
    ///      transactions anyone may execute. A redeemer who set `minValueOut` at a healthy mark and
    ///      was not included for an hour hands a searcher a free option: hold the transaction until
    ///      the ratio moves, then include it.
    ///
    ///      THE JUSTIFICATION IS STRONGER ON THIS CHAIN, NOT WEAKER. BNB Smart Chain has roughly
    ///      0.45-second blocks and two dominant builders, so mempool-holding is cheaper there than
    ///      on L1. The same note that tells the router's transaction to use a private relay applies
    ///      to this leg.
    ///
    ///      THE TWO-ARGUMENT FORM IS NOT SHIPPED. It exists on the Ethereum instance only because
    ///      deleting it is an ABI break, and it is exactly the form Cantina 3.1.5 is about: a
    ///      price-bounded but not time-bounded exit. A new instance has no caller written against
    ///      it, so not shipping it closes that finding BY CONSTRUCTION. Do not add it back.
    function redeem(uint256 usdfrAmount, uint256 minValueOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valuePaid)
    {
        if (block.timestamp > deadline) revert Controller_DeadlinePassed(deadline, block.timestamp);
        return _redeem(usdfrAmount, minValueOut, false);
    }

    /// @dev THE EXIT - READ THIS WHOLE BLOCK BEFORE CHANGING THE ARITHMETIC OR THE ORDER.
    ///      The step labels R1..R19 in the body are the specification.
    ///
    ///      WHAT THE REDEEMER IS PAID, UNDER ADR-0038 AND THE FOREST ROAD DIRECTION OF 2026-09-07.
    ///      The reserve pays, in this order: the redeemer's OWN RECORDED ASSETS at one unit of value
    ///      per USDfr of value, capped by the units that redeemer themselves deposited; then the
    ///      PRO-RATA BASKET for the remainder. THE REDEEMER NAMES NOTHING. There is no elected exit
    ///      and none may be added: free election is the free option ADR-0037 section 4.1 exists to close,
    ///      and what closes it here is THE CAP, not a fee and not a floor share. A holder cannot
    ///      convert an impaired asset into a sound one at the expense of the holders who stay,
    ///      because they can only take back what they put in. The record does not move when USDfr is
    ///      transferred, so a market buyer carries no record and settles entirely on the basket,
    ///      which is also the ordinary path for yield and protocol-fee USDfr, minted with no record
    ///      at all. That path must therefore work well and is exercised by the same code.
    ///
    ///      R6, R7 and R8 price the admitted burn from supply and backing. Outside a pending
    ///      review, the existing frozen-leg reduction remains. During review, admission requires
    ///      full coverage by healthy deposit records, so R6 keeps the full requested burn. The
    ///      junior draw, par ceiling and non-worsening checks then apply to that admitted amount.
    ///
    ///      WHAT DOES CHANGE IS THE VERIFICATION, IN EXACTLY TWO PLACES, AND BOTH ARE STATED WHERE
    ///      THEY LIVE: R13's value equality becomes a bound plus a returned promise, and R13b
    ///      measures that promise against the reserve's own claim-liability ledger.
    ///
    ///      Outside a pending review, the existing tension between R6 and the record draw remains. R6
    ///      REFUSES a redeem-frozen leg's share rather than re-weighting it, precisely so the
    ///      refused part of the claim survives as FULLY TRANSFERABLE USDfr in the caller's wallet
    ///      rather than as an illiquid claim. The record draw does not go through R6: the reserve
    ///      draws the holder's record across every recorded asset, and where that asset is frozen or
    ///      deployed the draw settles as a DEFERRED CLAIM on it. That is correct in VALUE terms, and
    ///      it is what the record cap requires, since paying the basket there would reopen the very
    ///      transfer the cap closes. But it converts transferable USDfr into an illiquid,
    ///      asset-specific claim without the holder having said so, which is the outcome R6 was
    ///      written to avoid on the basket side. THE TWO RULES ARE NOT YET RECONCILED. It is a
    ///      reserve-side allocation question, not a controller one, and the choices are: skip a
    ///      frozen leg in the record draw and leave that record standing; or bound the whole draw by
    ///      what is fundable and return the remainder as unburned USDfr. Forest Road should be asked
    ///      which, and the invariant suite must pin whichever is chosen.
    ///
    ///      WHAT THE PRICE PROMISES, EXACTLY. Every rounding is DOWN, twice per leg, so
    ///      `valuePaid <= valueOut <= usdfrIn`. The redeemer is paid at most their pro-rata share
    ///      and THE INSTANTANEOUS BOOK COVERAGE RATIO left behind for the holders who did not
    ///      redeem is unchanged or better. Every wei of rounding accrues to them, never to the
    ///      redeemer. That property is the ONLY thing this arithmetic promises.
    ///
    ///      WHAT IT DOES NOT PROMISE. COMPOSITION: backing is not homogeneous, and the exit is
    ///      settled entirely out of the IDLE legs at a ratio struck on a BLENDED mark, so a first
    ///      mover converts a part-liquid, part-impaired claim into 100% liquid assets and the
    ///      holders who stay are left with a residue concentrated in the leg that is still marking.
    ///      The instant path is FIRST-COME-FIRST-SERVED ON LIQUIDITY. It is not a run in VALUE
    ///      terms; it is a race in LIQUIDITY terms. SEQUENCING: the ratio is preserved AT THE
    ///      CURRENT MARK, and a conservative mark that is later DEEPENED - the ordinary shape of a
    ///      workout - reallocates the extra loss onto whoever did not move first. ADR-0034 accepts
    ///      the second explicitly: the mark that triggers a draw is conservative and REVERSIBLE, so
    ///      a draw crystallises junior capital against a loss that may never materialise, and the
    ///      beneficiary has already exited. `mintableHeadroom()` retains the standing prepayment so
    ///      the reversal does not become sUSDfr yield.
    ///
    ///      During a pending currency review, admission requires the entire requested burn to
    ///      fit within the caller's own healthy deposit records. Mixed reviewed/frozen records and
    ///      unrecorded basket claims wait for assessment. Settlement checks those records again
    ///      and refuses a general-basket remainder, including one caused by unit rounding.
    ///      Outside review, the existing redeem-freeze rule reduces the burn by payable/gross
    ///      liquidity; any unburned USDfr remains a fungible claim on the fund.
    ///
    ///      R6 MUST RUN BEFORE R7. `_exitDrawTarget` sizes the draw off `usdfrIn`; sizing it off the
    ///      UN-REDUCED request would draw junior capital for value the exit will not pay, which
    ///      violates ADR-0034 Y-bis requirement 3 - the draw brings absorption FORWARD in time, it
    ///      does not ENLARGE it.
    ///
    ///      THE BURN IS A SINGLE CALL ABOVE EVERY SETTLEMENT WINDOW, AND IT MUST STAY THERE. The
    ///      burn fires USDfr's deliberately FAIL-OPEN points hook; a hook moving one wei inside a
    ///      strict-equality balance window is a redemption kill switch that the token's own
    ///      `try/catch` cannot absorb, because the revert happens in the CALLER's frame. GENERAL
    ///      RULE for anyone extending this function: no call a redeemer or a governance-set module
    ///      can influence may sit inside any before/after measurement pair.
    ///
    ///      THE CONTROLLER DOES NOT SPLIT THE BASKET, AND THAT IS DELIBERATE ON THIS INSTANCE.
    ///      `ReserveManager.releaseRecorded` owns the allocation, the deterministic sub-unit dust
    ///      placement and the per-leg delivery attempt, including the escrow fallback that keeps a
    ///      reverting, paused or gas-bombing token from freezing delivery of the others. A
    ///      controller-side re-implementation of that split would be a SECOND ENUMERATION of one
    ///      quantity - the defect shape this file already records - and it would diverge from the
    ///      reserve the day a sub-18-decimal asset makes the dust pass live, turning honest
    ///      redemptions into reverts. What the controller does instead is CHECK: it asserts the
    ///      returned legs are the registry in listing order (`Controller_BasketShapeMismatch`), that
    ///      no refused leg was paid (`Controller_RedemptionNotSettled`), and that the reserve's own
    ///      `valuePaid` equals the par value of the units it says it moved, recomputed from the
    ///      controller's own cached scales (`Controller_BasketValueMismatch`). Those checks touch NO
    ///      TOKEN, so a hostile or paused reserve asset can never make the verification itself
    ///      revert - which is why the Ethereum instance's `payeeBefore`/`payeeAfter` window is NOT
    ///      ported. That window would re-brick exactly the class the reserve's escrow removes.
    ///
    ///      WHY IT IS SAFE TO PRICE OFF `totalBackingValue()` HERE. `_requireCustodiedPayableLegs`
    ///      has already refused if there is any observable custody gap, so at this line
    ///      `recognizedBackingValue() == totalBackingValue()` by construction. Pricing off the
    ///      recorded basis therefore quotes the same number as the recognition-aware basis while
    ///      keeping ONE basis across the quote and the closing assertion. If that gate is ever
    ///      relaxed, this must move to `recognizedBackingValue()` in the same change.
    ///      `previewRedeem` uses the recognition-aware basis precisely because it is NOT behind it.
    function _redeem(uint256 usdfrAmount, uint256 minValueOut, bool requirePar)
        private
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valuePaid)
    {
        // R1
        ControllerStorage storage $ = _storage();
        _requireAccrualFresh($);
        _requireKYC($, msg.sender);
        // R2
        if (usdfrAmount == 0) revert Controller_ZeroAmount();
        // R3 - the recorded basis; see this function's NatSpec.
        (uint256 supplyBefore, uint256 backingBefore) = _supplyAndBacking($);
        // R4 - ONE reading of the reserve's payable state.
        Basket memory basket = _payableBasket($, usdfrAmount);
        if (basket.pendingAsset != address(0)) revert Controller_AssetAdjudicationPending(basket.pendingAsset);
        if (basket.totalPayable == 0) revert Controller_NoPayableReserve();
        // R5 - PER-ASSET on the paying legs, then the reserve's own protocol-wide gate.
        _requireCustodiedPayableLegs($, basket);
        // R6 - the frozen-leg reduction. With no refused leg this is the identity.
        usdfrIn = basket.totalPayable == basket.grossPayable
            ? usdfrAmount
            : Math.mulDiv(usdfrAmount, basket.totalPayable, basket.grossPayable);
        if (usdfrIn == 0) revert Controller_AmountTooSmall(usdfrAmount);
        // R7 - the atomic junior draw. It runs BEFORE the quote on purpose: ADR-0034 requires that
        // a quote which cannot be funded must not be issued, and striking the price on the draw's
        // MEASURED outcome makes an unfundable quote unrepresentable rather than merely refused.
        uint256 drawn = _drawJuniorForExit($, usdfrIn, supplyBefore, backingBefore);
        // R8
        uint256 valueOut = _quoteRedeemValue(usdfrIn, supplyBefore, backingBefore, drawn);
        if (valueOut == 0) {
            // A protocol whose backing has fallen to zero must not answer "your amount is too
            // small" when the truth is "there is nothing left to pay you".
            if (backingBefore == 0 && supplyBefore != 0) revert Controller_NoRedeemableBacking(supplyBefore);
            revert Controller_AmountTooSmall(usdfrAmount);
        }
        // R9 - a DECODED error, ahead of the burn, where the reserve would otherwise refuse from
        // inside its own release with the redeemer's USDfr already burned in the caller's
        // simulation. Not a behaviour change; a diagnosability change.
        //
        // This remains a partial liquidity check. Outside review, assetRecords supplies gross
        // payable value, while settlement nets reserved pending claims. During review, the record
        // reader also nets those claims before publishing totalPayable. Settlement still enforces
        // its own record and allocation bounds; it can refuse an unrepresentable remainder.
        if (valueOut > basket.totalPayable) {
            revert Controller_InsufficientPayableReserve(valueOut, basket.totalPayable);
        }
        // R10 - an EARLY refusal only. `valuePaid <= valueOut` always, so a quote below the caller's
        // floor is certainly a settlement below it, and refusing here spares the burn and its hook.
        // The BINDING check is R14, on the settled number.
        if (!requirePar && valueOut < minValueOut) revert Controller_SlippageExceeded(valueOut, minValueOut);

        // R10b - the reserve's aggregate outstanding claim value, read BEFORE the release so R13b
        // can measure the rise this settlement causes. `address(0)` is passed deliberately: the
        // fourth return is protocol-wide and independent of the (holder, asset) pair, and naming a
        // listed asset here would imply a per-asset reading this check does not use.
        uint256 claimBefore;
        (,,, claimBefore) = $.reserves.recordOf(msg.sender, address(0));

        // R11 - ONE burn, above every settlement window. See this function's NatSpec.
        $.usdfr.burn(msg.sender, usdfrIn);
        // R12 - the reserve allocates and delivers. It pays THIS redeemer's OWN RECORDED ASSETS
        // first, capped by their own deposit record, then the pro-rata basket for the remainder; an
        // undeliverable leg degrades to a claimable escrow entry for this redeemer rather than
        // reverting the whole settlement, and a recorded asset the reserve cannot fund degrades to a
        // DEFERRED CLAIM ON THAT ASSET rather than to a basket payment. During a pending review,
        // settlement refuses any general-basket remainder and rechecks that all records are healthy.
        (assets, amounts, valuePaid) = $.reserves.releaseRecorded(msg.sender, valueOut);
        // R13 - verify the reserve's answer against the controller's own cached reading.
        uint256 promised = _assertBasketSettled(basket, assets, amounts, valuePaid, valueOut, usdfrIn);
        // R13b - and verify the part of that answer the unit arithmetic can no longer prove. See
        // `Controller_ClaimNotRecognized`.
        //
        // IT IS GATED ON `promised != 0` DELIBERATELY, AND THE OTHER DIRECTION IS COVERED ELSEWHERE.
        // The hole opened by relaxing R13's equality is a reserve OVER-reporting settled value, and
        // that is what this closes. A reserve that wrote a claim and then UNDER-reported `valuePaid`
        // is caught on the caller's own terms instead: the par form asserts `valuePaid == usdfrIn`
        // at R14 and the bounded form binds `minValueOut` there, so the redeemer is never silently
        // settled short. Paying for a second staticcall on every redemption to re-catch a case two
        // existing guards already refuse is not a trade this hot path should make.
        if (promised != 0) {
            (,,, uint256 claimAfter) = $.reserves.recordOf(msg.sender, address(0));
            uint256 recognised = claimAfter < claimBefore ? 0 : claimAfter - claimBefore;
            if (recognised != promised) revert Controller_ClaimNotRecognized(promised, recognised);
            emit RedeemPromised(msg.sender, promised);
        }
        // R14 - the binding settlement rule.
        if (requirePar) {
            if (valuePaid != usdfrIn) revert Controller_ParExitNotAvailable(usdfrIn, valuePaid);
        } else if (valuePaid < minValueOut) {
            revert Controller_SlippageExceeded(valuePaid, minValueOut);
        }
        // R15 - the per-leg register. `Redeemed` carries only a scalar; without this no observer can
        // reconstruct who was paid in which asset (CLAUDE.md section 3.1).
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            uint256 units = amounts[i];
            if (units != 0) emit RedeemLegSettled(msg.sender, assets[i], units, units * basket.scale[i]);
        }
        // R16 - THE ANCHOR IS RE-BASED ON THE POST-DRAW SUPPLY, AND THAT IS LOAD-BEARING.
        // `supplyBefore` was read BEFORE the junior draw burned `drawn`, so passing it here would
        // hand this check exactly `drawn` wei of slack to worsen into, and would hide an
        // under-delivering reserve behind junior capital on the leg where the holder's USDfr is
        // ALREADY BURNED. Anyone "simplifying" this back to `supplyBefore` silently disables the
        // guard in exactly the state it exists for.
        _assertDeficitNotWorsened($, supplyBefore - drawn, backingBefore);
        // R17 - the crystallised, IRREVERSIBLE part of a REVERSIBLE mark. Recording it is what stops
        // a later `releasePrincipalImpairment` turning the exiter's loss into vault yield.
        //
        // A PROMISE IS NOT A SHORTFALL, AND THE MEASUREMENT ALREADY REFLECTS THAT. `valuePaid`
        // includes any deferred claim written for this redeemer, because that value left backing in
        // the same transaction and the holder owns those units in the ledger already. So a holder
        // whose recorded asset was deployed does NOT crystallise a senior shortfall for the part
        // they are still owed. `subParShortfall` is a CREDIT-LOSS ledger; putting a timing
        // difference into it would corrupt the quantity a later impairment release is measured
        // against.
        if (valuePaid < usdfrIn) {
            uint256 crystallised = usdfrIn - valuePaid;
            uint256 cumulative = $.subParShortfall + crystallised;
            $.subParShortfall = cumulative;
            emit SeniorShortfallCrystallised(msg.sender, crystallised, cumulative);
            emit SubParRedemption(msg.sender, usdfrIn, valuePaid, supplyBefore, backingBefore);
        }
        // R18
        emit Redeemed(msg.sender, usdfrIn, valuePaid);
    }

    // -- Credit-layer paths (wired in Phases E/G) -------------------------

    /// @inheritdoc IMintRedeemController
    /// @dev THE `to` CONSTRAINT (AUDIT FIX R16-M1) - LOAD-BEARING, DO NOT DELETE. `mintYield`
    ///      constrained `to` in no way, and `burnLoss` constrained `from` in no way. The two
    ///      COMPOSED into arbitrary confiscation - burn a named holder's balance, mint the same
    ///      amount to an attacker - and `_assertBacking` could not detect it BY CONSTRUCTION,
    ///      because it compared two global aggregates and the pair left both unchanged. It was
    ///      reproduced on a mainnet fork with 250,000 real USDC borrowed from the Maker PSM.
    ///
    ///      WHAT CONSTRAINING THE ENDPOINTS ACTUALLY BOUGHT, STATED HONESTLY (R17 CORRECTION).
    ///      R16 claimed the endpoints "break the composition at both ends". That overstates it and
    ///      the overstatement is itself a defect, so here is the true statement. The aggregate
    ///      blindness is STRUCTURAL and untouched: `burnLoss` carries no solvency assertion at all
    ///      (correctly - see its NatSpec) and this function's assertion compares two global
    ///      aggregates, so a burn of X followed by a mint of X is invisible to it BY CONSTRUCTION.
    ///      What the endpoint lists removed is the ARBITRARY-VICTIM form: `from` must now be a
    ///      governance-named loss source AND (R17) a CONTRACT, so no user wallet is seizable, and
    ///      the residual composition can only reach the `sUSDfr` vault, whose burn is pro-rata
    ///      across every senior depositor. What `Roles.LOSS_BURNER_ROLE` removed is the
    ///      SINGLE-ROLE form: the composition now needs BOTH `LOSS_BURNER_ROLE` and `CREDIT_ROLE`,
    ///      which `Deploy.s.sol` deliberately splits across `DefaultManager` and `WaterfallEngine`.
    ///      THAT SPLIT IS LOAD-BEARING AND MUST NEVER BE RELAXED "FOR SYMMETRY" - it is one
    ///      `grantRole` deep, and `Validate.s.sol` asserts it post-deploy.
    ///
    ///      WHY A DEDICATED LIST AND NOT `ComplianceRegistry.isProtocolExempt`. That list looks
    ///      like the right one and is not: it is already overloaded as the sanctions-bypass set,
    ///      the USDfr emergency-pause carve-out, the `PointsModule` ineligibility set and the
    ///      `sUSDfr` fee-recipient validity set. Hanging burn authority off it means a
    ///      compliance-motivated de-listing silently disables the loss cascade, and a listing
    ///      made to keep a module transferable silently grants it burn authority. Separate
    ///      concerns get separate lists.
    ///
    ///      WHENNOTPAUSED IS DELIBERATE AND ASYMMETRIC WITH `burnLoss` (AUDIT FIX R16-L1). A
    ///      guardian pause must never leave supply EXPANSION available while user exits are
    ///      frozen. This mirrors the rule `USDfr._update` already enforces on the token itself
    ///      ("mints stay closed even to a listed module, because a pause must never permit
    ///      supply EXPANSION"), so `WaterfallEngine`'s interest leg was already unavailable
    ///      under a USDfr pause; this makes a controller pause say the same thing instead of
    ///      being a one-way valve that closes the user inflow and leaves the credit-layer
    ///      inflow open. R17 removed the LIVENESS cost of that choice without weakening it:
    ///      `mintableHeadroom()` reads zero while paused, so `WaterfallEngine._routeInterest`
    ///      clamps to zero and WITHHOLDS instead of reverting, and an ordinary borrower repayment
    ///      still settles under a controller pause. See `pause` and `mintableHeadroom`.
    ///
    ///      AUDIT FIX (R18): R17 APPLIED THAT ONLY TO HALF THE PAUSE SURFACE. `mintableHeadroom()`
    ///      read this contract's `paused()` and nothing else, while the SAME guardian address holds
    ///      `GUARDIAN_ROLE` on `USDfr` (`Deploy.s.sol` grants both), and `USDfr._update` refuses
    ///      every mint under a token pause - its `protocolLeg` carve-out requires
    ///      `from != address(0)`, so a mint can never qualify for it. One un-timelocked
    ///      `USDfr.pause()` therefore still reverted the yield leg, and because
    ///      `WaterfallEngine.distribute` is atomic it took the principal leg, the attestation
    ///      spend, the exposure release and the lifecycle transition down with it - the precise
    ///      harm the clamp exists to prevent, reached through the pause the clamp could not see.
    ///      `mintableHeadroom()` now reads BOTH pauses, so either one withholds instead of
    ///      reverting.
    ///
    ///      BOTH BASES ARE ASSERTED (AUDIT FIX R17) - DO NOT DELETE EITHER ASSERTION. This was the
    ///      one supply-EXPANDING path with no recognition-aware check of any kind. R16's comment
    ///      below said "while it is short it refuses outright"; that was true only of the RECORDED
    ///      deficit. Under an unreconciled custody shortfall - the R4-01 state, in which `mint`
    ///      and `redeem` both revert and `backingInvariantHolds()` publishes FALSE - the recorded
    ///      basis still reported the protocol whole, so the credit layer could mint fresh USDfr
    ///      against cash the reserve could already see was absent, and `recognizedDeficit()` rose
    ///      by the full amount minted while the predicate passed. That is R4-01's "sells a new
    ///      claim on a hole" reached through the credit door, and it is the L1 one-way-valve shape
    ///      on the recognition axis. `burnLoss` is deliberately NOT gated the same way: it only
    ///      ever LOWERS supply, and a recognition-aware assertion there would revert the C-01
    ///      cascade's own burns (see `_requireCustodiedAsset`). The asymmetry is now provable
    ///      rather than asserted - `test_R17_B02_burnLossStaysOpenUnderARecognisedShortfall` pins
    ///      it.
    /// @notice Record the supply/backing baseline for a yield mint whose backing leg moves FIRST.
    ///
    /// @dev WHY THIS EXISTS. `_assertDeficitNotWorsened` and its recognised twin are NON-WORSENING
    ///      checks, and they are correct. What was wrong was WHERE they measured from.
    ///      `WaterfallEngine.capitalizePik` raises backing (`recordPikCapitalization`) and only then
    ///      raises supply here, so `mintYield`'s own snapshot was taken with backing ALREADY moved.
    ///      For a standing deficit D and a capitalisation of `a` it read deficitBefore as
    ///      max(0, D - a) against a deficitAfter of D, called a pair that changes the deficit by
    ///      EXACTLY ZERO a worsening, and refused. Measured: one USDC unit of conservative mark on
    ///      an unrelated facility froze every PIK capitalisation in the book.
    ///
    ///      THIS DOES NOT WEAKEN THE RULE, IT MEASURES IT PROPERLY. Both assertions still run, and
    ///      they now run against the TRUE pre-operation state, so the mint is admitted only if the
    ///      pair really is deficit-neutral end to end. A caller that raises backing and then mints
    ///      more than it credited still fails. A paired mint preserves recognized surplus while
    ///      retention is active and requires the retention obligation to equal its opening value.
    ///      Existing undercoverage can remain unchanged; an intervening retention change cannot
    ///      use an older baseline. Ordinary yield mints still enforce the absolute retention floor.
    ///
    ///      The fee twin never needed this because it CLAMPS to `mintableHeadroom()` and withholds;
    ///      PIK cannot clamp, because a partial mint leaves backing above supply by the withheld
    ///      amount and that phantom surplus is absorbed pre-cascade.
    function beginPairedYield() external onlyRole(Roles.CREDIT_ROLE) nonReentrant whenNotPaused {
        ControllerStorage storage $ = _storage();
        _requireAccrualFresh($);
        if ($.pairedYieldCaller != address(0)) revert Controller_PairedYieldAlreadyOpen($.pairedYieldCaller);
        (uint256 supplyBefore, uint256 backingBefore) = _supplyAndBacking($);
        $.pairedYieldCaller = msg.sender;
        $.pairedSupplyBefore = supplyBefore;
        $.pairedBackingBefore = backingBefore;
        $.pairedRecognizedBefore = $.reserves.recognizedBackingValue();
        $.pairedRetentionBefore = $.subParShortfall + $.reserves.exitPrepaidAbsorption();
        emit PairedYieldOpened(msg.sender, supplyBefore, backingBefore);
    }

    /// @notice Governance escape for a paired-yield baseline stranded by a reverted operation.
    /// @dev Mirrors `sUSDfr.clearStaleFeeOperation`. THE EARLIER VERSION OF THIS NOTE CLAIMED A
    ///      STRANDED BASELINE COULD ONLY EVER BE STRICTER. That was false: the deficit is not
    ///      monotone, so a snapshot taken in a WORSE state would be a LOOSER baseline for a later
    ///      mint. `beginPairedYield` therefore refuses to open a second baseline while one stands,
    ///      `mintYield` consumes it so it can never span two mints, and this is the governance
    ///      escape for the only way one can be stranded: an operation that opened a baseline and
    ///      then reverted after the state had moved.
    function clearStalePairedYield() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualFresh(_storage());
        ControllerStorage storage $ = _storage();
        address caller = $.pairedYieldCaller;
        _clearPairedYield($);
        emit PairedYieldCleared(caller);
    }

    function _clearPairedYield(ControllerStorage storage $) private {
        $.pairedYieldCaller = address(0);
        $.pairedSupplyBefore = 0;
        $.pairedBackingBefore = 0;
        $.pairedRecognizedBefore = 0;
        $.pairedRetentionBefore = 0;
    }

    function mintYield(address to, uint256 amount) external onlyRole(Roles.CREDIT_ROLE) nonReentrant whenNotPaused {
        ControllerAccrualLib.mintYield(_storage(), to, amount, address(0), 0);
    }

    /// @inheritdoc IMintRedeemController
    function mintYieldSplit(address senior, uint256 total, address feeRecipient, uint256 fee)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
    {
        ControllerStorage storage $ = _storage();
        if ($.pairedYieldCaller != msg.sender) revert Controller_PairedYieldRequired();
        ControllerAccrualLib.mintYield($, senior, total, feeRecipient, fee);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE `from` CONSTRAINT (AUDIT FIX R16-M1/M2) - LOAD-BEARING, DO NOT DELETE. See
    ///      `mintYield` for the confiscation composition this half closes. It also answers a
    ///      second finding on its own: `USDfr.burn` takes NO ALLOWANCE, so an unconstrained
    ///      `from` made the capital-free cure for a shortfall a FORCED, NON-PRO-RATA seizure
    ///      from one named holder while an identically-placed holder paid nothing.
    ///
    ///      WHAT IS AND IS NOT PROMISED HERE (R17 CORRECTION). R16 wrote that "the only reachable
    ///      burns are the cascade's own". That described the DEPLOYED WIRING, not the reachable
    ///      set: `setLossSource` was a plain DEFAULT_ADMIN setter that accepted any non-zero
    ///      address including a bare EOA, so one routine-looking timelock transaction restored the
    ///      seizure this function is supposed to have closed - and the repo's own fixture listed
    ///      an EOA. R17 makes the setter refuse a CODELESS account, mirroring
    ///      `ReserveManager.setLossAbsorber`/`setLossController`, so the claim is now a property of
    ///      the CODE for every externally-owned account: no user wallet is seizable, allowance or
    ///      no allowance. It remains a property of the WIRING for contracts - governance can still
    ///      name a contract that holds USDfr - so the honest statement is: the only reachable burns
    ///      are from governance-named CONTRACT endpoints, which `Deploy.s.sol` sets to
    ///      `DefaultManager` (burning junior capital it has already received into ITSELF) and the
    ///      `sUSDfr` vault (pro-rata by construction, because it moves the vault's exchange rate
    ///      for every senior depositor at once), and which `Validate.s.sol` asserts post-deploy.
    ///
    ///      LEAST PRIVILEGE - `Roles.LOSS_BURNER_ROLE`, NOT `Roles.CREDIT_ROLE`. Verified by
    ///      grep at R16: every `burnLoss` call site in `src/` is in `DefaultManager`, passing
    ///      `address(this)` or `$.vault`. `WaterfallEngine` was granted `CREDIT_ROLE` on this
    ///      contract by `Deploy.s.sol` and therefore held a burn power IT NEVER USED. Splitting
    ///      the role removes that power from the engine entirely, so a compromise of the
    ///      repayment path cannot reach the burn path at all. `Validate.s.sol` asserts the
    ///      engine does NOT hold `LOSS_BURNER_ROLE`.
    ///
    ///      NO BACKING ASSERTION HERE, AND THAT IS THE FIX, NOT AN OMISSION (AUDIT FIX R16-M6).
    ///      This function previously asserted the backing invariant. Burning strictly LOWERS
    ///      `totalSupply` and cannot touch `backingValue` - the contract is `nonReentrant`, and
    ///      nothing on the burn path can raise supply or lower backing - so the assertion was
    ///      unfalsifiable: no reachable state could make it fire. That was proved empirically,
    ///      and it is exactly why the earlier `Controller_LossBurnDeficitMismatch` guard could be
    ///      DELETED IN FULL with the entire deterministic and invariant suite green. A guard no
    ///      test can red is not protection; it is a comment that an auditor will read as
    ///      protection. This round removes it and states the proof instead. The guards that
    ///      remain on this function - the role, the endpoint list, the zero-amount check - are
    ///      each proved by a deletion mutation.
    ///
    ///      NOT `whenNotPaused`, DELIBERATELY. Loss absorption is the one supply path that must
    ///      never be pausable: a guardian pause that stopped the cascade would leave a recognised
    ///      loss unallocated for the whole pause. `USDfr._update`'s emergency carve-out makes the
    ///      same choice for the same reason.
    function burnLoss(address from, uint256 amount) external onlyRole(Roles.LOSS_BURNER_ROLE) nonReentrant {
        if (amount == 0) revert Controller_ZeroAmount();
        ControllerStorage storage $ = _storage();
        ControllerAccrualLib.authorizeLossBurn(address($.accrual), from, amount);
        if (!$.lossSource[from]) revert Controller_NotLossSource(from);
        $.usdfr.burn(from, amount);
        emit LossBurned(from, amount);
    }

    // -- Governance: credit-layer endpoints (AUDIT FIX R16-M1) ------------

    /// @notice Authorizes (or revokes) an address as a destination for `mintYield`.
    /// @dev Timelocked governance only. Production wiring is the `sUSDfr` vault and the protocol
    ///      fee recipient; `Deploy.s.sol` sets both and `Validate.s.sol` asserts them. Zero is
    ///      refused so `mintYield(address(0), ...)` can never be enabled, which is what lets that
    ///      function drop its own zero-address check instead of carrying an unreachable one.
    /// @param account The address that may receive yield mints.
    /// @param authorized True to authorize, false to revoke.
    function setYieldSink(address account, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualFresh(_storage());
        if (account == address(0)) revert Controller_ZeroAddress();
        _storage().yieldSink[account] = authorized;
        emit YieldSinkUpdated(account, authorized);
    }

    /// @notice Authorizes (or revokes) an address as a source for `burnLoss`.
    /// @dev Timelocked governance only. Production wiring is `DefaultManager` (which burns the
    ///      junior capital it has already received into itself) and the `sUSDfr` vault (cascade
    ///      layer 3, pro-rata by construction). Zero is refused for the same reason as
    ///      `setYieldSink`.
    ///
    ///      THE CONTRACT CHECK (AUDIT FIX R17) - LOAD-BEARING, DO NOT DELETE. `burnLoss` burns
    ///      with NO ALLOWANCE and carries no backing assertion, and it is deliberately not
    ///      pausable, so neither the invariant nor a guardian can stop it. Listing an EOA here is
    ///      therefore a one-transaction, governance-reachable restoration of finding M2 - a
    ///      forced, non-pro-rata seizure of one named holder - dressed as routine wiring in a
    ///      timelock queue, which reads very differently from an upgrade. Every production loss
    ///      source is a protocol module; no user wallet is ever one. `ReserveManager`'s sibling
    ///      setters (`setLossAbsorber`, `setLossController`) already refuse a codeless address and
    ///      this is the same constraint. It is deliberately NOT applied to `setYieldSink`, which
    ///      legitimately names the Forest Road fee-recipient treasury and may be an EOA - that
    ///      half of the M1 composition credits an address, it does not seize one.
    ///
    ///      A CODE CHECK ALONE IS NOT "NO USER WALLET" AFTER PECTRA (AUDIT FIX R18) - DO NOT DELETE
    ///      THE DELEGATION-DESIGNATOR CHECK. R17 wrote that refusing a codeless account made the
    ///      claim "a property of the CODE for every externally-owned account: no user wallet is
    ///      seizable". THAT WAS FALSE ON THE DEPLOYMENT TARGET. EIP-7702 has been live on Ethereum
    ///      L1 (ADR-0009) since Pectra in May 2025: an ordinary key-controlled EOA that signs a
    ///      delegation carries a 23-byte code field of the form `0xef0100 ++ address`, so
    ///      `EXTCODESIZE` returns 23 and R17's check ADMITTED IT. Every MetaMask smart account,
    ///      Ambire wallet and gas-sponsored onboarding flow produces exactly that shape, so finding
    ///      M2 - a forced, allowance-free, non-pro-rata seizure of one named holder, unstoppable by
    ///      the guardian because `burnLoss` is deliberately not pausable and carries no backing
    ///      assertion - was still one routine-looking timelock transaction away for precisely the
    ///      class of wallet the guard names.
    ///
    ///      WHY THE FIRST BYTE IS SUFFICIENT AND A BOUND-BACK PROBE WAS NOT CHOSEN. EIP-3541 has
    ///      forbidden deploying any code beginning with `0xEF` since London, so no legitimately
    ///      deployed contract can collide with the designator prefix; refusing a leading `0xEF`
    ///      byte therefore excludes delegated EOAs without excluding any real module. The stronger
    ///      alternative - requiring the candidate to answer a bound-back probe - was NOT taken
    ///      because the two production loss sources (`DefaultManager` and the `sUSDfr` vault) do not
    ///      implement such a probe and adding one to them is a cross-module change; it is recorded
    ///      here as the follow-up if governance wants "cannot be wired by accident" rather than
    ///      "cannot be a wallet".
    ///
    ///      THE HONEST CLAIM IS THEREFORE: no CODELESS account and no DELEGATED EOA can be named a
    ///      loss source. It remains a property of the WIRING, not the code, that the named contract
    ///      is one whose burn is pro-rata.
    /// @param account The address `burnLoss` may burn from. Must have code, and must not be an
    ///        EIP-7702 delegated EOA.
    /// @param authorized True to authorize, false to revoke.
    function setLossSource(address account, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualFresh(_storage());
        if (account == address(0)) revert Controller_ZeroAddress();
        // Only AUTHORIZATION is constrained. Revocation must never be blocked by the state of the
        // account being revoked - a governance kill-switch that a self-destructed endpoint could
        // disable would be a worse defect than the one this closes.
        if (authorized) {
            if (account.code.length == 0) revert Controller_LossSourceNotContract(account);
            if (_isDelegatedEOA(account)) revert Controller_LossSourceIsDelegatedEOA(account);
        }
        _storage().lossSource[account] = authorized;
        emit LossSourceUpdated(account, authorized);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev Timelocked governance. Zero is refused so a non-zero fee can never mint into the void,
    ///      and because `mint` fails CLOSED on an unset recipient rather than skipping the fee.
    ///
    ///      NOT CONSTRAINED TO A CONTRACT, DELIBERATELY, AND THE ASYMMETRY IS THE POINT. Unlike
    ///      `setLossSource`, this address is CREDITED, not seized from, so neither the codeless
    ///      check nor the EIP-7702 designator check applies - the harm those close is a forced,
    ///      allowance-free, non-pro-rata seizure of one named holder, and crediting an address
    ///      cannot produce it. This is the same asymmetry `setYieldSink` already documents for the
    ///      Forest Road fee-recipient treasury, which may legitimately be an EOA.
    ///
    ///      THE FEE IS REVENUE, NOT LOSS ABSORPTION, AND NOBODY MAY LATER ARGUE OTHERWISE. It is a
    ///      USDfr amount carved from the minter's own credit and sent HERE. It is NOT an ADR-0031
    ///      fee-share mint, and it is NOT reserve surplus: routing it to surplus would make it layer
    ///      ZERO of the cascade, because ADR-0033 section 6 step 1 has existing backing surplus absorb the
    ///      portion of a recognized loss that does not require a supply burn - which would silently
    ///      convert protocol revenue into first-loss capital sitting AHEAD of the curator, inverting
    ///      the cascade. It also does not close the mint-side free option; it PRICES it. With a
    ///      secondary asset at price `p`, cap `K` and fee `f`, a KYC'd minter earns `(1 - f - p)`
    ///      per unit on `min(K, sound idle)` per conversion cycle whenever `p < 1 - f`, and the
    ///      remaining holders bear `(1 - p) * K` in full because the fee left the reserve.
    /// @param recipient The address to credit. Must not be zero.
    function setMintFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireAccrualFresh(_storage());
        if (recipient == address(0)) revert Controller_ZeroAddress();
        ControllerStorage storage $ = _storage();
        address previous = $.mintFeeRecipient;
        $.mintFeeRecipient = recipient;
        emit MintFeeRecipientUpdated(previous, recipient);
    }

    /// @inheritdoc IMintRedeemController
    function mintFeeRecipient() external view returns (address) {
        return _storage().mintFeeRecipient;
    }

    /// @dev AUDIT FIX (R18) - LOAD-BEARING, DO NOT DELETE. True if `account` carries an EIP-7702
    ///      delegation designator, i.e. an ordinary EOA whose key signed a `SetCode` authorization.
    ///      The designator is EXACTLY 23 bytes and EXACTLY `0xef0100 ++ delegate`; EIP-3541 makes a
    ///      leading `0xEF` undeployable for real contract code, so this cannot false-positive on a
    ///      protocol module - `test_R18_C2_a23ByteContractThatIsNotADesignatorIsStillNameable`
    ///      pins that half. The refusal itself is falsified by
    ///      `test_R18_C2_a7702DelegatedWalletCannotBeNamedALossSource`, which MODELS the delegation
    ///      with `vm.etch` rather than signing one, so the property is pinned on the repo's default
    ///      `cancun` profile. What matters is the on-chain CODE FIELD, which is byte-identical
    ///      either way; that test carries its own control showing the same address REFUSED as a
    ///      plain EOA and ADMITTED by R17's rule once the designator is present.
    function _isDelegatedEOA(address account) private view returns (bool) {
        if (account.code.length != 23) return false;
        bytes3 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(account, ptr, 0, 3)
            head := mload(ptr)
        }
        return head == bytes3(0xef0100);
    }

    // -- Guardian ---------------------------------------------------------

    /// @notice Pauses the user mint/redeem paths and the credit-layer YIELD MINT. Emergency use
    ///         only.
    /// @dev AUDIT FIX (R16-L1) corrected both the code and this NatSpec. A pause closes every
    ///      path that ISSUES USDfr (`mint`, `mintYield`) and the user exit (`redeem`); it
    ///      deliberately leaves `burnLoss` open, because loss absorption must never be pausable.
    ///      Pausing therefore cannot expand supply and cannot be used to freeze the cascade.
    ///      Note this is a SEPARATE pause from `USDfr.pause()`; the token's own pause closes the
    ///      user legs in both directions via `USDfr._update`'s protocol-leg carve-out.
    ///
    ///      WHAT A PAUSE DOES TO THE REPAYMENT PATH (AUDIT FIX R17 - STATED, BECAUSE R16 DID NOT).
    ///      `WaterfallEngine.distribute` is atomic and calls `mintYield` on every payment carrying
    ///      interest, so R16's `whenNotPaused` silently made a single un-timelocked GUARDIAN key
    ///      able to stop EVERY borrower repayment - principal leg, attestation spend, exposure
    ///      release and lifecycle transition included - and with it the ordinary interest payments
    ///      that are the protocol's only native cure for a deficit. R17 keeps the modifier (supply
    ///      expansion must stay closed) and removes the coupling: `mintableHeadroom()` reads ZERO
    ///      while paused, so `_routeInterest` clamps the distribution to zero, emits
    ///      `InterestWithheldForBackingRepair` and settles. The cash still lands in the reserve as
    ///      backing; only the YIELD is suspended.
    ///
    ///      R18 FINISHED THAT FIX ON BOTH AXES, BECAUSE R17 HAD DONE HALF OF EACH.
    ///        - THE OTHER PAUSE. R17's clamp read only THIS contract's `paused()`. The same
    ///          guardian address holds `GUARDIAN_ROLE` on `USDfr` too (`Deploy.s.sol` grants both),
    ///          and `USDfr._update` refuses every mint under a token pause, so one un-timelocked
    ///          `USDfr.pause()` still reverted every interest-bearing `distribute` - principal leg,
    ///          attestation spend, exposure release and lifecycle transition included. The sentence
    ///          above about the coupling being "removed" was therefore true of a controller pause
    ///          and false of a token pause. `mintableHeadroom()` now reads BOTH.
    ///        - THE OTHER MINT. R17 stated here that "`WaterfallEngine.fund`'s origination-fee mint
    ///          still reverts under a pause, which is intended". R18 CLAMPS that mint to
    ///          `mintableHeadroom()` as well, so under either pause `fund` now WITHHOLDS the fee and
    ///          the facility funds. That is deliberate and is not a weakening: stopping origination
    ///          during an emergency is the job of `WaterfallEngine`'s OWN `whenNotPaused` on `fund`,
    ///          which a guardian pausing the engine still gets in full. A CONTROLLER pause is a rule
    ///          about SUPPLY EXPANSION, and the fee is the part of `fund` that expands supply - so
    ///          withholding the fee is exactly what a controller pause should buy, and reverting the
    ///          whole origination was collateral damage of the same shape as the repayment coupling
    ///          this paragraph was written to remove.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _requireSettledState();
        _pause();
    }

    /// @notice Unpauses mint/redeem and the yield mint.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _requireSettledState();
        _unpause();
    }

    // -- Views ------------------------------------------------------------

    /// @inheritdoc IMintRedeemController
    function backingValue() public view returns (uint256) {
        return _storage().reserves.totalBackingValue();
    }

    /// @notice Current economic USDfr supply, including earned claims after accrual opt-in.
    /// @dev Uses the reserve's capped accounting and its frozen delivery snapshot. Read
    ///      USDfr.totalSupply() when measuring only physical token issuance.
    function totalUSDfr() public view returns (uint256) {
        return _effectiveSupply(_storage());
    }

    /// @notice Binds continuous accounting after reserve identities and the token's binding are configured.
    /// @dev Binding is permanent; enabling the reserve itself is a separate guarded ceremony step.
    function enableContinuousAccrual() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ControllerStorage storage $ = _storage();
        if (address($.accrual) != address(0)) revert Controller_AccrualAlreadyBound();
        if ($.pairedYieldCaller != address(0)) revert Controller_AccrualDuringPairedYield();
        ControllerAccrualLib.validate(address($.reserves), address($.usdfr));
        $.accrual = IContinuousAccrual(address($.reserves));
        emit ContinuousAccrualBound(address($.reserves));
    }

    /// @notice The configured continuous reserve, or zero before explicit binding.
    function accrualReserve() external view returns (address) {
        return address(_storage().accrual);
    }

    /// @notice Converts a reserve-owned, already accrued liability into physical USDfr.
    /// @dev Remains available while paused; all ordinary supply expansion keeps its pause gates.
    function mintAccrued(uint256 nonce) external nonReentrant {
        ControllerStorage storage $ = _storage();
        if ($.pairedYieldCaller != address(0)) revert Controller_AccrualDuringPairedYield();
        ControllerAccrualLib.deliver(address($.accrual), address($.usdfr), $.yieldSink, nonce);
        emit AccruedDeliveryRelayed(nonce);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT NOTE (MA-2/R18 MERGE ADJUDICATION). This is a compatibility diagnostic for the
    ///      RECORDED ledger; it is NOT an operation-admission predicate. The earlier MA-2 fix used
    ///      this absolute level as `WaterfallEngine.distribute`'s closing gate. That correctly
    ///      separated custody observation from recorded accounting, but deadlocked principal
    ///      recoveries whenever any genuine impairment or residual deficit remained.
    ///
    ///      `WaterfallEngine.distribute` now snapshots `recognizedDeficit()` and rejects only an
    ///      increase, after `ReserveManager.recordPayment` has independently proved exact cash
    ///      receipt. This view remains useful for comparing recorded and recognised bases, but a
    ///      false result does not forbid a non-worsening cash-in operation and a true result is not
    ///      sufficient authorization for one.
    ///
    ///      WHY THE RECORDED BASIS IS CORRECT HERE, AND IS NOT A HOLE. `distribute` is a cash-IN
    ///      path: `ReserveManager.recordPayment` pulls the borrower's USDC in and verifies receipt
    ///      by balance delta, so a distribution cannot lower live custody and cannot widen the
    ///      recognised gap (`Fix_MA02-recognition-contamination.t.sol
    ///      ::test_MA2_interestIsWithheldToRepairRecognisedGapWithoutBlockingRepayment` and
    ///      `::test_MA2_absorbedCustodyDeficitDoesNotBlockNeutralPrincipalCollection` - CITATION
    ///      CORRECTED, SWEEP-1 VAC-F8: the superseded name
    ///      `test_MA2_theInterestMintCannotWidenTheRecognisedGap` is not in the tree). Gating it
    ///      on the RECOGNISED
    ///      basis halted every performing borrower's repayment, protocol-wide, for a custody hole
    ///      elsewhere - blocking the money that repairs the balance sheet. The custody window is
    ///      closed where cash LEAVES: `_requireCustodiedAsset` / `_requireCustodiedPayableLegs` (user par),
    ///      `ReserveStorageLib.requireCustodied` (both reserve out-doors, MA-1) and
    ///      `ReserveManager.custodyLossUnabsorbed()` (curator, R6-CF1).
    ///
    ///      DO NOT WIRE THIS INTO A USER path, dashboard, or absolute credit gate. It is
    ///      deliberately blind to the custody shortfall; using it as a solvency or exit-pricing
    ///      signal reinstates R4-01.
    ///      AUDIT FIX (SWEEP-3 S3-F1) - THE `_requireSettledState()` BELOW IS LOAD-BEARING, DO NOT
    ///      DELETE. `_requireSettledState`'s own NatSpec states the rule categorically: the RAW
    ///      delegating views are deliberately ungated because each is a single live read of one
    ///      module, and "what is false mid-transition is the COMPOSITION of a supply reading with a
    ///      backing reading ... so it is exactly the COMPOSITES that are gated". This is a
    ///      composite (`totalUSDfr() <= backingValue()`) and it was the one the R18 fix's
    ///      hand-written five-view enumeration missed - the sixth. MEASURED: it answered TRUE
    ///      ("supply is within backing") from inside the burn window on a book that was short both
    ///      before and after the transaction, while `backingInvariantHolds()` - the identical
    ///      composition one basis over - correctly REFUSED from the same frame.
    ///      Falsified by `test_S3_F1_creditServicingBackingHoldsAnswersFromInsideTheBurnWindow`.
    function creditServicingBackingHolds() external view returns (bool) {
        _requireSettledState();
        return totalUSDfr() <= backingValue();
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT FIX (R4-01) - LOAD-BEARING, DO NOT "RESTORE" THIS TO `backingValue()`. This is
    ///      the protocol's public honesty surface: the dashboard reads it and the invariant
    ///      campaigns use it as the "is the protocol whole" predicate. Measured against the
    ///      RECORDED ledger it reported TRUE while `observeIdleUnits()` was simultaneously
    ///      publishing a non-zero shortfall to the same caller in the same block - the contract
    ///      contradicting itself. It is now measured against `recognizedBackingValue()`.
    /// @dev AUDIT NOTE (R16-M4): `WaterfallEngine.distribute` no longer HARD-GATES on this. It
    ///      gates on `recognizedDeficit()` not increasing across the call, which is the same
    ///      recognition-aware measurement expressed as a non-worsening rule, so a repayment that
    ///      REPAIRS backing is no longer refused merely because the protocol was already short.
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState`. See
    ///      `Controller_ViewUnavailableMidTransition`.
    function backingInvariantHolds() external view returns (bool) {
        _requireSettledState();
        return totalUSDfr() <= recognizedBackingValue();
    }

    /// @inheritdoc IMintRedeemController
    function recognizedBackingValue() public view returns (uint256) {
        return _storage().reserves.recognizedBackingValue();
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState` - a composite of a supply reading
    ///      and a backing reading is false mid-burn. See `Controller_ViewUnavailableMidTransition`.
    function backingDeficit() public view returns (uint256) {
        _requireSettledState();
        uint256 supply = totalUSDfr();
        uint256 backing = backingValue();
        return supply > backing ? supply - backing : 0;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState`, as `backingDeficit` is.
    function recognizedDeficit() external view returns (uint256) {
        _requireSettledState();
        uint256 supply = totalUSDfr();
        uint256 backing = recognizedBackingValue();
        return supply > backing ? supply - backing : 0;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THREE CORRECTIONS, ALL LOAD-BEARING (AUDIT FIX R17). This one view decides how much
    ///      interest `WaterfallEngine._routeInterest` may mint as yield, so every basis error in
    ///      it is paid out of the reserve and cannot be recovered.
    ///
    ///      (1) IT READS THE RECOGNISED BASIS, NOT THE RECORDED ONE. DO NOT "RESTORE" THIS TO
    ///      `backingValue()`. It is the headroom for MINTING, and minting against cash the reserve
    ///      can already see it does not hold is precisely what R4-01 forbids. Measured on the
    ///      recorded ledger, an unreconciled custody shortfall was invisible here: headroom
    ///      equalled the whole interest receipt, `_routeInterest`'s clamp withheld ZERO, the
    ///      protocol fee was taken on the GROSS out of an open hole (contradicting that function's
    ///      own "Forest Road does not collect a performance fee out of a shortfall"), and
    ///      `distribute`'s closing gate passed because the incoming cash and the new supply cancel
    ///      to the wei on both bases. Meanwhile `mint` and `redeem` were frozen and
    ///      `backingInvariantHolds()` published FALSE - the contract contradicting itself, which is
    ///      the R4-01 finding verbatim. In the healthy state `idleCustodyShortfall() == 0` makes
    ///      the two bases identical, so this is a STRICT TIGHTENING: headroom can only shrink,
    ///      withholding can only increase, and the healthy path is bit-for-bit unchanged.
    ///
    ///      (2) IT IS ZERO WHILE PAUSED. See `pause`. This is what lets `mintYield` keep
    ///      `whenNotPaused` - an absolute rule about supply expansion - without a guardian key
    ///      being able to stop every borrower repayment as a side effect.
    ///
    ///      (3) IT NETS OUT `seniorSubParShortfall()`. See that function. Without this, value
    ///      recovered from a released impairment mark becomes yield to the `sUSDfr` vault instead
    ///      of coverage for the holders who bore the mark.
    ///
    ///      (4) IT IS ZERO WHILE THE USDfr TOKEN IS PAUSED, NOT ONLY WHILE THIS CONTRACT IS
    ///      (AUDIT FIX R18) - DO NOT DELETE THE `$.usdfr.paused()` TERM. R17 shipped (2) reading
    ///      only `paused()`, this contract's own Pausable. The SAME guardian address holds
    ///      `GUARDIAN_ROLE` on `USDfr` (`Deploy.s.sol` grants both), and `USDfr._update` refuses
    ///      every mint while the token is paused - its protocol-leg carve-out requires
    ///      `from != address(0)`, which a mint can never satisfy. So one un-timelocked
    ///      `USDfr.pause()` still made `mintYield` REVERT, and `WaterfallEngine.distribute` is
    ///      atomic, so it took every borrower repayment down with it: principal leg, attestation
    ///      spend, exposure release, lifecycle transition. The clamp built to prevent exactly that
    ///      harm could not see the pause that caused it. Both pauses now read zero here, so either
    ///      one WITHHOLDS instead of reverting.
    ///
    ///      The four compose as a floor: whichever binds hardest wins, and each only ever
    ///      REDUCES what may be minted, so none of them can create an over-issuance.
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState`. See
    ///      `Controller_ViewUnavailableMidTransition` - mid-burn this view read the ENTIRE realised
    ///      loss of a cascade as distributable yield capacity, and it is the exact quantity
    ///      `WaterfallEngine._routeInterest` sizes real yield off.
    function mintableHeadroom() external view returns (uint256) {
        _requireSettledState();
        ControllerStorage storage $ = _storage();
        // THE SAME THIRD SURFACE AS `previewRedeem` (Cantina 3.1.3). Advertising headroom while
        // the reserve is paused publishes a mint that cannot execute: `mint` reaches
        // `reserves.depositUSDC`, which is `whenNotPaused` on the reserve.
        if (!_accrualAvailable($) || paused() || $.usdfr.paused() || IPausableModule(address($.reserves)).paused()) {
            return 0;
        }
        uint256 backing = $.reserves.recognizedBackingValue();
        // AUDIT FIX (ADR-0034 Y-bis) - `exitPrepaidAbsorption()` IS RETAINED ALONGSIDE
        // `subParShortfall`, AND DELETING IT REOPENS THE LEAK ON THE JUNIOR SIDE. The junior draw
        // burns junior USDfr against a mark (`recognizePrincipalImpairment`) that is CONSERVATIVE
        // and REVERSIBLE. If the mark is later released, backing rises while supply is already
        // lower by the drawn amount, so the book carries a surplus of exactly the standing
        // prepayment. Untreated, this view reads that surplus as distributable and
        // `WaterfallEngine._routeInterest` mints it to the `sUSDfr` vault as yield - the curator's
        // crystallised loss becomes the senior's income. That is the identical leak R17's
        // `seniorSubParShortfall` closed for the EXITER's haircut, aimed at the junior tranche
        // instead. Retained, not recycled.
        //
        // IT IS A STOCK NETTED OFF A LEVEL, exactly like `subParShortfall` beside it, and NOT a
        // cumulative stock differenced against a per-transaction flow - the shape that broke an
        // adjacent fix on this same view.
        //
        // WHAT IT DOES NOT DO, SAID PLAINLY: there is no restitution path. A fully reversed mark
        // leaves the curator permanently down and the value parked in this retention. Minting it
        // back needs `CuratorModule` as a yield sink and a reversal of the per-pool share
        // arithmetic. OUTSTANDING, and named as such.
        //
        // SWEEP-2 S2-F3 - OPEN, AND DELIBERATELY NOT FIXED IN THIS ROUND. STOPPED FOR A FOREST ROAD
        // DECISION. The ledger has exactly TWO consumers: `realizeLoss`'s layer-0 credit
        // (`ReserveManager.consumeExitPrepayment`, bounded by the facility's RECOGNISED MARK) and
        // this netting. On an UNMARKED deficit - an idle write-down, a custody-reconciliation
        // residual - the first has no route to fire (`totalPrincipalImpairment() == 0`, so the
        // layer-0 credit is 0 and ReserveManager's live custody cascade deliberately does not
        // consume the ledger, correctly avoiding a double charge), so the retention here stands
        // forever and the book closes permanently over-backed by exactly the junior capital the
        // exit burned. MEASURED: a
        // 9,900.99e18 draw, a par settlement, `seniorSubParShortfall() == 0`, and
        // `mintableHeadroom() == 0` for good.
        //
        // WHY IT IS NOT REMEDIATED HERE. Every available cure is an ECONOMIC choice under
        // CLAUDE.md section 0.7 and prime directive 5, not a safety fix:
        //   (a) retiring the ledger releases the surplus into `_routeInterest` - i.e. junior
        //       crystallised capital becomes SENIOR YIELD, which is the exact leak this term was
        //       added to close, merely on a different trigger;
        //   (b) refunding the curator needs `CuratorModule` as a yield sink plus a reversal of the
        //       per-pool share arithmetic - a new mechanism, not an audit-round edit;
        //   (c) leaving it is what ships today: the junior tranche's payment is retained as
        //       over-collateralisation for the remaining USDfr holders, and the withholding is on
        //       the SENIOR YIELD LEG, not a second charge on the junior tranche.
        // Bounding it by `totalPrincipalImpairment()` was evaluated and REJECTED: it releases the
        // surplus at the exact moment a mark is RELEASED, which is when the leak (a) actually
        // fires. Forest Road must choose between (a), (b) and (c); do not choose it in code.
        uint256 claimed = _effectiveSupply($) + $.subParShortfall + $.reserves.exitPrepaidAbsorption();
        return backing > claimed ? backing - claimed : 0;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE CRYSTALLISED SENIOR HAIRCUT (AUDIT FIX R17) - DO NOT DELETE, AND DO NOT ADD A
    ///      SETTER THAT LOWERS IT.
    ///
    ///      THE PROBLEM IT ANSWERS. `ReserveManager.recognizePrincipalImpairment` is a governance
    ///      VALUATION act, and a REVERSIBLE one: `releasePrincipalImpairment` exists precisely
    ///      because, as its own NatSpec says, an irreversible mark "would be a one-way ratchet ...
    ///      and governance would rationally refuse to mark at all". R16 made that reversible mark
    ///      PRICE-EFFECTIVE for exits the instant it lands. A holder who redeemed during the
    ///      window crystallised a PERMANENT loss against a TEMPORARY number; when the mark was
    ///      later released, the recovered value reappeared as headroom and `_routeInterest` minted
    ///      it to the `sUSDfr` vault. The senior exiter's haircut became someone else's yield -
    ///      and it did so before the cascade's junior layer (curator first-loss) had absorbed
    ///      anything, which is the ordering `DefaultManager.realizeLoss`
    ///      refuses to invert (it reverts with `DefaultManager_LossExceedsAbsorptionCapacity`
    ///      rather than let a loss reach unstaked USDfr holders).
    ///
    ///      WHAT THIS DOES. Every sub-par settlement adds `usdfrIn - valuePaid` here, and
    ///      `mintableHeadroom()` subtracts the running total. Recovered value therefore stays in
    ///      the pool as COVERAGE for the holders who are still in it, rather than being minted out
    ///      as yield. It is monotonic and has no setter on purpose: a governance lever that could
    ///      lower it would restore the leak in one transaction.
    ///
    ///      WHAT THIS DOES NOT DO, SAID PLAINLY. It does not REPAY the exiter - there is no
    ///      on-chain record of who exited at what price beyond the `SubParRedemption` and
    ///      `SeniorShortfallCrystallised` events, and building a claims register for departed
    ///      holders is a materially larger design than an audit round should introduce
    ///      unilaterally. It converts "the haircut is captured by the yield layer" into "the
    ///      haircut is retained by the remaining USDfr holders as over-collateralisation".
    ///
    ///      WHAT IT COSTS - R18 REWROTE THIS, BECAUSE R17'S VERSION UNDERSTATED IT AND ITS STATED
    ///      CURE WAS CIRCULAR. R17 said "the cost is bounded and one-off: interest is withheld
    ///      until backing exceeds supply plus this total, after which yield flows normally
    ///      forever". Three things were wrong with that sentence and an auditor must have the
    ///      correct ones:
    ///        1. IT IS NOT ONLY INTEREST. `mintYield` enforces the retention as an ABSOLUTE level
    ///           check, so ORIGINATION FEES are refused by it too - and under R17 that refused
    ///           `WaterfallEngine.fund` OUTRIGHT, because `fund`'s fee mint was the one `mintYield`
    ///           caller not sized off `mintableHeadroom()`.
    ///        2. THE CURE WAS CIRCULAR, WHICH IS FINDING M5's SHAPE. Withheld interest requires a
    ///           performing facility; a new facility requires `fund`; `fund` was refused. After a
    ///           terminal workout - the residual absorbed by the cascade, `deployedPrincipal() == 0`,
    ///           nothing left to release - nothing on chain could pay interest, so "after which
    ///           yield flows normally forever" had no "after which". R18 CLOSES THAT: `fund` now
    ///           clamps its fee to `mintableHeadroom()` and WITHHOLDS instead of reverting, so
    ///           origination stays open and its interest is once again a reachable cure. The
    ///           retention itself is unchanged.
    ///        3. THE QUANTITY IS THE WHOLE LOSS, NOT THE HAIRCUT ALONE. Yield resumes only once
    ///           `recognizedBackingValue() - totalUSDfr() >= seniorSubParShortfall()`, i.e. the
    ///           protocol must earn back the standing deficit AND this retention out of interest.
    ///      The remaining cures, stated so an operator can act on them: withheld interest from any
    ///      performing facility, `ReserveManager.releasePrincipalImpairment` on a still-REVERSIBLE
    ///      mark, and `WaterfallEngine.setOriginationFee(classId, 0)` (DEFAULT_ADMIN, timelocked)
    ///      which removes the fee mint from `fund` altogether.
    ///
    ///      THE KNOWN OVER-CHARGE, DISCLOSED RATHER THAN FIXED. The justification above is that
    ///      value RECOVERED when a REVERSIBLE mark is released must stay with the holders who bore
    ///      it. This code cannot distinguish a mark that will be released from one that becomes a
    ///      REALISED loss, and accrues in both cases. On the realised path there is nothing left to
    ///      recover - curator first-loss and the senior vault have already
    ///      paid, and the exiter already bore their own haircut - so the retention keeps standing
    ///      against a recovery that can never arrive. The alternative named at the end of this
    ///      paragraph in R17 (a REALISED-LOSS WATERMARK: hold the crystallised amount pending and
    ///      retire it when the cascade allocates the corresponding loss) is the right answer to
    ///      that and is NOT implemented here: retiring retention on a `burnLoss` requires the
    ///      controller to know which burns correspond to which crystallisation, which is a
    ///      `DefaultManager` coordination change, and it would make this quantity non-monotonic -
    ///      the property the whole mitigation rests on. R18's clamp removes the ORIGINATION FREEZE
    ///      that made the over-charge severe; the over-charge itself is OUTSTANDING and is a Forest
    ///      Road decision on the brief's Part 4 locked economics (CLAUDE.md section 0.5/section 0.7), alongside
    ///      ADR-0034 (see `_redeem`), which decides the adjacent question of the exit PRICE.
    function seniorSubParShortfall() external view returns (uint256) {
        return _storage().subParShortfall;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE DUST FLOOR, STATED HONESTLY RATHER THAN "FIXED", AND RE-DERIVED FOR THE BASKET.
    ///      There is no such thing as a fraction of an asset's smallest unit to pay out, so a leg
    ///      whose pro-rata share floors below one native unit pays nothing. The floor is therefore
    ///      no longer a constant and is no longer global: it is
    ///      `ceil(min_i(scale_i) * supply / backing)` over the PAYING legs, which is ONE WEI for the
    ///      all-18-decimal genesis pair and becomes material only when a sub-18-decimal asset is
    ///      listed. It is published THROUGH THIS VIEW rather than in prose, so the frontend states
    ///      the floor instead of discovering it by simulating a revert. The alternatives are worse:
    ///      rounding UP pays out cash that is not backed, and a dust ledger adds storage and a claim
    ///      mechanism for sub-cent amounts.
    ///
    /// @dev IT PRICES ON THE RECOGNISED BASIS - DO NOT "ALIGN" IT WITH `redeem` BY MOVING IT TO
    ///      `totalBackingValue()`. The two share the ARITHMETIC; they do not share the
    ///      PRECONDITIONS, and that is the whole point. `redeem` sits behind the custody gate, which
    ///      guarantees the recorded and recognised bases are equal by the time it quotes. This view
    ///      sits behind nothing - it is permissionless and needs no KYC - so on the recorded basis
    ///      it would publish a PAR quote in exactly the state where the recorded ledger is known to
    ///      be false, for a call that would then revert. Wherever `redeem` is actually REACHABLE the
    ///      two bases are identical, so the quote is still exact there.
    ///
    /// @dev EVERY PAUSE SURFACE IS READ, INCLUDING THE RESERVE'S - CANTINA 3.1.3 LIMB (a), CLOSED.
    ///      There are now THREE whole-quote pauses and three PER-ASSET limbs, and they act at
    ///      different granularities on purpose:
    ///        - this contract's `paused()`      -> whole quote to zeros (`redeem` is `whenNotPaused`)
    ///        - `usdfr.paused()`                -> whole quote to zeros (the burn cannot execute)
    ///        - `reserves.paused()`             -> whole quote to zeros (the release is `whenNotPaused`)
    ///        - `row.frozenRedeem` (per asset)  -> that LEG's weight to zero
    ///        - a live reserve-loss arm         -> see `Controller_AssetAdjudicationPending`
    ///        - a per-asset custody shortfall   -> the protocol-wide R4-01 gate below
    ///      The Ethereum instance reads the first two and not the third, and the reason it misses
    ///      the third is mechanical: `ReserveManager` inherits `paused()` from `PausableUpgradeable`
    ///      and never declares it on `IReserveManager`, so nothing in the type system pointed at it.
    ///      `IPausableModule` is that pointer. The per-asset limbs are handled for free by
    ///      `_payableBasket`, so this view and `_redeem` consume ONE enumeration of "which legs
    ///      pay" - the property that stops two views of one published quantity from disagreeing.
    ///
    /// @dev LIMB (b) REMAINS OPEN, DELIBERATELY, AND THE SAFETY DIRECTION IS WHAT MAKES IT
    ///      TOLERABLE. `drawn = 0` here, so below par this view publishes the UNDRAWN floor while
    ///      `redeem` settles at the junior-drawn price, which is equal or BETTER. Passing this
    ///      number back as `minValueOut` can therefore never revert on slippage. Anyone tempted to
    ///      "fix" the undrawn quote should note that moving it in the OTHER direction would make the
    ///      published number unsafe to use as a floor. Simulating the draw needs live curator
    ///      capacity, which is not reachable from this contract. ON THIS INSTANCE THE COST OF
    ///      CLOSING IT IS UNMEASURED: the Ethereum acceptance rests on a 218-byte cost in a
    ///      `DefaultManager` that had 183 bytes left, and ADR-0037 D3a(ii) removes that contract's
    ///      whole layer-two branch, so the figure does not carry across. MEASURE BEFORE INHERITING
    ///      THE ACCEPTANCE.
    ///
    /// @dev THE PER-LEG AMOUNTS ARE LOWER BOUNDS, AND THE COUPLING THAT MAKES THEM SO IS NAMED HERE
    ///      SO IT CANNOT SILENTLY BREAK. This view reproduces the reserve's PROPORTIONAL FLOOR pass
    ///      and deliberately NOT its sub-unit dust pass, and that pass can only ADD to a leg. So
    ///      settlement allocates at least these units and pays at least this `valueOut`. IF
    ///      `ReserveBasketLib` EVER GAINS A PASS THAT REDUCES A LEG, THIS STOPS BEING A FLOOR and
    ///      the quote becomes unsafe to bind against.
    ///
    /// @dev IT IS NOT A PROMISE ACROSS TRANSACTIONS. `recordPrincipalWritedown` and friends can move
    ///      the ratio in the next block or the same one, and a leg that was payable at quote and
    ///      frozen at settlement lowers `valuePaid` below this number so `minValueOut` binds and the
    ///      exit REVERTS. That is the correct fail-closed outcome, and it is a new way for a quoted
    ///      number to fail that the Ethereum instance does not have: a freeze between quote and
    ///      settlement means REQUOTE.
    /// @dev During review this view uses msg.sender's records. RPC clients must set the holder as
    ///      `from`; a router or other account has its own record limit. Outside review the existing
    ///      holder-agnostic basket composition remains, including its documented record-path limits.
    function previewRedeem(uint256 usdfrAmount)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valueOut)
    {
        _requireSettledState();
        ControllerStorage storage $ = _storage();
        Basket memory basket = _payableBasket($, usdfrAmount);
        assets = basket.tokens;
        amounts = new uint256[](assets.length);
        if (!_accrualAvailable($) || paused() || $.usdfr.paused() || IPausableModule(address($.reserves)).paused()) {
            return (assets, amounts, 0, 0);
        }
        // The protocol-wide R4-01 gate. `redeem` is refused in this state, so quoting a settleable
        // price here would be the contract contradicting itself inside one block.
        if ($.reserves.idleCustodyShortfall() != 0) return (assets, amounts, 0, 0);
        if (basket.pendingAsset != address(0) || basket.totalPayable == 0 || usdfrAmount == 0) {
            return (assets, amounts, 0, 0);
        }
        usdfrIn = basket.totalPayable == basket.grossPayable
            ? usdfrAmount
            : Math.mulDiv(usdfrAmount, basket.totalPayable, basket.grossPayable);
        if (usdfrIn == 0) return (assets, amounts, 0, 0);
        // `drawn = 0`: the undrawn floor. See the limb (b) note above.
        valueOut = _quoteRedeemValue(usdfrIn, _effectiveSupply($), $.reserves.recognizedBackingValue(), 0);
        if (valueOut == 0 || valueOut > basket.totalPayable) return (assets, amounts, 0, 0);
        (amounts, valueOut) = _previewSplit(basket, valueOut);
        if (valueOut == 0) return (assets, amounts, 0, 0);
    }

    /// @inheritdoc IMintRedeemController
    function isYieldSink(address account) external view returns (bool) {
        return _storage().yieldSink[account];
    }

    /// @inheritdoc IMintRedeemController
    function isLossSource(address account) external view returns (bool) {
        return _storage().lossSource[account];
    }

    /// @notice Wired module addresses (for post-deploy validation and the dashboard).
    function modules() external view returns (address usdfr, address compliance, address reserves) {
        ControllerStorage storage $ = _storage();
        return (address($.usdfr), address($.compliance), address($.reserves));
    }

    // -- Internals --------------------------------------------------------

    function _requireKYC(ControllerStorage storage $, address account) private view {
        if (!$.compliance.isAllowed(account)) revert Controller_NotKYCAllowed(account);
    }

    /// @dev AUDIT FIX (R18) - LOAD-BEARING, DO NOT DELETE FROM ANY VIEW THAT CARRIES IT. The
    ///      READ-ONLY-REENTRANCY GUARD on the composite views.
    ///
    ///      THE WINDOW IS THE PROTOCOL'S OWN DESIGNED CALLBACK, NOT AN EXOTIC ONE. `_redeem` burns
    ///      (supply down) BEFORE `releaseBasket` lowers backing, and `DefaultManager.realizeLoss`
    ///      burns curator first-loss and the senior vault BEFORE `recordPrincipalWritedown` lowers
    ///      backing. `USDfr._update` fires the participation-points hook inside every one of those
    ///      burns. The R18 adversarial round measured an observer holding control there reading
    ///      `mintableHeadroom()` as the ENTIRE realised loss of a cascade - 400,000e18 of phantom
    ///      yield capacity, where the view reads 0 on both sides of the transaction -
    ///      `backingInvariantHolds()` as TRUE on a 20%-short book, and `previewRedeem` as PAR on
    ///      the same book. `mintableHeadroom()` is the exact quantity
    ///      `WaterfallEngine._routeInterest` sizes real yield off.
    ///
    ///      WHY REVERT RATHER THAN RETURN A NUMBER. R4-01's standard, which this file invokes
    ///      repeatedly, is that the contract must not contradict itself inside one block;
    ///      `backingInvariantHolds()`'s own NatSpec cites exactly that. Answering with a number
    ///      known to be false is the contradiction. A named revert is the honest answer and is
    ///      fail-CLOSED for an integrator: a `try/catch` reader sees "unavailable", never a lie.
    ///      The WRITE half was already closed - every entry point is `nonReentrant`, pinned by
    ///      `test_R17_G04_mintIsReentrancyLocked` and siblings - so this closes the read half with
    ///      the same slot and no new state.
    ///
    ///      THE RAW DELEGATING VIEWS (`backingValue`, `recognizedBackingValue`, `totalUSDfr`) ARE
    ///      DELIBERATELY NOT GATED. Each is a single live read of one module and is TRUE whenever it
    ///      is read - mid-transition included. What is false mid-transition is the COMPOSITION of a
    ///      supply reading with a backing reading taken at different points of the same state
    ///      change, so it is exactly the composites that are gated.
    function _requireSettledState() private view {
        if (_reentrancyGuardEntered()) revert Controller_ViewUnavailableMidTransition();
    }

    /// @dev THE R4-01 GUARD, NOW PER ASSET - LOAD-BEARING, DO NOT DELETE. The MINT door for one
    ///      asset is closed while the reserve holds less of THAT asset than its idle ledger claims.
    ///      The reserve publishes that gap to anyone for free; if nothing consumes it, the protocol
    ///      goes on selling par claims against a hole until the live balance is gone.
    ///
    ///      SUB-PAR PRICING DOES NOT REPLACE THIS AND MUST NOT BE ARGUED TO. Sub-par pricing
    ///      protects holders when the protocol KNOWS what it is worth. An unreconciled custody gap
    ///      is precisely the state in which it does NOT: the tally is a claim the live balance has
    ///      falsified, so any quote derived from it would over-pay by exactly the size of the hole.
    ///      Recognition first; then `reconcileIdleUnits` writes the ledger down to the truth; THEN
    ///      sub-par pricing is meaningful and the door reopens by itself.
    ///
    ///      IT IS NOT A LATCH, and no role is needed to clear it: restoring custody, or the
    ///      permissionless `reconcileIdleUnits` writing the ledger down to the live balance, reopens
    ///      that asset in the same block with no governance action.
    ///
    ///      WHY THIS IS NOT FOLDED INTO THE DEFICIT RULE, and must not be. The custody cascade's own
    ///      burn runs while this shortfall is standing: the reserve allocates the loss and burns
    ///      supply BEFORE it lowers the tally. A recognition-aware assertion on the credit-layer
    ///      paths would revert those burns and brick custody-loss absorption entirely, which is the
    ///      opposite of the intent. Recognition closes the USER window; absorption stays
    ///      authenticated and unobstructed.
    ///
    ///      `idleCustodyShortfallOf` IS STORAGE-ONLY ON THIS RESERVE - it reads a LATCHED shortfall,
    ///      not a live `balanceOf` - so a token that reverts on every call cannot reach it and
    ///      cannot make this check itself fail. A reader who expects an external read here because
    ///      the Ethereum sibling has one should note the difference: the live read lives in the
    ///      reserve's own permissionless `reconcileIdleUnits`, at the edge, where a failure is local
    ///      to that asset and produces no latch at all.
    function _requireCustodiedAsset(ControllerStorage storage $, address asset) private view {
        uint256 shortfall = $.reserves.idleCustodyShortfallOf(asset);
        if (shortfall != 0) {
            revert Controller_ReserveCustodyShortfall(asset, shortfall, $.reserves.recognizedBackingValue());
        }
    }

    /// @dev THE R4-01 GUARD ON THE EXIT SIDE. The `continue` on a refused leg is load-bearing: a leg
    ///      the basket will not pay from must never be able to close a leg it will. That is the
    ///      R2-M-03 brick class ADR-0037 section 4.4 names as the sharpest thing the registry must not
    ///      reintroduce, and its falsifier is a listed asset that is payout-frozen and whose token
    ///      reverts on every call, with the sound leg's exit still working.
    ///
    ///      THE SECOND CHECK IS NOT REDUNDANT AND IS NOT A RELAXATION - READ BOTH BEFORE PRUNING
    ///      EITHER. `ReserveManager.releaseBasket` applies its OWN R4-01 gate and that gate is
    ///      deliberately PROTOCOL-WIDE: it is a LOSS predicate, not a token-liveness predicate, and
    ///      allocation is protocol-wide because supply is protocol-wide. So a latched shortfall in a
    ///      leg this basket would not have paid from still refuses the release. Without the
    ///      aggregate check here that refusal would arrive from inside the reserve AFTER the burn in
    ///      a caller's simulation, with a reserve-internal error. The per-leg loop names the ASSET
    ///      when the short leg is one the exit would have paid from; the aggregate names the
    ///      protocol with `address(0)`. Both are honest; neither is dead.
    ///
    ///      THE PER-ASSET RELAXATION THE DESIGN WANTS IS THE RESERVE'S TO MAKE. If the reserve's own
    ///      gate ever becomes per asset, this loop is already the right shape and only the aggregate
    ///      check below would come out.
    function _requireCustodiedPayableLegs(ControllerStorage storage $, Basket memory basket) private view {
        uint256 n = basket.tokens.length;
        for (uint256 i; i < n; ++i) {
            if (basket.payableValue[i] == 0) continue;
            uint256 shortfall = $.reserves.idleCustodyShortfallOf(basket.tokens[i]);
            if (shortfall != 0) {
                revert Controller_ReserveCustodyShortfall(
                    basket.tokens[i], shortfall, $.reserves.recognizedBackingValue()
                );
            }
        }
        uint256 aggregate = $.reserves.idleCustodyShortfall();
        if (aggregate != 0) {
            revert Controller_ReserveCustodyShortfall(address(0), aggregate, $.reserves.recognizedBackingValue());
        }
    }

    /// @dev Reads the reserve basket and applies the holder's recorded-deposit limit during review.
    ///      The linked helper uses storage-backed reserve getters only. A pending review counts
    ///      even when its asset is empty or redeem-frozen, so receipts cannot change admission.
    function _payableBasket(ControllerStorage storage $, uint256 requested) private view returns (Basket memory) {
        return ControllerAccrualLib.payableBasket($.reserves, msg.sender, requested);
    }

    /// @dev VERIFICATION OF THE RESERVE'S OWN ANSWER - LOAD-BEARING, DO NOT DELETE ANY OF THE FOUR
    ///      CHECKS. The controller does not compute the split (see `_redeem`), so this is where it
    ///      refuses to take the reserve's word for it. Every check reads MEMORY and the controller's
    ///      own cached scales; none of them touches a token, so a hostile, paused or gas-bombing
    ///      reserve asset cannot make the verification itself revert.
    ///        1. POSITIONAL STABILITY. The returned legs must BE the registry, in listing order, at
    ///           full length. The router pairs legs with assets by index; a reserve that reordered,
    ///           truncated or padded would silently mis-pair every integrator.
    ///        2. NO REFUSED LEG IS PAID. A leg the basket weighted at zero must move nothing. This
    ///           is what makes the frozen-leg REFUSAL real rather than advisory.
    ///        3. THE VALUE BOUND, AND THIS IS THE ONE CHECK ADR-0038 CHANGED. It used to be the
    ///           EQUALITY `sum units_i * scale_i == valuePaid`, which caught a reserve that over-paid
    ///           one leg while under-booking its ledger. Under the record-capped exit a settlement
    ///           may legitimately carry value that moved NO units, when the redeemer's own recorded
    ///           asset is deployed into a facility and the reserve escrows a deferred claim on it
    ///           instead. So the equality relaxes to `sum units_i * scale_i <= valuePaid` and the
    ///           difference is RETURNED as the promised part rather than swallowed. THE HALF THAT
    ///           WAS LOST IS REPLACED, NOT DROPPED: the caller must then measure that promise
    ///           against the reserve's own claim-liability ledger (R13b), which is a second
    ///           measurement and not a restatement of the reserve's word. A reviewer who sees only
    ///           the `<=` here and concludes the guard was weakened has read half of it.
    ///        4. NO OVER-PAYMENT. `valuePaid <= valueOut`. Every rounding in the allocation is DOWN,
    ///           so this holds by construction on the honest path; it is the cheap, legible
    ///           statement of the bound, and it is the only thing between an allocation bug and an
    ///           exiting holder being paid out of the holders who stayed.
    /// @return promised `valuePaid` minus the value of the units actually moved: the part settled as
    ///         a deferred claim on the redeemer's own recorded asset. Zero on every pure-basket
    ///         settlement, which is every settlement by a holder with no deposit record.
    function _assertBasketSettled(
        Basket memory basket,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 valuePaid,
        uint256 valueOut,
        uint256 usdfrIn
    ) private pure returns (uint256 promised) {
        uint256 n = basket.tokens.length;
        if (tokens.length != n || amounts.length != n) {
            revert Controller_BasketShapeMismatch(n, address(0), address(0));
        }
        uint256 measured;
        for (uint256 i; i < n; ++i) {
            if (tokens[i] != basket.tokens[i]) {
                revert Controller_BasketShapeMismatch(i, basket.tokens[i], tokens[i]);
            }
            uint256 units = amounts[i];
            if (units == 0) continue;
            if (basket.payableValue[i] == 0) {
                revert Controller_RedemptionNotSettled(basket.tokens[i], 0, units, usdfrIn);
            }
            measured += units * basket.scale[i];
        }
        if (measured > valuePaid || valuePaid > valueOut) {
            revert Controller_BasketValueMismatch(measured, valuePaid);
        }
        promised = valuePaid - measured;
    }

    /// @dev The ordinary basket quote floors each leg. During review, the shared record allocator
    ///      gives the holder's own composition and refuses an unrepresentable remainder. The
    ///      quoted value includes existing same-currency pending claims when healthy records are
    ///      not fully funded; the units array contains only immediately allocatable units.
    function _previewSplit(Basket memory basket, uint256 valueOut)
        private
        pure
        returns (uint256[] memory amounts, uint256 valuePaid)
    {
        return ControllerAccrualLib.previewSplit(basket, valueOut);
    }

    /// @dev The one solvency measurement, read on the RECORDED basis. Deliberately NOT
    ///      recognition-aware - see `_requireCustodiedAsset` for why a recognition-aware
    ///      measurement on the supply-affecting paths would brick the C-01 absorption cascade,
    ///      and `ReserveManager`'s MERGE NOTE for why `totalBackingValue()` must stay recorded.
    function _supplyAndBacking(ControllerStorage storage $) private view returns (uint256 supply, uint256 backing) {
        supply = _effectiveSupply($);
        backing = $.reserves.totalBackingValue();
    }

    function _effectiveSupply(ControllerStorage storage $) private view returns (uint256) {
        return address($.accrual) == address(0)
            ? $.usdfr.totalSupply()
            : ControllerAccrualLib.supply(address($.accrual), address($.usdfr));
    }

    function _requireAccrualFresh(ControllerStorage storage $) private view {
        if (address($.accrual) != address(0)) $.accrual.requireAccrualFresh();
    }

    function _accrualAvailable(ControllerStorage storage $) private view returns (bool) {
        return address($.accrual) == address(0) || ControllerAccrualLib.available(address($.accrual));
    }

    function _mintBaseline(ControllerStorage storage $) private view returns (MintBaseline memory before_) {
        before_.rawSupply = $.usdfr.totalSupply();
        (before_.supply, before_.backing) = _supplyAndBacking($);
    }

    /// @dev THE SINGLE SOLVENCY RULE (ADR-0012 as amended by audit round R16 - findings
    ///      M3/M4/M5) - LOAD-BEARING, DO NOT DELETE FROM ANY CALL SITE. An operation may not
    ///      INCREASE `deficit = max(0, totalSupply - backingValue)`.
    ///
    ///      WHICH BASIS THIS MEASURES (R17 CORRECTION - R16 STATED THE RULE IN BASIS-FREE TERMS AN
    ///      AUDITOR WOULD READ AS COVERING BOTH). It measures the RECORDED deficit only. That is
    ///      correct for `mint` and `redeem`, which sit behind the custody gates and so
    ///      cannot execute at all while the two bases differ, and it is deliberate for `burnLoss`,
    ///      which carries no assertion because it can only lower supply. It was NOT sufficient for
    ///      `mintYield`, the one supply-EXPANDING path with no custody precondition, which is why
    ///      that path additionally asserts `_assertRecognizedDeficitNotWorsened`.
    ///
    ///      WHILE THE PROTOCOL IS WHOLE THIS IS ADR-0012, UNCHANGED. `deficitBefore == 0` forces
    ///      `deficitAfter == 0`, i.e. `totalSupply <= backingValue`, and it still reverts with
    ///      `Controller_BackingInvariantViolated(supply, backing)` - the same error, the same
    ///      arguments, the same meaning. Nothing about the healthy path is relaxed.
    ///
    ///      WHILE THE PROTOCOL IS SHORT IT IS THE RULE THE ABSOLUTE FORM COULD NOT EXPRESS. The
    ///      absolute form said only "supply exceeds backing", which is already true and stays
    ///      true, so it reverted every operation including the ones that repair the hole. The
    ///      distinct `Controller_DeficitWorsened` error exists so that a caller in this state is
    ///      told the operation was refused for WIDENING the gap, not that a gap exists - an
    ///      auditor or an integrator reading `Controller_BackingInvariantViolated` in a
    ///      knowingly sub-par protocol would reasonably conclude the check was firing for the
    ///      standing condition.
    ///
    ///      IT IS MEASURED, NOT ASSUMED - BUT IT IS A NON-WORSENING RULE, AND R18 CORRECTED WHAT
    ///      R17 CLAIMED THAT BUYS. Both readings do come from live external calls to the token and
    ///      the reserve, taken before and after the operation. R17 concluded from that: "a module
    ///      that reports one thing and does another is caught here even when the operation's own
    ///      arithmetic looks correct." THAT SENTENCE WAS FALSE WHENEVER THE PROTOCOL CARRIED
    ///      SURPLUS. The rule is non-worsening, so a discrepancy is caught only for the part
    ///      EXCEEDING `backingValue() - totalUSDfr()`; the standing surplus silently pays for the
    ///      rest. R17 made that worse rather than better, because `mintableHeadroom()` now nets out
    ///      `seniorSubParShortfall()` and `_routeInterest` therefore mints down to
    ///      `surplus == retention` rather than to zero - so after any crystallised haircut the
    ///      protocol is DESIGNED to sit permanently on a masking budget of exactly that size.
    ///      The correct statement is: this rule catches only the part of any discrepancy that
    ///      exceeds the standing surplus, and it is a BACKSTOP, not the primary measurement. The
    ///      primary measurements are the LEVEL-FREE DELTA CHECKS on the operations themselves -
    ///      `Controller_DepositNotCustodied` (custody), `Controller_DepositNotRecognized`
    ///      (recognition, added in R18 for exactly this reason) and
    ///      `Controller_RedemptionNotSettled` (outflow) - each of which is an EQUALITY on a measured
    ///      delta that no surplus can absorb.
    function _assertDeficitNotWorsened(ControllerStorage storage $, uint256 supplyBefore, uint256 backingBefore)
        private
        view
    {
        (uint256 supplyAfter, uint256 backingAfter) = _supplyAndBacking($);
        uint256 deficitAfter = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
        uint256 deficitBefore = supplyBefore > backingBefore ? supplyBefore - backingBefore : 0;
        if (deficitAfter <= deficitBefore) return;
        if (deficitBefore == 0) revert Controller_BackingInvariantViolated(supplyAfter, backingAfter);
        revert Controller_DeficitWorsened(deficitBefore, deficitAfter);
    }

    /// @dev THE REDEMPTION VALUE QUOTE - shared by `redeem` and `previewRedeem` so the quoted price
    ///      and the settled price cannot diverge. It is ASSET-AGNOSTIC: it answers a value in
    ///      18-decimal USD, and the split into legs is a separate step. That separation is what
    ///      makes the arithmetic scale-free, and it is the largest structural difference from the
    ///      Ethereum sibling, whose `usdfrIn` was an OUTPUT produced by the whole-unit grid. Here
    ///      `usdfrIn` is an INPUT, the grid is gone, and per-leg flooring happens downstream.
    ///
    ///      ADR-0034 Y-bis IS IMPLEMENTED AND `drawn` IS WHAT IMPLEMENTS IT. Pricing the direct exit
    ///      off the GROSS book mark nets NOTHING against junior capital, so a holder redeeming while
    ///      curator capital sat intact would absorb a loss the junior tranche contracted to take
    ///      first - the locked cascade run backwards. The cure is not a change of basis: the
    ///      junior-netted price PROMISES more than gross-marked backing, and the difference sits in
    ///      the curator pools, not in the reserve's tokens. So `_drawJuniorForExit` MOVES that
    ///      capital in the same transaction and hands the result in here as `drawn`.
    ///
    ///      THE OVERFLOW BOUND (CANTINA 3.1.1) - RE-DERIVED AT SCALE 1, WHERE THE ETHEREUM
    ///      DISPOSITION DOES NOT SURVIVE. On Ethereum `usdfrIn = (usdfrAmount / 1e12) * 1e12`, so
    ///      the truncation returns `M mod 1e12` wei of headroom at the very top of the range and the
    ///      addition `usdfrIn + drawn` overflows only for inputs within 1e12 of
    ///      `type(uint256).max` - a panic window of width at most 2**40, unreachable in practice,
    ///      hence "acknowledged". WITH NO GRID `usdfrIn == usdfrAmount` exactly, that slack is gone
    ///      entirely, and the window widens to the whole top `drawn` of the range, which on a book
    ///      with any real deficit is astronomically larger. "Acknowledged, reachable only on the
    ///      under-backed path" was a judgement about the first window and is not a judgement about
    ///      this one.
    ///      THE REMEDY IS STRONGER THAN THE ONE ADR-0034 NAMES. ADR-0034 proposes `usdfrIn <=
    ///      supply`, which bounds the sum at `2 * supply`: unreachable, but REPRESENTABLE. Bounding
    ///      the SUM instead makes the overflow UNREPRESENTABLE. `supply - drawn` cannot underflow,
    ///      because `drawn` was burned out of `supply` so `drawn <= supply` unconditionally, and
    ///      `_redeem` passes the PRE-DRAW supply deliberately - the price is struck against the
    ///      pre-draw book, which is the algebra `_exitDrawTarget` derives. After the check
    ///      `usdfrIn + drawn <= supply <= type(uint256).max`. It refuses only inputs no holder can
    ///      hold, so it costs no reachable redemption, and `previewRedeem` (with `drawn = 0`) now
    ///      answers a controller error instead of a `Panic(0x11)` - the half of the finding that is
    ///      actually user-visible.
    ///
    ///      THE `supply == 0` EARLY RETURN STAYS AND STAYS FALSIFIABLE. Without it the
    ///      `backing >= supply` branch is `0 >= 0`, so an EMPTY protocol quotes PAR against supply
    ///      that does not exist. The explicit guard also carries the division safety, and unlike the
    ///      argument it replaces it is falsifiable by deletion.
    ///
    ///      THE PAR CEILING IS KEPT AND IS LABELLED HONESTLY. With `_exitDrawTarget`'s exact `ceil`
    ///      sizing it is UNREACHABLE and no mutation reds it, so DO NOT write a comment claiming one
    ///      does. It is kept because it is the only thing standing between a future sizing bug and
    ///      an exiting holder being paid ABOVE par out of first-loss capital, i.e. stealing the
    ///      junior tranche through `redeem`. Read it exactly as `mint`'s `forceApprove(..., 0)` is
    ///      read: hygiene that is cheap and legible, not protection that a test can prove.
    ///
    ///      THERE IS NO SLITHER `divide-before-multiply` TRIAGE TO PORT. The expression
    ///      `(usdfrAmount / SCALE) * SCALE` does not exist on this instance, so the Ethereum
    ///      baseline entry for it MUST NOT be copied across: a baseline entry for a finding that
    ///      cannot fire is a stale triage, and this repository has already recorded the cost of
    ///      stale triage twice.
    function _quoteRedeemValue(uint256 usdfrIn, uint256 supply, uint256 backing, uint256 drawn)
        private
        pure
        returns (uint256 valueOut)
    {
        if (supply == 0) return 0;
        uint256 bound = supply - drawn;
        if (usdfrIn > bound) revert Controller_RedeemExceedsSupply(usdfrIn, bound);
        if (backing >= supply) return usdfrIn;
        valueOut = Math.mulDiv(usdfrIn + drawn, backing, supply);
        if (valueOut > usdfrIn) valueOut = usdfrIn;
    }

    /// @dev ADR-0034 Y-bis - HOW MUCH JUNIOR CAPITAL THIS EXIT NEEDS. Pure so it can be reasoned
    ///      about and fuzzed on its own.
    ///
    ///      THE RULE. `d* = min( ceil(usdfrIn * D / B), D )` with `D = supply - backing`.
    ///
    ///      WHY `/B` AND NOT `/supply` - THIS IS THE WHOLE ARITHMETIC AND IT IS EASY TO GET WRONG.
    ///      Burning `d` of junior USDfr removes `d` from SUPPLY ONLY; backing does not move,
    ///      because junior capital is denominated in USDfr, not in the reserve's USDC. Requiring
    ///      that the holders who STAY are no worse off after the exit gives
    ///      `B(supply - d - u) <= supply(B - v)`, i.e. `v <= B(u + d)/supply`; setting `v = u`
    ///      (par) yields `d >= u * D / B`. A `u * D / supply` draw structurally UNDER-draws and
    ///      leaves the exiter impaired while junior capital sits intact - which is decision X's
    ///      defect, not its cure.
    ///
    ///      WHY IT CANNOT OVER-DRAW, WHICH IS ADR-0034's THIRD BINDING REQUIREMENT. Each draw
    ///      lowers supply by exactly `d` with backing unmoved, so `D' = D - d` EXACTLY, and the
    ///      exit itself lowers `D` by a further `u - v >= 0`. The stock therefore decrements by the
    ///      flow one-for-one and draws TELESCOPE: cumulative draw over any sequence of exits can
    ///      never exceed the `D` standing when the mark was taken.
    ///
    ///      THE `min(..., D)` CLAMP IS UNREACHABLE, AND THIS PARAGRAPH USED TO CLAIM OTHERWISE.
    ///      CORRECTED (SWEEP-3 S3-F4). It said the clamp "makes over-draw UNREPRESENTABLE rather
    ///      than merely bounded" and cited
    ///      `testFuzz_Y_G05_theDrawNeverExceedsTheStandingDeficit` as its falsifier. BOTH CLAIMS
    ///      WERE FALSE. MEASURED: neutralising the clamp so it still compiles and still reads both
    ///      operands leaves the ENTIRE non-fork suite byte-identical to baseline - including that
    ///      named fuzz test at 1,025 runs and the ADR-0034 Z certifier
    ///      `invariant_Z_noDrawExceedsTheStandingDeficit` at 256 runs x 32,768 calls. Zero catchers.
    ///      THE THEOREM, so nobody re-argues it: the clamp binds iff `ceil(u*D/B) > D`, i.e. iff
    ///      `u > B`. `drawn` is measured as a balance RISE on the source, so the tokens must arrive
    ///      from other USDfr balances: `drawn <= S - u - balBefore(source) <= S - u`. With
    ///      `u > B = S - D` that gives `drawn < D <= the clamped target`. The clamp can never change
    ///      `drawn` on any path, including against a lying source.
    ///      KEEP IT - it is the cheap, legible statement of the bound, exactly as the par ceiling in
    ///      `_quoteRedeem` is kept - but label it honestly, and DO NOT write a comment claiming a
    ///      mutation reds it.
    ///
    ///      WHY IT CANNOT UNDER-DRAW. The target rounds UP (`Ceil`); every other rounding in the
    ///      quote is DOWN. So R17's
    ///      `testFuzz_M3_aSubParExitNeverWorsensTheRatioForTheHoldersWhoStayed` property is
    ///      STRENGTHENED by this change, never weakened.
    ///
    ///      IT IS A FLOW COMPUTED FROM A STOCK, AND `pendingSeniorImpairment()` IS DELIBERATELY NOT
    ///      CONSULTED. That view is a CREDIT-layer stock in units of declared/past-due PRINCIPAL;
    ///      `D` is a CUSTODY/VALUATION quantity. They diverge in BOTH directions - a
    ///      custody write-down has `D > 0` with `pendingSeniorImpairment() == 0`, and
    ///      a declared-but-unmarked default has the reverse - so mixing them would either fail to
    ///      fund the exit at all or price a whole book sub-par. That mixing of a cumulative stock
    ///      into a per-transaction flow is precisely the shape that broke an adjacent
    ///      `mintableHeadroom()` fix.
    function _exitDrawTarget(uint256 usdfrIn, uint256 supply, uint256 backing) private pure returns (uint256 target) {
        if (usdfrIn == 0 || backing == 0 || backing >= supply) return 0;
        uint256 deficit = supply - backing;
        target = Math.mulDiv(usdfrIn, deficit, backing, Math.Rounding.Ceil);
        if (target > deficit) target = deficit;
    }

    /// @dev ADR-0034 Y-bis - THE ATOMIC JUNIOR DRAW - LOAD-BEARING, DO NOT DELETE. Read
    ///      `ADR/0034-exit-pricing-in-cascade-order.md` in full before changing anything here.
    ///
    ///      WHAT IT FIXES. `_quoteRedeem` priced the direct exit off GROSS `totalBackingValue()`,
    ///      which nets NOTHING against junior capital, while the `sUSDfr` path prices off
    ///      `DefaultManager.pendingSeniorImpairment()`, which nets curator first-loss and then the
    ///      curator pools. A holder redeeming while curator capital sat intact therefore absorbed
    ///      a loss the junior tranche contracted to take first - the locked section 1.3 cascade run
    ///      backwards. Forest Road (2026-08-08) decided the residual price and the draw are NOT
    ///      alternatives: the residual price PROMISES more than gross-marked backing, and the
    ///      difference sits in the curator pool and the backstop, not in the reserve's USDC. So
    ///      junior capital is drawn IN THIS TRANSACTION and cascade order is enforced AT
    ///      SETTLEMENT.
    ///
    ///      THE SOURCE IS DERIVED, NOT STORED, AND THAT IS DELIBERATE. `$.reserves.lossAbsorber()`
    ///      IS the cascade the protocol runs its losses through; `ReserveManager.setLossAbsorber`
    ///      already refuses any address whose `reserveLossSource()` does not point back at it. A
    ///      second stored pointer here would be a second source of truth that could DISAGREE - a
    ///      controller drawing from `DefaultManager` v1 while the reserve allocates losses through
    ///      v2 - and it would cost a namespaced tail field, a governance setter, an ACL-surface
    ///      re-pin and `Deploy`/`Validate`/`Handover` wiring to buy that risk. Deriving costs one
    ///      `staticcall` and cannot desynchronise.
    ///
    ///      THE BURN AUTHORISATION IS THE `lossSource` LIST, AND IT IS THE GUARD THAT MATTERS.
    ///      `$.usdfr.burn(source, drawn)` is raw MINTER_ROLE power over a third party's balance -
    ///      exactly the confiscation primitive R16-M1/M2 constrained. Requiring `source` to be a
    ///      governance-named loss source reuses that existing, already-deployed list rather than
    ///      inventing a parallel one, so a compromised or misconfigured `ReserveManager` can at
    ///      worst point this at an address that is not on the list - which REVERTS. It can never
    ///      make `redeem` burn a user's wallet. Falsified by
    ///      `test_Y_G02_theDrawRefusesASourceGovernanceHasNotNamedALossSource`.
    ///
    ///      IT BURNS IN PLACE RATHER THAN CALLING `burnLoss`. `burnLoss` is `nonReentrant` on THIS
    ///      contract and `redeem` already holds that lock, so the `DefaultManager.realizeLoss`
    ///      shape (draw, then call back into `burnLoss`) reverts with
    ///      `ReentrancyGuardReentrantCall`. The drawn USDfr is left standing at the source and
    ///      burned here. Anyone "restoring symmetry" with `realizeLoss` bricks every under-backed
    ///      exit.
    ///
    ///      MEASURE, DO NOT TRUST. The delivered amount is measured as a balance delta on the
    ///      SOURCE and must be AT LEAST what the source reported, and the report must be at most
    ///      what was requested. A source that over-reports, under-delivers, or hands back more than
    ///      asked can therefore only cause a REVERT, never an overpayment out of junior capital.
    ///      Falsified by `test_Y_G06_aLyingDrawSourceCanOnlyRevertTheExitNeverOverpayIt` (the
    ///      report/delivery legs) and by
    ///      `S2_GuardVacuity.t.sol::test_S2_anOverDeliveringDrawSourceMustStillBeRefused` (the
    ///      `reported > target` leg, which had NO falsifier in the tree until SWEEP-2 measured it
    ///      as a deletable guard).
    ///
    ///      AUDIT FIX (SWEEP-2 S2-F5): the delivery leg is a FLOOR, not an equality, because a
    ///      strict equality here is a redemption kill switch in the hands of the fail-open points
    ///      hook. The full finding is at the comparison itself - read it before touching this.
    ///
    ///      WHERE IT SITS IN `_redeem`, AND WHY IT MUST STAY THERE. It runs BEFORE the R18
    ///      `payeeBefore`/`payeeAfter` delivery window. The burn fires `USDfr`'s deliberately
    ///      FAIL-OPEN points hook and `CuratorModule` fires `IPointsModule.onCuratorLoss`, and
    ///      R18's general rule on `_redeem` is that no call a redeemer or a governance-set module
    ///      can influence may sit between `payeeBefore` and `payeeAfter`. DO NOT MOVE IT DOWN.
    ///
    ///      UNWIRED IS TOLERATED, AND ONLY BECAUSE IT IS SAFE. A zero `lossAbsorber()` draws
    ///      nothing and the exit settles at exactly today's gross price. That is the state every
    ///      deployment starts in, and refusing the exit there would be a fresh deadlock in the
    ///      state ADR-0034 exists to cure. `Validate.s.sol` asserts the production wiring.
    ///
    ///      NOT WIRED IS SAFE; WIRED-BUT-UNANSWERING IS NOT, AND THAT IS DELIBERATE. A source that
    ///      is present but cannot answer `drawForSeniorExit` reverts the exit rather than silently
    ///      pricing it at the gross mark. This follows the house rule `WaterfallEngine` states for
    ///      the same shape - optional wiring via a zero check, and NEVER `try/catch`, because "a
    ///      failure here must fail loudly" (CLAUDE.md prime directive 4). THE OPERATIONAL
    ///      CONSEQUENCE, STATED SO IT IS NOT DISCOVERED LATE: `DefaultManager` MUST BE UPGRADED
    ///      BEFORE THIS CONTROLLER. Upgrading the controller first leaves every UNDER-BACKED exit
    ///      reverting until the manager catches up. Par exits are unaffected in either order,
    ///      because no draw is attempted while `backing >= supply`.
    ///
    ///      SLITHER TRIAGE (CLAUDE.md section 3.2 - transcribe into `STATE.md` at merge). This function
    ///      adds `reentrancy-balance` on itself and on `_redeem` (which goes 1 -> 3), plus
    ///      `incorrect-equality`. Both are the guard, not a bug, and are the same triage `mint` and
    ///      `_redeem` already carry: a balance read STRADDLING an external call and gating a state
    ///      change IS the measurement. AUDIT FIX (SWEEP-2 S2-F5) CORRECTS THIS PARAGRAPH: it used
    ///      to say the STRICT EQUALITY is what makes a lying source fail closed in both directions,
    ///      and that "a `>=` relaxation would let a source over-deliver and strand USDfr". Both
    ///      halves were wrong. The equality was breakable by any third party pushing one wei into
    ///      the window (measured), and over-delivery is refused by `reported > target`, not by the
    ///      delivery comparison at all - the source cannot over-deliver AND report honestly without
    ///      failing that first check, and if it under-reports its own over-delivery the excess is
    ///      simply never burned. A non-straddling read would still let it lie, which is why the
    ///      straddle stays.
    ///      CORRECTED 2026-09-10, when `check-natspec-staleness` ran on this tree for the first
    ///      time. This paragraph used to point at DefaultManager._coverFromBackstop (deliberately
    ///      not backticked: naming it as code is the very error being corrected) as the
    ///      function keeping the same straddling measurement for facility defaults and senior
    ///      exits. THERE IS NO SUCH FUNCTION ON THIS INSTANCE, and there is no layer two for it to
    ///      draw on: ADR-0037 D3a(ii) deletes sGROVE, GROVE and the backstop outright, and
    ///      `DefaultManager` says so in its own header. The sentence was inherited from the
    ///      Ethereum tree and asserted a mechanism this contract does not have.
    ///
    ///      WHAT IS ACTUALLY TRUE HERE. The straddling measurement survives on the paths this
    ///      instance does have: `DefaultManager.realizeLoss` and `absorbReserveLoss` draw layer one
    ///      only (`ICuratorModule.absorbLoss` / `absorbGlobalLoss`), and `allocation.backstopCovered`
    ///      is pinned at zero. The live custody path performs its equivalent balance-delta check
    ///      inside `ReserveCascadeLib`. The extraction remains a RENAME with no net new finding.
    function _drawJuniorForExit(ControllerStorage storage $, uint256 usdfrIn, uint256 supply, uint256 backing)
        private
        returns (uint256 drawn)
    {
        uint256 target = _exitDrawTarget(usdfrIn, supply, backing);
        if (target == 0) return 0;

        address source = $.reserves.lossAbsorber();
        if (source == address(0)) return 0;
        if (!$.lossSource[source]) revert Controller_ExitDrawSourceNotAuthorised(source);

        uint256 balBefore = $.usdfr.balanceOf(source);
        uint256 reported = ISeniorExitDrawSource(source).drawForSeniorExit(target);
        uint256 balAfter = $.usdfr.balanceOf(source);
        uint256 delivered = balAfter < balBefore ? 0 : balAfter - balBefore;
        // -- AUDIT FIX (SWEEP-2 S2-F5) - THE MEASUREMENT IS A FLOOR, NOT AN EQUALITY --
        //
        // LOAD-BEARING IN BOTH DIRECTIONS. DO NOT RESTORE `drawn != reported || drawn > target`.
        //
        // WHY THE EQUALITY HAD TO GO. R18 found that `_redeem`'s outflow window contained a call
        // the deliberately FAIL-OPEN points hook could influence, hoisted the burn out, and wrote a
        // general rule into `_redeem`'s NatSpec: no call a redeemer or a governance-set module can
        // influence may sit inside a strict-equality balance window. ADR-0034 Y-bis then opened a
        // SECOND such window here. Everything inside `drawForSeniorExit` - `CuratorModule`'s USDfr
        // transfer to `DefaultManager`, `SGrove.coverShortfall`'s - fires `USDfr._update`'s points
        // hook, which is fail-open ONLY inside the token's own `try/catch`; a points module that
        // succeeds while transferring ONE WEI of USDfr into `source` broke `delivered == reported`,
        // and this revert is OUTSIDE that `try/catch`. MEASURED: `Controller_ExitDrawNotDelivered
        // (target=4950...50, reported=4950...50, measured=4950...51)` - exactly one wei bricked
        // EVERY under-backed exit, the one path ADR-0034 exists to keep open, and unwiring the
        // module reopened it in the same state.
        //
        // WHAT IS STILL FAIL-CLOSED, AND WHY THAT IS THE WHOLE SAFETY PROPERTY:
        //   * `reported > target`  -> REVERT. A source may never hand back more than it was asked
        //     for; ADR-0034 requirement 3 is that the draw brings absorption FORWARD in time, it
        //     does not ENLARGE it. This is also the disjunct SWEEP-2 M3 measured as unfalsifiable
        //     in its old `drawn > target` form (`LyingExitDrawSource` never moves a token, so both
        //     of its modes were caught by the equality alone). It now has a real falsifier:
        //     `S2_GuardVacuity.t.sol::test_S2_anOverDeliveringDrawSourceMustStillBeRefused`.
        //   * `delivered < reported` -> REVERT. A source that OVER-REPORTS or UNDER-DELIVERS still
        //     fails loudly, which is the house rule (CLAUDE.md prime directive 4) and the reason
        //     this is a measurement at all.
        // Only a THIRD PARTY pushing EXTRA tokens into the source is now tolerated, and it is
        // strictly harmless: `drawn` is set from `reported`, which is bounded by `target`, so the
        // donation is neither burned nor credited to the redeemer's price. It simply sits at the
        // loss absorber, exactly as an unsolicited transfer to any module does.
        if (reported > target || delivered < reported) {
            revert Controller_ExitDrawNotDelivered(target, reported, delivered);
        }
        drawn = reported;
        if (drawn == 0) return 0;
        $.usdfr.burn(source, drawn);
        emit SeniorExitJuniorDrawn(msg.sender, target, drawn);
    }

    /// @dev A callback cannot replace the implementation or its authorities while a guarded
    ///      financial operation is using them. An idle controller remains governable when stale.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        _requireSettledState();
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        _requireSettledState();
        return super._revokeRole(role, account);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        _requireSettledState();
    }

    /// @dev CANTINA 3.1.2. A module must be a contract, must not be a delegated EOA, and must
    ///      answer the view the controller will call on it.
    ///
    ///      EXACT CALLDATA, not a bare selector with a padded argument: solc's dispatcher ignores
    ///      trailing calldata, so a selector-plus-argument probe would silently succeed against a
    ///      no-argument view and prove less than it appears to. `staticcall` so a probe can never
    ///      mutate; the returned value is discarded because what is tested is that the call
    ///      SUCCEEDS and returns a word.
    ///
    ///      THE EIP-7702 LIMB WAS ADDED 2026-09-10, and it closes an inconsistency rather than a
    ///      new attack. `setLossSource` already refuses a delegated EOA through `_isDelegatedEOA`:
    ///      since Pectra an ordinary key-controlled EOA that has signed a `SetCode` authorization
    ///      carries a 23-byte code field, so `code.length == 0` stopped being a test for "is a
    ///      contract". This probe was still using the old test, so the same address the loss-source
    ///      setter refuses could be wired in as a module here. Two guards in one contract
    ///      disagreeing about what counts as a contract is the kind of gap an auditor is entitled
    ///      to find embarrassing.
    ///
    ///      WHAT THIS STILL DOES NOT PROVE, stated because the previous version of this comment
    ///      claimed more than it delivered. A probe that only asks "does a staticcall return a
    ///      word" cannot distinguish a real module from an implementation reached instead of its
    ///      proxy, from an unrelated token that happens to answer, or from a fallback sink that
    ///      returns 32 bytes for any selector. Those remain admissible and the controls for them
    ///      are elsewhere: timelocked `DEFAULT_ADMIN_ROLE` on every setter, and the deployment
    ///      validator asserting each wired address against the manifest. Do not read this probe as
    ///      authentication; it is a liveness check that turns a silent misconfiguration into a loud
    ///      one.
    function _requireModuleResponds(address module, bytes memory callData) private view {
        if (module.code.length == 0 || _isDelegatedEOA(module)) revert Controller_ModuleNotResponding(module);
        (bool ok, bytes memory data) = module.staticcall(callData);
        if (!ok || data.length < 32) revert Controller_ModuleNotResponding(module);
    }

    function _storage() private pure returns (ControllerStorage storage $) {
        assembly {
            $.slot := CONTROLLER_STORAGE_LOCATION
        }
    }
}
