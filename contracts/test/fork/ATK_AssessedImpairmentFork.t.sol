// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Vm} from "forge-std/Vm.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ConservativeImpairmentMath} from "../../src/ConservativeImpairmentMath.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_AssessedImpairmentFork, adversarial attacks on the ADR-0027 assessed impairment
///        wrapper against the FULL protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice `AssessedImpairmentSource` is the `IImpairmentSource` that `Deploy._wire` installs on
///         sUSDfr (`setImpairmentSource`, Deploy.s.sol:853). It is the ONLY hop between the vault's
///         redemption price and `DefaultManager.pendingSeniorImpairment()`: on this fixture that base
///         routes to `DefaultAccrualLib.nativeSeniorImpairment` because the accrual reserve is bound,
///         and on the deployed `edf525c` path (accrual disabled, second contract below) it routes to
///         `ConservativeImpairmentMath`. Nothing else in `contracts/src` reads the wrapper:
///         `WaterfallEngine._withholdFeeForSeniorImpairment` reads the manager directly,
///         `CollateralRegistry.conservativeSeniorMark` and `ConservativeImpairmentMath` are callees
///         of the base, not consumers of the wrapper. So a published assessment can move exactly one
///         thing: what a senior holder is paid on exit (and the performance-fee NAV that ADR-0031
///         derives from the same wrapper). This file executes that claim rather than reading it.
///
///         Invariants under attack (CLAUDE.md 1.3):
///           I1. sUSDfr exchange-rate integrity: only governance may lower the mark, only to a value
///               at or below the conservative base, and a lowered mark must never outlive the risk
///               state it was published against.
///           I2. Redemption queue: a filled request is paid exactly the quote in force at settlement.
///           I3. Access control: no setter, the initializer or the upgrade path is reachable by an
///               unprivileged caller in any state.
///
///         Attacks (each ends in an unambiguous assertion; a blocked attack asserts the exact custom
///         error and the untouched state, a successful one would assert the violated money):
///           A1. THE OUTSIDER. carol (no KYC, no role) tries every setter, `grantRole`, the proxy
///               initializer, the implementation initializer and `upgradeToAndCall`. The timelock, which
///               this fixture never hands over to, is refused too; after the production grant the
///               timelock publishes and then upgrades the wrapper with the assessment surviving.
///           A2. THE BOUNDS. As the timelock, across a book with no facility, a Pending facility, an
///               Active one, a Defaulted one and a Resolved one: zero evidence, non-future expiry, an
///               expiry one second past the TTL, one wei above the base, exactly the base, zero, a
///               flip high to low to high, a clear, and every `setBaseSource` refusal.
///           A3. THE EFFECT. With a 350,000e18 base standing, a 100,000e18 assessment moves the senior
///               exit base by exactly 250,000e18 and nothing else: the manager's mark, the calculator,
///               the registry's ramped mark, the realized NAV, the class exposure and both junior
///               layers are unchanged. alice queues at the assessed price and is paid it to the wei
///               through the real queue after the cooldown; the assessment then expires on time.
///           A4. STALENESS. A realized loss and a clean resolution both invalidate the standing
///               assessment; a NEW default declared while the old assessment (still inside its TTL)
///               sits in storage does not inherit it; a permissionless backstop top-up leaves a fresh
///               assessment standing (FRV-FS-04) while the exact hash differs.
///           A5. THE CLOCK. Declared-only assessments expire at their stated deadline.
///               Accruing overdue cohorts add their full income growth to both assessed marks,
///               preserving validity. Changes to curator capital still invalidate the memorandum.
///           A6. THE DEPLOYED PATH. The same scene on an accrual-disabled deployment (the `edf525c`
///               shape): the base is the calculator's, the assessment reprices the exit identically,
///               and the clock does NOT kill an assessment during a past-due workout.
abstract contract ATK_AssessedImpairmentForkBase is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // 1
    uint256 internal constant SHARE_OFFSET = 1e6; // sUSDfr `_decimalsOffset()` == 6
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EVIDENCE = keccak256("atk-assessed-recovery-memorandum");

    /// @dev Declared locally so `vm.expectEmit` binds by signature; identical to the emitters'.
    event AssessmentSet(
        uint256 assessedSeniorImpairment,
        uint256 zeroRecoverySeniorImpairment,
        uint64 validUntil,
        bytes32 indexed evidenceHash,
        bytes32 indexed stateHash
    );
    event AssessmentCleared();
    event BaseSourceSet(address indexed oldSource, address indexed newSource);
    event AssessmentPerformanceFeeImpairmentSet(uint256 performanceFeeImpairment);
    event RequestFilled(uint256 indexed requestId, uint256 shares, uint256 assets, uint256 epoch);

    /// @dev The declared scene, kept in memory so the tests stay under the stack limit.
    struct Scene {
        uint256 id;
        uint256 sharesA;
        uint256 base; // the conservative mark standing after declaration
        uint64 until; // the expiry of the last publication
    }

    /// @dev Reads taken around a publication to prove what did and did not move.
    struct Reads {
        uint256 wrapperMark;
        uint256 wrapperPerformance;
        uint256 managerMark;
        uint256 managerPerformance;
        uint256 calculatorMark;
        uint256 registryMark;
        uint256 totalAssets;
        uint256 redemptionAssets;
        uint256 exchangeRate;
        uint256 feeRate;
        uint256 classExposure;
        uint256 curatorPool;
        uint256 reserve;
        uint256 quoteA;
    }

    /// @dev The wrapper's public assessment tuple, as a struct.
    struct Current {
        uint256 amount;
        uint64 until;
        bytes32 evidence;
        bool active;
        uint256 zeroRecovery;
    }

    function _assessed() internal view returns (AssessedImpairmentSource) {
        return AssessedImpairmentSource(dep.assessedImpairmentSource);
    }

    /// @dev Production hands DEFAULT_ADMIN on the wrapper to the timelock in `Deploy._handoverOne`
    ///      (PrivilegeTopology.deployHandoverTargets index 12). This fixture stops after `_seed`, so
    ///      the bootstrap deployer (`ops`) still holds it and the timelock does not. Reproduce the
    ///      production grant so every privileged act below runs as the timelock.
    function _grantTimelockAdmin() internal {
        AssessedImpairmentSource a = _assessed();
        assertTrue(a.hasRole(a.DEFAULT_ADMIN_ROLE(), ops), "fixture: the bootstrap deployer holds admin");
        assertFalse(a.hasRole(a.DEFAULT_ADMIN_ROLE(), timelock), "fixture: no handover ran, timelock lacks admin");
        assertTrue(a.hasRole(Roles.UPGRADER_ROLE, timelock), "init granted UPGRADER to the timelock");
        vm.prank(ops);
        a.grantRole(a.DEFAULT_ADMIN_ROLE(), timelock);
    }

    function _publish(uint256 amount, uint64 ttl) internal returns (uint64 until) {
        until = uint64(block.timestamp) + ttl;
        vm.prank(timelock);
        _assessed().setAssessment(amount, until, EVIDENCE);
    }

    /// @dev alice stakes 3,000,000e18; the anchor curator posts 150,000e18 of FILM first-loss and
    ///      500,000e18 of shared reserve; one 1,000,000e18 FILM facility is originated, funded and
    ///      declared at once. The conservative base is then 1,000,000 - 150,000 - 500,000 = 350,000e18.
    function _declaredScene() internal returns (Scene memory s) {
        _mintFromUSDC(alice, 5_000_000e6);
        s.sharesA = _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18);
        s.id = _originateAndFund(1_000_000e18);
        _declareDefault(s.id, keccak256("atk-assessed-declared"));
        s.base = defaultManager.pendingSeniorImpairment();
        assertEq(s.base, 350_000e18, "precondition: declared face less both junior layers");
    }

    function _reads(uint256 sharesA) internal view returns (Reads memory r) {
        AssessedImpairmentSource a = _assessed();
        r.wrapperMark = a.pendingSeniorImpairment();
        r.wrapperPerformance = a.performanceFeeImpairment();
        r.managerMark = defaultManager.pendingSeniorImpairment();
        r.managerPerformance = defaultManager.performanceFeeImpairment();
        r.calculatorMark = defaultManager.impairmentMath().pendingSeniorImpairment(address(defaultManager));
        r.registryMark =
            registry.conservativeSeniorMark(0, r.managerMark, address(vault), defaultManager.pastDueReliefAnchor());
        r.totalAssets = vault.totalAssets();
        r.redemptionAssets = vault.redemptionTotalAssets();
        r.exchangeRate = vault.currentExchangeRate();
        r.feeRate = vault.feeExchangeRate();
        r.classExposure = registry.classExposure(FILM);
        r.curatorPool = curator.poolBalance(FILM);
        r.reserve = sGrove.coverageReserve();
        r.quoteA = vault.previewRedeem(sharesA);
    }

    function _current() internal view returns (Current memory c) {
        (c.amount, c.until, c.evidence, c.active, c.zeroRecovery) = _assessed().currentAssessment();
    }

    function _active() internal view returns (bool) {
        return _current().active;
    }

    /// @dev The floor of the exact conservative value at `mark`, on the live supply and assets.
    function _quoteAt(uint256 shares, uint256 mark) internal view returns (uint256) {
        return Math.mulDiv(shares, vault.totalAssets() - mark + 1, vault.totalSupply() + SHARE_OFFSET);
    }

    /// @dev Originate (through the real m-of-n gate) WITHOUT funding: the facility stays Pending.
    function _originatePending(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(
            tokenId, keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref")
        );
        vm.prank(ops);
        uint256 id = bridge.originate(
            ops,
            _forkTerms(keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref"))
        );
        require(id == tokenId, "ATK_AIS: tokenId drift");
    }

    function _fundCoverage(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _postFirstLoss(uint256 classId, uint256 amount) internal {
        vm.startPrank(ops);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    /// @dev Permissionless accrual maintenance after a warp, driven by the attacker. A no-op on
    ///      the accrual-disabled deployment.
    function _freshen() internal {
        if (!reserves.accrualSnapshot().enabled) return;
        for (uint256 i = 0; i < 8; ++i) {
            vm.prank(carol);
            (, bool fresh) = reserves.checkpointAccrual(32);
            if (fresh) return;
        }
        revert("ATK_AIS: accrual book still stale after eight checkpoints");
    }

    /// @dev Warp to the earliest moment the current head can settle: past the heartbeat AND past
    ///      the head's ADR-0022 forced cooldown.
    function _warpToSettleable() internal {
        uint256 target = uint256(queue.epochEndsAt());
        uint256 h = queue.head();
        if (h < queue.totalRequests()) {
            uint256 eligibleAt = queue.eligibleToSettleAt(h);
            if (eligibleAt > target) target = eligibleAt;
        }
        if (block.timestamp < target) _warp(target - block.timestamp);
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    function _exceeds(uint256 assessed, uint256 base) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_ExceedsConservativeBase.selector, assessed, base);
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(dep.assessedImpairmentSource, IMPLEMENTATION_SLOT))));
    }
}

