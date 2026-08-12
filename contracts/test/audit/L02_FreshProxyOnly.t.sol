// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Validate} from "../../script/Validate.s.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {SGrove} from "../../src/SGrove.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title L-02 (ADR-0026) — SGrove is FRESH-PROXY-ONLY, and here is the proof
/// @notice These tests exist to make the fresh-proxy constraint EXECUTABLE rather than
///         merely documented. ADR-0026 gives `SGrove` voting units backed by
///         `VotesUpgradeable`; `SGrove` is a UUPS proxy and the timelock holds
///         `UPGRADER_ROLE`, so "just upgrade the live proxy" is a physically available
///         operation. It is also a fund-destroying one:
///
///         A pre-L-02 proxy that already has stakers carries a POPULATED `staked` mapping
///         and a VIRGIN `openzeppelin.storage.Votes` namespace. After an in-place upgrade
///         the two disagree permanently. A legacy staker calling `requestUnstake` hits
///         `_transferVotingUnits(staker, address(0), amount)` ->
///         `_push($._totalCheckpoints, _subtract, amount)` with `latest() == 0`. `_subtract`
///         is CHECKED arithmetic under 0.8.30, so the call reverts `Panic(0x11)` — forever.
///
///         SCOPE OF THE LOSS (corrected after review — the earlier claim here was too
///         strong). It is the ACTIVE slice that is trapped: `claimUnstake` needs an unbond
///         record, and after the upgrade only `requestUnstake` can create one, so active
///         stake can never leave. Anything ALREADY UNBONDING at upgrade time is still
///         RESCUABLE, because `claimUnstake` touches no voting units at all — it only
///         zeroes the unbond slot and transfers. That distinction matters to any rescue
///         plan, so it is pinned rather than asserted in prose:
///         `test_l02_brickedProxy_alreadyUnbondingSliceIsStillClaimable`.
///
///         No reinitializer can repair it. The staker set is not enumerable
///         (`mapping(address staker => uint256) staked`, no array, no EnumerableSet), so
///         nothing on-chain can walk the holders and mint their missing voting units, and
///         `initialize` itself is spent (`InvalidInitialization`).
///
///         The bricked proxy also carries a SECOND, INDEPENDENT defect: its EIP-712 domain
///         is never seeded (`name == ""`, `version == ""`), because `__EIP712_init` only
///         runs inside the already-spent `initialize`. Every `delegateBySig` signature a
///         client produces against the documented domain therefore recovers the WRONG
///         address. Pinned by `test_l02_brickedProxy_eip712DomainIsEmptyAndTheClockAgrees`.
///
///         Hence: SGrove may only ever be deployed as a FRESH proxy, and the tripwire
///         `sGrove.totalVotingUnits() == sGrove.totalStaked()` (asserted by
///         `script/Validate.s.sol`) is what catches an operator who tries the other path.
///         Note WHY that specific assertion carries the whole weight: `clock()` and
///         `CLOCK_MODE()` are pure/view overrides living in the IMPLEMENTATION, so they
///         survive an in-place upgrade intact and `Validate`'s clock checks pass green on a
///         bricked proxy. And ahead of all of it sits the FIRST line of defence, the
///         manifest guard in `Validate._load`, which refuses a manifest written before
///         ADR-0026. These tests pin the hazard, both tripwires, the manifest guard, and
///         the positive control — the validator assertions by EXECUTING `Validate` itself,
///         not by re-implementing them inline.
/// @dev A note on the `LegacySGrove` stand-in at the bottom of this file: it mirrors
///      `SGrove.SGroveStorage` field for field at the SAME ERC-7201 location. If the two
///      layouts ever diverge the test proves nothing, so the layout equivalence is asserted
///      explicitly (every field written by the legacy code is read back through the NEW
///      implementation) before any failure is exercised.
contract L02FreshProxyOnlyTest is Test, Deploy {
    GroveToken internal grove;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal upgrader = makeAddr("upgrader");
    address internal treasury = makeAddr("forestRoadTreasury");
    address internal usdfr = makeAddr("usdfr");
    address internal legacyStaker = makeAddr("legacyStaker");
    address internal freshStaker = makeAddr("freshStaker");
    address internal delegatee = makeAddr("delegatee");
    address internal attester2Addr = makeAddr("l02Attester2");

    uint256 internal constant LEGACY_ACTIVE = 100e18;
    uint256 internal constant LEGACY_UNBONDING = 50e18;

    /// @dev The ERC-7201 root of `SGrove.SGroveStorage`, identical to the constant in
    ///      `src/SGrove.sol` (and to `LegacySGrove`'s below). PACKING: `grove` takes slot +0
    ///      alone (a second address would not fit), then `usdfr` (20 bytes) +
    ///      `unbondingPeriod` (8) + `perEventCapBps` (2) = 30 bytes all share slot +1. So
    ///      `totalStaked` is at +2 and the `staked` mapping base is at +3. Both offsets are
    ///      proved correct at the use site by reading the pokes back through the public
    ///      getters — an off-by-one would read 0 and fail those assertions.
    bytes32 internal constant SGROVE_STORAGE_ROOT = 0x8947529af82e5c31b771fc0b2221fa39dd660e5ffcb6bd0eae7a66d91fc54b00;

    /// @dev EIP-712 domain typehash, restated locally so a signature can be built against the
    ///      domain a CORRECTLY initialized SGrove would use.
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev `VotesUpgradeable`'s delegation struct hash.
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    // sentinels stamped into every non-`staked` storage field so the layout check is total
    uint256 internal constant SEED_COVERAGE = 4_242e18;
    uint256 internal constant SEED_INDEX_WAD = 7e18;
    uint256 internal constant SEED_ACCRUED = 123e18;
    uint256 internal constant SEED_RATE = 999;
    uint256 internal constant SEED_EVENT_ID = 7;
    uint256 internal constant SEED_EVENT_COVERED = 11e18;
    uint256 internal constant SEED_EVENT_CAP = 22e18;
    uint16 internal constant LEGACY_CAP_BPS = 5_000;

    function setUp() public {
        vm.warp(1_750_000_000);
        grove = GroveToken(
            address(
                new ERC1967Proxy(
                    address(new GroveToken()), abi.encodeCall(GroveToken.initialize, (admin, admin, treasury))
                )
            )
        );
    }

    // ── 1. the hazard: in-place upgrade of a staked legacy proxy bricks unstaking ──

    /// @notice Pins the fund-loss mechanic itself. A legacy proxy with a live staker,
    ///         upgraded in place to the L-02 implementation, keeps every byte of its
    ///         accounting state (so nothing looks wrong) and yet can never pay that staker
    ///         out again: `requestUnstake` underflows the virgin total-supply checkpoint.
    function test_l02_inPlaceUpgradeOfAStakedLegacyProxyBricksUnstake() public {
        LegacySGrove legacy = _deployLegacy();
        _stakeLegacy(legacy, legacyStaker, LEGACY_ACTIVE + LEGACY_UNBONDING);
        // one matured-ish unbond record so the ARRAY-element layout is exercised too
        vm.prank(legacyStaker);
        uint64 legacyReleaseAt = legacy.legacyRequestUnstake(LEGACY_UNBONDING);
        legacy.legacySeed(
            SEED_COVERAGE,
            SEED_INDEX_WAD,
            legacyStaker,
            SEED_INDEX_WAD, // userIndexWad == rewardIndexWad => pendingRewards == accruedRewards
            SEED_ACCRUED,
            SEED_RATE,
            uint64(block.timestamp), // periodFinish == lastUpdateTime == now => zero extrapolation
            uint64(block.timestamp),
            SEED_EVENT_ID,
            SEED_EVENT_COVERED,
            SEED_EVENT_CAP
        );

        // baseline through the LEGACY implementation
        assertEq(legacy.stakedOf(legacyStaker), LEGACY_ACTIVE, "legacy active stake");
        assertEq(legacy.totalStaked(), LEGACY_ACTIVE, "legacy total staked");

        SGrove upgraded = _upgradeInPlace(legacy);

        // ── layout equivalence: every legacy-written field reads back through L-02 ──
        assertEq(upgraded.stakedOf(legacyStaker), LEGACY_ACTIVE, "staked mapping survived the upgrade");
        assertEq(upgraded.totalStaked(), LEGACY_ACTIVE, "totalStaked survived the upgrade");
        assertEq(grove.balanceOf(address(upgraded)), LEGACY_ACTIVE + LEGACY_UNBONDING, "GROVE is really in there");
        SGrove.Unbond[] memory unbonds = upgraded.unbondsOf(legacyStaker);
        assertEq(unbonds.length, 1, "unbond array survived");
        assertEq(unbonds[0].amount, uint192(LEGACY_UNBONDING), "unbond element field 1 (amount) aligns");
        assertEq(unbonds[0].releaseAt, legacyReleaseAt, "unbond element field 2 (releaseAt) aligns");
        uint64 unbondingPeriod = upgraded.params();
        assertEq(unbondingPeriod, uint64(Config.SGROVE_UNBONDING_PERIOD), "unbondingPeriod aligns");
        uint256 packedParams = uint256(vm.load(address(upgraded), bytes32(uint256(SGROVE_STORAGE_ROOT) + 1)));
        assertEq(uint16(packedParams >> 224), LEGACY_CAP_BPS, "retired perEventCapBps tombstone aligns");
        (address g, address u,) = upgraded.modules();
        assertEq(g, address(grove), "grove slot aligns");
        assertEq(u, usdfr, "usdfr slot aligns");
        assertEq(upgraded.coverageReserve(), SEED_COVERAGE, "coverageReserve aligns");
        assertEq(upgraded.rewardPerToken(), SEED_INDEX_WAD, "rewardIndexWad aligns");
        assertEq(upgraded.pendingRewards(legacyStaker), SEED_ACCRUED, "accruedRewards + userIndexWad align");
        (uint256 rate, uint64 finish, uint64 lastUpdate, uint64 duration) = upgraded.rewardSchedule();
        assertEq(rate, SEED_RATE, "rewardRate aligns");
        assertEq(finish, uint64(block.timestamp), "periodFinish aligns");
        assertEq(lastUpdate, uint64(block.timestamp), "lastUpdateTime aligns");
        assertEq(duration, Config.SGROVE_REWARDS_DURATION, "rewardsDuration aligns");
        (uint256 drawn, uint256 cap) = upgraded.eventCoverage(SEED_EVENT_ID);
        assertEq(drawn, SEED_EVENT_COVERED, "eventCovered tail mapping aligns");
        assertEq(cap - drawn, SEED_COVERAGE, "ADR-0035 public view uses live reserve");
        bytes32 retiredCapSlot = keccak256(abi.encode(SEED_EVENT_ID, uint256(SGROVE_STORAGE_ROOT) + 12));
        assertEq(uint256(vm.load(address(upgraded), retiredCapSlot)), SEED_EVENT_CAP, "retired cap tombstone aligns");
        // the layout is faithful. Everything below is therefore about L-02, not about a
        // mis-modelled stand-in.

        // ── the Votes namespace, by contrast, is virgin ──
        assertEq(upgraded.totalVotingUnits(), 0, "voting units were never minted for the legacy staker");
        assertEq(upgraded.getVotes(legacyStaker), 0, "legacy staker has no delegate votes");
        assertEq(upgraded.delegates(legacyStaker), address(0), "legacy staker never self-delegated");

        // ── and that is fatal: the stake can never be withdrawn ──
        vm.prank(legacyStaker);
        vm.expectRevert(stdError.arithmeticError);
        upgraded.requestUnstake(LEGACY_ACTIVE);

        // not just the full amount — ANY amount, because latest() == 0
        vm.prank(legacyStaker);
        vm.expectRevert(stdError.arithmeticError);
        upgraded.requestUnstake(1);

        // the funds are still visibly there, and still unreachable
        assertEq(upgraded.stakedOf(legacyStaker), LEGACY_ACTIVE, "stake unchanged: every exit reverted");
        assertEq(grove.balanceOf(legacyStaker), 0, "staker got nothing back");

        // and there is no repair path: `initialize` is spent, and no reinitializer exists
        // that could walk the (non-enumerable) staker set to mint the missing units.
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        upgraded.initialize(admin, guardian, upgrader, address(grove), usdfr, address(this));
    }

    // ── 2. the tripwire that would have caught it ──────────────────────────

    /// @notice Pins the PREDICATE `script/Validate.s.sol` now asserts —
    ///         `totalVotingUnits() == totalStaked()` — as a property of the two proxy
    ///         shapes: FALSE on the bricked proxy, TRUE on a fresh L-02 proxy holding the
    ///         identical stake.
    /// @dev This test restates the predicate INLINE, so on its own it would stay green if
    ///      `Validate.s.sol` dropped the check entirely (reviewer finding: false-green
    ///      adjacent). `test_l02_validateScriptRejectsTheBrickedProxy` closes that by
    ///      executing the real `Validate` against a real deployment; this one stays because
    ///      it isolates the property from the validator's ~100 other assertions.
    function test_l02_theTripwireCatchesIt() public {
        LegacySGrove legacy = _deployLegacy();
        _stakeLegacy(legacy, legacyStaker, LEGACY_ACTIVE);
        SGrove bricked = _upgradeInPlace(legacy);

        // the tripwire FIRES on the bricked proxy
        assertEq(bricked.totalStaked(), LEGACY_ACTIVE, "bricked proxy still reports the stake");
        assertEq(bricked.totalVotingUnits(), 0, "bricked proxy has no voting units");
        assertTrue(
            bricked.totalVotingUnits() != bricked.totalStaked(),
            "Validate.s.sol's assertion must FAIL on an in-place-upgraded proxy"
        );

        // the tripwire PASSES on a fresh L-02 proxy carrying the identical stake
        SGrove fresh = _deployFresh();
        _stakeFresh(fresh, freshStaker, LEGACY_ACTIVE);
        assertEq(fresh.totalStaked(), LEGACY_ACTIVE, "fresh proxy holds the same stake");
        assertEq(fresh.totalVotingUnits(), LEGACY_ACTIVE, "fresh proxy minted matching voting units");
        assertEq(fresh.totalVotingUnits(), fresh.totalStaked(), "Validate.s.sol's assertion must HOLD on a fresh proxy");
    }

    // ── 3. the narrower precondition ───────────────────────────────────────

    /// @notice "totalStaked reconciles" is NOT a safe precondition for the upgrade — only
    ///         "every staked balance is zero at upgrade time" is. A legacy staker holding
    ///         100 who stakes 1 MORE after the upgrade self-delegates on the way in, which
    ///         books their WHOLE 101 as delegate votes while the total-supply checkpoint
    ///         only ever saw the 1. The mismatch is now internal to a single account, and
    ///         only that post-upgrade 1 GROVE is ever withdrawable.
    function test_l02_mixedStateIsAlsoBroken() public {
        LegacySGrove legacy = _deployLegacy();
        _stakeLegacy(legacy, legacyStaker, LEGACY_ACTIVE);
        SGrove mixed = _upgradeInPlace(legacy);

        _stakeFresh(mixed, legacyStaker, 1e18); // one more, through the L-02 code path

        assertEq(mixed.stakedOf(legacyStaker), LEGACY_ACTIVE + 1e18, "balance is 101");
        assertEq(mixed.totalStaked(), LEGACY_ACTIVE + 1e18, "totalStaked is 101");
        assertEq(mixed.delegates(legacyStaker), legacyStaker, "the late stake self-delegated");
        assertEq(mixed.getVotes(legacyStaker), LEGACY_ACTIVE + 1e18, "delegate votes are 101 (the WHOLE balance)");
        assertEq(mixed.totalVotingUnits(), 1e18, "but the total-supply checkpoint only ever saw the 1");

        // the full exit still panics ...
        vm.prank(legacyStaker);
        vm.expectRevert(stdError.arithmeticError);
        mixed.requestUnstake(LEGACY_ACTIVE + 1e18);
        // ... and so does anything larger than the post-upgrade slice
        vm.prank(legacyStaker);
        vm.expectRevert(stdError.arithmeticError);
        mixed.requestUnstake(2e18);

        // exactly the post-upgrade slice can leave, and nothing more, ever again
        vm.prank(legacyStaker);
        mixed.requestUnstake(1e18);
        assertEq(mixed.totalVotingUnits(), 0, "the only voting units in existence are burned");
        assertEq(mixed.getVotes(legacyStaker), LEGACY_ACTIVE, "delegate votes still phantom-hold the legacy 100");
        assertEq(mixed.stakedOf(legacyStaker), LEGACY_ACTIVE, "the legacy 100 remains staked");
        vm.prank(legacyStaker);
        vm.expectRevert(stdError.arithmeticError);
        mixed.requestUnstake(1); // 100 GROVE is now permanently unwithdrawable

        // and the tripwire still fires on this "reconciling totalStaked" state
        assertTrue(mixed.totalVotingUnits() != mixed.totalStaked(), "mixed state is caught by the same assertion");
    }

    // ── 4. positive control ────────────────────────────────────────────────

    /// @notice A FRESH L-02 proxy does the whole lifecycle cleanly, with voting units
    ///         tracking active stake exactly at every step: stake mints units and
    ///         self-delegates, `requestUnstake` burns them immediately (unbonding stake
    ///         does not vote), and `claimUnstake` is vote-neutral.
    function test_l02_aFreshProxyIsUnaffected() public {
        SGrove fresh = _deployFresh();
        vm.prank(treasury);
        grove.transfer(freshStaker, LEGACY_ACTIVE);

        vm.startPrank(freshStaker);
        grove.approve(address(fresh), LEGACY_ACTIVE);
        vm.expectEmit(true, true, true, false);
        emit IVotes.DelegateChanged(freshStaker, address(0), freshStaker);
        vm.expectEmit(true, false, false, true);
        emit IVotes.DelegateVotesChanged(freshStaker, 0, LEGACY_ACTIVE);
        vm.expectEmit(true, false, false, true);
        emit SGrove.Staked(freshStaker, LEGACY_ACTIVE);
        fresh.stake(LEGACY_ACTIVE);
        vm.stopPrank();

        assertEq(fresh.delegates(freshStaker), freshStaker, "first stake self-delegates");
        assertEq(fresh.getVotes(freshStaker), LEGACY_ACTIVE, "votes == active stake");
        assertEq(fresh.totalVotingUnits(), LEGACY_ACTIVE, "total units == total staked");
        assertEq(fresh.totalVotingUnits(), fresh.totalStaked(), "tripwire holds after stake");

        uint256 stakeTimepoint = block.timestamp;
        vm.warp(block.timestamp + 1);
        assertEq(fresh.getPastVotes(freshStaker, stakeTimepoint), LEGACY_ACTIVE, "checkpoint is queryable");
        assertEq(fresh.getPastTotalSupply(stakeTimepoint), LEGACY_ACTIVE, "past total units checkpointed");

        // unbonding removes voting power the instant it is requested
        vm.prank(freshStaker);
        uint256 id = fresh.requestUnstake(40e18);
        assertEq(fresh.getVotes(freshStaker), 60e18, "unbonding stake does not vote");
        assertEq(fresh.totalVotingUnits(), 60e18, "total units follow active stake down");
        assertEq(fresh.totalVotingUnits(), fresh.totalStaked(), "tripwire holds after requestUnstake");

        // claiming is vote-neutral (the units were already burned)
        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(freshStaker);
        fresh.claimUnstake(id);
        assertEq(grove.balanceOf(freshStaker), 40e18, "GROVE really came back");
        assertEq(fresh.getVotes(freshStaker), 60e18, "claimUnstake does not touch votes again");
        assertEq(fresh.totalVotingUnits(), 60e18, "claimUnstake does not touch total units again");
        assertEq(fresh.totalVotingUnits(), fresh.totalStaked(), "tripwire holds after claimUnstake");

        // and the remainder exits cleanly, all the way to zero
        vm.prank(freshStaker);
        uint256 id2 = fresh.requestUnstake(60e18);
        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(freshStaker);
        fresh.claimUnstake(id2);
        assertEq(grove.balanceOf(freshStaker), LEGACY_ACTIVE, "full principal recovered");
        assertEq(fresh.getVotes(freshStaker), 0, "votes back to zero");
        assertEq(fresh.totalVotingUnits(), 0, "units back to zero");
        assertEq(fresh.totalStaked(), 0, "stake back to zero");
    }

    // ── 5. the loss is real but NOT total: the unbonding slice is rescuable ─

    /// @notice CORRECTION pinned as a test (review finding 4). This file used to claim the
    ///         legacy staker's GROVE was "permanently unwithdrawable" full stop. That
    ///         overstates it. `claimUnstake` reads no voting units, mutates no checkpoint
    ///         and calls no `_transferVotingUnits`; it only zeroes the unbond slot and
    ///         transfers. So a slice that was ALREADY UNBONDING when the operator upgraded
    ///         in place still matures and still pays out on the bricked proxy — and a real
    ///         rescue plan needs to know that, because it means the recoverable set is
    ///         exactly "whatever happened to be mid-unbond", not "nothing".
    ///
    ///         What stays trapped is the ACTIVE slice, and this test holds that half of the
    ///         statement to account too: after the rescue, `requestUnstake(1)` still panics.
    function test_l02_brickedProxy_alreadyUnbondingSliceIsStillClaimable() public {
        LegacySGrove legacy = _deployLegacy();
        _stakeLegacy(legacy, legacyStaker, LEGACY_ACTIVE + LEGACY_UNBONDING);
        vm.prank(legacyStaker);
        uint64 releaseAt = legacy.legacyRequestUnstake(LEGACY_UNBONDING);

        SGrove bricked = _upgradeInPlace(legacy);
        assertEq(bricked.totalVotingUnits(), 0, "precondition: the Votes namespace is virgin");
        assertEq(bricked.stakedOf(legacyStaker), LEGACY_ACTIVE, "precondition: 100 active, 50 unbonding");

        // the unbonding clock is still enforced through the NEW implementation
        vm.prank(legacyStaker);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_StillUnbonding.selector, uint256(0), releaseAt));
        bricked.claimUnstake(0);

        // ... and once it matures, the claim SUCCEEDS on the bricked proxy
        vm.warp(uint256(releaseAt));
        vm.prank(legacyStaker);
        bricked.claimUnstake(0);
        assertEq(grove.balanceOf(legacyStaker), LEGACY_UNBONDING, "the already-unbonding slice IS recoverable");
        assertEq(grove.balanceOf(address(bricked)), LEGACY_ACTIVE, "only the active slice is still custodied");
        assertEq(bricked.totalVotingUnits(), 0, "claimUnstake touched no voting units (that is WHY it worked)");

        // the claim is not repeatable, and the active slice is still trapped
        vm.prank(legacyStaker);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, uint256(0)));
        bricked.claimUnstake(0);
        vm.prank(legacyStaker);
        vm.expectRevert(stdError.arithmeticError);
        bricked.requestUnstake(1);
        assertEq(bricked.stakedOf(legacyStaker), LEGACY_ACTIVE, "100 GROVE remains permanently trapped");
    }

    // ── 6. the SECOND failure, and why the clock check cannot see either ───

    /// @notice Two things the file previously did not say (review findings 3 and 5).
    ///
    ///         (a) The bricked proxy's EIP-712 domain is EMPTY. `__EIP712_init` runs only
    ///             inside `initialize`, which is spent, so `eip712Domain()` reports
    ///             `name == ""` / `version == ""` where a fresh proxy reports
    ///             `"Staked Forest Road Grove"` / `"1"`. That is a second, independent
    ///             failure of the in-place path: a `delegateBySig` signed over the
    ///             DOCUMENTED domain recovers some other address entirely, so the signer's
    ///             votes are not delegated — asserted here end to end, against a fresh
    ///             proxy that accepts the identical construction.
    ///
    ///         (b) `clock()` and `CLOCK_MODE()` are pure/view overrides that live in the
    ///             IMPLEMENTATION, not in storage. They therefore survive the in-place
    ///             upgrade perfectly intact, and `Validate`'s clock assertions
    ///             (`sGrove clock must be timestamp`) pass GREEN on a bricked proxy. That
    ///             is the whole justification for the `totalVotingUnits() == totalStaked()`
    ///             line: it is the ONLY validator assertion standing between an operator
    ///             and the loss.
    function test_l02_brickedProxy_eip712DomainIsEmptyAndTheClockAgrees() public {
        LegacySGrove legacy = _deployLegacy();
        _stakeLegacy(legacy, legacyStaker, LEGACY_ACTIVE);
        SGrove bricked = _upgradeInPlace(legacy);
        SGrove fresh = _deployFresh();

        // ── (a) the unseeded domain ────────────────────────────────────────
        (, string memory bName, string memory bVersion, uint256 bChain, address bVerifier,,) = bricked.eip712Domain();
        assertEq(bName, "", "bricked EIP-712 name is unseeded (__EIP712_init never ran)");
        assertEq(bVersion, "", "bricked EIP-712 version is unseeded");
        assertEq(bChain, block.chainid, "chainId is computed, not stored, so it is still right");
        assertEq(bVerifier, address(bricked), "verifyingContract is address(this), so it is still right");

        (, string memory fName, string memory fVersion,,,,) = fresh.eip712Domain();
        assertEq(fName, Config.SGROVE_NAME, "a fresh proxy seeds the domain name");
        assertEq(fVersion, "1", "a fresh proxy seeds the domain version");

        // and the consequence: a signature over the DOCUMENTED domain binds nothing here
        (address signer, uint256 signerPk) = makeAddrAndKey("sigDelegator");
        uint256 expiry = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signDelegation(address(bricked), Config.SGROVE_NAME, "1", signerPk, delegatee, 0, expiry);
        bricked.delegateBySig(delegatee, 0, expiry, v, r, s);
        assertEq(bricked.delegates(signer), address(0), "bricked: the signer's delegation did NOT land");
        assertEq(bricked.nonces(signer), 0, "bricked: the signer's nonce was not even consumed");

        (v, r, s) = _signDelegation(address(fresh), Config.SGROVE_NAME, "1", signerPk, delegatee, 0, expiry);
        fresh.delegateBySig(delegatee, 0, expiry, v, r, s);
        assertEq(fresh.delegates(signer), delegatee, "fresh: the identical construction binds correctly");
        assertEq(fresh.nonces(signer), 1, "fresh: the signer's nonce was consumed");

        // ── (b) the clock checks cannot tell the two proxies apart ─────────
        assertEq(bricked.CLOCK_MODE(), "mode=timestamp", "Validate's sGrove clock-MODE check PASSES on a brick");
        assertEq(bricked.clock(), uint48(block.timestamp), "Validate's clock-VALUE check would pass too");
        assertEq(bricked.CLOCK_MODE(), fresh.CLOCK_MODE(), "clock mode is identical on both shapes");
        assertEq(bricked.clock(), fresh.clock(), "clock value is identical on both shapes");

        // ... so this is the only assertion that separates them
        assertEq(fresh.totalVotingUnits(), fresh.totalStaked(), "fresh: units == staked");
        assertEq(bricked.totalStaked(), LEGACY_ACTIVE, "bricked: 100 staked");
        assertEq(bricked.totalVotingUnits(), 0, "bricked: 0 units");
        assertTrue(
            bricked.totalVotingUnits() != bricked.totalStaked(),
            "units != staked is the SOLE validator assertion that catches an in-place upgrade"
        );
    }

    // ── 7. the tripwire, EXECUTED through the real Validate script ─────────

    /// @notice Review finding 1: `test_l02_theTripwireCatchesIt` re-implements the predicate
    ///         inline and never imports `Validate`, so deleting `Validate.s.sol`'s
    ///         `"sGrove votes != staked"` line left it green. This test runs the REAL
    ///         validator — the same `validateDeployment` / `validateHandover` entry points
    ///         the deploy tooling and `Handover.s.sol` call — against a REAL full-stack
    ///         deployment, and asserts it REFUSES the bricked shape with that exact message.
    ///
    /// @dev Why the bricked shape is reproduced with `vm.store` rather than by handing
    ///      `Validate` the `LegacySGrove`-upgraded proxy built elsewhere in this file: the
    ///      validator asserts ~15 other things about `a.sGrove` FIRST (module wiring,
    ///      `DefaultManager.backstop()`, `CREDIT_ROLE`, and critically the AGGREGATOR's
    ///      `sGrove()` leg, which is IMMUTABLE and bound to the deployed proxy). A
    ///      substituted proxy therefore trips "votesAggregator legs" long before line 291
    ///      and would prove nothing about the tripwire. So the deployment's own sGROVE is
    ///      put into exactly the storage shape an in-place upgrade leaves — a populated
    ///      `staked`/`totalStaked` pair over a virgin Votes namespace — and the size of the
    ///      divergence is taken from the genuinely-bricked proxy, not invented.
    function test_l02_validateScriptRejectsTheBrickedProxy() public {
        Validate validator = new Validate();
        Ctx memory c = _l02Ctx();
        D memory d = _deployStack(c);
        Validate.M memory a = _validateArgs(d, c);

        // positive control 1: the pristine deployment validates GREEN, end to end
        validator.validateDeployment(a);
        assertEq(SGrove(d.sGrove).totalStaked(), 0, "a fresh deployment starts with no stake");

        // positive control 2: and it still validates GREEN once REAL stake exists, so the
        // tripwire is not merely satisfied by 0 == 0. (`validateHandover` here rather than
        // `validateDeployment` because moving GROVE out of the treasury lawfully breaks the
        // GENESIS-only supply equality, which is a different assertion.)
        grove_transferAndStake(d, freshStaker, LEGACY_ACTIVE);
        assertEq(SGrove(d.sGrove).totalStaked(), LEGACY_ACTIVE, "real stake landed");
        assertEq(SGrove(d.sGrove).totalVotingUnits(), LEGACY_ACTIVE, "real stake minted matching units");
        validator.validateHandover(a);

        // the divergence a genuine in-place upgrade produces, measured on a genuine one
        LegacySGrove legacy = _deployLegacy();
        _stakeLegacy(legacy, legacyStaker, LEGACY_ACTIVE);
        SGrove bricked = _upgradeInPlace(legacy);
        uint256 divergence = bricked.totalStaked() - bricked.totalVotingUnits();
        assertEq(divergence, LEGACY_ACTIVE, "a bricked proxy is short by exactly the legacy staker's stake");

        // reproduce it on the deployment's own (fully wired) sGROVE
        _pokeLegacyStake(d.sGrove, legacyStaker, divergence);
        assertEq(SGrove(d.sGrove).stakedOf(legacyStaker), divergence, "poke landed in the staked mapping");
        assertEq(SGrove(d.sGrove).totalStaked(), LEGACY_ACTIVE + divergence, "poke landed in totalStaked");
        assertEq(SGrove(d.sGrove).totalVotingUnits(), LEGACY_ACTIVE, "the Votes namespace did NOT move");

        // and now the REAL validator refuses the state, on both entry points
        vm.expectRevert(bytes("sGrove votes != staked"));
        validator.validateHandover(a);
        // `_validateWiring` runs before `_validateGenesis`, so this is the same line firing
        vm.expectRevert(bytes("sGrove votes != staked"));
        validator.validateDeployment(a);
    }

    // ── 8. the FIRST line of defence: the manifest guard ───────────────────

    /// @notice Review finding 6. `Validate._load` refuses to even parse a manifest with no
    ///         `.votesAggregator` key: such a stack was deployed before staked GROVE could
    ///         vote, and its Governor is permanently bound to GROVE directly
    ///         (`GovernorVotes._token` has no setter), so it must be REDEPLOYED. This is
    ///         the check that fires before any of the on-chain assertions, and it was
    ///         untested.
    /// @dev `_load` reads `deployments/<chainid>.json` from disk via `vm.readFile`, so it is
    ///      driven exactly that way: a fixture manifest is written under a chain-id this
    ///      repo will never deploy to (`foundry.toml` grants read-write on `./deployments`),
    ///      `vm.chainId` points `_load` at it, and it is removed again. The live manifests
    ///      are never touched. A `ValidateExposed` subclass is needed only because `_load`
    ///      is `internal`.
    function test_l02_validateRejectsAPreAdr0026Manifest() public {
        ValidateExposed exposed = new ValidateExposed();
        uint256 fixtureChain = 424_242; // not a chain this repo deploys to
        vm.chainId(fixtureChain);
        string memory path = string.concat("deployments/", vm.toString(fixtureChain), ".json");
        address aggregator = makeAddr("votesAggregator");
        address placeholder = makeAddr("manifestPlaceholder");

        // a manifest in the PRE-ADR-0026 shape is refused, loudly and legibly
        _writeManifestFixture(path, "l02ManifestNoAggregator", placeholder, address(0));
        vm.expectRevert(bytes("manifest predates ADR-0026 (L-02): no .votesAggregator key -- redeploy, do not upgrade"));
        exposed.load();

        // positive control: the SAME manifest with the key present loads cleanly, so the
        // revert above is the guard firing and not an unrelated parse failure
        _writeManifestFixture(path, "l02ManifestWithAggregator", placeholder, aggregator);
        Validate.M memory m = exposed.load();
        assertEq(m.votesAggregator, aggregator, "the aggregator address is read off the manifest");
        assertEq(m.sGrove, placeholder, "and the rest of the manifest parsed too");
        assertTrue(m.keepOpsAdmin, "the fixture's posture flag round-trips");

        vm.removeFile(path);
    }

    // ── 9. delegating AFTER a partial unbond (a surviving-mutant hole) ─────

    /// @notice Review finding 2. Nothing in the L-02 suite delegated AFTER starting an
    ///         unbond — every test delegated first — so a `_getVotingUnits` that counted
    ///         `staked + unbonding` survived the whole surface. It is a real bug: `_delegate`
    ///         moves `_getVotingUnits(account)` to the new delegate, so an inflated reading
    ///         subtracts more from the old delegate's checkpoint than was ever added to it
    ///         and the staker can never delegate again.
    ///
    ///         Voting units are the ACTIVE stake and nothing else, so only 60 moves.
    function test_l02_freshProxy_delegateAfterPartialUnbondMovesOnlyActiveStake() public {
        SGrove fresh = _deployFresh();
        _stakeFresh(fresh, freshStaker, LEGACY_ACTIVE);
        assertEq(fresh.getVotes(freshStaker), LEGACY_ACTIVE, "self-delegated 100 on the way in");

        vm.prank(freshStaker);
        fresh.requestUnstake(40e18);
        assertEq(fresh.getVotes(freshStaker), 60e18, "40 stopped voting the instant it was unbonded");

        // the previously-untested ordering: unbond FIRST, delegate SECOND
        vm.prank(freshStaker);
        fresh.delegate(delegatee);

        assertEq(fresh.getVotes(freshStaker), 0, "the delegator keeps nothing");
        assertEq(fresh.getVotes(delegatee), 60e18, "exactly the ACTIVE slice moved, not 100");
        assertEq(fresh.totalVotingUnits(), 60e18, "delegation never changes the total");
        assertEq(fresh.totalVotingUnits(), fresh.totalStaked(), "tripwire holds after a late delegation");

        // and the position still exits cleanly afterwards, burning from the NEW delegate
        vm.prank(freshStaker);
        fresh.requestUnstake(60e18);
        assertEq(fresh.getVotes(delegatee), 0, "the burn came out of the delegate's checkpoint");
        assertEq(fresh.totalVotingUnits(), 0, "total units back to zero");
        assertEq(fresh.totalStaked(), 0, "total stake back to zero");
    }

    // ── helpers ────────────────────────────────────────────────────────────

    /// @dev The deploy posture this file validates against: the testnet shape that actually
    ///      ships today (deployer == ops == treasury, admin retained), with an INDEPENDENT
    ///      attester2 so `attesterQuorumIndependent` is honestly true.
    function _l02Ctx() internal view returns (Ctx memory c) {
        c.deployer = address(this);
        c.opsAdmin = address(this);
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = address(this); // AUDIT FIX (D7-01 round 5): SETTLEMENT_KEEPER_ROLE holder; Deploy._wire fails closed on zero
        c.frTreasury = address(this);
        c.feeRecipient = address(this);
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true;
        c.attester2Derived = false;
    }

    /// @dev The real deploy sequence, run in-process with this test as the deployer EOA.
    function _deployStack(Ctx memory c) internal returns (D memory d) {
        d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
    }

    function _validateArgs(D memory d, Ctx memory c) internal pure returns (Validate.M memory a) {
        a.compliance = d.compliance;
        a.usdfr = d.usdfr;
        a.reserves = d.reserves;
        a.controller = d.controller;
        a.vault = d.vault;
        a.points = d.points;
        a.registry = d.registry;
        a.oracle = d.oracle;
        a.bridge = d.bridge;
        a.curator = d.curator;
        a.waterfall = d.waterfall;
        a.defaultManager = d.defaultManager;
        a.assessedImpairmentSource = d.assessedImpairmentSource;
        a.queue = d.queue;
        a.grove = d.grove;
        a.sGrove = d.sGrove;
        a.timelock = d.timelock;
        a.governor = d.governor;
        a.votesAggregator = d.votesAggregator;
        a.deployer = c.deployer;
        a.opsAdmin = c.opsAdmin;
        a.proposalGuardian = c.proposalGuardian;
        a.queueKeeper = c.opsAdmin; // AUDIT FIX (D7-01 round 5): SETTLEMENT_KEEPER_ROLE holder; Deploy._wire fails closed on zero
        a.attester2 = c.attester2;
        a.frTreasury = c.frTreasury;
        a.feeRecipient = c.feeRecipient;
        a.stable = d.stable;
        a.keepOpsAdmin = c.keepOpsAdmin;
        a.attesterQuorumIndependent = true;
    }

    /// @dev Move GROVE out of the deployed treasury (this contract) and stake it through the
    ///      REAL `stake` path, so the deployment carries genuine, vote-backed stake.
    function grove_transferAndStake(D memory d, address who, uint256 amount) internal {
        GroveToken(d.grove).transfer(who, amount);
        vm.startPrank(who);
        GroveToken(d.grove).approve(d.sGrove, amount);
        SGrove(d.sGrove).stake(amount);
        vm.stopPrank();
    }

    /// @dev Write `staked[staker] += amount` and `totalStaked += amount` DIRECTLY, leaving
    ///      the `openzeppelin.storage.Votes` namespace untouched: byte for byte the shape an
    ///      in-place upgrade of a pre-L-02 proxy leaves behind. Both slot offsets are proved
    ///      at the call site by reading the result back through `stakedOf`/`totalStaked`.
    function _pokeLegacyStake(address sGroveProxy, address staker, uint256 amount) internal {
        bytes32 totalSlot = bytes32(uint256(SGROVE_STORAGE_ROOT) + 2);
        bytes32 stakedSlot = keccak256(abi.encode(staker, uint256(SGROVE_STORAGE_ROOT) + 3));
        vm.store(sGroveProxy, totalSlot, bytes32(uint256(vm.load(sGroveProxy, totalSlot)) + amount));
        vm.store(sGroveProxy, stakedSlot, bytes32(uint256(vm.load(sGroveProxy, stakedSlot)) + amount));
    }

    /// @dev Build a `Delegation` signature against an EXPLICIT EIP-712 domain, so the test can
    ///      sign over the domain a correctly-initialized SGrove would use regardless of what
    ///      the target proxy actually has in storage.
    function _signDelegation(
        address verifyingContract,
        string memory name,
        string memory version,
        uint256 pk,
        address to,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifyingContract
            )
        );
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, to, nonce, expiry));
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }

    /// @dev Write a manifest fixture for `Validate._load`. `aggregator == address(0)` omits
    ///      the `.votesAggregator` key entirely — the pre-ADR-0026 shape.
    function _writeManifestFixture(string memory path, string memory objectKey, address placeholder, address aggregator)
        internal
    {
        vm.serializeAddress(objectKey, "compliance", placeholder);
        vm.serializeAddress(objectKey, "usdfr", placeholder);
        vm.serializeAddress(objectKey, "reserves", placeholder);
        vm.serializeAddress(objectKey, "controller", placeholder);
        vm.serializeAddress(objectKey, "vault", placeholder);
        vm.serializeAddress(objectKey, "points", placeholder);
        vm.serializeAddress(objectKey, "registry", placeholder);
        vm.serializeAddress(objectKey, "oracle", placeholder);
        vm.serializeAddress(objectKey, "bridge", placeholder);
        vm.serializeAddress(objectKey, "curator", placeholder);
        vm.serializeAddress(objectKey, "waterfall", placeholder);
        vm.serializeAddress(objectKey, "defaultManager", placeholder);
        vm.serializeAddress(objectKey, "assessedImpairmentSource", placeholder);
        vm.serializeAddress(objectKey, "queue", placeholder);
        vm.serializeAddress(objectKey, "grove", placeholder);
        vm.serializeAddress(objectKey, "sGrove", placeholder);
        vm.serializeAddress(objectKey, "timelock", placeholder);
        vm.serializeAddress(objectKey, "governor", placeholder);
        vm.serializeAddress(objectKey, "proposalGuardian", placeholder);
        if (aggregator != address(0)) vm.serializeAddress(objectKey, "votesAggregator", aggregator);
        vm.serializeAddress(objectKey, "deployer", placeholder);
        vm.serializeAddress(objectKey, "opsAdmin", placeholder);
        vm.serializeAddress(objectKey, "attester2", placeholder);
        vm.serializeAddress(objectKey, "frTreasury", placeholder);
        vm.serializeAddress(objectKey, "feeRecipient", placeholder);
        vm.serializeAddress(objectKey, "stable", placeholder);
        vm.writeFile(path, vm.serializeBool(objectKey, "TESTNET_keepOpsAdmin", true));
    }

    function _deployLegacy() internal returns (LegacySGrove legacy) {
        legacy = LegacySGrove(
            address(
                new ERC1967Proxy(
                    address(new LegacySGrove()),
                    abi.encodeCall(LegacySGrove.initialize, (admin, guardian, upgrader, address(grove), usdfr))
                )
            )
        );
    }

    function _deployFresh() internal returns (SGrove fresh) {
        fresh = SGrove(
            address(
                new ERC1967Proxy(
                    address(new SGrove()),
                    abi.encodeCall(SGrove.initialize, (admin, guardian, upgrader, address(grove), usdfr, address(this)))
                )
            )
        );
    }

    /// @dev The operationally-available-but-forbidden path: same proxy, new implementation.
    function _upgradeInPlace(LegacySGrove legacy) internal returns (SGrove upgraded) {
        address newImpl = address(new SGrove());
        // gated on UPGRADER_ROLE — the timelock holds it in production, so this IS reachable
        vm.prank(legacyStaker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlErrors.AccessControlUnauthorizedAccount.selector, legacyStaker, Roles.UPGRADER_ROLE
            )
        );
        legacy.upgradeToAndCall(newImpl, "");

        vm.prank(upgrader);
        legacy.upgradeToAndCall(newImpl, "");
        upgraded = SGrove(address(legacy));
    }

    function _stakeLegacy(LegacySGrove legacy, address who, uint256 amount) internal {
        vm.prank(treasury);
        grove.transfer(who, amount);
        vm.startPrank(who);
        grove.approve(address(legacy), amount);
        legacy.stake(amount);
        vm.stopPrank();
    }

    function _stakeFresh(SGrove sg, address who, uint256 amount) internal {
        vm.prank(treasury);
        grove.transfer(who, amount);
        vm.startPrank(who);
        grove.approve(address(sg), amount);
        sg.stake(amount);
        vm.stopPrank();
    }
}

