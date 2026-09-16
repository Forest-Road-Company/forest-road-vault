// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_CollateralRegistryFork — adversarial assault on CollateralRegistry, the on-chain
///        diversification guarantee (CLAUDE.md 1.3 concentration invariant).
///
/// @notice AUTHORISED assessment of the owner's own pre-audit code. Local only; nothing is
///         broadcast and no real value moves. Every test ATTEMPTS a concrete exploit and makes the
///         outcome unambiguous: where the registry blocks the attack it asserts the EXACT custom
///         error; where an attack would succeed it asserts the violated state.
///
///         THE INVARIANT UNDER FIRE: per-borrower / per-state / per-class concentration limits are
///         "never exceeded by an origination, INCLUDING BY SPLITTING OR ORDERING".
///
///         PERMISSIONLESS ENTRY POINT attacked hardest: `syncConcentrationBreaches` — the only
///         state-mutating function any roleless actor can reach. It writes the event edge-detection
///         caches (`overLimitBits`, `borrowerOverLimit`, `stateOverLimit`). The attack proves it
///         can neither revert nor move the admission decision nor corrupt the (recomputed)
///         disclosure views: if a hostile sync could flip a cached bit that a later admission or a
///         breach view trusted, this file would catch it.
///
///         WHY A FRESH REGISTRY FOR THE ENFORCEMENT TESTS. The REAL Deploy topology seeds every
///         class/borrower/state limit to `Config.RAMP_CONCENTRATION_LIMIT_BPS` (100% = unbounded:
///         nothing binds), so the fork registry cannot exercise a binding limit at all. The
///         enforcement attacks therefore run against a fresh proxy configured with the LAUNCH-realistic
///         limits the fixtures use (class 35%, borrower 15%, state 25%, 25M bootstrap floor) with
///         this contract holding DEFAULT_ADMIN + CREDIT_ROLE — i.e. a maximally-privileged credit
///         module trying to sneak exposure past the caps by splitting and reordering, which is
///         exactly the threat the invariant names. The real fork registry is still attacked for the
///         permissionless-sync / access-control non-corruption properties (`onFork`).
contract ATK_CollateralRegistryForkTest is ForkLifecycleFixture {
    uint256 internal constant C1 = Config.CLASS_FILM_TAX_CREDITS; // 1 — target class, 35% limit
    uint256 internal constant C2 = Config.CLASS_RENEWABLE_ENERGY; // 2 — filler class, 100% limit

    // Launch-realistic absolute caps at the 25M bootstrap floor (limitBps * floor / BPS):
    uint256 internal constant FLOOR = 25_000_000e18;
    uint256 internal constant BORROWER_CAP = 3_750_000e18; // 1500bps of 25M
    uint256 internal constant CLASS_CAP = 8_750_000e18; // 3500bps of 25M
    uint256 internal constant STATE_CAP = 6_250_000e18; // 2500bps of 25M

    CollateralRegistry internal atk; // fresh registry with realistic, BINDING limits (I control it)
    address internal attacker = makeAddr("atkRegistryAttacker"); // no roles anywhere

    function setUp() public override {
        super.setUp(); // full fork deploy when MAINNET_RPC_URL is set; a clean no-op otherwise

        // A fresh registry with this contract as admin + credit module, so the origination path
        // (recordExposureIncrease/Decrease) is directly drivable against BINDING limits.
        atk = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(new CollateralRegistry()),
                    abi.encodeCall(CollateralRegistry.initialize, (address(this), address(this)))
                )
            )
        );
        atk.grantRole(Roles.CREDIT_ROLE, address(this));
        atk.setClass(C1, _recv("Film & TV Tax Credits", 3500));
        atk.setClass(C2, _recv("Renewable Energy", 10_000)); // 100% — a non-binding filler dimension

        // Pin the assumptions the concrete arithmetic below depends on. If a default ever drifts,
        // fail LOUDLY here rather than let a mis-scaled cap silently weaken every assertion.
        (uint16 bl, uint16 sl, uint256 fl) = atk.limits();
        require(bl == 1500 && sl == 2500 && fl == FLOOR, "ATK: unexpected registry defaults");
    }

    function _recv(string memory name, uint16 conc) internal pure returns (ICollateralRegistry.ClassParams memory) {
        return ICollateralRegistry.ClassParams({
            name: name,
            model: ICollateralRegistry.CollateralModel.Receivable,
            active: true,
            maxLtvBps: 8000,
            maxMaturity: 730 days,
            concentrationLimitBps: conc,
            marginCallLtvBps: 0,
            liquidationLtvBps: 0,
            maxMarkAge: 0
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. SPLIT — chop one over-limit borrower origination into many tiny ones.
    //    If the check only looked at each increment in isolation this would slip
    //    past; because every increase re-checks the whole post-trade position,
    //    the final wei reverts at exactly the cap.
    // ─────────────────────────────────────────────────────────────────────
    function test_borrowerLimit_cannotBeExceededBySplitting() public {
        bytes32 bA = keccak256("split_borrower");
        bytes32 sA = keccak256("split_state");

        // Five 750k slices land exactly on the 3.75M borrower cap — each individually admitted.
        for (uint256 i = 0; i < 5; ++i) {
            atk.recordExposureIncrease(C1, bA, sA, 750_000e18);
        }
        assertEq(atk.borrowerExposure(bA), BORROWER_CAP, "split reached exactly the cap");

        // The next wei — however tiny — is refused. Splitting bought nothing: this is the same
        // wouldBe a single 3.75M+1 origination would have produced.
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, bA, BORROWER_CAP + 1, uint256(1500)
            )
        );
        atk.recordExposureIncrease(C1, bA, sA, 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. SPREAD ACROSS BORROWERS+STATES — try to inflate the CLASS past its cap
    //    while keeping every borrower and every state individually clean. The
    //    class dimension aggregates all of it, so it binds regardless.
    // ─────────────────────────────────────────────────────────────────────
    function test_classLimit_cannotBeExceededBySpreadingAcrossBorrowersAndStates() public {
        // Five 1.75M facilities, each a DISTINCT borrower and DISTINCT state (so neither the 3.75M
        // borrower cap nor the 6.25M state cap ever binds), summing to the 8.75M class cap.
        for (uint256 i = 0; i < 5; ++i) {
            atk.recordExposureIncrease(C1, bytes32(uint256(0x1000 + i)), bytes32(uint256(0x2000 + i)), 1_750_000e18);
        }
        assertEq(atk.classExposure(C1), CLASS_CAP, "spread reached exactly the class cap");

        // A sixth fresh borrower/state adding a single wei tips the CLASS over — the class error
        // fires first (it is checked before borrower/state), proving the aggregate cap is intact.
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector, C1, CLASS_CAP + 1, uint256(3500)
            )
        );
        atk.recordExposureIncrease(C1, bytes32(uint256(0x1005)), bytes32(uint256(0x2005)), 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. SPREAD ACROSS BORROWERS in ONE STATE — try to inflate the STATE past its
    //    cap while every borrower stays clean. The state dimension binds.
    // ─────────────────────────────────────────────────────────────────────
    function test_stateLimit_cannotBeExceededBySpreadingAcrossBorrowers() public {
        bytes32 sX = keccak256("shared_state");
        // Five 1.25M facilities, distinct borrowers, SAME state, same class. State reaches 6.25M;
        // class reaches 6.25M (< 8.75M) and each borrower is 1.25M (< 3.75M), so only state binds.
        for (uint256 i = 0; i < 5; ++i) {
            atk.recordExposureIncrease(C1, bytes32(uint256(0x3000 + i)), sX, 1_250_000e18);
        }
        assertEq(atk.stateExposure(sX), STATE_CAP, "spread reached exactly the state cap");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_StateConcentrationExceeded.selector, sX, STATE_CAP + 1, uint256(2500)
            )
        );
        atk.recordExposureIncrease(C1, bytes32(uint256(0x3005)), sX, 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. PERMISSIONLESS syncConcentrationBreaches — a roleless attacker cannot use
    //    it to revert, to freeze admission, or to corrupt the recomputed views.
    // ─────────────────────────────────────────────────────────────────────
    function test_syncConcentrationBreaches_permissionless_cannotCorruptOrRevert() public {
        bytes32 bA = keccak256("sync_borrower");
        bytes32 sA = keccak256("sync_state");
        atk.recordExposureIncrease(C1, bA, sA, BORROWER_CAP); // book == class == borrower == state == 3.75M

        // On this young book (total 3.75M) the DISCLOSURE views read over-limit on all three
        // dimensions (raw share of the real book, floor-independent) — the ground truth the
        // attacker will try, and fail, to move.
        uint256 bitsBefore = atk.overConcentratedClasses();
        assertEq(bitsBefore, 1, "class 1 sits above its raw share limit");
        (bool c0, bool b0, bool s0) = atk.isOverConcentrated(C1, bA, sA);
        assertTrue(c0 && b0 && s0, "all three dimensions read over-limit pre-attack");

        // Hostile sync #1: duplicates, a zero id, an unrelated id.
        bytes32[] memory bIds = new bytes32[](4);
        bIds[0] = bA;
        bIds[1] = bA;
        bIds[2] = bytes32(0);
        bIds[3] = keccak256("unrelated");
        bytes32[] memory sIds = new bytes32[](2);
        sIds[0] = sA;
        sIds[1] = bytes32(0);
        vm.prank(attacker);
        atk.syncConcentrationBreaches(bIds, sIds); // must not revert

        // Hostile sync #2: a large array — still just burns the attacker's own gas.
        bytes32[] memory big = new bytes32[](64);
        for (uint256 i = 0; i < 64; ++i) {
            big[i] = bA;
        }
        bytes32[] memory none = new bytes32[](0);
        vm.prank(attacker);
        atk.syncConcentrationBreaches(big, none); // must not revert

        // Disclosure views are RECOMPUTED, so the caches the attacker touched change nothing.
        assertEq(atk.overConcentratedClasses(), bitsBefore, "sync cannot alter the class breach bitmap");
        (bool c1, bool b1, bool s1) = atk.isOverConcentrated(C1, bA, sA);
        assertTrue(c1 == c0 && b1 == b0 && s1 == s0, "sync cannot alter isOverConcentrated");

        // Admission is untouched: the blocked origination is STILL blocked with the same error...
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, bA, BORROWER_CAP + 1, uint256(1500)
            )
        );
        atk.recordExposureIncrease(C1, bA, sA, 1);

        // ...and an admissible fresh-borrower origination STILL succeeds (sync did not freeze the book).
        atk.recordExposureIncrease(C1, keccak256("sync_fresh_b"), keccak256("sync_fresh_s"), 1);
        assertEq(atk.borrowerExposure(keccak256("sync_fresh_b")), 1, "fresh admission unaffected by sync");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. ACCESS CONTROL — the exposure mutators are the only way a limit could be
    //    grown; a roleless attacker is refused before any accounting runs.
    // ─────────────────────────────────────────────────────────────────────
    function test_exposureMutators_rejectRolelessAttacker() public {
        bytes32 b = keccak256("ac_borrower");
        bytes32 s = keccak256("ac_state");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        atk.recordExposureIncrease(C1, b, s, 1e18);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        atk.recordExposureDecrease(C1, b, s, 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. STANDING BREACH — a shrinking book (repayment/loss on a DIFFERENT dimension)
    //    lifts an untouched borrower's SHARE over its limit. The registry must (a) never
    //    block the decrease, (b) still admit a ZERO-principal no-op, yet (c) refuse to
    //    DEEPEN the breach by even one wei. Relative regime (floor set to 1).
    // ─────────────────────────────────────────────────────────────────────
    function test_standingBreach_permitsZeroButBlocksDeepen() public {
        atk.setConcentrationFloor(1); // strictly relative limits — no bootstrap floor
        bytes32 bA = keccak256("sb_borrower");
        bytes32 bFill = keccak256("sb_filler");
        atk.setBorrowerLimitOverride(bFill, 10_000); // filler borrower is unbounded

        // Seed: filler 8.5k in class 2 (state untagged), target 1.5k in class 1 => book 10k, and
        // borrowerA is at EXACTLY its 15% cap (1.5k / 10k).
        atk.recordExposureIncrease(C2, bFill, bytes32(0), 8_500e18);
        atk.recordExposureIncrease(C1, bA, bytes32(0), 1_500e18);
        (, bool bOverBefore,) = atk.isOverConcentrated(C1, bA, bytes32(0));
        assertFalse(bOverBefore, "borrower exactly at the limit is not yet over");

        // The book shrinks (a repayment/writedown on the filler). This must NEVER revert — a
        // concentration check able to block a decrease would let a risk limit veto a loss.
        atk.recordExposureDecrease(C2, bFill, bytes32(0), 5_000e18); // book 10k -> 5k
        (, bool bOverAfter,) = atk.isOverConcentrated(C1, bA, bytes32(0));
        assertTrue(bOverAfter, "book shrink lifted borrowerA's share to 30% > 15%: standing breach");

        // A zero-principal origination is a pure no-op and must still be admitted despite the breach.
        atk.recordExposureIncrease(C1, bA, bytes32(0), 0);
        assertEq(atk.borrowerExposure(bA), 1_500e18, "zero principal moved nothing");

        // But a single wei that would DEEPEN the standing breach is refused with the exact error.
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, bA, 1_500e18 + 1, uint256(1500)
            )
        );
        atk.recordExposureIncrease(C1, bA, bytes32(0), 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. HEADROOM EXACTNESS (fuzzed over book size, spanning below & above the floor).
    //    The "max admissible" the UI would offer must never lie: exactly-H is admitted
    //    and H+1 is refused, on both the view and the write path. If headroom over-reported
    //    by even one wei an origination could exceed a limit; the final invariant assert
    //    pins the recorded state under limitBps * max(book, floor).
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_headroomIsExactAndInvariantHolds(uint256 fillerRaw) public {
        uint256 filler = bound(fillerRaw, 1e18, 5_000_000_000e18); // spans the 25M bootstrap floor
        bytes32 bFill = keccak256("hr_filler");
        atk.setBorrowerLimitOverride(bFill, 10_000); // isolate the target: filler dimension unbounded
        atk.recordExposureIncrease(C2, bFill, bytes32(0), filler);

        bytes32 bT = keccak256("hr_target_borrower");
        bytes32 sT = keccak256("hr_target_state");
        uint256 h = atk.concentrationHeadroom(C1, bT, sT);
        assertGt(h, 0, "a nonempty book always leaves some headroom");

        // View: exactly-H is admissible (a revert here fails the test); H+1 is not.
        atk.checkConcentration(C1, bT, sT, h);
        vm.expectRevert();
        atk.checkConcentration(C1, bT, sT, h + 1);

        // Write: recording exactly-H succeeds; the very next wei reverts.
        atk.recordExposureIncrease(C1, bT, sT, h);
        vm.expectRevert();
        atk.recordExposureIncrease(C1, bT, sT, 1);

        // INVARIANT (CLAUDE.md 1.3): at the maximum admitted exposure, no dimension exceeds its
        // limitBps share of max(book, floor) — asserted exactly as `_breaches` computes it
        // (exp * BPS <= limitBps * base).
        uint256 total = atk.totalBookExposure();
        uint256 base = total > FLOOR ? total : FLOOR;
        assertLe(atk.classExposure(C1) * Config.BPS, uint256(3500) * base, "class within limit at max fill");
        assertLe(atk.borrowerExposure(bT) * Config.BPS, uint256(1500) * base, "borrower within limit at max fill");
        assertLe(atk.stateExposure(sT) * Config.BPS, uint256(2500) * base, "state within limit at max fill");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. REAL TOPOLOGY (onFork) — against the actual Deploy'd registry (100% ramp limits),
    //    a roleless, non-KYC attacker cannot corrupt the permissionless sync nor record exposure.
    //    Exposure created here comes only through the genuine CREDIT path (ClaimBridge.originate).
    // ─────────────────────────────────────────────────────────────────────
    function test_fork_permissionlessSyncCannotCorruptRealTopology() public onFork {
        _mintFromUSDC(alice, 5_000_000e6); // fills idle reserves so the facility can be funded
        uint256 id = _originateAndFund(1_000_000e18);
        assertGt(id, 0, "facility originated");

        bytes32 bID = keccak256("FORK_BORROWER"); // the ids _originateAndFund uses
        bytes32 sID = keccak256("US-GA");
        assertEq(registry.borrowerExposure(bID), 1_000_000e18, "real credit path recorded exposure");

        uint256 bitsBefore = registry.overConcentratedClasses();
        (bool c0, bool b0, bool s0) = registry.isOverConcentrated(C1, bID, sID);

        // Hostile sync from carol — not KYC'd, holds no role.
        bytes32[] memory bs = new bytes32[](3);
        bs[0] = bID;
        bs[1] = bID;
        bs[2] = bytes32(0);
        bytes32[] memory ss = new bytes32[](2);
        ss[0] = sID;
        ss[1] = bytes32(0);
        vm.prank(carol);
        registry.syncConcentrationBreaches(bs, ss); // must not revert

        assertEq(registry.overConcentratedClasses(), bitsBefore, "sync cannot move the real bitmap");
        (bool c1, bool b1, bool s1) = registry.isOverConcentrated(C1, bID, sID);
        assertTrue(c1 == c0 && b1 == b0 && s1 == s0, "sync cannot move real isOverConcentrated");

        // And carol cannot record exposure directly — the only path to grow a limit is role-gated.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        registry.recordExposureIncrease(C1, bID, sID, 1);
    }
}