contract ATK_AssessedImpairmentForkTest is ATK_AssessedImpairmentForkBase {
    // ─────────────────────────────────────────────────────────────────────
    // A1 (I3): the outsider, the un-handed-over timelock, and the upgrade path
    // ─────────────────────────────────────────────────────────────────────

    /// @notice carol, holding no role and not KYC'd, is refused by every setter, by `grantRole`, by
    ///         both initializers and by `upgradeToAndCall`, each with its exact error; the wrapper's
    ///         mark and the exit quote are untouched. The timelock is refused on this fixture too,
    ///         because no handover ran; after the production grant it publishes, then upgrades the
    ///         proxy to a fresh implementation with the assessment and the exit quote surviving.
    /// @dev Attacks I3 and I1. Any one of these succeeding lets an outsider set the senior exit
    ///      price of a 3,000,000e18 vault to par while a 1,000,000e18 default stands.
    function test_atk_theOutsiderCannotPublishClearRewireInitializeOrUpgrade() public onFork {
        Scene memory s = _declaredScene();
        uint256 quoteAtBase = vault.previewRedeem(s.sharesA);
        _outsiderIsRefusedEverywhere(s);
        assertEq(_assessed().pendingSeniorImpairment(), s.base, "nothing moved the mark");
        assertEq(vault.previewRedeem(s.sharesA), quoteAtBase, "nor the exit quote");
        assertFalse(_active(), "no assessment stands");
        _timelockPublishesThenUpgrades(s);
    }

    function _outsiderIsRefusedEverywhere(Scene memory) internal {
        AssessedImpairmentSource a = _assessed();
        bytes32 admin = a.DEFAULT_ADMIN_ROLE();
        uint64 ttl = uint64(block.timestamp + 30 days);
        address freshImpl = address(new AssessedImpairmentSource());

        vm.startPrank(carol);
        vm.expectRevert(_unauthorized(carol, admin));
        a.setAssessment(0, ttl, EVIDENCE);
        vm.expectRevert(_unauthorized(carol, admin));
        a.clearAssessment();
        vm.expectRevert(_unauthorized(carol, admin)); // the role gate precedes the zero/revisioned checks
        a.setBaseSource(carol);
        vm.expectRevert(_unauthorized(carol, admin));
        a.grantRole(admin, carol);
        vm.expectRevert(_unauthorized(carol, Roles.UPGRADER_ROLE));
        a.upgradeToAndCall(freshImpl, "");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        a.initialize(carol, carol, address(defaultManager));
        vm.stopPrank();

        // The implementation behind the proxy disabled its own initializers in the constructor.
        address impl = _implementation();
        vm.prank(carol);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AssessedImpairmentSource(impl).initialize(carol, carol, address(defaultManager));

        // The timelock on THIS fixture: init granted it UPGRADER only; DEFAULT_ADMIN arrives with
        // `_handover`, which the lifecycle fixture never runs.
        vm.prank(timelock);
        vm.expectRevert(_unauthorized(timelock, admin));
        a.setAssessment(0, ttl, EVIDENCE);
    }

    /// @dev Production shape: the timelock publishes, then upgrades. `_authorizeUpgrade` re-validates
    ///      the live base's full revisioned interface (six staticcalls) before allowing the switch.
    function _timelockPublishesThenUpgrades(Scene memory s) internal {
        AssessedImpairmentSource a = _assessed();
        _grantTimelockAdmin();
        s.until = _publish(100_000e18, 30 days);
        assertTrue(_active(), "published");
        uint256 quoteAssessed = vault.previewRedeem(s.sharesA);
        assertEq(quoteAssessed, _quoteAt(s.sharesA, 100_000e18), "the assessed quote");
        // Same scene, same instant as the accrual-disabled contract below: the two paths must quote
        // the same exit to the wei (3,000,000e18 staked plus the 10e18 seed, nothing streamed yet).
        assertEq(vault.totalAssets(), 3_000_010e18, "bound path at t0: no streamed accrual in the NAV");
        emit log_named_uint("bound path: assessed exit quote (alice) at t0", quoteAssessed);
        (bytes32 snapBefore,,) = a.assessmentState();

        address fresh = address(new AssessedImpairmentSource());
        vm.prank(timelock);
        a.upgradeToAndCall(fresh, "");
        assertEq(_implementation(), fresh, "implementation switched");

        Current memory c = _current();
        assertEq(c.amount, 100_000e18, "assessment survived the upgrade (canonical ERC-7201 slot)");
        assertEq(c.until, s.until, "expiry survived");
        assertEq(c.evidence, EVIDENCE, "evidence survived");
        assertTrue(c.active, "still active");
        assertEq(c.zeroRecovery, s.base, "base unchanged by the upgrade");
        (bytes32 snapAfter, bytes32 live, bool matches) = a.assessmentState();
        assertEq(snapAfter, snapBefore, "snapshot hash survived");
        assertEq(live, snapBefore, "and still equals the live state");
        assertTrue(matches, "matches");
        assertEq(a.pendingSeniorImpairment(), 100_000e18, "the wrapper still returns the assessment");
        assertEq(vault.previewRedeem(s.sharesA), quoteAssessed, "the exit quote is unchanged by the upgrade");
        assertEq(a.baseSource(), address(defaultManager), "base wiring survived");

        // The upgraded proxy's initializer is still closed.
        vm.prank(carol);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        a.initialize(carol, carol, address(defaultManager));
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2 (I1): the publication bounds across the book's states
    // ─────────────────────────────────────────────────────────────────────

    /// @notice As the timelock: with no facility, a Pending facility and an Active facility the base
    ///         is zero, so zero is publishable and one wei is not; with a Defaulted facility standing
    ///         at a 350,000e18 base every bound is exercised (zero evidence, non-future expiry, one
    ///         second past the TTL, one wei above the base, exactly the base, zero, a flip 300k to
    ///         100k to 300k, a clear); every `setBaseSource` refusal; after the facility Resolves the
    ///         base is zero again and one wei is refused.
    /// @dev Attacks I1. The bounds are the whole difference between "governance may recognise
    ///      supportable recovery" and "governance may set any exit price": one missing check hands
    ///      the timelock an unbounded valuation power the ADR does not grant it.
    function test_atk_publicationBoundsAcrossEveryBookState() public onFork {
        _grantTimelockAdmin();
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 sharesA = _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18);

        _boundsOnAZeroBase("no facility");
        uint256 pendingId = _originatePending(500_000e18);
        assertEq(uint8(bridge.facility(pendingId).state), uint8(ClaimBridge.LoanState.Pending), "pending");
        _boundsOnAZeroBase("pending facility");
        uint256 id = _originateAndFund(1_000_000e18);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active), "active");
        _boundsOnAZeroBase("active facility");

        _declareDefault(id, keccak256("atk-assessed-bounds"));
        assertEq(defaultManager.pendingSeniorImpairment(), 350_000e18, "declared face less both junior layers");
        assertFalse(_active(), "the declaration invalidated the zero assessment (new default, new revision)");
        assertEq(_assessed().pendingSeniorImpairment(), 350_000e18, "so the wrapper is back on the base");
        _boundsOnTheDeclaredBase(sharesA);
        _flipAndClear();
        _baseSourceRefusals();

        _repay(id, 0, 1_000_000e18);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved), "resolved");
        _boundsOnAZeroBase("resolved facility");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "par");
    }

    /// @dev The base is zero: zero is publishable and active, one wei exceeds the base.
    function _boundsOnAZeroBase(string memory where) internal {
        AssessedImpairmentSource a = _assessed();
        assertEq(defaultManager.pendingSeniorImpairment(), 0, string.concat(where, ": no mark"));
        uint64 day = uint64(block.timestamp + 1 days);
        vm.startPrank(timelock);
        a.setAssessment(0, day, EVIDENCE);
        assertTrue(_active(), string.concat(where, ": zero on a zero base is active"));
        vm.expectRevert(_exceeds(1, 0));
        a.setAssessment(1, day, EVIDENCE);
        vm.stopPrank();
    }

    /// @dev Every refusal, then exactly the base at exactly the TTL, then zero (par exit).
    function _boundsOnTheDeclaredBase(uint256 sharesA) internal {
        AssessedImpairmentSource a = _assessed();
        uint256 base = 350_000e18;
        uint256 assets = vault.totalAssets();
        uint64 nowTs = uint64(block.timestamp);
        uint64 maxTtl = nowTs + a.MAX_ASSESSMENT_TTL();

        vm.startPrank(timelock);
        vm.expectRevert(AssessedImpairmentSource.Assessment_ZeroEvidenceHash.selector);
        a.setAssessment(100_000e18, maxTtl, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(AssessedImpairmentSource.Assessment_NotFuture.selector, nowTs));
        a.setAssessment(100_000e18, nowTs, EVIDENCE);
        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_TooLong.selector, maxTtl + 1, maxTtl)
        );
        a.setAssessment(100_000e18, maxTtl + 1, EVIDENCE);
        vm.expectRevert(_exceeds(base + 1, base));
        a.setAssessment(base + 1, maxTtl, EVIDENCE);
        assertFalse(_active(), "four refusals published nothing");

        a.setAssessment(base, maxTtl, EVIDENCE);
        assertTrue(_active(), "at the base is admitted");
        assertEq(a.pendingSeniorImpairment(), base, "min(base, base)");
        assertEq(vault.redemptionTotalAssets(), assets - base, "no change to the exit base");

        a.setAssessment(0, maxTtl, EVIDENCE);
        assertEq(a.pendingSeniorImpairment(), 0, "zero assessed");
        assertEq(vault.redemptionTotalAssets(), assets, "par exit while a 1,000,000e18 default stands");
        assertEq(vault.previewRedeem(sharesA), _quoteAt(sharesA, 0), "the par quote");
        assertEq(a.performanceFeeImpairment(), 650_000e18, "fee NAV keeps the 650,000e18 junior credit");
        vm.stopPrank();
    }

    /// @dev Flip high, low, high: each publication overwrites the last; raising within the base is
    ///      allowed. Then clear: the base returns and storage is zeroed.
    function _flipAndClear() internal {
        AssessedImpairmentSource a = _assessed();
        uint256 assets = vault.totalAssets();
        uint64 maxTtl = uint64(block.timestamp) + a.MAX_ASSESSMENT_TTL();
        vm.startPrank(timelock);
        a.setAssessment(300_000e18, maxTtl, EVIDENCE);
        assertEq(vault.redemptionTotalAssets(), assets - 300_000e18, "300k");
        a.setAssessment(100_000e18, maxTtl, EVIDENCE);
        assertEq(vault.redemptionTotalAssets(), assets - 100_000e18, "100k");
        a.setAssessment(300_000e18, maxTtl, EVIDENCE);
        assertEq(
            vault.redemptionTotalAssets(), assets - 300_000e18, "back to 300k: governance may raise within the base"
        );
        assertEq(a.performanceFeeImpairment(), 300_000e18 + 650_000e18, "fee base follows the assessment");
        vm.expectEmit(true, true, true, true, address(a));
        emit AssessmentCleared();
        a.clearAssessment();
        vm.stopPrank();
        Current memory c = _current();
        assertEq(c.amount, 0, "cleared amount");
        assertEq(c.until, 0, "cleared expiry");
        assertEq(c.evidence, bytes32(0), "cleared evidence");
        assertFalse(c.active, "inactive");
        assertEq(c.zeroRecovery, 350_000e18, "base reported");
        assertEq(a.pendingSeniorImpairment(), 350_000e18, "the base prices again");
        assertEq(a.performanceFeeImpairment(), defaultManager.performanceFeeImpairment(), "gross fee base again");
        (bytes32 snap,, bool matches) = a.assessmentState();
        assertEq(snap, bytes32(0), "snapshot cleared");
        assertFalse(matches, "a cleared snapshot never matches");
    }

    /// @dev The base source: zero, an EOA, a contract without the interface, and the same engine again
    ///      (which still clears the standing assessment).
    function _baseSourceRefusals() internal {
        AssessedImpairmentSource a = _assessed();
        uint64 maxTtl = uint64(block.timestamp) + a.MAX_ASSESSMENT_TTL();
        vm.startPrank(timelock);
        vm.expectRevert(AssessedImpairmentSource.Assessment_ZeroAddress.selector);
        a.setBaseSource(address(0));
        vm.expectRevert(abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, carol));
        a.setBaseSource(carol);
        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(vault))
        );
        a.setBaseSource(address(vault));
        a.setAssessment(200_000e18, maxTtl, EVIDENCE);
        assertTrue(_active(), "published before the rewire");
        vm.expectEmit(true, true, true, true, address(a));
        emit AssessmentCleared();
        vm.expectEmit(true, true, true, true, address(a));
        emit BaseSourceSet(address(defaultManager), address(defaultManager));
        a.setBaseSource(address(defaultManager));
        vm.stopPrank();
        assertFalse(_active(), "a base change clears the assessment, even to the same engine");
        assertEq(a.baseSource(), address(defaultManager), "wired");
        assertEq(a.pendingSeniorImpairment(), 350_000e18, "base prices");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3 (I1, I2): the effect, and an exit paid at the assessed quote
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With a 350,000e18 base standing, a 100,000e18 assessment raises the senior exit base
    ///         by exactly 250,000e18 and moves nothing else on chain: the manager's mark, the
    ///         calculator, the registry's ramped mark, the realized NAV and exchange rate, the class
    ///         exposure and both junior layers are identical before and after. alice queues at the
    ///         assessed price and is paid it to the wei after the 21-day cooldown; the assessment then
    ///         expires on its 30th day and the next quote is the base quote again.
    /// @dev Attacks I1 and I2. If the assessment leaked into the manager or registry it would change
    ///      the cascade or a fee withholding; if it did not reach the vault the lever would be dead; if
    ///      the queue paid other than the quote in force the difference is money moved between
    ///      cohorts.
    function test_atk_anAssessmentRepricesOnlyTheSeniorExitAndTheQueuePaysExactlyThatQuote() public onFork {
        Scene memory s = _declaredScene();
        _mintFromUSDC(bob, 2_000_000e6);
        uint256 sharesB = _stake(bob, 1_000_000e18);
        queue.setEpochLiquidityBps(10_000); // ops: the whole idle reserve may settle
        _grantTimelockAdmin();
        uint256 quoteAtBase = _publishAndAssertOnlyTheExitMoved(s);
        _aliceExitsAtTheAssessedQuote(s, quoteAtBase);
        _assessmentExpiresAndBobIsRequotedTheBase(s, sharesB);
    }

    function _publishAndAssertOnlyTheExitMoved(Scene memory s) internal returns (uint256 quoteAtBase) {
        AssessedImpairmentSource a = _assessed();
        Reads memory before = _reads(s.sharesA);
        assertEq(before.wrapperMark, s.base, "the wrapper passes the base through with no assessment");
        assertEq(before.managerPerformance, 1_000_000e18, "gross fee impairment is the declared face");
        assertEq(before.redemptionAssets, before.totalAssets - s.base, "exit base at the mark");
        quoteAtBase = before.quoteA;

        s.until = uint64(block.timestamp + 30 days);
        vm.expectEmit(true, true, true, true, address(a));
        emit AssessmentSet(100_000e18, s.base, s.until, EVIDENCE, defaultManager.impairmentStateHash());
        vm.expectEmit(true, true, true, true, address(a));
        emit AssessmentPerformanceFeeImpairmentSet(100_000e18 + (1_000_000e18 - 350_000e18));
        vm.prank(timelock);
        a.setAssessment(100_000e18, s.until, EVIDENCE);

        Reads memory after_ = _reads(s.sharesA);
        // What moved: the wrapper's two views and everything the vault derives from them.
        assertEq(after_.wrapperMark, 100_000e18, "the wrapper returns the assessment");
        assertEq(after_.wrapperPerformance, 750_000e18, "assessed senior plus the 650,000e18 junior credit");
        assertEq(after_.redemptionAssets, after_.totalAssets - 100_000e18, "exit base at the assessment");
        assertEq(after_.redemptionAssets - before.redemptionAssets, 250_000e18, "exactly the assessed recovery");
        assertEq(after_.quoteA, _quoteAt(s.sharesA, 100_000e18), "the assessed quote is the floor at 100k");
        assertGt(after_.quoteA, before.quoteA, "alice's exit quote rose");
        assertGt(after_.feeRate, before.feeRate, "the ADR-0031 performance NAV rose with the fee-neutral credit kept");
        // What did not move: everything upstream of the wrapper.
        assertEq(after_.managerMark, before.managerMark, "DefaultManager's mark is untouched");
        assertEq(after_.managerPerformance, before.managerPerformance, "DefaultManager's gross view is untouched");
        assertEq(after_.calculatorMark, before.calculatorMark, "ConservativeImpairmentMath is untouched");
        assertEq(after_.registryMark, before.registryMark, "CollateralRegistry.conservativeSeniorMark is untouched");
        assertEq(after_.totalAssets, before.totalAssets, "realized NAV is untouched");
        assertEq(after_.exchangeRate, before.exchangeRate, "the realized exchange rate is untouched");
        assertEq(after_.classExposure, before.classExposure, "registry exposure is untouched");
        assertEq(after_.curatorPool, before.curatorPool, "layer one is untouched");
        assertEq(after_.reserve, before.reserve, "layer two is untouched");
        assertEq(vault.maxWithdraw(address(queue)), 0, "the queue holds no shares yet");
        emit log_named_uint("exit quote at the base (alice, 3,000,000e18 staked)", before.quoteA);
        emit log_named_uint("exit quote at the 100,000e18 assessment", after_.quoteA);
    }

    function _aliceExitsAtTheAssessedQuote(Scene memory s, uint256 quoteAtBase) internal {
        vm.startPrank(alice);
        vault.approve(address(queue), s.sharesA);
        uint256 req = queue.requestRedeem(s.sharesA);
        vm.stopPrank();
        _warpToSettleable();
        _freshen();
        assertLe(block.timestamp, s.until, "settlement lands inside the 30-day TTL");
        assertTrue(_active(), "the assessment is still in force at settlement");
        uint256 expected = _quoteAt(s.sharesA, 100_000e18);
        assertEq(vault.previewRedeem(s.sharesA), expected, "the settlement quote is the assessed floor");
        assertEq(vault.maxWithdraw(address(queue)), expected, "advertised capacity equals the assessed quote");
        uint256 atBaseNow = _quoteAt(s.sharesA, s.base);
        vm.expectEmit(true, true, true, true, address(queue));
        emit RequestFilled(req, s.sharesA, expected, queue.currentEpoch());
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(req);
        assertEq(rem, 0, "filled in full");
        assertEq(claimable, expected, "paid EXACTLY the assessed quote");
        assertGt(claimable, quoteAtBase, "she is paid more than the base would have paid");
        emit log_named_uint("alice paid at the assessment", claimable);
        emit log_named_uint("alice would have been paid at the base", atBaseNow);
        emit log_named_uint("uplift: alice's share of the 250,000e18 assessed recovery", claimable - atBaseNow);
        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = queue.claim(req);
        assertEq(paid, claimable, "claim pays the fill");
        assertEq(usdfr.balanceOf(alice) - aliceBefore, paid, "alice received exactly the fill");
    }

    function _assessmentExpiresAndBobIsRequotedTheBase(Scene memory s, uint256 sharesB) internal {
        AssessedImpairmentSource a = _assessed();
        uint256 bobAssessed = vault.previewRedeem(sharesB);
        vm.warp(s.until);
        assertTrue(_active(), "valid through the last second of the TTL");
        vm.warp(uint256(s.until) + 1);
        assertFalse(_active(), "expired one second later");
        assertEq(a.pendingSeniorImpairment(), s.base, "the base prices again");
        assertEq(a.performanceFeeImpairment(), 1_000_000e18, "the gross fee base again");
        _freshen();
        uint256 bobAtBase = vault.previewRedeem(sharesB);
        assertEq(bobAtBase, _quoteAt(sharesB, s.base), "bob's quote is the base floor");
        assertLt(bobAtBase, bobAssessed, "and below what the assessment quoted him");
        emit log_named_uint("bob quoted at the assessment", bobAssessed);
        emit log_named_uint("bob quoted after expiry", bobAtBase);
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4 (I1): staleness across realization, resolution and a new default
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A standing 100,000e18 assessment is invalidated by a realized loss (revision advance),
    ///         a republication by the clean resolution, and neither attaches to a NEW 1,000,000e18
    ///         default declared while the old assessment, still inside its TTL, sits in storage: the
    ///         wrapper prices the new default at its full 1,000,000e18 base, not at the stale
    ///         100,000e18. A permissionless reserve top-up then leaves a fresh assessment standing
    ///         while the exact hash differs (FRV-FS-04), and the wrapper caps it at the lower live base.
    /// @dev Attacks I1. The stale-assessment attack is the ADR's named vulnerability: an assessment
    ///      published for one workout surviving into another would price 900,000e18 of new senior
    ///      loss as 100,000e18 for whoever exits first.
    function test_atk_aStaleAssessmentCannotSurviveRealizationResolutionOrANewDefault() public onFork {
        Scene memory s = _declaredScene();
        _grantTimelockAdmin();
        s.until = _publish(100_000e18, 30 days);
        assertTrue(_active(), "published");
        _realizationInvalidates(s);
        _resolutionInvalidates(s);
        _aNewDefaultDoesNotInheritTheStaleAssessment(s);
        _aReserveTopUpIsToleratedDirectionally();
    }

    /// @dev 650,000e18 takes all of layer one and two, zero senior; the mark had already priced it so
    ///      the base is unchanged, but the risk state (revision, declared principal, pools) is not the
    ///      one assessed.
    function _realizationInvalidates(Scene memory s) internal {
        AssessedImpairmentSource a = _assessed();
        _realizeLoss(s.id, 650_000e18, bytes32(0));
        assertEq(curator.poolBalance(FILM), 0, "layer one exhausted");
        assertEq(sGrove.coverageReserve(), 0, "layer two exhausted");
        assertEq(defaultManager.pendingSeniorImpairment(), s.base, "the base is unchanged by a priced realization");
        assertFalse(_active(), "the realization invalidated the assessment");
        (,, bool matches) = a.assessmentState();
        assertFalse(matches, "snapshot no longer matches");
        assertEq(a.pendingSeniorImpairment(), s.base, "the base prices, inside the TTL");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets() - s.base, "exit base back at the mark");
        Current memory c = _current();
        assertEq(c.amount, 100_000e18, "the stale amount is still in storage");
        assertEq(c.until, s.until, "with a live expiry");
    }

    /// @dev Republish against the realized state, then the borrower repays the remaining 350,000e18.
    function _resolutionInvalidates(Scene memory s) internal {
        AssessedImpairmentSource a = _assessed();
        s.until = _publish(100_000e18, 30 days);
        assertTrue(_active(), "republished against the new state");
        _repay(s.id, 0, 350_000e18);
        assertEq(uint8(bridge.facility(s.id).state), uint8(ClaimBridge.LoanState.Resolved), "resolved");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no mark");
        assertFalse(_active(), "the resolution invalidated the assessment");
        assertEq(a.pendingSeniorImpairment(), 0, "zero base, zero returned");
        assertEq(_current().amount, 100_000e18, "stale amount still in storage after the resolve");
    }

    /// @dev A NEW default with no junior capital left: the whole 1,000,000e18 face is senior.
    function _aNewDefaultDoesNotInheritTheStaleAssessment(Scene memory s) internal {
        AssessedImpairmentSource a = _assessed();
        uint256 id2 = _originateAndFund(1_000_000e18);
        _declareDefault(id2, keccak256("atk-assessed-second-default"));
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18, "no layer one, no layer two: the full face");
        assertLt(block.timestamp, s.until, "the stale assessment is still inside its TTL");
        assertFalse(_active(), "the stale assessment does not attach to the new default");
        assertEq(
            a.pendingSeniorImpairment(),
            1_000_000e18,
            "STALE ASSESSMENT ATTACK: the wrapper prices the new default in full"
        );
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets() - 1_000_000e18, "exit base at the new mark");
        assertEq(vault.previewRedeem(s.sharesA), _quoteAt(s.sharesA, 1_000_000e18), "alice's quote at the new mark");
    }

    /// @dev Fresh assessment on the new default, then permissionless top-ups of the shared reserve.
    function _aReserveTopUpIsToleratedDirectionally() internal {
        AssessedImpairmentSource a = _assessed();
        _publish(400_000e18, 30 days);
        assertTrue(_active(), "fresh assessment");
        assertEq(a.pendingSeniorImpairment(), 400_000e18, "assessed");
        _mintFromUSDC(bob, 1_000_000e6);
        _fundCoverage(bob, 200_000e18); // `fundCoverage` is permissionless; bob is merely KYC'd
        assertEq(defaultManager.pendingSeniorImpairment(), 800_000e18, "the base fell by the top-up");
        (bytes32 snap, bytes32 live, bool stillMatches) = a.assessmentState();
        assertTrue(snap != live, "the exact hash moved (capacity is in it)");
        assertTrue(stillMatches, "FRV-FS-04: a capacity increase does not void professional work");
        assertTrue(_active(), "still active");
        assertEq(a.pendingSeniorImpairment(), 400_000e18, "min(400k, 800k)");
        assertEq(a.performanceFeeImpairment(), 400_000e18, "fee base snapshotted at publication: no junior credit then");
        // A larger top-up drives the base below the assessment: the wrapper follows the lower base.
        _fundCoverage(bob, 500_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "base 300k");
        assertTrue(_active(), "still active");
        assertEq(a.pendingSeniorImpairment(), 300_000e18, "min(400k, 300k): never above the live base");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5: accrual, assessment stability, and expiry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Time preserves declared-only assessments until expiry. A live overdue cohort
    ///         increases both assessed marks by all additional gross interest. Real changes to
    ///         curator capital and risk membership still require a new assessment.
    function test_accruingCohortIncreasesAssessedLossWhileDeclaredOnlyAssessmentIsStable() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 sharesA = _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18);
        uint256 idA = _originateAndFund(1_000_000e18);
        uint256 idB = _originateAndFund(1_000_000e18); // performing; the unrelated facility
        _declareDefault(idA, keccak256("atk-assessed-clock"));
        assertEq(defaultManager.pendingSeniorImpairment(), 350_000e18, "base");
        _grantTimelockAdmin();
        _declaredOnlyBookIsClockStableAndExpiresOnTime();
        _anUnrelatedCouponIsChecked(idB);
        _accruingPastDueCohortIncreasesBothAssessmentMarks(idB, sharesA);
    }

    /// @dev The declaration stopped A's accrual; B performs outside the risk hash.
    function _declaredOnlyBookIsClockStableAndExpiresOnTime() internal {
        AssessedImpairmentSource a = _assessed();
        uint256 t0 = block.timestamp;
        _publish(100_000e18, 30 days);
        bytes32 risk0 = defaultManager.impairmentRiskStateHash();
        vm.warp(t0 + 1);
        assertEq(defaultManager.impairmentRiskStateHash(), risk0, "declared-only: the risk hash is clock-stable");
        assertTrue(_active(), "active after one second");
        _warp(29 days - 1);
        _freshen();
        assertEq(defaultManager.impairmentRiskStateHash(), risk0, "29 days of keeper checkpoints did not move it");
        assertTrue(_active(), "active on day 29");
        assertEq(a.pendingSeniorImpairment(), 100_000e18, "still assessed");
        vm.warp(t0 + 30 days);
        assertTrue(_active(), "active at the last second of the TTL");
        vm.warp(t0 + 30 days + 1);
        assertFalse(_active(), "EXPIRED one second past the TTL");
        assertEq(a.pendingSeniorImpairment(), 350_000e18, "base after expiry");
    }

    /// @dev An ordinary coupon on the unrelated, performing facility B, inside its grace window. The
    ///      receipt's sub-unit rounding correction (`ReserveRoundingLib.allocate`, the C4 family in
    ///      FORK_ADVERSARIAL_RESULTS_2026-09-15) is charged to the FILM curator pool through
    ///      `CuratorModule.absorbLoss`; `poolBalance(classId)` is in the risk hash for every class, so
    ///      the workout assessment is void the moment any facility anywhere pays a coupon that carries
    ///      dust. Executed here: 661,311,220,868 wei of dust voids a 100,000e18 assessment.
    function _anUnrelatedCouponIsChecked(uint256 idB) internal {
        _freshen();
        _publish(100_000e18, 30 days);
        assertTrue(_active(), "republished");
        uint256 poolBefore = curator.poolBalance(FILM);
        bytes32 riskBefore = defaultManager.impairmentRiskStateHash();
        uint256 coupon = (uint256(1_000_000e18) * 1400 * 30 days / (10_000 * 360 days)) / 1e12 * 1e12;
        vm.recordLogs();
        _repay(idB, coupon, 0);
        uint256 dust = _curatorDustAbsorbed(vm.getRecordedLogs());
        uint256 poolAfter = curator.poolBalance(FILM);
        emit log_named_uint("curator pool before the unrelated coupon", poolBefore);
        emit log_named_uint("curator pool after the unrelated coupon", poolAfter);
        emit log_named_uint("LossAbsorbed(FILM) dust charged by the coupon", dust);
        assertEq(poolBefore, 150_000e18, "layer one intact before the coupon");
        assertEq(poolBefore - poolAfter, dust, "the pool moved by exactly the coupon's rounding dust");
        assertEq(dust, 661_311_220_868, "661,311,220,868 wei on a 1,000,000e18 coupon at day 30 plus one second");
        assertTrue(defaultManager.impairmentRiskStateHash() != riskBefore, "curator dust moved the risk hash");
        assertFalse(_active(), "AN UNRELATED COUPON VOIDED THE WORKOUT ASSESSMENT");
        assertEq(_assessed().pendingSeniorImpairment(), defaultManager.pendingSeniorImpairment(), "the base prices");
        assertEq(
            defaultManager.pendingSeniorImpairment(), 350_000e18 + dust, "the base rose by the dust layer one lost"
        );
    }

    /// @dev Sum of `CuratorModule.LossAbsorbed(FILM, loss, ..)` amounts in the recorded logs.
    function _curatorDustAbsorbed(Vm.Log[] memory logs) internal view returns (uint256 dust) {
        bytes32 topic = keccak256("LossAbsorbed(uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(curator) || logs[i].topics.length != 2 || logs[i].topics[0] != topic) {
                continue;
            }
            if (uint256(logs[i].topics[1]) != FILM) continue;
            (uint256 loss,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            dust += loss;
        }
    }

    /// @dev A new overdue mark invalidates the prior memorandum. After republication, a
    ///      clock tick reserves only the additional gross interest without changing validity.
    function _accruingPastDueCohortIncreasesBothAssessmentMarks(uint256 idB, uint256 sharesA) internal {
        AssessedImpairmentSource a = _assessed();
        _warp(60 days);
        _freshen();
        vm.prank(carol);
        defaultManager.markPastDue(idB);
        assertFalse(_active(), "a new past-due mark invalidates (by design)");
        assertGt(defaultManager.pendingSeniorImpairment(), 350_000e18, "the base rose with the marked cohort");
        uint64 until = _publish(100_000e18, 30 days);
        assertTrue(_active(), "published in the same block as the mark: active");
        emit log_named_uint("base at publication (declared A plus marked B)", defaultManager.pendingSeniorImpairment());
        uint256 quoteAssessed = vault.previewRedeem(sharesA);
        assertEq(quoteAssessed, _quoteAt(sharesA, 100_000e18), "assessed quote");
        bytes32 riskMarked = defaultManager.impairmentRiskStateHash();
        uint256 accruedMarked = reserves.accruedPastDue(FILM);
        uint256 feeMarkBefore = a.performanceFeeImpairment();

        vm.warp(block.timestamp + 1);
        uint256 accruedNext = reserves.accruedPastDue(FILM);
        emit log_named_uint("accruedPastDue(FILM) at publication", accruedMarked);
        emit log_named_uint("accruedPastDue(FILM) one second later", accruedNext);
        assertGt(accruedNext, accruedMarked, "the marked cohort accrued in one second");
        assertTrue(defaultManager.impairmentRiskStateHash() != riskMarked, "the risk hash moved on the clock alone");
        assertTrue(_active(), "elapsed interest must preserve the assessment");
        uint256 increase = accruedNext - accruedMarked;
        assertEq(a.pendingSeniorImpairment(), 100_000e18 + increase, "additional overdue income remains reserved");
        assertEq(a.performanceFeeImpairment(), feeMarkBefore + increase, "fee reserve must include the same income");
        emit log_named_uint("base one second later", defaultManager.pendingSeniorImpairment());
        assertEq(_current().until, until, "the original expiry remains in force");
        uint256 quoteNext = vault.previewRedeem(sharesA);
        assertLe(quoteNext, quoteAssessed, "overdue-only income cannot raise the exit price");
        assertLe(quoteAssessed - quoteNext, increase, "time reinstated the full conservative loss");
        emit log_named_uint("assessed exit quote (alice)", quoteAssessed);
        emit log_named_uint("exit quote one second later (alice)", quoteNext);
        emit log_named_uint("step down", quoteAssessed - quoteNext);
    }
}