/// @dev Local alias so the AccessControl revert selector can be referenced without pulling
///      the whole interface into the test's inheritance.
interface IAccessControlErrors {
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
}

/// @dev Exposes `Validate._load` so the ADR-0026 manifest guard — the FIRST thing that runs
///      when an operator points the validator at a pre-L-02 deployment — can be executed
///      from a test. `_load` is `internal view`; nothing else is changed.
contract ValidateExposed is Validate {
    function load() external view returns (M memory) {
        return _load();
    }
}

/// @title LegacySGrove — a faithful stand-in for the PRE-L-02 SGrove
/// @notice Same ERC-7201 storage location and the SAME `SGroveStorage` field order as
///         `src/SGrove.sol`, including the `Unbond` ARRAY element struct — but no
///         `VotesUpgradeable` inheritance and no voting-unit bookkeeping in `stake`.
///         That is precisely the pre-ADR-0026 shape. It is deliberately faithful rather
///         than convenient: if the layouts diverged, the upgrade test would be measuring a
///         mis-modelled stand-in instead of the real hazard, which is why
///         `test_l02_inPlaceUpgradeOfAStakedLegacyProxyBricksUnstake` reads every field
///         back through the NEW implementation before exercising the failure.
contract LegacySGrove is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

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
        uint256 totalStaked;
        mapping(address staker => uint256) staked;
        mapping(address staker => Unbond[]) unbonds;
        uint256 coverageReserve;
        uint256 rewardIndexWad;
        mapping(address staker => uint256) userIndexWad;
        mapping(address staker => uint256) accruedRewards;
        uint256 rewardRate;
        uint64 periodFinish;
        uint64 lastUpdateTime;
        uint64 rewardsDuration;
        mapping(uint256 eventId => uint256) eventCovered;
        mapping(uint256 eventId => uint256) eventCapSnapshot;
    }

    // identical to SGrove's — that is the whole point
    bytes32 private constant SGROVE_STORAGE_LOCATION =
        0x8947529af82e5c31b771fc0b2221fa39dd660e5ffcb6bd0eae7a66d91fc54b00;

    error SGrove_ZeroAddress();
    error SGrove_ZeroAmount();
    error SGrove_InsufficientStake(uint256 requested, uint256 staked);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The pre-L-02 initializer: no `__EIP712_init`, no `__Votes_init`.
    function initialize(address admin, address guardian, address upgrader, address grove, address usdfr)
        external
        initializer
    {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || grove == address(0)
                || usdfr == address(0)
        ) revert SGrove_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        SGroveStorage storage $ = _storage();
        $.grove = IERC20(grove);
        $.usdfr = IERC20(usdfr);
        $.unbondingPeriod = uint64(Config.SGROVE_UNBONDING_PERIOD);
        $.perEventCapBps = 5_000; // historical pre-ADR-0035 value; now a retained tombstone
        $.rewardsDuration = Config.SGROVE_REWARDS_DURATION;
    }

    /// @notice Pre-L-02 `stake`: balances only, no voting units, no self-delegation.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert SGrove_ZeroAmount();
        SGroveStorage storage $ = _storage();
        $.staked[msg.sender] += amount;
        $.totalStaked += amount;
        $.grove.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Pre-L-02 `requestUnstake`: pushes a real `Unbond` element so the ARRAY
    ///         layout is populated by the legacy code and read back by the new one.
    function legacyRequestUnstake(uint256 amount) external nonReentrant returns (uint64 releaseAt) {
        SGroveStorage storage $ = _storage();
        uint256 current = $.staked[msg.sender];
        if (amount > current) revert SGrove_InsufficientStake(amount, current);
        $.staked[msg.sender] = current - amount;
        $.totalStaked -= amount;
        releaseAt = uint64(block.timestamp) + $.unbondingPeriod;
        $.unbonds[msg.sender].push(Unbond({amount: uint192(amount), releaseAt: releaseAt}));
    }

    /// @notice Test-only writer that stamps every remaining `SGroveStorage` field with a
    ///         distinct sentinel, so the post-upgrade read-back proves TOTAL layout
    ///         equivalence rather than just the two fields the failure happens to touch.
    function legacySeed(
        uint256 coverageReserve_,
        uint256 rewardIndexWad_,
        address staker,
        uint256 userIndexWad_,
        uint256 accruedRewards_,
        uint256 rewardRate_,
        uint64 periodFinish_,
        uint64 lastUpdateTime_,
        uint256 eventId,
        uint256 eventCovered_,
        uint256 eventCapSnapshot_
    ) external {
        SGroveStorage storage $ = _storage();
        $.coverageReserve = coverageReserve_;
        $.rewardIndexWad = rewardIndexWad_;
        $.userIndexWad[staker] = userIndexWad_;
        $.accruedRewards[staker] = accruedRewards_;
        $.rewardRate = rewardRate_;
        $.periodFinish = periodFinish_;
        $.lastUpdateTime = lastUpdateTime_;
        $.eventCovered[eventId] = eventCovered_;
        $.eventCapSnapshot[eventId] = eventCapSnapshot_;
    }

    function stakedOf(address staker) external view returns (uint256) {
        return _storage().staked[staker];
    }

    function totalStaked() external view returns (uint256) {
        return _storage().totalStaked;
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (SGroveStorage storage $) {
        assembly {
            $.slot := SGROVE_STORAGE_LOCATION
        }
    }
}
