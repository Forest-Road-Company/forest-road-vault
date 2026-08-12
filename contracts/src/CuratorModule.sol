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

import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {IConservativeImpairmentBook} from "./interfaces/IConservativeImpairmentBook.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {IGovernanceSchedule, ITimelockSchedule} from "./interfaces/IGovernanceSchedule.sol";
import {IPointsModule} from "./interfaces/IPointsModule.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title CuratorModule — per-class curator first-loss vaults (ADR-0004)
/// @notice Cascade LAYER 1 (CLAUDE.md §1.3 ordering): curator capital absorbs realized
///         losses before the sGROVE backstop and before any depositor impairment.
///         Each collateral class has its own USDfr pool; multiple curators in a class
///         hold internal shares so partial absorptions dilute all of them exactly
///         pro-rata. A fully wiped pool advances to a new share round: stale-round
///         shares are worth zero and are cleared lazily on the holder's next post.
///
///         SUBORDINATION HEADROOM: capital protecting live exposure cannot leave —
///         withdrawals are capped at `poolBalance - requiredFirstLoss(classId)`, where the
///         requirement is `max(min(firstLossTarget, classExposure), declaredDefaulted + pastDue)`.
///         AUDIT FIX (SWEEP-2 CSG-F1): the second term is NOT decoration. Until it was added this
///         line read `poolBalance - min(firstLossTarget, classExposure)` and was FALSE — the
///         conservative senior NAV credits layer 1 at `min(declared + pastDue, poolBalance)`, so
///         on any class whose exposure exceeds its target a curator could withdraw capital the
///         senior redemption price was already extending credit for. See `_requiredFirstLoss`.
///         Curators earn nothing here; their return comes from origination economics.
///         Senior (`sUSDfr`) is therefore never subordinated to this junior capital.
///
///         TWO INDEPENDENT WITHDRAWAL FREEZES, one per loss path. Headroom alone is not
///         enough: it is a LEVEL check against live exposure and says nothing about a loss
///         already in flight. R4-EC2 freezes a class on a FACILITY default
///         (`unresolvedDefaults`, armed by `freezeOnDefault`); R6-CF1 freezes ALL classes
///         while a reserve-CUSTODY loss is recognised, observable or incompletely absorbed
///         (`custodyFreezeActive`, derived from the ReserveManager plus an optional guardian
///         pre-arm). Neither substitutes for the other, and removing either re-opens a
///         curator's ability to exit ahead of a loss it is layer 1 for.
/// @dev `absorbLoss` is deliberately NOT pausable: the guardian can halt curator
///      post/withdraw traffic, but never the loss cascade — a paused cascade during a
///      credit event would block honest loss recognition (CLAUDE.md fail-loudly).
contract CuratorModule is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ICuratorModule
{
    using SafeERC20 for IERC20;

    /// @notice The largest share/balance ratio a class pool may carry before `postFirstLoss`
    ///         treats it as WIPED and starts a fresh round (AUDIT FIX SWEEP-3 S3-F1).
    /// @dev 1e18 = a share price of 1e-18, i.e. one share worth less than the smallest
    ///      representable unit of an 18-decimal token. See the block in `postFirstLoss` for why
    ///      this constant exists, what it bounds, and why lowering it back to "exact zero" (which
    ///      is what any value above 1e18 approaches) re-opens a permissionless liveness brick on
    ///      cascade layer 1. Below 1e18 outstanding shares this reduces EXACTLY to the shipped
    ///      `balance == 0` predicate, so it is strictly a widening.
    uint256 internal constant MAX_SHARE_INFLATION = 1e18;

    /// @notice AUDIT FIX (SWEEP-4 S4-R1). How many CLOSED rounds one call will walk a stale stake
    ///         through. See `_settleStaleRound` for why the walk exists, why it must be bounded,
    ///         and why a bound is not a loss: `claimClosedRound` keeps the progress of every hop it
    ///         makes, so a chain longer than this is recovered by calling it again.
    /// @dev Each hop requires a class's layer-1 pool to have been driven to a share price of 1e-18
    ///      or below and then recapitalised, so 32 unclaimed closes on one stake is far outside any
    ///      operational scenario; the bound exists to keep worst-case gas finite on the very
    ///      recapitalisation path S3-F1 exists to protect, not because 32 is expected to bind.
    uint256 private constant MAX_CLOSED_ROUND_HOPS = 32;

    struct ClassPool {
        uint256 balance; // USDfr actually held for this class
        uint256 totalShares; // internal pro-rata shares over `balance`
        uint256 round; // advances when a pool is wiped to zero with shares outstanding
        // Cumulative power-of-two reduction applied to share units in this round.
        // Appended for upgrade safety; zero is the legacy scale.
        uint256 shareScale;
    }

    struct CuratorStake {
        uint256 shares;
        uint256 round; // shares are valid only while round == pool.round
        // Scale at the last write to this stake; conversion is lazy and rounds down.
        uint256 shareScale;
    }

    /// @notice AUDIT FIX (SWEEP-4 S4-R1). The residual-claim snapshot taken when a round is CLOSED
    ///         as economically wiped while a non-zero balance still stands.
    /// @dev It is a pure CONVERSION RATE, not a pot of money. At the close the new round opens with
    ///      `totalShares == balance` (share price exactly 1) and those shares are minted with NO
    ///      owner; this snapshot records who owns them. `carriedShares` therefore stays inside
    ///      `pool.totalShares` and inside `pool.balance` for the whole of its life, which is what
    ///      makes the residual keep absorbing as cascade layer 1 exactly as it did before the close.
    ///      Both fields are decremented on each settlement, so the remaining holders always divide
    ///      the remaining carried shares — the standard remaining/remaining form, exact under
    ///      floor division with the dust favouring the pool.
    struct ClosedRound {
        uint256 shares; // unsettled shares OF the closed round (the denominator)
        uint256 carriedShares; // shares of round+1 those unsettled shares collectively own
        // Lazy share-scale normalization is aggregate state. Record the scale at the close so a
        // stale stake written before a later normalization is converted into this snapshot's
        // units before the remaining/remaining division.
        uint256 shareScale;
    }

    /// @custom:storage-location erc7201:forestroad.storage.CuratorModule
    struct CuratorStorage {
        IERC20 usdfr;
        ICollateralRegistry registry;
        mapping(uint256 classId => ClassPool) pools;
        mapping(uint256 classId => mapping(address curator => CuratorStake)) stakes;
        mapping(uint256 classId => mapping(address curator => bool)) approved;
        mapping(uint256 classId => uint256) targets; // first-loss target (ADR-0004)
        // AUDIT FIX (R4-EC2): per-class count of unresolved defaults. Non-zero freezes
        // curator withdrawals so a curator cannot front-run realizeLoss to pull excess
        // first-loss ahead of a loss it should absorb. Incremented by the DefaultManager
        // on default entry (declareDefault / liquidate), decremented by governance on
        // workout resolution. (Append-only: added at the tail for upgrade safety.)
        mapping(uint256 classId => uint256) unresolvedDefaults;
        // AUDIT FIX (P-01): participation-points hook. First-loss capital accrues points at
        // the curator multiple (in lieu of only earning origination economics). Optional;
        // fail-open so a points failure can never block first-loss post/withdraw.
        IPointsModule pointsModule;
        // Vault fee-accounting coordinator. Brackets capacity writes so a curator
        // top-up/withdrawal cannot be mistaken for senior investment performance.
        IsUSDfr feeVault;
        // ── AUDIT FIX (R6-CF1) tail: the reserve-CUSTODY arm of the withdrawal freeze ─────
        // APPEND-ONLY TAIL. These four fields MUST stay last and MUST NOT be reordered, retyped
        // or moved: `CuratorModule` sits behind a live UUPS proxy and everything above is already
        // written on-chain. `tools/check-storage-layout.mjs` and
        // `tools/check-compiled-storage-layout.mjs` both enforce this.
        //
        // WHY THEY EXIST (do not delete): R4-EC2 froze withdrawals on a FACILITY default, and the
        // only writer of `unresolvedDefaults` is `DefaultManager.freezeOnDefault`. The
        // reserve-CUSTODY loss path armed nothing, so a curator could pull every dollar of
        // headroom between an adjudicated custody incident being recognised and its write-down
        // executing — handing a loss that curator capital is LAYER 1 for straight to the sGROVE
        // backstop and senior depositors. `reserves` is the source of the derived freeze predicate;
        // `governor` supplies the live governance-path length the guardian pre-arm must outlast.
        IReserveManager reserveManager;
        address governor;
        uint64 custodyPreArmExpiry;
        uint32 custodyPreArmCount;
        // ── AUDIT FIX (SWEEP-4 S4-R1) tail: closed-round residual claims ──────────────────────
        // APPEND-ONLY TAIL, SAME RULE AS THE R6-CF1 BLOCK ABOVE: this mapping MUST stay last and
        // MUST NOT be reordered or retyped. Both storage-layout gates enforce it.
        //
        // WHY IT EXISTS (do not delete): SWEEP-3 S3-F1 fixed a real liveness brick by closing a
        // round once the share price falls to or below 1e-18, and it forfeited the residual
        // `balance` to the pool as UNOWNED backing. Its NatSpec bounds that forfeiture as dust on
        // the assumption that the share price is near 1. It is not: `totalShares` is not bounded by
        // the balance, because a post made while the price is ALREADY collapsed mints
        // `mulDiv(amount, totalShares, balance)` shares. MEASURED on the shipped tree
        // (`SweepR4_CuratorClosedRounds`): after one such ordinary recapitalisation a
        // 0.999e18 loss closed the round and destroyed a 1_000e18 curator claim — a thousandfold
        // amplification of the loss the cascade actually took, on the permissionless ADR-0034 Y-bis
        // draw path. This mapping is what carries that claim across the close.
        mapping(uint256 classId => mapping(uint256 round => ClosedRound)) closedRounds;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.CuratorModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CURATOR_STORAGE_LOCATION =
        0x3ed45dc5309d95eb5c32609ee7ca79f82c5062e7efdb606949190d8a38c9b400;

    /// @notice AUDIT FIX (F3-PA-c) — THE BOUND THE PRE-ARM DURATION IS DERIVED FROM. Ceiling on the
    ///         governance path `custodyPreArmDuration()` will honour. Governance can set
    ///         `votingDelay`/`votingPeriod`/`minDelay` to arbitrary values, so without a bound a
    ///         retuned parameter (or an overflowing sum) could turn a guardian pre-arm into an
    ///         unbounded lock on curator capital.
    ///
    ///         DO NOT CHANGE ONE OF THESE TWO CONSTANTS WITHOUT THE OTHER. The pre-arm's stated
    ///         requirement is that it strictly EXCEED the governance path it was derived from.
    ///         R6-CF1 shipped the cap on the DURATION only, and each of the three terms capped at
    ///         `CUSTODY_PRE_ARM_MAX_DURATION` — so a path of up to 3 x 90 days could be summed and
    ///         then silently truncated to a 90-day window, INVERTING the requirement stated in
    ///         `custodyPreArmDuration`'s own NatSpec with no signal of any kind. The cap now binds
    ///         on the PATH, and `CUSTODY_PRE_ARM_MAX_DURATION == CUSTODY_PRE_ARM_MAX_PATH * 3 / 2`
    ///         EXACTLY, which makes the duration clamp provably non-binding and the
    ///         "duration > bounded path" property structural rather than incidental. Beyond
    ///         `CUSTODY_PRE_ARM_MAX_PATH` the cap does still bind — but never silently: see
    ///         `custodyPreArmCoversLiveGovernancePath` and the `CustodyFreezePreArmTruncated`
    ///         event, and `script/Validate.s.sol`, which refuses a deployment whose pre-arm no
    ///         longer OUTLASTS the live path.
    ///
    ///         P-49 — BE PRECISE HERE, THE TWO CONDITIONS ARE NOT THE SAME. The cap binding is
    ///         not by itself a refusal. Once the path exceeds `CUSTODY_PRE_ARM_MAX_PATH` the
    ///         derived duration pins at `CUSTODY_PRE_ARM_MAX_DURATION` (90 days), which still
    ///         outlasts any live path below 90 days. So for a live path in
    ///         (60 days, 90 days) the cap BINDS and coverage still HOLDS; refusal begins at a
    ///         live path of 90 days, where duration ceases to exceed it. This block previously
    ///         claimed a deployment was refused wherever the cap binds, and the validator did
    ///         not check either condition — see P-49.
    uint64 public constant CUSTODY_PRE_ARM_MAX_PATH = 60 days;

    /// @notice AUDIT FIX (R6-CF1). Ceiling on one guardian pre-arm. Equal to
    ///         `CUSTODY_PRE_ARM_MAX_PATH * 3 / 2` by construction — see the note above.
    uint64 public constant CUSTODY_PRE_ARM_MAX_DURATION = 90 days;

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). The fail-closed sentinel `_markedFirstLoss` returns when
    ///      the wired loss absorber cannot answer `declaredDefaultedPrincipal`/`pastDuePrincipal`.
    ///      `type(uint128).max` is ~3.4e38 USDfr: unreachably above any pool balance (USDfr's
    ///      supply is bounded by the reserve's USDC backing), so `_headroom` floors to zero and
    ///      every withdrawal is refused, while `requiredFirstLoss()` publishes an obviously
    ///      sentinel value rather than reverting. DO NOT lower it to a "realistic" number: the
    ///      point is that it can never be a plausible requirement that someone reads as real.
    uint256 private constant _UNREADABLE_BOOK_LOCK = type(uint128).max;

    /// @notice AUDIT FIX (R6-CF1, corrected by F3-PA-b). How many times a guardian may arm or
    ///         re-arm the custody freeze WITHIN ONE EPISODE before governance must intervene. Two
    ///         is deliberate — one initial arm plus one extension carries the freeze across the
    ///         full governance path with margin, and no more.
    ///
    ///         "CONSECUTIVE" IS NOW TRUE OF THE COUNTER, AND IT WAS NOT. R6-CF1 shipped this bound
    ///         against a LIFETIME counter that nothing ever reset except `cancelCustodyPreArm`.
    ///         Two arms anywhere in the protocol's life therefore spent the guardian's emergency
    ///         lever PERMANENTLY, and the only way back was a timelocked governance transaction —
    ///         i.e. the fast lever could only be restored at the speed of the slow one, which is
    ///         the whole thing it exists to outrun. `preArmCustodyFreeze` now opens a NEW episode
    ///         (count back to zero) once the previous pre-arm has lapsed AND layer-1 capital has
    ///         stood genuinely unfrozen for `custodyPreArmCooldown()`.
    ///
    ///         THE COOLDOWN IS WHAT KEEPS THE BOUND A BOUND. Resetting on mere lapse would let a
    ///         guardian chain episodes back-to-back and hold a permanent freeze with the budget
    ///         still nominally "spent". Because the cooldown is `MAX_CONSECUTIVE x duration`,
    ///         measured from the lapse, the guardian's unilateral duty cycle can never exceed 50%
    ///         and every episode is followed by a real, reachable, unfrozen window.
    uint32 public constant CUSTODY_PRE_ARM_MAX_CONSECUTIVE = 2;

    /// @dev AUDIT FIX (F3-PA-d). Gas ceiling on each governance-parameter read. A governor address
    ///      is governance-set and its code is not ours; an unbounded staticcall lets a hostile or
    ///      broken governor burn the caller's gas and take `preArmCustodyFreeze` down with it. An
    ///      out-of-gas sub-call returns `success == false` here, which falls back to the `Config`
    ///      floor — the guardian still arms.
    uint256 private constant GOV_READ_GAS = 100_000;

    /// @dev ERC-6372 clock description the live governance-path read requires, as the governor
    ///      returns it: the ABI encoding of the string, not the string's own hash. Anything else
    ///      denominates voting windows in units that must not be added to `block.timestamp`.
    ///      AUDIT FIX (F3-PA-d): comparing RETURNDATA rather than a decoded value is what removes
    ///      the uncatchable `abi.decode` revert — see `_clockIsTimestamp`.
    string private constant CLOCK_MODE_TIMESTAMP = "mode=timestamp";

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the module and seeds the five genesis classes with the
    ///         ADR-0004 default first-loss target ($10M/class).
    /// @param admin Governance timelock (approves curators, sets targets).
    /// @param guardian Emergency pauser (post/withdraw only — never the cascade).
    /// @param upgrader Upgrade authority (timelock).
    /// @param usdfr First-loss denomination asset.
    /// @param registry Collateral registry (class exposure for the headroom rule).
    /// @param feeVault sUSDfr vault whose conservative NAV nets this capacity.
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address usdfr,
        address registry,
        address feeVault
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr == address(0)
                || registry == address(0) || feeVault == address(0)
        ) revert Curator_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        CuratorStorage storage $ = _storage();
        $.usdfr = IERC20(usdfr);
        $.registry = ICollateralRegistry(registry);
        $.feeVault = IsUSDfr(feeVault);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.targets[classId] = Config.DEFAULT_FIRST_LOSS_PER_CLASS;
            emit FirstLossTargetSet(classId, Config.DEFAULT_FIRST_LOSS_PER_CLASS);
        }
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @notice Approves or revokes `curator` for `classId` (anchor curator = Forest
    ///         Road, additional curators pluggable per ADR-0004). Revocation blocks
    ///         new posts only; the existing stake keeps absorbing and stays
    ///         withdrawable within headroom.
    function setCuratorApproved(uint256 classId, address curator, bool approved)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (curator == address(0)) revert Curator_ZeroAddress();
        _requireKnownClass(classId);
        _storage().approved[classId][curator] = approved;
        emit CuratorApproved(classId, curator, approved);
    }

    /// @notice Sets a class's first-loss target (the subordination requirement while
    ///         exposure is at or above it). Governance-adjustable per ADR-0004.
    function setFirstLossTarget(uint256 classId, uint256 target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        _storage().targets[classId] = target;
        emit FirstLossTargetSet(classId, target);
    }

    /// @notice Emitted when the participation-points hook changes.
    event PointsModuleUpdated(address indexed module);

    /// @notice Wires the participation-points hook so first-loss capital accrues points
    ///         (P-01). Timelocked governance only.
    /// @dev P-48b: a CODELESS module is refused. `onCuratorStakeChange` and `onCuratorLoss`
    ///      return no data, so solc emits an `extcodesize` guard BEFORE the call and therefore
    ///      OUTSIDE the fail-open `try` at :609, :663 and :1464. Without this check a single
    ///      governance call would make those hooks fail CLOSED and block `postFirstLoss`,
    ///      `withdrawFirstLoss` and — most seriously — `absorbLoss`, defeating in one step the
    ///      property both call sites promise in terms: "never block the never-pausable cascade".
    ///      `P48b_CuratorCodelessPointsModule.t.sol` pins the guard and the state it prevents.
    /// @param module The points ledger, or zero to disable the hook entirely.
    function setPointsModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module != address(0) && module.code.length == 0) revert Curator_PointsModuleNotAContract(module);
        _storage().pointsModule = IPointsModule(module);
        emit PointsModuleUpdated(module);
    }

    /// @notice The wired participation-points hook (zero disables it).
    function pointsModule() external view returns (address) {
        return address(_storage().pointsModule);
    }

    // ── Curator paths ────────────────────────────────────────────────────

    /// @inheritdoc ICuratorModule
    function postFirstLoss(uint256 classId, uint256 amount) external nonReentrant whenNotPaused {
        CuratorStorage storage $ = _storage();
        if (!$.approved[classId][msg.sender]) revert Curator_NotApprovedCurator(classId, msg.sender);
        if (amount == 0) revert Curator_ZeroAmount();
        $.feeVault.beginFeeNeutralMarkedNavChange();

        ClassPool storage pool = $.pools[classId];
        // A wiped pool (balance zero, shares outstanding) starts a new round: the old
        // shares are worthless and must not dilute fresh capital.
        //
        // ── AUDIT FIX (SWEEP-3 S3-F1) — "WIPED" IS A RATIO, NOT AN EXACT ZERO ────────────────
        //
        // LOAD-BEARING. DO NOT NARROW THIS BACK TO `pool.balance == 0`, AND DO NOT DELETE THE
        // `pool.totalShares = pool.balance` LINE BELOW.
        //
        // WHAT WAS WRONG. The predicate was `pool.balance == 0 && pool.totalShares != 0`, an EXACT
        // wipe. `absorbLoss`/`absorbGlobalLoss` clamp to what the pool holds, so a loss ONE WEI
        // short of the balance left the round standing with a collapsed share price, and every
        // later `postFirstLoss` multiplied the share/balance ratio by `total / residual`.
        // The residual is ATTACKER-CHOSEN: `MintRedeemController._exitDrawTarget` is
        // `ceil(usdfrIn * deficit / backing)` and the redeemer picks `usdfrIn` at 1-wei
        // granularity, so the draw takes EVERY integer value in range including `curatorTotal - 1`.
        // Any KYC'd USDfr holder, any time the book is short, no role required.
        //
        // MEASURED: ONE permissionless under-backed redemption left ALL FIVE class pools at 1 wei
        // against 1,000e18 shares (ratio 1e21). Three such draws with ordinary recapitalisation in
        // between made `postFirstLoss` revert on `Math.mulDiv` overflow for EVERY curator, while
        // `postedOf` floored to zero for every holder of less than the whole share supply — so
        // nobody could withdraw the surviving wei that kept the round from advancing. Cascade
        // layer 1 was unfundable for that class, with no governance lever on `pools[classId]`.
        // This is a LIVENESS defect, not a value-conservation one: attribution stayed exact
        // throughout (`test_S3_N1_theInflatedRatioStillAttributesValueCorrectly`).
        //
        // WHY 1e18. At `balance * 1e18 <= totalShares` the share price is at or below 1e-18, i.e.
        // one share is worth less than the smallest representable unit of an 18-decimal token: the
        // old stakes are economically nil. THE MAXIMUM ANYONE LOSES AT AN ADVANCE IS THE WHOLE
        // RESIDUAL `balance`, and the rule is self-limiting — because the ratio can never exceed
        // 1e18, `balance >= totalShares / 1e18`, and `totalShares` is bounded by what was posted
        // in the round. On a 1,000,000e18 pool that caps the forfeited dust at 1e6 wei
        // (1e-12 USDfr). It also bounds `mulDiv(amount, totalShares, balance) <= amount * 1e18`,
        // which is what removes the overflow brick.
        //
        // WHY `totalShares = pool.balance` AND NOT ZERO. Zeroing the shares while a non-zero
        // residual stands would mint `shares == amount` against `balance == amount + residual`,
        // pushing the share price ABOVE 1 and breaking the shipped invariant this contract's own
        // NatSpec relies on (measured: `[FAIL: share price never exceeds 1]`). Seeding the new
        // round with `totalShares == balance` leaves the price at exactly 1 — the new round opens
        // 1:1 — and the residual stands as backing that keeps absorbing before any curator's fresh
        // capital.
        //
        // ── AUDIT FIX (SWEEP-4 S4-R1) — THE RESIDUAL IS NOW OWNED, NOT FORFEITED ─────────────
        //
        // WHAT S3-F1 GOT WRONG. It called the forfeited residual "dust" and bounded it by
        // `totalShares / 1e18`, reasoning from a share price near 1. THE BOUND DOES NOT HOLD:
        // `totalShares` is not bounded by the balance. A post made while the price is already
        // collapsed mints `mulDiv(amount, totalShares, balance)`, which inflates `totalShares` by
        // up to 1e18x against the SAME balance — so after one ordinary recapitalisation the close
        // threshold sits just under the WHOLE pool. MEASURED (`SweepR4_CuratorClosedRounds`):
        // a 999000999000999002-wei loss (0.0999% of the pool) closed the round and destroyed a
        // 1000000000000000001001-wei curator claim. A thousandfold amplification of the loss the
        // cascade actually took, reachable by any KYC'd redeemer on the ADR-0034 Y-bis draw path.
        //
        // THE FIX IS A SNAPSHOT, NOT A RESERVE. `_advanceRoundIfWiped` records
        // `closedRounds[classId][round] = {shares: oldTotalShares, carriedShares: balance}`: the
        // closing cohort collectively owns the `balance` shares the new round opens with, and
        // `_settleStaleRound` hands each of them their pro-rata slice lazily.
        //
        // WHY NOT A SEPARATE CLAIM RESERVE — REJECTED, WITH THE REASON. Moving the residual OUT of
        // `pool.balance` into a set-aside pot is the obvious shape, and it INVERTS THE CASCADE:
        // that residual is curator capital, it is layer 1, and CLAUDE.md §1.3 requires it to absorb
        // before the sGROVE backstop and before depositor principal. A set-aside stops absorbing,
        // so the next loss of that size would skip layer 1 and land on layer 2 — and because the
        // residual is NOT bounded as dust (see above), the amount skipped is not bounded either.
        // A set-aside would also drop `poolBalance()`, which is the exact quantity
        // `ConservativeImpairmentMath.pendingSeniorImpairment` reads as layer-1 credit, so the two
        // enumerations would disagree — the SEAM-class defect this repository has paid for twice.
        // The snapshot form moves NOTHING: `pool.balance`, `poolBalance()`, `headroom()`,
        // `absorbLoss` and `absorbGlobalLoss` are all bit-for-bit unchanged by a close, and the
        // carried shares dilute with every later loss exactly as the capital behind them does.
        //
        // Falsified by `test_S3_F1_layerOneMustStillBeReFundableAfterNearTotalExitDraws`,
        // `test_S3_F1_theFacilityRouteInflatesTheShareRatioIdentically` and
        // `test_S3_F1_oneExitDrawCanCollapseTheShareRatioInEveryClassAtOnce`. The control
        // `test_S3_F1_control_aFullDrawAdvancesTheRoundAndRecapitalisationKeepsWorking` pins that
        // the exact-wipe behaviour is unchanged.
        //
        // WHY THE NORMALISATION IS LAZY — IT BELONGS HERE AND NOWHERE ELSE. I first put the same
        // call in `absorbLoss`/`absorbGlobalLoss` so a collapsed ratio could never even STAND in
        // storage. MEASURED, that broke a real value property: `testFuzz_absorbLoss_proRataExact`
        // reds with `at most 1 wei dust per curator: 2 < 4`, because advancing the round inside the
        // absorption zeroes stale stakes and a curator's legitimate claim on the 4-wei residual is
        // forfeited AT THE LOSS. Attribution is exact while the ratio merely SITS collapsed —
        // `postedOf` still floors correctly and `withdrawFirstLoss` still works — so the collapse
        // is only ever harmful at the next MINT, which is exactly here. Normalising at the loss
        // traded a real attribution property for a cosmetic one. DO NOT MOVE THIS CALL INTO THE
        // CASCADE. (Consequence, stated rather than hidden: between a near-total absorption and the
        // next post, `poolShares()` publishes a ratio a reader cannot interpret. It is inert —
        // nothing in `src/` consumes it — and it is registered as INFO.)
        _advanceRoundIfWiped($, classId, pool);
        _normalizePoolShares(classId, pool);

        CuratorStake storage stake = $.stakes[classId][msg.sender];
        // AUDIT FIX (SWEEP-4 S4-R1) — THIS REPLACED `stake.shares = 0`, AND MUST NOT GO BACK.
        // Unconditionally zeroing a stale stake is what forfeited the residual. Settling converts
        // it instead; a stake too stale to convert in one step REFUSES the post rather than
        // erasing the claim (see `_settleStaleRound` for why the refusal is not a brick).
        // `stakeRound` is read BEFORE settling: the whole call reverts, so reporting the post-hop
        // round would tell an operator where the stake is NOT.
        uint256 stakeRound = stake.round;
        if (!_settleStaleRound($, classId, pool, msg.sender, stake)) {
            revert Curator_UnsettledClosedRound(classId, stakeRound, pool.round);
        }
        _syncStakeShares(pool, stake);

        // SHARE-PRICE <= 1 INVARIANT (fuzzed in CreditInvariants): only absorption
        // changes the balance/share ratio, and only downward; withdrawals burn
        // ceil-rounded shares, which cannot push the price above 1. Therefore
        // totalShares >= balance always, and shares >= amount >= 1 here — no zero-share
        // mint is reachable.
        uint256 shares;
        if (pool.totalShares == 0) {
            shares = amount;
        } else {
            uint256 availableShares = type(uint256).max - pool.totalShares;
            if (amount > availableShares / 2) revert Curator_ShareCapacityExceeded(amount, availableShares);
            shares = Math.mulDiv(amount, pool.totalShares, pool.balance);
        }

        stake.shares += shares;
        stake.shareScale = pool.shareScale;
        pool.totalShares += shares;
        pool.balance += amount;
        $.usdfr.safeTransferFrom(msg.sender, address(this), amount);
        $.feeVault.endFeeNeutralMarkedNavChange();
        emit FirstLossPosted(classId, msg.sender, amount, shares, pool.round);
        _notifyPoints($, classId, msg.sender); // P-01: accrue points on the new posted first-loss
    }

    /// @inheritdoc ICuratorModule
    /// @dev ADR-0034 Y-bis NOTE (SWEEP-1 CSG-N1, 2026-08-08) — STATED BECAUSE IT IS CURRENTLY
    ///      INCIDENTAL, NOT DESIGNED. `DefaultManager.drawForSeniorExit` charges ALL FIVE class
    ///      pools pro-rata, but R4-EC2's `unresolvedDefaults` freeze is PER CLASS, so a curator in
    ///      an untouched class looks free to run ahead of a draw that will charge them.
    ///
    ///      IT IS CLOSED, EXACTLY, BY R6-CF1 LIMB 4 — but only by coincidence of predicate.
    ///      `MintRedeemController._exitDrawTarget` returns non-zero only while
    ///      `usdfr.totalSupply() > reserves.totalBackingValue()`, and `custodyLossUnabsorbed()`
    ///      limb 4 reads `controller.totalUSDfr() > controller.backingValue()`, which are literally
    ///      the same two reads. So the freeze is live on precisely the set where a draw can fire,
    ///      and it freezes EVERY class, not just the defaulted one — verified end to end
    ///      (a FILM-only impairment leaves `unresolvedDefaults(ENERGY) == 0` and an ENERGY
    ///      withdrawal still reverts `Curator_CustodyLossFrozen`).
    ///
    ///      THE WARNING: nothing pins that coincidence. A future change to `_exitDrawTarget`'s
    ///      predicate — widening it beyond the under-backed set, for instance — would silently
    ///      re-open a curator escape ahead of a crystallisation that ADR-0034 Y-bis's own
    ///      implementation requirements say must not be escapable. If you touch
    ///      `_exitDrawTarget`'s guard, re-derive this coupling.
    function withdrawFirstLoss(uint256 classId, uint256 amount) external nonReentrant whenNotPaused {
        CuratorStorage storage $ = _storage();
        if (amount == 0) revert Curator_ZeroAmount();
        // AUDIT FIX (R4-EC2): once a facility in this class has defaulted, the curator
        // cannot withdraw until governance resolves the workout — otherwise a curator
        // could front-run realizeLoss and pull excess first-loss ahead of the loss.
        if ($.unresolvedDefaults[classId] != 0) revert Curator_ClassDefaultFrozen(classId);
        // AUDIT FIX (R6-CF1) — LOAD-BEARING, DO NOT DELETE. The R4-EC2 guard above covers only the
        // FACILITY path: `unresolvedDefaults` has exactly one writer, `freezeOnDefault`, reached
        // from `declareDefault`/`liquidate`. The live reserve-CUSTODY path is
        // `ReserveManager.ratifyAndOpen -> _absorbRecognizedReserveLoss ->
        // _drawJuniorReserveLoss -> absorbGlobalLoss`; before this guard it armed NOTHING, so a
        // curator could pull every dollar of headroom between the incident being recognised and
        // the write-down executing, and duck a loss this capital is CASCADE LAYER 1 for. That is
        // the same inversion R4-EC2's own comment describes, on the other loss path.
        //
        // The predicate is class-INDEPENDENT because a custody loss has no collateral class:
        // `absorbGlobalLoss` charges all five pools pro-rata, so every pool is at risk.
        // See `IReserveManager.custodyLossUnabsorbed` for the five limbs and the window each
        // covers. Fail CLOSED when unwired: "cannot tell" must not read as "clear" here.
        if (address($.reserveManager) == address(0)) revert Curator_ReserveNotWired();
        if (custodyFreezeActive()) revert Curator_CustodyLossFrozen();

        ClassPool storage pool = $.pools[classId];
        CuratorStake storage stake = $.stakes[classId][msg.sender];
        // AUDIT FIX (SWEEP-4 S4-R1) — LOAD-BEARING. Without this a closed-round residual is
        // claimable in principle and unreachable in practice: `_postedOf` floors a stale stake to
        // zero, so every withdrawal of it would revert `Curator_InsufficientStake` and the claim
        // the snapshot preserved could never become USDfr. It sits AFTER both freezes deliberately
        // — a frozen class must not settle-and-exit in one call — and settling is always available
        // on its own through the permissionless `claimClosedRound`.
        uint256 stakeRound = stake.round; // read BEFORE settling — see `postFirstLoss`
        if (!_settleStaleRound($, classId, pool, msg.sender, stake)) {
            revert Curator_UnsettledClosedRound(classId, stakeRound, pool.round);
        }
        _syncStakeShares(pool, stake);

        uint256 posted = _postedOf(pool, stake);
        if (amount > posted) revert Curator_InsufficientStake(classId, msg.sender, amount, posted);

        uint256 free = _headroom($, classId, pool);
        if (amount > free) revert Curator_HeadroomExceeded(classId, amount, free);
        $.feeVault.beginFeeNeutralMarkedNavChange();

        // Shares burn rounds UP so a withdrawal can never take more value than the
        // caller's stake is worth (rounding dust favors the pool, i.e. the senior
        // side). Because amount <= posted = floor(shares·balance/totalShares), the
        // ceil here never exceeds the caller's shares (ceil(x) <= n iff x <= n).
        uint256 shares = Math.mulDiv(amount, pool.totalShares, pool.balance, Math.Rounding.Ceil);

        stake.shares -= shares;
        pool.totalShares -= shares;
        pool.balance -= amount;
        $.usdfr.safeTransfer(msg.sender, amount);
        $.feeVault.endFeeNeutralMarkedNavChange();
        emit FirstLossWithdrawn(classId, msg.sender, amount, shares, pool.round);
        _notifyPoints($, classId, msg.sender); // P-01: reconcile points to the reduced posted first-loss
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (SWEEP-4 S4-R1) — LOAD-BEARING, DO NOT DELETE. This is the ESCAPE that makes
    ///      the `Curator_UnsettledClosedRound` refusal in `postFirstLoss`/`withdrawFirstLoss` a
    ///      two-transaction path rather than a brick: those two must revert on a stake that cannot
    ///      be brought to the live round in one conversion (silently erasing it is the defect), and
    ///      this walks the stake forward one closed round per call with no revert at all.
    ///
    ///      PERMISSIONLESS, AND THAT IS DELIBERATE. It moves no value and grants the caller
    ///      nothing: it only re-attributes shares that were minted at the close and have been part
    ///      of `poolShares(classId)` ever since. Making it caller-restricted would put layer-1
    ///      recapitalisation liveness — the very property S3-F1 exists to protect — behind one
    ///      address being available and willing to transact.
    ///
    ///      NOT PAUSABLE AND NOT FREEZE-GATED, ALSO DELIBERATE. Both withdrawal freezes (R4-EC2
    ///      `unresolvedDefaults`, R6-CF1 `custodyFreezeActive`) and the guardian pause exist to stop
    ///      capital LEAVING ahead of a loss. Settling leaves nothing: the settled shares sit in the
    ///      same pool, absorb the same losses, and can only be withdrawn through
    ///      `withdrawFirstLoss`, where every one of those guards still binds. Gating attribution on
    ///      them would instead mean a curator's residual claim decays while the class is frozen,
    ///      which inverts what the freezes are for.
    function claimClosedRound(uint256 classId, address curator) external nonReentrant {
        _requireKnownClass(classId);
        if (curator == address(0)) revert Curator_ZeroAddress();
        CuratorStorage storage $ = _storage();
        ClassPool storage pool = $.pools[classId];
        _settleStaleRound($, classId, pool, curator, $.stakes[classId][curator]);
        _notifyPoints($, classId, curator);
    }

    // ── Cascade layer 1 (credit layer only; never pausable) ──────────────

    /// @inheritdoc ICuratorModule
    function absorbLoss(uint256 classId, uint256 loss)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        returns (uint256 absorbed, uint256 residual)
    {
        if (loss == 0) revert Curator_ZeroAmount();
        CuratorStorage storage $ = _storage();
        ClassPool storage pool = $.pools[classId];

        uint256 balanceBefore = pool.balance;
        absorbed = loss < pool.balance ? loss : pool.balance;
        residual = loss - absorbed;
        if (absorbed != 0) {
            // Shares are untouched: every staker in the class dilutes pro-rata.
            pool.balance -= absorbed;
            // NOTE (SWEEP-3 S3-F1): the round is deliberately NOT advanced here. See the
            // "WHY THE NORMALISATION IS LAZY" paragraph in `postFirstLoss`.
            $.usdfr.safeTransfer(msg.sender, absorbed);
        }
        emit LossAbsorbed(classId, loss, absorbed, residual);
        // AUDIT FIX (P-01 follow-up / H-03): a loss dilutes every curator's postedOf without a
        // per-curator hook, so freeze curator point accrual in this class at the loss instant
        // until each curator reconciles. The bracketing pool balances are passed through so the
        // ledger can write each curator's stale cached balance down by the EXACT pro-rata
        // dilution (shares are untouched here, only `pool.balance` moves) — otherwise a curator
        // who tops back up to their pre-loss notional keeps the destroyed capital's maturity
        // ramp. FAIL-OPEN — never block the never-pausable cascade.
        if (absorbed != 0) {
            IPointsModule pm = $.pointsModule;
            if (address(pm) != address(0)) {
                try pm.onCuratorLoss(classId, balanceBefore, pool.balance) {} catch {}
            }
        }
    }

    /// @inheritdoc ICuratorModule
    function absorbGlobalLoss(uint256 loss)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        returns (uint256 absorbed, uint256 residual)
    {
        if (loss == 0) revert Curator_ZeroAmount();
        CuratorStorage storage $ = _storage();
        uint256[5] memory balances;
        uint256[5] memory allocations;
        uint256 total;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            balances[i] = $.pools[i + 1].balance;
            total += balances[i];
        }
        absorbed = loss < total ? loss : total;
        residual = loss - absorbed;
        if (absorbed == 0) return (0, residual);

        uint256 allocated;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            allocations[i] = Math.mulDiv(absorbed, balances[i], total);
            allocated += allocations[i];
        }
        uint256 dust = absorbed - allocated;
        for (uint256 i = 0; i < Config.NUM_CLASSES && dust != 0; ++i) {
            uint256 remainingCapacity = balances[i] - allocations[i];
            if (remainingCapacity == 0) continue;
            uint256 add = dust < remainingCapacity ? dust : remainingCapacity;
            allocations[i] += add;
            dust -= add;
        }
        assert(dust == 0);

        IPointsModule pm = $.pointsModule;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 amount = allocations[i];
            if (amount == 0) continue;
            uint256 classId = i + 1;
            ClassPool storage pool = $.pools[classId];
            uint256 balanceBefore = pool.balance;
            pool.balance -= amount;
            // NOTE (SWEEP-3 S3-F1): the ADR-0034 Y-bis senior-exit draw arrives HERE, and it is the
            // path whose residual an unprivileged redeemer picks to the wei — but the round is
            // deliberately NOT advanced here. See "WHY THE NORMALISATION IS LAZY" in
            // `postFirstLoss`.
            emit LossAbsorbed(classId, amount, amount, 0);
            if (address(pm) != address(0)) {
                try pm.onCuratorLoss(classId, balanceBefore, pool.balance) {} catch {}
            }
        }
        $.usdfr.safeTransfer(msg.sender, absorbed);
    }

    // ── Default freeze (audit R4-EC2) ────────────────────────────────────

    /// @inheritdoc ICuratorModule
    /// @dev CREDIT_ROLE (the DefaultManager) records a default entering the class. Not
    ///      pausable — a default must always be recordable, mirroring the cascade. The
    ///      counter lets concurrent defaults on one class each require their own lift.
    function freezeOnDefault(uint256 classId) external onlyRole(Roles.CREDIT_ROLE) {
        _requireKnownClass(classId);
        CuratorStorage storage $ = _storage();
        uint256 count = $.unresolvedDefaults[classId] + 1;
        $.unresolvedDefaults[classId] = count;
        emit ClassDefaultFrozen(classId, count);
    }

    /// @inheritdoc ICuratorModule
    /// @dev Governance timelock lifts one freeze once a workout resolves. Reverts if the
    ///      class is not frozen, so lifts can never drive the counter below zero.
    function liftDefaultFreeze(uint256 classId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        CuratorStorage storage $ = _storage();
        uint256 count = $.unresolvedDefaults[classId];
        if (count == 0) revert Curator_NotFrozen(classId);
        count -= 1;
        $.unresolvedDefaults[classId] = count;
        emit ClassDefaultFreezeLifted(classId, count);
    }

    // ── Custody-loss freeze (audit R6-CF1) ───────────────────────────────

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (R6-CF1) — LOAD-BEARING, DO NOT DELETE. `withdrawFirstLoss` refuses while
    ///      this is true. The predicate is DERIVED from reserve state rather than latched into a
    ///      counter, and that is the point of the fix: the finding was that the facility path
    ///      armed a counter and no custody path armed anything, so a NEW custody entry point could
    ///      re-open the hole simply by forgetting to call an arming function. A derived predicate
    ///      cannot be forgotten.
    ///
    ///      TWO LIMBS. The guardian PRE-ARM covers a loss that is known but not yet visible
    ///      on-chain and that governance has not had time to recognise. Everything else is
    ///      `IReserveManager.custodyLossUnabsorbed`, which is the C-01 release condition verbatim:
    ///      release only when absorption is complete, no deficit or live shortfall remains, and
    ///      `totalUSDfr() <= backingValue()`.
    ///
    ///      NOTE THE ASYMMETRY, IT IS DELIBERATE: a guardian can turn this ON and has NO way to
    ///      turn it off, and governance's `cancelCustodyPreArm` clears only the pre-arm limb.
    ///      Neither role can release a genuine custody freeze early.
    ///
    ///      DELETION COVERAGE (audit F3-FREEZE-01). Both branches below are LOAD-BEARING and both
    ///      are mutation-covered — deleting either must turn a test red, which is the only thing
    ///      that stops a guard degrading into decoration:
    ///        pre-arm branch  -> Fix_R6CF1-freeze-limb-isolation.t.sol::..._preArmIsTheOnlyLimb
    ///                           (drives the pre-arm while EVERY reserve limb is provably off, so
    ///                            the reserve predicate cannot mask its deletion), and the stateful
    ///                           `INV_CustodyFreezePredicate` guards `preArm:*`.
    ///        unwired branch  -> ..._unwiredReserveReadsAsFrozen, and the stateful `unwired:*` guards.
    ///      The positive control lives beside them (`..._clearStateIsNotAPermanentFreeze` and the
    ///      `clear` guard): a mutant that simply returns `true` must fail too, otherwise "always
    ///      frozen" would pass every negative test in the file.
    function custodyFreezeActive() public view returns (bool) {
        CuratorStorage storage $ = _storage();
        if ($.custodyPreArmExpiry > block.timestamp) return true;
        IReserveManager reserves_ = $.reserveManager;
        // Unwired reads as FROZEN. A guard that silently disappears when its input is missing is
        // not a guard (CLAUDE.md prime directive 4); post-deploy validation catches the wiring.
        if (address(reserves_) == address(0)) return true;
        return reserves_.custodyLossUnabsorbed();
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (R6-CF1). NOT pausable and NOT bounded by a class: a guardian must always be
    ///      able to stop layer-1 capital leaving, and a custody loss charges every pool.
    ///      Re-arming REPLACES the standing pre-arm with `block.timestamp + duration` and consumes
    ///      budget; see `CUSTODY_PRE_ARM_MAX_CONSECUTIVE` for why the budget is what stops a
    ///      guardian from freezing curator capital indefinitely.
    ///
    ///      CORRECTED (SWEEP-1 CSG-F3, 2026-08-08) — THIS LINE SAID RE-ARMING "EXTENDS" THE
    ///      STANDING PRE-ARM. IT DOES NOT, AND MUST NOT. `duration` is derived LIVE from the
    ///      governance path (`_derivePreArm`), so whenever that path has SHORTENED since the last
    ///      arm — including the one-transaction case `setGovernor(address(0))`, which collapses
    ///      the 90-day window to the 15-day `Config` floor — a good-faith re-arm SHORTENS the
    ///      window AND spends a unit of budget doing it. MEASURED: a 90-day arm followed by a
    ///      governance retune and a re-arm dropped the expiry by 74 days, exhausting the budget,
    ///      after which the ENTIRE 300,000e18 layer-1 pool was withdrawable inside the window the
    ///      first arm had already covered.
    ///
    ///      DO NOT "FIX" THIS WITH `expiry = max(previousExpiry, now + duration)`. MEASURED: that
    ///      reds three `CustodyPreArmInvariants` assertions —
    ///      "pre-arm EXPIRY diverged from the independent model", "custodyFreezeActive() != the
    ///      independent model of the guardian pre-arm limb", and "layer 1 refused while nothing was
    ///      armed - the pre-arm has become a lock". `expiry = now + duration` is DELIBERATE: a
    ///      `max()` breaks the <=50% guardian duty-cycle bound that F3-PA-b exists to enforce, and
    ///      turns the emergency lever into a permanent freeze. THE TWO PROPERTIES GENUINELY
    ///      CONFLICT and the conflict was written down nowhere; this paragraph is where it is
    ///      written down. OPERATOR RULE: read `custodyPreArmDuration()` BEFORE re-arming — if it
    ///      has fallen below the remaining life of the standing pre-arm, re-arming makes the
    ///      protection worse, not better.
    ///
    ///      AUDIT FIX (F3-PA-b) — THE CONSECUTIVE-EPISODE RESET IS LOAD-BEARING, DO NOT DELETE.
    ///      Without it `custodyPreArmCount` is a LIFETIME counter and the guardian's emergency
    ///      lever is permanently spent after two arms in the protocol's entire life, restorable
    ///      only by a timelocked governance transaction. WITHOUT THE `+ cooldown` TERM the reset
    ///      is equally wrong in the other direction: a guardian could re-arm the instant the
    ///      previous window lapsed and hold a permanent freeze on layer-1 capital while the budget
    ///      still read as spent. Both halves of the predicate are guards; both are mutation-tested
    ///      (`Fix_F3PA-prearm-budget-trap.t.sol`) and driven statefully by
    ///      `test/invariant/CustodyPreArmInvariants.t.sol`.
    ///
    ///      AUDIT FIX (F3-PA-c) — the truncation signal at the end is a guard too. The cap on the
    ///      derivation path is allowed to bind, but it is NEVER allowed to bind silently: an
    ///      operator watching this event learns that one window no longer outlasts the live
    ///      governance path and that `replenishCustodyPreArmBudget` must carry the difference.
    function preArmCustodyFreeze() external onlyRole(Roles.GUARDIAN_ROLE) {
        CuratorStorage storage $ = _storage();
        (uint256 livePath, uint64 duration) = _derivePreArm();
        uint64 previousExpiry = $.custodyPreArmExpiry;
        uint32 count = $.custodyPreArmCount;

        // GUARD (F3-PA-b): a NEW episode begins once the previous pre-arm has lapsed AND layer-1
        // has stood genuinely unfrozen for the full cooldown. `previousExpiry` is the lapse
        // instant; the cooldown is measured from it, so the unfrozen window is real elapsed time
        // and not an artefact of when the guardian happens to call.
        uint256 cooldown = uint256(duration) * CUSTODY_PRE_ARM_MAX_CONSECUTIVE;
        if (count != 0 && block.timestamp >= uint256(previousExpiry) + cooldown) {
            emit CustodyFreezePreArmEpisodeReset(count, previousExpiry);
            count = 0;
        }

        count += 1;
        if (count > CUSTODY_PRE_ARM_MAX_CONSECUTIVE) {
            revert Curator_PreArmBudgetExhausted(count, CUSTODY_PRE_ARM_MAX_CONSECUTIVE);
        }

        uint64 expiry = uint64(block.timestamp) + duration;
        $.custodyPreArmCount = count;
        $.custodyPreArmExpiry = expiry;
        emit CustodyFreezePreArmed(msg.sender, expiry, count);

        // GUARD (F3-PA-c): the cap may bind, but never silently.
        if (uint256(duration) <= livePath) {
            emit CustodyFreezePreArmTruncated(livePath, duration, count);
        }
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (R6-CF1). Governance's answer to a FALSE ALARM. It clears BOTH the standing
    ///      pre-arm and the budget, because a false alarm means no protection is wanted. It is safe
    ///      to give governance this because it clears only the pre-arm limb — an open incident, a
    ///      latched deficit, a live shortfall or an under-backed protocol all keep
    ///      `custodyFreezeActive()` true regardless. DO NOT extend this to clear the derived limbs:
    ///      that would hand governance a loss-dodging lever and undo the fix.
    ///
    ///      AUDIT FIX (F3-PA-a) — THIS IS NO LONGER THE BUDGET-REPLENISHMENT LEVER, and it must
    ///      never become one again. R6-CF1 shipped it as the ONLY way to replenish the guardian's
    ///      budget while it also zeroes `custodyPreArmExpiry`. Using it for its documented purpose
    ///      — "governance has looked, the incident is REAL, keep going" — therefore destroyed the
    ///      very protection it was called to extend, and in the same block a curator could take
    ///      every dollar of layer-1 headroom out ahead of a loss it is layer 1 for. That is the
    ///      HIGH. `replenishCustodyPreArmBudget` is the lever for a REAL incident; this one is for
    ///      a false alarm and nothing else.
    function cancelCustodyPreArm() external onlyRole(DEFAULT_ADMIN_ROLE) {
        CuratorStorage storage $ = _storage();
        uint64 previous = $.custodyPreArmExpiry;
        if (previous == 0 && $.custodyPreArmCount == 0) revert Curator_NoPreArm();
        $.custodyPreArmExpiry = 0;
        $.custodyPreArmCount = 0;
        emit CustodyFreezePreArmCancelled(previous);
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (F3-PA-a) — LOAD-BEARING, DO NOT DELETE, AND DO NOT "SIMPLIFY" IT INTO
    ///      `cancelCustodyPreArm`. The one line that matters is the line that ISN'T here: this
    ///      function must NOT write `custodyPreArmExpiry`. Replenishing the guardian's budget is
    ///      what governance does when it has looked at the incident and found it REAL; if that act
    ///      also cleared the standing pre-arm it would open, at minimum, a one-transaction window
    ///      in which layer-1 capital is free to leave ahead of the loss — and a curator can be the
    ///      very next transaction. Adding a mutation here that zeroes the expiry reds
    ///      `test_F3PA_replenishingBudgetMustNotDestroyActiveProtection` and the stateful
    ///      `invariant_PA2_freezeMatchesIndependentModel`.
    function replenishCustodyPreArmBudget() external onlyRole(DEFAULT_ADMIN_ROLE) {
        CuratorStorage storage $ = _storage();
        uint32 spent = $.custodyPreArmCount;
        if (spent == 0) revert Curator_NoPreArm();
        $.custodyPreArmCount = 0;
        emit CustodyFreezePreArmBudgetReplenished(spent, $.custodyPreArmExpiry);
    }

    /// @inheritdoc ICuratorModule
    function custodyPreArm() external view returns (uint64 expiry, uint32 count) {
        CuratorStorage storage $ = _storage();
        return ($.custodyPreArmExpiry, $.custodyPreArmCount);
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (R6-CF1) — DO NOT REPLACE WITH A LITERAL. A pre-arm that expires before
    ///      governance could possibly have ratified it is decoration: the guardian arms, the
    ///      freeze lapses mid-proposal, and the curator exits anyway. The requirement is therefore
    ///      that this strictly EXCEED the governance path it was derived from,
    ///      `custodyPreArmGovernancePath()`.
    ///
    ///      All three terms are governance-mutable, so the live reading (when a governor is wired)
    ///      is taken and used whenever it is longer than the `Config` launch floor. The +50% is the
    ///      margin over the protocol-enforced minimum: proposal drafting, queueing and execution
    ///      latency all sit on top of it.
    ///
    ///      AUDIT FIX (F3-PA-c). The cap now binds on the PATH (`CUSTODY_PRE_ARM_MAX_PATH`), and
    ///      `CUSTODY_PRE_ARM_MAX_DURATION` is exactly 3/2 of it, so the clamp on the last line is
    ///      provably non-binding and `custodyPreArmDuration() > custodyPreArmGovernancePath()`
    ///      holds at EVERY parameterisation — it is fuzzed as such. R6-CF1 capped the DURATION
    ///      while summing three separately-capped terms, so a live path of up to 3 x 90 days was
    ///      truncated to a 90-day window and the requirement above silently inverted. Where the
    ///      path cap genuinely binds (a live path beyond `CUSTODY_PRE_ARM_MAX_PATH`) the shortfall
    ///      is reported by `custodyPreArmCoversLiveGovernancePath`, emitted by
    ///      `CustodyFreezePreArmTruncated`, and — from P-49 — actually checked at deploy time by
    ///      `script/Validate.s.sol`, which requires `custodyPreArmCoversLiveGovernancePath()`.
    ///      That refuses the regime where the derived duration no longer outlasts the live path
    ///      (a live path at or above `CUSTODY_PRE_ARM_MAX_DURATION`), NOT merely where the path
    ///      cap binds. Before P-49 the validator asserted `custodyPreArmDuration()` against the
    ///      `Config` launch path — an assertion `_governancePath()`'s own floor makes
    ///      UNFALSIFIABLE, since the floor guarantees a duration of at least 15 days against a
    ///      10-day bound.
    function custodyPreArmDuration() public view returns (uint64 duration) {
        (, duration) = _derivePreArm();
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (F3-PA-c). The path the duration is actually derived from: the longer of the
    ///      `Config` launch floor and the live reading, bounded by `CUSTODY_PRE_ARM_MAX_PATH`.
    function custodyPreArmGovernancePath() public view returns (uint64) {
        uint256 path = _governancePath();
        return path > CUSTODY_PRE_ARM_MAX_PATH ? CUSTODY_PRE_ARM_MAX_PATH : uint64(path);
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (F3-PA-c) — a REAL consumer, not a decorative view. `script/Validate.s.sol`
    ///      refuses to validate a deployment where this is false, and `preArmCustodyFreeze` emits
    ///      `CustodyFreezePreArmTruncated` whenever it arms into that regime.
    function custodyPreArmCoversLiveGovernancePath() public view returns (bool) {
        (uint256 livePath, uint64 duration) = _derivePreArm();
        return uint256(duration) > livePath;
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (F3-PA-b). `MAX_CONSECUTIVE x duration`, measured from the lapse of the
    ///      previous pre-arm, so a guardian's unilateral duty cycle over layer-1 capital can never
    ///      exceed one half.
    function custodyPreArmCooldown() public view returns (uint64) {
        (, uint64 duration) = _derivePreArm();
        return uint64(uint256(duration) * CUSTODY_PRE_ARM_MAX_CONSECUTIVE);
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (R6-CF1). Zero is accepted and means "explicitly unwired", which reads as
    ///      FROZEN — there is no configuration of this module in which the custody guard is
    ///      silently absent. A non-zero address must answer `usdc()`, which both requires code and
    ///      rejects an address that is not a ReserveManager.
    function setReserveManager(address reserves_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_storage().reserveManager) != address(0) && custodyFreezeActive()) {
            revert Curator_ReserveManagerChangeFrozen();
        }
        if (reserves_ != address(0)) {
            if (reserves_.code.length == 0) revert Curator_InvalidReserveManager(reserves_);
            try IReserveManager(reserves_).usdc() returns (address token) {
                if (token == address(0)) revert Curator_InvalidReserveManager(reserves_);
            } catch {
                revert Curator_InvalidReserveManager(reserves_);
            }
        }
        _storage().reserveManager = IReserveManager(reserves_);
        emit ReserveManagerUpdated(reserves_);
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (R6-CF1). Zero leaves the `Config` launch parameters as the sole source of
    ///      the pre-arm duration — safe, because those are a FLOOR the live reading can only raise.
    function setGovernor(address governor_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governor_ != address(0) && governor_.code.length == 0) revert Curator_InvalidGovernor(governor_);
        _storage().governor = governor_;
        emit GovernorUpdated(governor_);
    }

    /// @notice Governance recovery route if a Guardian pause halted curator user paths.
    function governanceUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice The wired ReserveManager whose custody-loss window gates withdrawals (0 = frozen).
    function reserveManager() external view returns (address) {
        return address(_storage().reserveManager);
    }

    /// @notice The wired governor the pre-arm duration is derived from (0 = `Config` floor only).
    function governor() external view returns (address) {
        return _storage().governor;
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses curator post/withdraw. The cascade (`absorbLoss`) is NEVER
    ///         pausable — see the contract-level note.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses curator post/withdraw.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc ICuratorModule
    function poolBalance(uint256 classId) external view returns (uint256) {
        return _storage().pools[classId].balance;
    }

    /// @inheritdoc ICuratorModule
    function unresolvedDefaults(uint256 classId) external view returns (uint256) {
        return _storage().unresolvedDefaults[classId];
    }

    /// @inheritdoc ICuratorModule
    /// @dev AUDIT FIX (SWEEP-4 S4-R1, FOUR-INPUT COMPOSITION). A live-round stake is exact. A
    ///      stale closed-round stake is a conservative pre-settlement quote: the executable
    ///      `claimClosedRound` path divides one shared remaining/remaining snapshot and therefore
    ///      depends on which holder settles first, information a per-holder view cannot know.
    ///      Rounding every independent stale quote up can make their aggregate exceed the pool;
    ///      the view therefore rounds down except for the unique stake that owns the snapshot's
    ///      entire remaining denominator. That whole-cohort claimant may receive the same one-unit
    ///      remainder as executable settlement without making aggregate quotes exceed the pool.
    ///      Settlement still keeps every non-zero residual reachable, and its post-write
    ///      `_notifyPoints` publishes the exact live value.
    function postedOf(uint256 classId, address curator) external view returns (uint256) {
        CuratorStorage storage $ = _storage();
        ClassPool storage pool = $.pools[classId];
        (uint256 shares, bool live) = _settledShares($, classId, pool, $.stakes[classId][curator]);
        if (!live || pool.totalShares == 0) return 0;
        return Math.mulDiv(shares, pool.balance, pool.totalShares);
    }

    /// @inheritdoc ICuratorModule
    function closedRound(uint256 classId, uint256 round)
        external
        view
        returns (uint256 closedShares, uint256 carriedShares)
    {
        ClosedRound storage snap = _storage().closedRounds[classId][round];
        return (snap.shares, snap.carriedShares);
    }

    /// @inheritdoc ICuratorModule
    function requiredFirstLoss(uint256 classId) public view returns (uint256) {
        CuratorStorage storage $ = _storage();
        return _requiredFirstLoss($, classId);
    }

    /// @inheritdoc ICuratorModule
    function headroom(uint256 classId) external view returns (uint256) {
        CuratorStorage storage $ = _storage();
        return _headroom($, classId, $.pools[classId]);
    }

    /// @inheritdoc ICuratorModule
    function firstLossTarget(uint256 classId) external view returns (uint256) {
        return _storage().targets[classId];
    }

    /// @inheritdoc ICuratorModule
    function isApprovedCurator(uint256 classId, address curator) external view returns (bool) {
        return _storage().approved[classId][curator];
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules() external view returns (address usdfr, address registry, address feeVault) {
        CuratorStorage storage $ = _storage();
        return (address($.usdfr), address($.registry), address($.feeVault));
    }

    /// @notice Current share round for a class pool (advances on full wipe-out).
    function poolRound(uint256 classId) external view returns (uint256) {
        return _storage().pools[classId].round;
    }

    /// @notice Total internal shares for a class pool. Always >= `poolBalance` (the
    ///         share price never exceeds 1 — see the note in `postFirstLoss`).
    function poolShares(uint256 classId) external view returns (uint256) {
        return _storage().pools[classId].totalShares;
    }

    // ── Internals ────────────────────────────────────────────────────────

    /// @dev AUDIT FIX (SWEEP-3 S3-F1) — LOAD-BEARING, DO NOT DELETE OR INLINE AWAY.
    ///      Advances the class share round when the pool is EFFECTIVELY wiped, i.e. when its share
    ///      price has fallen to or below 1e-18 (`balance * MAX_SHARE_INFLATION <= totalShares`).
    ///      The full statement of the defect, the attacker's exact control over the residual, the
    ///      measured brick, and the derivation of both the constant and the dust bound are in the
    ///      block on `postFirstLoss`. Read that before touching this.
    ///
    ///      IT IS CALLED FROM `postFirstLoss` AND FROM NOWHERE ELSE — in particular NOT from
    ///      `absorbLoss`/`absorbGlobalLoss`. See "WHY THE NORMALISATION IS LAZY" in `postFirstLoss`
    ///      for the measurement that settled that.
    ///
    ///      SETTING `totalShares = balance` (NOT ZERO) IS PART OF THE FIX. Zero would mint
    ///      `shares == amount` against `balance == amount + residual` on the next post, pushing the
    ///      share price ABOVE 1 and breaking this contract's shipped share-price invariant. At
    ///      `totalShares == balance` the price is exactly 1 and the forfeited residual stands as
    ///      UNOWNED backing that absorbs before any curator's capital.
    ///
    ///      Falsified by `test_S3_F1_layerOneMustStillBeReFundableAfterNearTotalExitDraws`,
    ///      `test_S3_F1_theFacilityRouteInflatesTheShareRatioIdentically` and
    ///      `test_S3_F1_oneExitDrawCanCollapseTheShareRatioInEveryClassAtOnce`.
    ///
    ///      AUDIT FIX (SWEEP-4 S4-R1) — THE SNAPSHOT WRITE IS A GUARD, NOT BOOKKEEPING. Deleting it
    ///      restores the shipped forfeiture and reds
    ///      `test_S4_R1_aRoundCloseMustNotForfeitTheSurvivingResidual`. The `residual != 0` test is
    ///      what keeps the exact-wipe case (`balance == 0`) writing nothing at all: there is
    ///      genuinely no claim to carry there, and a zero-valued snapshot would be indistinguishable
    ///      from "never closed".
    function _advanceRoundIfWiped(CuratorStorage storage $, uint256 classId, ClassPool storage pool) private {
        uint256 shares = pool.totalShares;
        uint256 residual = pool.balance;
        if (shares == 0 || residual > shares / MAX_SHARE_INFLATION) return;
        uint256 closing = pool.round;
        if (residual != 0) {
            // The new round opens with `totalShares == residual` (price exactly 1) and those shares
            // are minted with no owner. Record that the CLOSING cohort owns them, pro-rata to the
            // shares they held in the round that just closed.
            ClosedRound storage snap = $.closedRounds[classId][closing];
            snap.shares = shares;
            snap.carriedShares = residual;
            snap.shareScale = pool.shareScale;
            emit ClosedRoundSnapshotted(classId, closing, residual, shares, residual);
        }
        pool.round = closing + 1;
        pool.totalShares = residual;
        emit PoolRoundAdvanced(classId, closing + 1);
    }

    /// @dev AUDIT FIX (SWEEP-4 S4-R1) — LOAD-BEARING, DO NOT DELETE OR SIMPLIFY BACK TO
    ///      `stake.shares = 0`. Converts a stale-round stake into its pro-rata slice of the
    ///      SUCCEEDING round's shares, using the snapshot `_advanceRoundIfWiped` took at the close.
    ///
    ///      REMAINING / REMAINING. Both snapshot fields are decremented by exactly what this
    ///      settlement takes, so the holders who have not settled always divide the carried shares
    ///      that have not been handed out. `Math.mulDiv` floors, so the arithmetic can never hand
    ///      out more than was carried and the rounding dust stays unowned in the pool — the same
    ///      direction `withdrawFirstLoss`'s ceil rounding favours. `snap.shares` starts at the
    ///      closing round's ENTIRE `totalShares`, which is an upper bound on the sum of every stake
    ///      in that round, so the subtraction cannot underflow; it is left CHECKED so that a future
    ///      change breaking that bound fails loudly instead of silently over-distributing.
    ///
    ///      IT WALKS, AND THE WALK IS NOT OPTIONAL — MEASURED. Carried shares stay UNOWNED in the
    ///      pool until claimed, so when the succeeding round closes in its turn they are carried
    ///      again: a stake that slept through N closes needs N conversions. A single-hop version of
    ///      this function reds `test_S3_F1_layerOneMustStillBeReFundableAfterNearTotalExitDraws` —
    ///      the second curator's claim converts to exactly ONE share at the first close, is
    ///      therefore not zero, and is then stranded two rounds behind while `postFirstLoss`
    ///      refuses. That is the very liveness property S3-F1 exists to protect, so the walk is
    ///      what keeps this fix from re-opening the finding it is layered on.
    ///
    ///      BOUNDED, BECAUSE AN UNBOUNDED WALK IS A GAS BRICK ON THE SAME LIVENESS PATH. Closes are
    ///      permissionless in effect (any KYC'd redeemer can drive the ADR-0034 Y-bis draw), so the
    ///      chain length is not the curator's to control and must not be able to grow a
    ///      `postFirstLoss` past the block gas limit. `MAX_CLOSED_ROUND_HOPS` bounds one call;
    ///      a longer chain is still fully recoverable because `claimClosedRound` KEEPS the progress
    ///      of every hop it makes and may be called repeatedly.
    ///
    ///      RETURNS `false` RATHER THAN REVERTING, and the distinction is the whole design.
    ///      Reverting here would undo the hops this call just made and no sequence of calls could
    ///      ever make progress. Callers that are about to change the stake's value
    ///      (`postFirstLoss`, `withdrawFirstLoss`) turn the `false` into
    ///      `Curator_UnsettledClosedRound` — refusing rather than erasing — while `claimClosedRound`
    ///      simply keeps the hops, so walking the chain terminates.
    ///
    ///      THE `shares == 0` EXIT IS NOT AN OPTIMISATION. Each hop multiplies a stake by a factor
    ///      of at most 1e-18 (that is the close condition), so a claim that has floored to zero is
    ///      zero at every later round too. Jumping such a stake straight to the live round is what
    ///      keeps the ordinary case — a genuinely wiped stake, which is most of them — a single
    ///      transaction with no chain to walk. A `snapShares == 0` hop is the same statement for the
    ///      exact-wipe case, where no snapshot was ever written because nothing survived to carry.
    function _settleStaleRound(
        CuratorStorage storage $,
        uint256 classId,
        ClassPool storage pool,
        address curator,
        CuratorStake storage stake
    ) private returns (bool complete) {
        uint256 liveRound = pool.round;
        uint256 fromRound = stake.round;
        if (fromRound == liveRound) return true;

        uint256 shares = stake.shares;
        uint256 sharesScale = stake.shareScale;
        if (shares == 0) {
            stake.round = liveRound;
            stake.shareScale = pool.shareScale;
            return true;
        }

        uint256 staleShares = shares;
        uint256 round_ = fromRound;
        for (uint256 hops = 0; round_ != liveRound && hops < MAX_CLOSED_ROUND_HOPS; ++hops) {
            ClosedRound storage snap = $.closedRounds[classId][round_];
            uint256 snapShares = snap.shares;
            if (snapShares == 0) {
                shares = 0; // the round closed on an exact wipe: there was nothing to carry
                break;
            }
            // A pool normalization may have reduced the aggregate share units since this stake
            // was written. Snapshots carry their own scale; convert the stale stake before
            // decrementing the snapshot denominator, otherwise a lazy old stake can exceed the
            // denominator and panic on the subtraction.
            shares = _rescaleClosedShares(shares, sharesScale, snap.shareScale);
            sharesScale = snap.shareScale;
            if (shares == 0) break;
            if (shares > snapShares) shares = snapShares;
            uint256 converted = Math.mulDiv(shares, snap.carriedShares, snapShares);
            // Keep a live residual claim reachable across a close even when the exact
            // pro-rata share is below one current share unit. The carry is decremented
            // with the same remaining/remaining rule, so no settlement can exceed it.
            if (converted == 0 && snap.carriedShares != 0) converted = 1;
            if (converted > snap.carriedShares) converted = snap.carriedShares;
            snap.shares = snapShares - shares;
            snap.carriedShares -= converted;
            shares = converted;
            round_ += 1;
            if (shares == 0) break;
        }
        if (shares == 0) round_ = liveRound;

        if (shares != 0 && round_ == liveRound) {
            shares = _rescaleClosedShares(shares, sharesScale, pool.shareScale);
            sharesScale = pool.shareScale;
        }
        if (shares == 0) {
            round_ = liveRound;
            sharesScale = pool.shareScale;
        }
        stake.shares = shares;
        stake.round = round_;
        stake.shareScale = sharesScale;
        emit ClosedRoundSettled(classId, curator, fromRound, round_, staleShares, shares);
        return round_ == liveRound;
    }

    function _postedOf(ClassPool storage pool, CuratorStake storage stake) private view returns (uint256) {
        if (stake.round != pool.round || pool.totalShares == 0) return 0;
        return Math.mulDiv(_currentStakeShares(pool, stake), pool.balance, pool.totalShares);
    }

    /// @dev Closed-round conversion uses a ceiling when a lazy scale rebase would otherwise
    ///      erase a non-zero stale stake. That one-unit floor is bounded by the snapshot carry;
    ///      ordinary live-round normalization continues to use the loss-favouring floor below.
    function _rescaleClosedShares(uint256 shares, uint256 fromScale, uint256 toScale) private pure returns (uint256) {
        if (fromScale == toScale || shares == 0) return shares;
        if (fromScale > toScale) {
            uint256 downshift = fromScale - toScale;
            if (downshift >= 256 || shares > type(uint256).max >> downshift) {
                revert Curator_ShareCapacityExceeded(shares, type(uint256).max);
            }
            return shares << downshift;
        }
        uint256 upshift = toScale - fromScale;
        if (upshift >= 256) return 1;
        return Math.ceilDiv(shares, uint256(1) << upshift);
    }

    /// @dev Keeps the aggregate share ratio representable without iterating curators. The
    /// aggregate rounds up and holders round down, so normalization cannot create value.
    function _normalizePoolShares(uint256 classId, ClassPool storage pool) private returns (bool normalized) {
        if (pool.balance == 0 || pool.totalShares == 0) return false;
        uint256 ratio = pool.totalShares / pool.balance;
        if (ratio < 2) return false;
        uint256 shift = Math.log2(ratio);
        if (shift == 0) return false;
        uint256 divisor = uint256(1) << shift;
        pool.totalShares = Math.ceilDiv(pool.totalShares, divisor);
        pool.shareScale += shift;
        emit PoolSharesNormalized(classId, shift, pool.totalShares);
        return true;
    }

    function _currentStakeShares(ClassPool storage pool, CuratorStake storage stake) private view returns (uint256) {
        uint256 shift = pool.shareScale - stake.shareScale;
        if (shift >= 256) return 0;
        return stake.shares >> shift;
    }

    function _syncStakeShares(ClassPool storage pool, CuratorStake storage stake) private {
        if (stake.shareScale == pool.shareScale) return;
        stake.shares = _currentStakeShares(pool, stake);
        stake.shareScale = pool.shareScale;
    }

    /// @dev AUDIT FIX (SWEEP-4 S4-R1, FOUR-INPUT COMPOSITION). Read-only projection used by
    ///      `postedOf`. It follows the same round chain and hop bound as `_settleStaleRound`, but it
    ///      floors stale conversions for independent partial holders instead of applying that
    ///      write path's one-unit residual minimum to every quote. Several independent views all
    ///      see the same undecremented snapshot, so rounding each one up produces a non-executable
    ///      aggregate above the pool. The unique stake equal to the snapshot's entire remaining
    ///      denominator is the exception: it alone may receive the one-unit remainder, which is
    ///      aggregate-safe and preserves a sole claimant across a chain of closes. Any other
    ///      conservative zero remains claimable through `claimClosedRound`, which writes the exact
    ///      live stake and notifies Points.
    function _settledShares(
        CuratorStorage storage $,
        uint256 classId,
        ClassPool storage pool,
        CuratorStake storage stake
    ) private view returns (uint256 shares, bool live) {
        uint256 liveRound = pool.round;
        uint256 round_ = stake.round;
        shares = stake.shares;
        uint256 sharesScale = stake.shareScale;
        bool receivesRemainder;
        if (round_ == liveRound) return (_currentStakeShares(pool, stake), true);
        if (shares == 0) return (0, true);
        for (uint256 hops = 0; round_ != liveRound && hops < MAX_CLOSED_ROUND_HOPS; ++hops) {
            ClosedRound storage snap = $.closedRounds[classId][round_];
            uint256 snapShares = snap.shares;
            if (snapShares == 0) return (0, true);
            // Equality means this stake is the snapshot's whole REMAINING cohort. A one-share
            // deficit is also conclusive when the denominator is > 2: aggregate normalization
            // rounds `pool.totalShares` up while the sole holder rounds down, leaving exactly that
            // unowned share. Two distinct positive stakes cannot both be within one of a
            // denominator above two because their sum is bounded by the denominator. The tiny
            // ambiguous denominators stay conservative.
            bool wholeRemaining = shares == snapShares || (snapShares > 2 && shares == snapShares - 1);
            if (!receivesRemainder && sharesScale == snap.shareScale && wholeRemaining) {
                receivesRemainder = true;
            }
            shares = _rescaleClosedSharesView(shares, sharesScale, snap.shareScale, receivesRemainder);
            sharesScale = snap.shareScale;
            if (shares == 0) return (0, true);
            if (shares > snapShares) shares = snapShares;
            // Read-side quotes cannot predict settlement order. Floor the undecremented snapshot
            // conversion so independently queried holders remain aggregate-safe; only the write
            // path may apply its one-unit minimum while decrementing the shared carry.
            shares = Math.mulDiv(shares, snap.carriedShares, snapShares);
            if (shares == 0 && snap.carriedShares != 0 && receivesRemainder) shares = 1;
            if (shares > snap.carriedShares) shares = snap.carriedShares;
            if (shares == 0) return (0, true);
            round_ += 1;
        }
        if (round_ == liveRound && shares != 0) {
            shares = _rescaleClosedSharesView(shares, sharesScale, pool.shareScale, receivesRemainder);
        }
        return (shares, round_ == liveRound);
    }

    function _rescaleClosedSharesView(uint256 shares, uint256 fromScale, uint256 toScale, bool receivesRemainder)
        private
        pure
        returns (uint256)
    {
        if (fromScale == toScale || shares == 0) return shares;
        if (fromScale > toScale) {
            uint256 downshift = fromScale - toScale;
            if (downshift >= 256 || shares > type(uint256).max >> downshift) return 0;
            return shares << downshift;
        }
        uint256 upshift = toScale - fromScale;
        if (upshift >= 256) return 0;
        uint256 divisor = uint256(1) << upshift;
        return receivesRemainder ? Math.ceilDiv(shares, divisor) : shares / divisor;
    }

    /// @dev Subordination requirement: live exposure must stay protected up to the
    ///      class target. Below the target, all posted capital protecting exposure is
    ///      locked; a fully repaid class (zero exposure) frees everything.
    ///
    ///      ── AUDIT FIX (SWEEP-2 CSG-F1) — THE MARKED FLOOR. LOAD-BEARING, DO NOT DELETE. ──
    ///
    ///      THE TWO FORMULAS DISAGREED, AND THE SENIOR PRICE WAS THE ONE HOLDING THE SHORT END.
    ///      What may LEAVE was `poolBalance - min(firstLossTarget, classExposure)`. What the
    ///      conservative senior NAV COUNTS as cascade layer 1 is, per class,
    ///      `min(declaredDefaultedPrincipal + pastDuePrincipal, poolBalance)`
    ///      (`ConservativeImpairmentMath.pendingSeniorImpairment`). Whenever
    ///      `classExposure > firstLossTarget` — the ordinary steady state for any class book above
    ///      the `Config.DEFAULT_FIRST_LOSS_PER_CLASS` floor — the second exceeds the first, so
    ///      capital the senior redemption price was ALREADY EXTENDING CREDIT FOR was withdrawable.
    ///
    ///      WHY THE TWO FREEZES DID NOT COVER IT. A DECLARED default freezes the class
    ///      (R4-EC2 `unresolvedDefaults`); an ADR-0034 Y-bis exit draw freezes every class
    ///      (R6-CF1 limb 4). An UNATTESTED PAST-DUE MARK freezes NOTHING — `markPastDue`'s NatSpec
    ///      says so deliberately, because "a reversible past-due mark must not freeze first-loss" —
    ///      and it does not move `totalBackingValue()`, so limb 4 reads false as well. That is the
    ///      one loss path with no freeze at all, and it is exactly the path that credits layer 1.
    ///
    ///      MEASURED (SWEEP-2 CSG-F1, HIGH): with a 350,000e18 past-due mark standing and no
    ///      freeze armed, a curator withdrew 800,000e18 of layer-1 capital with no revert and the
    ///      senior redemption price fell 1,000,000e18 -> 650,000e18. The discriminating control is
    ///      that the IDENTICAL withdrawal on the IDENTICAL shape reverts `Curator_ClassDefaultFrozen`
    ///      once the same mark is attested.
    ///
    ///      WHY A FLOOR AND NOT A FREEZE. Freezing on `markPastDue` would hand a griefing lever to
    ///      whoever can mark a facility past due — the sting the H-5 redesign deliberately closed.
    ///      A floor locks ONLY the capital the mark itself credits, never the whole pool and never
    ///      the class, so `markPastDue` stays non-freezing while the conservative NAV stops
    ///      crediting capital that can walk out from under it. It also closes the one-call route
    ///      in: `setFirstLossTarget` has no lower bound, and before this a single governance call
    ///      lowering the target manufactured 800,000e18 of headroom out of credited capital.
    ///
    ///      THE PERMISSIONLESS-MARK TRADE-OFF, STATED SO IT IS NOT DISCOVERED LATE. `markPastDue`
    ///      is permissionless, so a bystander CAN now lock curator capital — up to, and only up to,
    ///      the principal the mark itself puts at risk. That is not griefing: the call reverts
    ///      unless the facility is genuinely past its `nextPaymentDue` plus its class grace window,
    ///      and the same permissionless mark ALREADY depresses the senior redemption price by the
    ///      same principal (H-5's design). Locking exactly what it credits is the consistent
    ///      position; leaving it withdrawable was not. The lock is temporary and has two ordinary
    ///      exits — `clearPastDue` (SERVICER, on cure evidence) and the facility simply repaying —
    ///      plus the declared-default path, which supersedes it with the R4-EC2 class freeze.
    ///
    ///      SOFT-DEFAULTS TO THE OLD FORMULA WHEN THE CREDIT BOOK IS UNREACHABLE, and that is safe
    ///      HERE and only here: `withdrawFirstLoss` reverts `Curator_ReserveNotWired` before it
    ///      ever reads this, so the degraded answer is reachable only through the `headroom()` /
    ///      `requiredFirstLoss()` VIEWS, which must not revert on a partially wired deployment.
    function _requiredFirstLoss(CuratorStorage storage $, uint256 classId) private view returns (uint256) {
        uint256 exposure = $.registry.classExposure(classId);
        uint256 target = $.targets[classId];
        uint256 required = exposure < target ? exposure : target;
        uint256 marked = _markedFirstLoss($, classId);
        return marked > required ? marked : required;
    }

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). The per-class layer-1 credit the conservative senior NAV is
    ///      currently extending, read from the SAME source of truth the NAV reads:
    ///      `declaredDefaultedPrincipal(classId) + pastDuePrincipal(classId)` on the wired loss
    ///      absorber. Mirroring the NAV's own expression is the point — two enumerations of the
    ///      same quantity that do not agree is how this defect existed (see SEAM-1). If
    ///      `ConservativeImpairmentMath`'s layer-1 term ever changes, CHANGE THIS WITH IT.
    ///
    ///      No new storage: the absorber is reached through the already-wired `reserves`
    ///      (`IReserveManager.lossAbsorber()`), so `CuratorStorage`'s append-only tail is
    ///      untouched and both storage-layout gates stay green.
    ///
    ///      The NAV clamps this at `poolBalance`; clamping here would be redundant because
    ///      `_headroom` already floors at zero.
    ///
    ///      IT FAILS CLOSED, AND IT DOES SO WITHOUT REVERTING — BOTH HALVES ARE DELIBERATE.
    ///      `ReserveManager.setLossAbsorber` validates only `reserveLossSource()`, so a mis-wired
    ///      or not-yet-upgraded absorber can be present and unable to answer these two getters.
    ///      "Cannot tell" must not read as "nothing is credited" — that is the same reasoning
    ///      `custodyFreezeActive()` states for its own unwired case — so an unreadable book locks
    ///      the pool (`_UNREADABLE_BOOK_LOCK`, unreachably above any pool balance, so
    ///      `_headroom` floors at zero). It is a RAW length-checked staticcall rather than a plain
    ///      interface call because `headroom()` and `requiredFirstLoss()` are read by
    ///      `Validate.s.sol`, by dashboards and by the invariant oracles: a revert there is a worse
    ///      failure mode than a loud sentinel, and it is NOT `try`/`catch` for the reason
    ///      `_liveGovernancePath` documents at length — a permissive fallback answers with SUCCESS
    ///      and EMPTY returndata, and Solidity's `catch` does not catch the `abi.decode` failure
    ///      that follows.
    ///
    ///      A ZERO absorber is the exception and returns 0, not the lock: that is the state every
    ///      deployment starts in, and locking there would brick first-loss withdrawal on a
    ///      partially wired stack. `withdrawFirstLoss` already refuses outright while `reserves`
    ///      itself is unwired (`Curator_ReserveNotWired`), and `custodyFreezeActive()` returns
    ///      true — hence freezes — while the absorber is unset.
    function _markedFirstLoss(CuratorStorage storage $, uint256 classId) private view returns (uint256) {
        IReserveManager reserves = $.reserveManager;
        if (address(reserves) == address(0)) return 0;
        address book = reserves.lossAbsorber();
        if (book == address(0)) return 0;
        (bool okDeclared, uint256 declared) =
            _readClassPrincipal(book, IConservativeImpairmentBook.declaredDefaultedPrincipal.selector, classId);
        (bool okPastDue, uint256 pastDue) =
            _readClassPrincipal(book, IConservativeImpairmentBook.pastDuePrincipal.selector, classId);
        if (!okDeclared || !okPastDue) return _UNREADABLE_BOOK_LOCK;
        unchecked {
            // Both legs are principal balances bounded by the book; their sum cannot overflow.
            return declared + pastDue;
        }
    }

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). One length-checked raw staticcall. Returns `(false, 0)` on
    ///      a revert, on empty returndata (the permissive-fallback case), or on anything that is
    ///      not exactly one word — never a decoded value from data too short to hold one.
    function _readClassPrincipal(address book, bytes4 selector, uint256 classId)
        private
        view
        returns (bool ok, uint256 value)
    {
        (bool success, bytes memory data) = book.staticcall(abi.encodeWithSelector(selector, classId));
        if (!success || data.length != 32) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }

    function _headroom(CuratorStorage storage $, uint256 classId, ClassPool storage pool)
        private
        view
        returns (uint256)
    {
        uint256 required = _requiredFirstLoss($, classId);
        return pool.balance > required ? pool.balance - required : 0;
    }

    /// @dev Notifies the points module of the curator's new posted first-loss (P-01),
    ///      FAIL-OPEN — a points failure must never block first-loss post/withdraw (which are
    ///      cascade-relevant capital movements).
    function _notifyPoints(CuratorStorage storage $, uint256 classId, address curator) private {
        IPointsModule pm = $.pointsModule;
        if (address(pm) != address(0)) {
            uint256 posted = _postedOf($.pools[classId], $.stakes[classId][curator]);
            try pm.onCuratorStakeChange(curator, classId, posted) {} catch {}
        }
    }

    /// @dev AUDIT FIX (F3-PA-c). The governance path the pre-arm must outlast, UNBOUNDED except
    ///      for overflow safety: the longer of the `Config` launch floor and the live reading.
    ///      `custodyPreArmGovernancePath()` is this value bounded by `CUSTODY_PRE_ARM_MAX_PATH`;
    ///      the difference between the two is exactly what
    ///      `custodyPreArmCoversLiveGovernancePath()` reports.
    function _governancePath() private view returns (uint256) {
        uint256 path = uint256(Config.GOV_VOTING_DELAY) + uint256(Config.GOV_VOTING_PERIOD) + Config.TIMELOCK_MIN_DELAY;
        uint256 live = _liveGovernancePath(_storage().governor);
        return live > path ? live : path;
    }

    /// @dev AUDIT FIX (F3-PA-c). Single derivation for every pre-arm view and for the arm itself,
    ///      so the live governance reads happen ONCE per call and the three published quantities
    ///      can never disagree with each other within a transaction.
    ///
    ///      THE LAST LINE IS A GUARD. `duration > boundedPath` is what the whole mechanism rests
    ///      on; with `CUSTODY_PRE_ARM_MAX_DURATION == CUSTODY_PRE_ARM_MAX_PATH * 3 / 2` the clamp
    ///      cannot bind, and the `+ 1` cannot fire for any path at or above the `Config` floor of
    ///      ten days. Both stay because the property must hold by construction and not by
    ///      arithmetic that a future constant change could quietly falsify.
    function _derivePreArm() private view returns (uint256 livePath, uint64 duration) {
        livePath = _governancePath();
        uint256 bounded = livePath > CUSTODY_PRE_ARM_MAX_PATH ? uint256(CUSTODY_PRE_ARM_MAX_PATH) : livePath;
        uint256 derived = bounded + bounded / 2;
        if (derived > CUSTODY_PRE_ARM_MAX_DURATION) derived = CUSTODY_PRE_ARM_MAX_DURATION;
        if (derived <= bounded) derived = bounded + 1;
        duration = uint64(derived);
    }

    /// @dev AUDIT FIX (R6-CF1). Live `votingDelay + votingPeriod + timelock minDelay`, in SECONDS,
    ///      or zero when it cannot be read commensurably. Zero is safe: the caller keeps the
    ///      `Config` floor, which is never shorter than the launch governance path.
    ///
    ///      AUDIT FIX (F3-PA-d) — WHY THERE IS NO `try`/`catch` HERE ANY MORE, AND WHY IT MUST NOT
    ///      COME BACK. R6-CF1 read these four values through `try`/`catch` and asserted in its own
    ///      comment that the leading `code.length` check made that safe. IT DOES NOT. `code.length`
    ///      only proves the address is a contract; it says nothing about the callee's ANSWER. A
    ///      governor with a permissive fallback — a proxy whose implementation slot is empty, a
    ///      Safe, anything with `fallback() external {}` — answers `CLOCK_MODE()` with SUCCESS and
    ///      EMPTY returndata, and Solidity's `try`/`catch` does NOT catch the `abi.decode` failure
    ///      that follows (measured: the decode revert escapes the inner `catch` entirely). That
    ///      reverted `custodyPreArmDuration()` and through it `preArmCustodyFreeze()` — disarming
    ///      the guardian exactly when it is needed, which is the failure mode the original comment
    ///      was written to rule out.
    ///
    ///      Every read is therefore a RAW staticcall whose returndata length is checked BEFORE any
    ///      decode, and each defence is load-bearing:
    ///        - `data.length != 32` rejects empty and short returndata; the surviving 32 bytes
    ///          decode as a `uint256` unconditionally, so no decode can revert.
    ///        - an address term is range-checked against `type(uint160).max` rather than decoded as
    ///          `address`, because `abi.decode(..., (address))` reverts on dirty high bits.
    ///        - the clock mode is compared as RETURNDATA against the canonical ABI encoding, so a
    ///          hostile dynamic-type header can never steer a decode. It is checked at all because
    ///          `votingDelay`/`votingPeriod` are denominated in the governor's ERC-6372 clock, and
    ///          adding BLOCK counts to `block.timestamp` is wrong by orders of magnitude.
    ///        - `GOV_READ_GAS` bounds each sub-call so a gas-burning governor cannot take the
    ///          guardian's arm down with it.
    ///        - each term is capped before summing so a hostile parameter cannot overflow.
    function _liveGovernancePath(address governor_) private view returns (uint256) {
        if (governor_ == address(0) || governor_.code.length == 0) return 0;
        if (!_clockIsTimestamp(governor_)) return 0;

        (bool okDelay, uint256 delay_) = _readUint(governor_, IGovernanceSchedule.votingDelay.selector);
        if (!okDelay) return 0;
        (bool okPeriod, uint256 period_) = _readUint(governor_, IGovernanceSchedule.votingPeriod.selector);
        if (!okPeriod) return 0;
        (bool okTimelock, uint256 rawTimelock) = _readUint(governor_, IGovernanceSchedule.timelock.selector);
        if (!okTimelock || rawTimelock > type(uint160).max) return 0;

        address timelock_ = address(uint160(rawTimelock));
        if (timelock_.code.length == 0) return 0;
        (bool okMin, uint256 minDelay_) = _readUint(timelock_, ITimelockSchedule.getMinDelay.selector);
        if (!okMin) return 0;

        return _capTerm(delay_) + _capTerm(period_) + _capTerm(minDelay_);
    }

    /// @dev AUDIT FIX (F3-PA-d). Gas-bounded, length-checked word read. Returns `ok == false`
    ///      rather than reverting for EVERY failure mode a foreign address can present: revert,
    ///      out-of-gas, empty returndata, short returndata, over-long returndata.
    function _readUint(address target, bytes4 selector) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory data) = target.staticcall{gas: GOV_READ_GAS}(abi.encodeWithSelector(selector));
        if (!success || data.length != 32) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }

    /// @dev AUDIT FIX (F3-PA-d). ERC-6372 clock check by RETURNDATA EQUALITY. Comparing the raw
    ///      bytes against the canonical ABI encoding of `"mode=timestamp"` means a governor that
    ///      returns nothing, garbage, or a malformed dynamic-type header simply fails the check and
    ///      falls back to the `Config` floor — it can never revert this call.
    function _clockIsTimestamp(address governor_) private view returns (bool) {
        (bool success, bytes memory data) =
            governor_.staticcall{gas: GOV_READ_GAS}(abi.encodeWithSelector(IGovernanceSchedule.CLOCK_MODE.selector));
        if (!success) return false;
        return keccak256(data) == keccak256(abi.encode(CLOCK_MODE_TIMESTAMP));
    }

    /// @dev AUDIT FIX (F3-PA-c). Overflow guard on a single governance term. `type(uint64).max`
    ///      rather than `CUSTODY_PRE_ARM_MAX_DURATION`: capping each term at the DURATION ceiling
    ///      was what let three capped terms sum past it and then be silently truncated. The path
    ///      is bounded once, as a whole, in `_derivePreArm`.
    function _capTerm(uint256 term) private pure returns (uint256) {
        return term > type(uint64).max ? uint256(type(uint64).max) : term;
    }

    function _requireKnownClass(uint256 classId) private pure {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert Curator_UnknownClass(classId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (CuratorStorage storage $) {
        assembly {
            $.slot := CURATOR_STORAGE_LOCATION
        }
    }
}
