// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICascadeBackstop} from "./interfaces/ICascadeBackstop.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title SGrove — the staked-GROVE backstop, cascade layer 2 (ADR-0014/0021)
/// @notice GROVE holders stake here (non-transferable positions, 21-day unbonding) and
///         earn a governance-routed share of protocol fees. Shortfall coverage comes
///         from a dedicated USDfr COVERAGE RESERVE — funded permissionlessly
///         (`fundCoverage`: fee routing, Forest Road seeds, anyone) — never from a
///         GROVE conversion (no on-chain GROVE/USD path exists; ADR-0021 records this
///         deliberately and HONESTLY: the backstop's real capacity is its USDfr
///         reserve, not the headline staked-GROVE value; capacity is public via
///         `coverageCapacity()`).
///
///         ICascadeBackstop contract (enforced by DefaultManager's balance-delta
///         check): `coverShortfall` transfers exactly `covered <= amount` USDfr to the
///         caller in-call, where covered = min(amount, reserve x 50% per-event cap,
///         ADR-0014 — preserving a residual backstop across successive events).
///
///         GOVERNANCE (ADR-0026, amending ADR-0013): staking GROVE here does NOT
///         disenfranchise the staker. `VotesUpgradeable` checkpoints each staker's
///         ACTIVE stake as voting units, so `getPastVotes(staker, timepoint)` is
///         queryable by the Governor. Unbonding stake does NOT vote (it stops being an
///         active position the instant `requestUnstake` is called). The GROVE this
///         contract custodies is deliberately left UNDELEGATED — that is what stops the
///         same GROVE from being counted twice. `GroveVotesAggregator` sums the two
///         sources for the Governor.
/// @dev Pause policy: user paths (stake/unstake/claims) are guardian-pausable;
///      `coverShortfall` is NEVER pausable — the cascade cannot be suppressed
///      (consistent with CuratorModule.absorbLoss and DefaultManager, ADR-0017 §4).
contract SGrove is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    VotesUpgradeable,
    ICascadeBackstop
{
    using SafeERC20 for IERC20;

    /// @dev LAYOUT-FROZEN: ARRAY element (`unbonds[staker]` below). Adding/reordering
    ///      any field shifts every existing element on the deployed proxy → corruption.
    ///      NEVER extend on an upgrade (mapping-value structs are the safe-to-extend ones).
    struct Unbond {
        uint192 amount;
        uint64 releaseAt;
    }

    /// @custom:storage-location erc7201:forestroad.storage.SGrove
    struct SGroveStorage {
        IERC20 grove;
        IERC20 usdfr;
        uint64 unbondingPeriod;
        uint16 perEventCapBps;
        uint256 totalStaked; // actively staked GROVE (unbonding excluded)
        mapping(address staker => uint256) staked;
        mapping(address staker => Unbond[]) unbonds;
        uint256 coverageReserve; // USDfr reserved for shortfall coverage (ADR-0021)
        // Reward accounting (Synthetix-style streaming, audit R4-EC1). rewardIndexWad is
        // the cumulative reward-per-staked-GROVE checkpoint (rewardPerTokenStored);
        // userIndexWad is each staker's last-checkpointed value; accruedRewards is their
        // settled-but-unclaimed balance. Rewards drip at `rewardRate` USDfr/sec until
        // `periodFinish`; `lastUpdateTime` is when rewardIndexWad was last advanced.
        uint256 rewardIndexWad; // cumulative USDfr rewards per staked GROVE (1e18)
        mapping(address staker => uint256) userIndexWad;
        mapping(address staker => uint256) accruedRewards;
        // ── streaming schedule (append-only tail for upgrade safety) ──
        uint256 rewardRate; // USDfr streamed per second (0 when no active stream)
        uint64 periodFinish; // timestamp the current stream ends
        uint64 lastUpdateTime; // last time rewardIndexWad was advanced
        uint64 rewardsDuration; // stream window applied to each notifyRewards
        // ── PM-R-07: per-EVENT cumulative coverage accounting (append-only TAIL) ──
        // MUST stay last. Inserting these mid-struct would shift every field below them and
        // corrupt the deployed proxy's state on upgrade.
        mapping(uint256 eventId => uint256) eventCovered;
        mapping(uint256 eventId => uint256) eventCapSnapshot;
        // Vault fee-accounting coordinator. Brackets live-capacity changes so
        // backstop funding/configuration cannot be booked as senior performance.
        IsUSDfr feeVault;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.SGrove")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SGROVE_STORAGE_LOCATION =
        0x8947529af82e5c31b771fc0b2221fa39dd660e5ffcb6bd0eae7a66d91fc54b00;

    uint256 private constant WAD = 1e18;

    event Staked(address indexed staker, uint256 amount);
    event UnstakeRequested(address indexed staker, uint256 indexed unbondId, uint256 amount, uint64 releaseAt);
    event UnstakeClaimed(address indexed staker, uint256 indexed unbondId, uint256 amount);
    event CoverageFunded(address indexed funder, uint256 amount);
    /// @param rate The new per-second stream rate (USDfr/sec). @param periodFinish When the stream ends.
    event RewardsNotified(address indexed notifier, uint256 amount, uint256 rate, uint64 periodFinish);
    event RewardsClaimed(address indexed staker, uint256 amount);
    event UnbondingPeriodSet(uint64 period);
    event PerEventCapSet(uint16 capBps);
    event RewardsDurationSet(uint64 duration);

    error SGrove_ZeroAddress();
    error SGrove_ZeroAmount();
    error SGrove_InsufficientStake(uint256 requested, uint256 staked);
    error SGrove_UnknownUnbond(uint256 unbondId);
    error SGrove_StillUnbonding(uint256 unbondId, uint64 releaseAt);
    error SGrove_NoStakers();
    error SGrove_NothingToClaim();
    error SGrove_BadParams();
    /// @notice The notified amount (plus any rolled-over remainder) is too small to yield
    ///         a non-zero per-second rate over the reward duration.
    error SGrove_RewardDust(uint256 amount, uint256 duration);
    /// @notice setRewardsDuration called while a stream is still active (must wait for it
    ///         to finish so in-flight accrual is not silently re-timed).
    error SGrove_StreamActive(uint64 periodFinish);
    /// @notice A mid-stream notification would lower the drip rate (stream-dilution grief,
    ///         audit M-1). Extending a live stream must not slow stakers' owed yield.
    error SGrove_RewardRateWouldDecrease(uint256 newRate, uint256 currentRate);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the backstop with the ADR-0014 launch calibration.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser (user paths only — never the cascade).
    /// @param upgrader Upgrade authority (timelock).
    /// @param grove The GROVE token (staking asset).
    /// @param usdfr The USDfr token (coverage + rewards denomination).
    /// @param feeVault sUSDfr vault whose conservative NAV nets this capacity.
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address grove,
        address usdfr,
        address feeVault
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || grove == address(0)
                || usdfr == address(0) || feeVault == address(0)
        ) revert SGrove_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        // ADR-0026: the EIP-712 domain backs `delegateBySig`. `__Votes_init` itself is
        // empty in OZ 5.4.0, so the domain MUST be seeded here or gasless delegation
        // would sign against an unset domain.
        __EIP712_init(Config.SGROVE_NAME, "1");
        __Votes_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        SGroveStorage storage $ = _storage();
        $.grove = IERC20(grove);
        $.usdfr = IERC20(usdfr);
        $.feeVault = IsUSDfr(feeVault);
        $.unbondingPeriod = uint64(Config.SGROVE_UNBONDING_PERIOD);
        $.perEventCapBps = uint16(Config.SGROVE_PER_EVENT_COVERAGE_CAP_BPS);
        $.rewardsDuration = Config.SGROVE_REWARDS_DURATION;
        emit UnbondingPeriodSet(uint64(Config.SGROVE_UNBONDING_PERIOD));
        emit PerEventCapSet(uint16(Config.SGROVE_PER_EVENT_COVERAGE_CAP_BPS));
        emit RewardsDurationSet(Config.SGROVE_REWARDS_DURATION);
    }

    // ── staking (non-transferable positions) ─────────────────────────────

    /// @notice Stakes `amount` GROVE. Rewards accrue pro-rata from this point.
    /// @dev ADR-0026 (L-02): the stake is checkpointed as voting units, and a staker with
    ///      no delegate on record is self-delegated FIRST — before `staked` is mutated.
    ///      The order is load-bearing: `_delegate` moves `_getVotingUnits(account)` (the
    ///      CURRENT stake) to the new delegate, so self-delegating after the increment
    ///      would move the new balance AND then `_transferVotingUnits` would add the same
    ///      `amount` again. Doing it first moves the OLD balance (zero on a first stake,
    ///      or exactly the prior stake for someone who had delegated away to `address(0)`),
    ///      and the increment is then booked once.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert SGrove_ZeroAmount();
        SGroveStorage storage $ = _storage();
        _updateReward($, msg.sender);
        if (delegates(msg.sender) == address(0)) _delegate(msg.sender, msg.sender);
        $.staked[msg.sender] += amount;
        $.totalStaked += amount;
        _transferVotingUnits(address(0), msg.sender, amount); // mint voting units
        $.grove.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Starts the 21-day unbonding clock on `amount` of the caller's stake
    ///         (ADR-0014: long enough that stakers cannot front-run a known loss
    ///         event). Unbonding stake stops earning rewards immediately.
    /// @dev ADR-0026 (L-02): unbonding stake stops VOTING immediately too — the voting
    ///      units are burned here, not at `claimUnstake`. `_transferVotingUnits` does not
    ///      read `_getVotingUnits`, so its position relative to the balance write is
    ///      immaterial; it is placed after for readability.
    function requestUnstake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 unbondId) {
        if (amount == 0) revert SGrove_ZeroAmount();
        SGroveStorage storage $ = _storage();
        uint256 current = $.staked[msg.sender];
        if (amount > current) revert SGrove_InsufficientStake(amount, current);
        _updateReward($, msg.sender);
        $.staked[msg.sender] = current - amount;
        $.totalStaked -= amount;
        _transferVotingUnits(msg.sender, address(0), amount); // burn voting units
        uint64 releaseAt = uint64(block.timestamp) + $.unbondingPeriod;
        unbondId = $.unbonds[msg.sender].length;
        $.unbonds[msg.sender].push(Unbond({amount: uint192(amount), releaseAt: releaseAt}));
        emit UnstakeRequested(msg.sender, unbondId, amount, releaseAt);
    }

    /// @notice Claims a matured unbond, returning the GROVE.
    function claimUnstake(uint256 unbondId) external nonReentrant whenNotPaused {
        SGroveStorage storage $ = _storage();
        Unbond[] storage list = $.unbonds[msg.sender];
        if (unbondId >= list.length) revert SGrove_UnknownUnbond(unbondId);
        Unbond memory u = list[unbondId];
        if (u.amount == 0) revert SGrove_UnknownUnbond(unbondId); // already claimed
        if (block.timestamp < u.releaseAt) revert SGrove_StillUnbonding(unbondId, u.releaseAt);
        list[unbondId].amount = 0; // ids stay stable; slot marked spent
        $.grove.safeTransfer(msg.sender, u.amount);
        emit UnstakeClaimed(msg.sender, unbondId, u.amount);
    }

    // ── coverage reserve (ADR-0021: the backstop's REAL capacity) ────────

    /// @notice Adds USDfr to the coverage reserve. Permissionless: governance-routed
    ///         fee share, Forest Road manual seeds/top-ups, anyone.
    function fundCoverage(uint256 amount) external nonReentrant {
        if (amount == 0) revert SGrove_ZeroAmount();
        SGroveStorage storage $ = _storage();
        $.feeVault.beginFeeNeutralMarkedNavChange();
        $.coverageReserve += amount;
        $.usdfr.safeTransferFrom(msg.sender, address(this), amount);
        $.feeVault.endFeeNeutralMarkedNavChange();
        emit CoverageFunded(msg.sender, amount);
    }

    /// @inheritdoc ICascadeBackstop
    /// @dev NEVER pausable (the cascade cannot be suppressed). Per-event cap: at most
    ///      `perEventCapBps` of the CURRENT reserve per call (ADR-0014 — a residual
    ///      backstop survives for subsequent events).
    function coverShortfall(uint256 eventId, uint256 amount)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        returns (uint256 covered)
    {
        if (amount == 0) revert SGrove_ZeroAmount();
        SGroveStorage storage $ = _storage();

        // AUDIT FIX (PM-R-07): the cap is now enforced CUMULATIVELY PER EVENT, not per call.
        // It previously recomputed `reserve * capBps` from the CURRENT reserve on every call,
        // so realizing one facility's loss in chunks drew 50%, then 50% of the remainder, and
        // so on — approaching the whole reserve. That silently voided the staker protection
        // ADR-0021 advertises: an sGROVE staker could not bound their exposure to a single
        // credit event, which is the entire point of a "per-event" cap.
        //
        // The cap is SNAPSHOTTED at the event's first draw, so the guarantee is stateable:
        // one default event can never take more than `capBps` of the coverage reserve AS IT
        // STOOD when that event began. A later event re-snapshots against the smaller reserve.
        // Keyed by the defaulted facility's tokenId. A facility that defaults, resolves and
        // defaults again keeps its earlier consumption — conservative for stakers, and the
        // safe direction.
        uint256 cap = $.eventCapSnapshot[eventId];
        if (cap == 0) {
            cap = Math.mulDiv($.coverageReserve, $.perEventCapBps, Config.BPS);
            // only persist a real snapshot; an event that arrives at an empty reserve has
            // consumed nothing and may still draw once the reserve is funded
            if (cap != 0) $.eventCapSnapshot[eventId] = cap;
        }
        uint256 already = $.eventCovered[eventId];
        uint256 room = cap > already ? cap - already : 0;

        covered = amount < room ? amount : room;
        if (covered > $.coverageReserve) covered = $.coverageReserve; // never over-deliver
        if (covered != 0) {
            $.eventCovered[eventId] = already + covered;
            $.coverageReserve -= covered;
            $.usdfr.safeTransfer(msg.sender, covered);
        }
        emit ShortfallCovered(msg.sender, amount, covered);
    }

    /// @notice Coverage already drawn for a loss event, and the cap snapshotted at its first draw.
    /// @param eventId The defaulted facility's `tokenId`.
    /// @return drawn Cumulative coverage delivered for this event.
    /// @return cap The per-event ceiling fixed at the event's first draw (0 = never drawn).
    function eventCoverage(uint256 eventId) external view returns (uint256 drawn, uint256 cap) {
        SGroveStorage storage $ = _storage();
        return ($.eventCovered[eventId], $.eventCapSnapshot[eventId]);
    }

    // ── rewards (governance-routed fee share, ADR-0014) ──────────────────

    /// @notice Schedules `amount` USDfr to STREAM linearly to stakers over the reward
    ///         duration, rather than distributing instantly. Permissionless like
    ///         `fundCoverage`. If a stream is already running, its undistributed remainder
    ///         is rolled forward into a fresh full-duration stream at the blended rate.
    /// @dev AUDIT FIX (R4-EC1): streaming makes rewards accrue in real time (Pendle-
    ///      compatible) and removes the deposit-before-harvest sandwich — a front-runner
    ///      who stakes right before a notification now earns only for the seconds they
    ///      actually hold, not a lump sum. The rolled-over remainder is still physically
    ///      held (never claimed), so `rate * duration <= USDfr held for rewards`.
    function notifyRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert SGrove_ZeroAmount();
        SGroveStorage storage $ = _storage();
        if ($.totalStaked == 0) revert SGrove_NoStakers();
        _updateReward($, address(0)); // bank accrual to date at the OLD rate first

        uint64 duration = $.rewardsDuration;
        // Fail loud, not with a raw 0x12 divide-by-zero panic, if the streaming window
        // was never seeded (audit R5-UP1: an in-place upgrade that appended the streaming
        // fields without a reinitializer would leave `rewardsDuration == 0`). `initialize`
        // seeds it; this is the belt-and-braces guard for the upgrade path.
        if (duration == 0) revert SGrove_BadParams();
        uint256 rate;
        if (block.timestamp >= $.periodFinish) {
            rate = amount / duration;
        } else {
            // roll the not-yet-streamed remainder of the live stream into the new one
            uint256 remaining = $.periodFinish - block.timestamp;
            uint256 leftover = remaining * $.rewardRate;
            rate = (amount + leftover) / duration;
            // AUDIT FIX (M-1): a mid-stream notify must not LOWER the drip rate. Otherwise
            // anyone could call notifyRewards(dust) repeatedly to re-stretch the remaining
            // rewards over a fresh full duration each time, diluting and deferring stakers'
            // owed yield indefinitely (a griefing DoS — no funds lost, but the stream never
            // finishes). Extending the window now requires real funding: to hold the rate
            // you must add ~rate·elapsed, which simply pays stakers more. Permissionless
            // top-ups that raise (or hold) the rate are still welcome.
            if (rate < $.rewardRate) revert SGrove_RewardRateWouldDecrease(rate, $.rewardRate);
        }
        // reject dust that rounds the per-second rate to 0 — it would pull USDfr in yet
        // stream nothing, stranding it (breaking custody). Batch into a larger notify.
        if (rate == 0) revert SGrove_RewardDust(amount, duration);

        $.rewardRate = rate;
        $.lastUpdateTime = uint64(block.timestamp);
        uint64 finish = uint64(block.timestamp) + duration;
        $.periodFinish = finish;
        $.usdfr.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsNotified(msg.sender, amount, rate, finish);
    }

    /// @notice Claims the caller's accrued USDfr rewards.
    function claimRewards() external nonReentrant whenNotPaused returns (uint256 amount) {
        SGroveStorage storage $ = _storage();
        _updateReward($, msg.sender);
        amount = $.accruedRewards[msg.sender];
        if (amount == 0) revert SGrove_NothingToClaim();
        $.accruedRewards[msg.sender] = 0;
        $.usdfr.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    // ── governance ───────────────────────────────────────────────────────

    /// @notice Sets the unbonding period (ADR-0014 default 21 days).
    /// @dev AUDIT FIX (L): bounded to [1, 365 days] so a governance fat-finger can't set
    ///      an absurd value that overflows `releaseAt = now + period` (wrapping to a
    ///      small number → instant unstake, defeating the cooldown).
    function setUnbondingPeriod(uint64 period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (period == 0 || period > 365 days) revert SGrove_BadParams();
        _storage().unbondingPeriod = period;
        emit UnbondingPeriodSet(period);
    }

    /// @notice Sets the per-event coverage cap (bps of the current reserve).
    function setPerEventCap(uint16 capBps) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (capBps == 0 || capBps > Config.BPS) revert SGrove_BadParams();
        SGroveStorage storage $ = _storage();
        $.feeVault.beginFeeNeutralMarkedNavChange();
        $.perEventCapBps = capBps;
        $.feeVault.endFeeNeutralMarkedNavChange();
        emit PerEventCapSet(capBps);
    }

    /// @notice Sets the reward streaming window applied to each `notifyRewards`.
    /// @dev Only when no stream is active (`block.timestamp >= periodFinish`), so a change
    ///      never silently re-times in-flight accrual. Bounded to [1, 365 days].
    function setRewardsDuration(uint64 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration == 0 || duration > Config.SGROVE_MAX_REWARDS_DURATION) revert SGrove_BadParams();
        SGroveStorage storage $ = _storage();
        if (block.timestamp < $.periodFinish) revert SGrove_StreamActive($.periodFinish);
        $.rewardsDuration = duration;
        emit RewardsDurationSet(duration);
    }

    // ── guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses user paths (stake/unstake/claims). The cascade never pauses.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses user paths.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── views ────────────────────────────────────────────────────────────

    /// @notice Actively staked GROVE for `staker` (unbonding excluded).
    function stakedOf(address staker) external view returns (uint256) {
        return _storage().staked[staker];
    }

    /// @notice Total actively staked GROVE.
    function totalStaked() external view returns (uint256) {
        return _storage().totalStaked;
    }

    /// @notice The USDfr coverage reserve (the backstop's real capacity base).
    function coverageReserve() external view returns (uint256) {
        return _storage().coverageReserve;
    }

    /// @notice What a single shortfall event could draw right now.
    function coverageCapacity() external view returns (uint256) {
        SGroveStorage storage $ = _storage();
        return Math.mulDiv($.coverageReserve, $.perEventCapBps, Config.BPS);
    }

    /// @notice Claimable rewards for `staker` right now (settled + streamed-so-far).
    function pendingRewards(address staker) public view returns (uint256) {
        SGroveStorage storage $ = _storage();
        return
            $.accruedRewards[staker] + Math.mulDiv($.staked[staker], _rewardPerToken($) - $.userIndexWad[staker], WAD);
    }

    /// @notice Alias for `pendingRewards` (Synthetix/Pendle-adapter naming).
    function earned(address staker) external view returns (uint256) {
        return pendingRewards(staker);
    }

    /// @notice Cumulative reward-per-staked-GROVE, extrapolated to `block.timestamp`.
    function rewardPerToken() external view returns (uint256) {
        return _rewardPerToken(_storage());
    }

    /// @notice The last timestamp at which rewards are still accruing (min(now, finish)).
    function lastTimeRewardApplicable() external view returns (uint64) {
        return _lastTimeApplicable(_storage());
    }

    /// @notice Current stream schedule (for frontends / Pendle SY adapters).
    function rewardSchedule()
        external
        view
        returns (uint256 rate, uint64 periodFinish, uint64 lastUpdateTime, uint64 rewardsDuration)
    {
        SGroveStorage storage $ = _storage();
        return ($.rewardRate, $.periodFinish, $.lastUpdateTime, $.rewardsDuration);
    }

    /// @notice A staker's unbond entries (amount 0 = already claimed).
    function unbondsOf(address staker) external view returns (Unbond[] memory) {
        return _storage().unbonds[staker];
    }

    /// @notice Current parameters.
    function params() external view returns (uint64 unbondingPeriod, uint16 perEventCapBps) {
        SGroveStorage storage $ = _storage();
        return ($.unbondingPeriod, $.perEventCapBps);
    }

    /// @notice Wired token addresses (post-deploy validation aid).
    function modules() external view returns (address grove, address usdfr, address feeVault) {
        SGroveStorage storage $ = _storage();
        return (address($.grove), address($.usdfr), address($.feeVault));
    }

    // ── governance voting (ADR-0026, L-02) ───────────────────────────────

    /// @notice EIP-6372 clock. MUST match GROVE's timestamp clock.
    /// @dev If this were left at the OZ default (block numbers) while GROVE checkpoints in
    ///      timestamps, the Governor would snapshot one unit and look the other up: every
    ///      staker's `getPastVotes` would silently read ~0. Asserted in `Validate.s.sol`.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 machine-readable clock description.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @notice Total voting units currently checkpointed here (== `totalStaked`).
    /// @dev Exposed so the double-counting invariant is externally checkable: this is the
    ///      slice of GROVE that votes through sGROVE rather than through GROVE itself.
    function totalVotingUnits() external view returns (uint256) {
        return _getTotalSupply();
    }

    /// @notice ERC-165 declaration used by DefaultManager to reject a replacement that
    ///         merely mimics `coverageCapacity()` but lacks the loss-delivery surface.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(ICascadeBackstop).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc VotesUpgradeable
    /// @dev Voting units are the staker's ACTIVE stake. Unbonding stake is excluded by
    ///      construction — `requestUnstake` already decremented `staked`.
    function _getVotingUnits(address account) internal view override returns (uint256) {
        return _storage().staked[account];
    }

    // ── internals ────────────────────────────────────────────────────────

    /// @dev The last second rewards accrue for: min(now, periodFinish). After the stream
    ///      ends, accrual stops cleanly (never streams past what was funded).
    function _lastTimeApplicable(SGroveStorage storage $) private view returns (uint64) {
        uint64 finish = $.periodFinish;
        return block.timestamp < finish ? uint64(block.timestamp) : finish;
    }

    /// @dev rewardPerTokenStored extrapolated by the elapsed streaming time. Guards
    ///      totalStaked == 0 (no accrual while nobody stakes — the stream time simply
    ///      passes and that slice is not credited, standard Synthetix semantics).
    function _rewardPerToken(SGroveStorage storage $) private view returns (uint256) {
        uint256 supply = $.totalStaked;
        if (supply == 0) return $.rewardIndexWad;
        uint256 elapsed = _lastTimeApplicable($) - $.lastUpdateTime;
        if (elapsed == 0) return $.rewardIndexWad;
        return $.rewardIndexWad + Math.mulDiv(elapsed * $.rewardRate, WAD, supply);
    }

    /// @dev Checkpoints global accrual to `block.timestamp`, then (if `staker != 0`) banks
    ///      that staker's share into accruedRewards. MUST be called before any change to a
    ///      staker's balance or the global rate (stake / requestUnstake / notify / claim).
    function _updateReward(SGroveStorage storage $, address staker) private {
        uint256 rpt = _rewardPerToken($);
        $.rewardIndexWad = rpt;
        $.lastUpdateTime = _lastTimeApplicable($);
        if (staker != address(0)) {
            uint256 owed = Math.mulDiv($.staked[staker], rpt - $.userIndexWad[staker], WAD);
            if (owed != 0) $.accruedRewards[staker] += owed;
            $.userIndexWad[staker] = rpt;
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (SGroveStorage storage $) {
        assembly {
            $.slot := SGROVE_STORAGE_LOCATION
        }
    }
}