/// @notice The deployed `edf525c` shape: the accrual engine is never wired, so
///         `DefaultManager.pendingSeniorImpairment` routes to `ConservativeImpairmentMath` and the
///         risk hash carries no accruing cohort.
contract ATK_AssessedImpairmentUnboundForkTest is ATK_AssessedImpairmentForkBase {
    function _wireContinuousAccrual(D memory) internal override {
        // Deliberately nothing: the deployed proxies have not bound the continuous-accrual reserve.
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6 (I1): the deployed path prices the same assessment and ignores the clock
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Same scene, accrual disabled: the base is the calculator's 350,000e18, a 100,000e18
    ///         assessment reprices the exit by exactly 250,000e18 as on the bound path, and after a
    ///         permissionless past-due mark a fresh assessment SURVIVES the clock: the ramp raises the
    ///         base each second while the wrapper keeps returning the assessment.
    /// @dev The difference from A5 is the whole content of the static MEDIUM: on the live proxies the
    ///      lever works during a past-due workout; on HEAD it does not.
    function test_atk_theDeployedPathPricesTheSameAssessmentAndTheClockDoesNotKillIt() public onFork {
        assertFalse(reserves.accrualSnapshot().enabled, "precondition: accrual is not enabled");
        assertEq(defaultManager.accrualReserve(), address(0), "precondition: manager unbound");
        assertEq(vault.accrualReserve(), address(0), "precondition: vault unbound");
        Scene memory s = _declaredScene();
        uint256 idB = _originateAndFund(1_000_000e18);
        _grantTimelockAdmin();
        _theCalculatorIsTheBaseAndTheAssessmentRepricesTheExit(s);
        _thePastDueWorkoutKeepsItsAssessment(s, idB);
    }

    function _theCalculatorIsTheBaseAndTheAssessmentRepricesTheExit(Scene memory s) internal {
        ConservativeImpairmentMath calc = defaultManager.impairmentMath();
        assertEq(calc.pendingSeniorImpairment(address(defaultManager)), s.base, "the calculator IS the base here");
        Reads memory before = _reads(s.sharesA);
        _publish(100_000e18, 30 days);
        Reads memory after_ = _reads(s.sharesA);
        assertEq(after_.wrapperMark, 100_000e18, "assessed");
        assertEq(after_.redemptionAssets - before.redemptionAssets, 250_000e18, "exactly the assessed recovery");
        assertEq(after_.quoteA, _quoteAt(s.sharesA, 100_000e18), "the assessed quote");
        assertEq(after_.managerMark, before.managerMark, "manager untouched");
        assertEq(after_.calculatorMark, before.calculatorMark, "calculator untouched");
        assertEq(after_.registryMark, before.registryMark, "registry untouched");
        assertEq(after_.totalAssets, before.totalAssets, "realized NAV untouched");
        assertEq(after_.totalAssets, 3_000_010e18, "3,000,000e18 staked plus the 10e18 seed, no streamed accrual");
        emit log_named_uint("deployed path: base exit quote (alice)", before.quoteA);
        emit log_named_uint("deployed path: assessed exit quote (alice)", after_.quoteA);
    }

    /// @dev carol marks B past due; governance republishes; the clock passes and the ramp climbs.
    function _thePastDueWorkoutKeepsItsAssessment(Scene memory s, uint256 idB) internal {
        AssessedImpairmentSource a = _assessed();
        _warp(60 days);
        vm.prank(carol);
        defaultManager.markPastDue(idB);
        assertFalse(_active(), "a new past-due mark invalidates (by design)");
        uint256 baseMarked = defaultManager.pendingSeniorImpairment();
        assertGt(baseMarked, s.base, "the base rose with the marked cohort");
        _publish(100_000e18, 30 days);
        assertTrue(_active(), "published");
        bytes32 riskMarked = defaultManager.impairmentRiskStateHash();
        vm.warp(block.timestamp + 1);
        assertEq(defaultManager.impairmentRiskStateHash(), riskMarked, "DEPLOYED PATH: the risk hash is clock-stable");
        assertTrue(_active(), "DEPLOYED PATH: still active one second later");
        assertEq(a.pendingSeniorImpairment(), 100_000e18, "the assessment prices");
        _warp(7 days);
        assertGt(defaultManager.pendingSeniorImpairment(), baseMarked, "the ramp raised the base over the week");
        assertTrue(_active(), "still active after a week of ramp");
        assertEq(a.pendingSeniorImpairment(), 100_000e18, "the assessment still prices: the ramp cannot lower it");
        assertEq(
            vault.previewRedeem(s.sharesA), _quoteAt(s.sharesA, 100_000e18), "the exit quote holds at the assessment"
        );
        emit log_named_uint("deployed path: base at the mark", baseMarked);
        emit log_named_uint("deployed path: base a week later", defaultManager.pendingSeniorImpairment());
    }
}
