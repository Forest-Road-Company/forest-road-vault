// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {PointsHook_InsufficientGas} from "../../src/libraries/PointsHookGas.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev GOVERNANCE-COMPROMISE DOUBLE. A participation-points module that acts INSIDE a strict-equality
///      balance window. `USDfr._update` hands every wired points module control after each balance
///      change, so a module can run exactly while `SGrove.coverShortfall` or `CuratorModule.absorb*`
///      is delivering USDfr to the address a window measures. This double fires only when USDfr lands
///      at `target` (the measured address) from `onlyFrom` (address(0) means any sender), which is
///      precisely the transfer the window straddles. Two modes:
///        DonateWei: transfers ONE WEI of its own USDfr into `target`, so the measured delta exceeds
///                   the reported delivery by exactly one.
///        BurnGas:   spins until almost no gas is left, then RETURNS (never reverts), so the token's
///                   fail-open `try/catch` is never even consulted; the caller retains only EIP-150's
///                   1/64 (or whatever explicit cap the call site imposed).
///      `burnOnCuratorLoss` additionally burns inside `CuratorModule`'s uncapped `onCuratorLoss` hook,
///      and `donateOnCuratorLoss` lands the wei from that hook instead of from the token hook (the
///      curator hook fires inside the same `absorbLoss` / `absorbGlobalLoss` frame the reserve's
///      windows straddle, so it is a second mid-window position with the same reach).
///      Every action is counted so a test can prove the module DID act; a hook that silently did not
///      run would make every "completes anyway" assertion vacuous.
///      The double also answers `proxiableUUID` with the ERC-1967 implementation slot so it can be
///      installed through `PointsModule.upgradeToAndCall` (the UPGRADER_ROLE door) as well as through
///      the two `setPointsModule` doors. Its storage occupies slots 0.. of whichever account runs it,
///      which the ERC-7201 layout of the production module never touches.
contract WindowHostilePointsModule is IPointsModule {
    enum Mode {
        Idle,
        DonateWei,
        BurnGas
    }

    IERC20 public immutable USDFR;
    Mode public mode;
    address public target;
    address public onlyFrom;
    bool public burnOnCuratorLoss;
    bool public donateOnCuratorLoss;
    uint256 public usdfrHookFires;
    uint256 public curatorHookFires;
    uint256 public lastGasOffered;

    /// @dev Leaves enough to return cleanly; a revert here would be swallowed by the token and
    ///      the burn would silently not count.
    uint256 private constant GAS_FLOOR = 5_000;
    /// @dev A test that forgets to cap the call would hand this loop ~2^63 gas. Refuse (the revert
    ///      is swallowed by the caller's try/catch and the fire counter rolls back, so the test's
    ///      "the module acted" assertion fails loudly instead of the machine spinning forever).
    uint256 private constant GAS_SANITY = 500_000_000;

    constructor(IERC20 usdfr_) {
        USDFR = usdfr_;
    }

    function configure(Mode mode_, address target_, address onlyFrom_, bool burnOnCuratorLoss_) external {
        mode = mode_;
        target = target_;
        onlyFrom = onlyFrom_;
        burnOnCuratorLoss = burnOnCuratorLoss_;
        donateOnCuratorLoss = false;
    }

    /// @dev Route the wei through the curator hook: `onCuratorLoss` transfers one wei to `target`
    ///      and the token hook stays silent, so a test can attribute the landing to that hook alone.
    function configureCuratorDonation(address target_) external {
        mode = Mode.DonateWei;
        target = target_;
        onlyFrom = address(0);
        burnOnCuratorLoss = false;
        donateOnCuratorLoss = true;
    }

    function onUSDfrTransfer(address from, address to, uint256 amount) external override {
        if (msg.sender != address(USDFR) || mode == Mode.Idle || amount == 0) return;
        if (donateOnCuratorLoss) return; // the curator hook is the only actor in that configuration
        if (to != target || from == address(this)) return; // never recurse on our own donation
        if (onlyFrom != address(0) && from != onlyFrom) return;
        lastGasOffered = gasleft();
        ++usdfrHookFires;
        if (mode == Mode.DonateWei) {
            require(USDFR.transfer(target, 1), "hostile module: donation failed");
            return;
        }
        _burn();
    }

    function onCuratorLoss(uint256, uint256, uint256) external override {
        if (donateOnCuratorLoss && mode == Mode.DonateWei) {
            lastGasOffered = gasleft();
            ++curatorHookFires;
            require(USDFR.transfer(target, 1), "hostile module: curator-hook donation failed");
            return;
        }
        if (!burnOnCuratorLoss || mode != Mode.BurnGas) return;
        lastGasOffered = gasleft();
        ++curatorHookFires;
        _burn();
    }

    function onSharesTransfer(address, address, uint256) external override {}
    function onCuratorStakeChange(address, uint256, uint256) external override {}

    /// @dev ERC-1822: lets OpenZeppelin's `upgradeToAndCallUUPS` accept this contract as the new
    ///      implementation of the production `PointsModule` proxy.
    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function _burn() private view {
        require(gasleft() < GAS_SANITY, "hostile module: refuse to burn an unbounded budget");
        uint256 spin;
        while (gasleft() > GAS_FLOOR) {
            unchecked {
                ++spin;
            }
        }
    }
}

/// @dev The approve-then-transferFrom leg of A1: an attacker-owned contract that pulls USDfr the
///      attacker approved and pushes it at the measured address. Sequential, like everything else
///      an unprivileged actor can do.
contract PullDonor {
    IERC20 public immutable USDFR;

    constructor(IERC20 usdfr_) {
        USDFR = usdfr_;
    }

    function pull(address from, address to, uint256 amount) external {
        require(USDFR.transferFrom(from, to, amount), "pull failed");
    }
}

/// @title ATK_MeasurementWindowFork, adversarial execution of the strict-equality balance windows on
///        the loss path against the FULL protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice The static rounds of 15 September 2026 enumerated eleven strict-equality balance windows
///         and concluded: "none of the eleven is permissionlessly brickable; each requires control of
///         the points module". That conclusion was reasoned, never executed. This suite executes it,
///         both ways, against the invariants it protects (CLAUDE.md 1.3):
///           I3. loss cascade ordering and liveness: an attested loss must be allocatable
///               curator -> sGROVE -> sUSDfr, and the allocation must be exact to the wei;
///           I2. value conservation: nothing inside a window may create, destroy or misroute a wei;
///           I8. access control: the mid-window position (the points hook) is reachable by no
///               unprivileged role in any state.
///
///         Sites executed (file:line on HEAD 5ecb7ba):
///           CommitmentLedger.sol:116     received != covered, straddling SGrove.coverShortfall,
///                                        measuring DefaultManager's own USDfr balance; reached by
///                                        realizeLoss, drawForSeniorExit and absorbReserveLoss.
///           ReserveCascadeLib.sol:194    received != curatorAbsorbed, straddling absorbGlobalLoss.
///           ReserveCascadeLib.sol:203    received != backstopCovered, straddling coverShortfall.
///           ReserveRoundingLib.sol:164   _equal(6, ...), straddling absorbLoss{gas}.
///           ReserveRoundingLib.sol:181   _equal(9, ...), straddling coverShortfall{gas}.
///           MintRedeemController._drawJuniorForExit: the one site already relaxed to a FLOOR
///                                        (SWEEP-2 S2-F5), which must still tolerate the wei.
///
///         Attacks (each ends in an unambiguous assertion; a blocked attack asserts the specific
///         custom error and the untouched state, a successful one asserts the violated quantity):
///           A1. PERMISSIONLESS. carol (no KYC, no role) and alice (KYC'd holder) land every USDfr
///               and USDC movement they can reach adjacent to the window (transfer, approve plus
///               transferFrom, vault deposit, queue request, repayment, recapitalize) and try every
///               privileged door into the window. Every door reverts with its exact error, every
///               adjacent movement is sequential, and realizeLoss completes with exact figures.
///           A2. GAS. A governance-installed points module burns the forwarded gas inside the window
///               without reverting. For EVERY site the smallest transaction budget that still
///               completes is binary-searched under snapshots and asserted from both sides, against
///               the fork block's own 60,000,000 limit, through the USDfr hook (capped only by the
///               F-18-02 floor) and through the curator hook (uncapped). One configuration bricks
///               the cascade at every budget up to the block limit; the others force a budget of
///               roughly three to twenty times the benign cost, which is griefing, not a brick.
///               Below each threshold the site is bricked with the same `PointsHook_InsufficientGas`
///               at the next balance change; no site is exempt, including the two rounding windows
///               whose `_forwardGas` retention only narrows the band.
///           A3. ONE WEI. A governance-installed points module lands one wei inside each window,
///               from the token hook and, where the reserve's window straddles a curator call, from
///               the curator hook as well. Each site's exact outcome is asserted: completes, or
///               reverts with the exact error carrying measured-versus-reported values.
///           A4. FLOOR. The same wei against MintRedeemController._drawJuniorForExit, which must
///               tolerate it (S2-F5 still in force), and against the layer-two window nested inside
///               the same exit, which does not.
///
///         Every attack that lands (A2, A3 on the four strict sites, A4's nested window) is
///         reachable ONLY through USDfr.setPointsModule or CuratorModule.setPointsModule (both
///         DEFAULT_ADMIN_ROLE) or PointsModule.upgradeToAndCall (UPGRADER_ROLE, the timelock), the
///         third door being executed as well and reaching the same brick without the setter ever
///         moving. That is the governance-compromise premise the static conclusion drew, and A1 is
///         the executed proof that no unprivileged actor can substitute for it.
contract ATK_MeasurementWindowForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev A generous single-transaction budget, used where a bounded call must be made under a
    ///      burner whose gas the test does not want to search: `WindowHostilePointsModule` refuses
    ///      an unbounded budget, so every call that can reach it carries an explicit cap.
    uint256 internal constant TX_BUDGET_30M = 30_000_000;

    /// @dev The declared-default rounding path is reached one day after funding: the interpolated
    ///      segment exceeds the canonical Actual/360 grid entitlement by 887,750,154,989 wei at
    ///      that instant (derived entirely from the fork block timestamp, so deterministic).
    uint256 internal constant ROUNDING_WARP = 1 days;

    // Declared locally so `vm.expectEmit` matches the real emissions by canonical signature.
    event LossRealized(
        uint256 indexed tokenId,
        uint256 indexed classId,
        uint256 loss,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 depositorLoss
    );
    event SeniorExitDrawn(uint256 required, uint256 curatorAbsorbed, uint256 backstopCovered);
    event ReserveLossAllocated(
        uint256 indexed incidentId,
        uint256 backingReduction,
        uint256 surplusAbsorbed,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 seniorBurned,
        uint256 residualDeficit
    );
    event AccrualRoundingAllocated(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint256 amount,
        uint256 prepaid,
        uint256 curator,
        uint256 backstop,
        uint256 senior,
        uint256 unabsorbed,
        uint256 markConsumed
    );

    WindowHostilePointsModule internal hostile;

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        hostile = new WindowHostilePointsModule(IERC20(address(usdfr)));
        deal(USDC, ops, 40_000_000e6);
        deal(USDC, bob, 40_000_000e6);
        deal(USDC, alice, 40_000_000e6);
        // The wei donor is funded the only way an outsider could fund it: a holder's permissionless
        // transfer. Sixteen wei covers every donation this suite makes.
        _mintFromUSDC(alice, 1e6);
        vm.prank(alice);
        require(usdfr.transfer(address(hostile), 16), "alice -> hostile");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A1, I8 and I3: no unprivileged actor can enter the window, and every
    //     movement they can make is sequential. realizeLoss completes exactly.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice carol (not KYC'd, no role, 1,000,000 USDC) and alice (KYC'd USDfr holder) throw every
    ///         reachable USDfr and USDC movement at the three cascade counterparties in the same
    ///         block as `realizeLoss`, and try every privileged door into the window. If any of it
    ///         could land INSIDE `CommitmentLedger.coverDelegate`'s window, `realizeLoss` would revert
    ///         `DefaultManager_BackstopContractViolated` and a 1,000,000 USDfr attested loss could
    ///         not be booked: an unprivileged liveness kill on the cascade. A failure here means the
    ///         static conclusion is wrong in the direction that matters most.
    function test_atk_permissionlessActorsCannotEnterTheWindow() public onFork {
        _mintFromUSDC(alice, 10_000e6);
        uint256 tokenId = _facilityCascadeBook(300_000e18, 500_000e18);
        // A second, performing facility so a REPAYMENT can be one of the adjacent movements.
        uint256 t2 = _originateAndFundFilm(keccak256("mw-borrower-2"), keccak256("mw-state-2"), 500_000e18);

        // carol obtains USDfr the only way she can: a permissionless transfer from a holder.
        vm.prank(alice);
        require(usdfr.transfer(carol, 1_000e18), "alice -> carol");

        _everyPrivilegedDoorRefusesCarol(tokenId);
        _everyAdjacentMovementLandsSequentially(t2);

        // ── the cascade, with the production module wired ──
        uint256 loss = 1_000_000e18;
        Figures memory f = _expectedFacilityFigures(loss);
        assertEq(f.absorbed, 300_000e18, "layer 1 sized as intended");
        assertEq(f.covered, 500_000e18, "layer 2 sized as intended");
        assertEq(f.depositorLoss, 200_000e18, "layer 3 sized as intended");

        uint256 dmBefore = usdfr.balanceOf(address(defaultManager));
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 supplyBefore = usdfr.totalSupply();
        assertEq(dmBefore, 3, "three donated wei stand at the manager before the window opens");

        bytes32 evidence = _attestLoss(tokenId, loss, bytes32(0));
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit LossRealized(tokenId, FILM, loss, f.absorbed, f.covered, f.depositorLoss);
        defaultManager.realizeLoss(tokenId, loss, evidence);

        assertEq(curator.poolBalance(FILM), f.pool - f.absorbed, "layer 1 charged exactly its capital");
        assertEq(sGrove.coverageReserve(), f.coverage - f.covered, "layer 2 charged exactly the residual");
        assertEq(
            vaultBefore - usdfr.balanceOf(address(vault)), f.depositorLoss, "layer 3 charged exactly the remainder"
        );
        assertEq(supplyBefore - usdfr.totalSupply(), loss, "exactly the loss left supply: nothing created or destroyed");
        assertEq(
            usdfr.balanceOf(address(defaultManager)), dmBefore, "junior delivery burned exactly; donations untouched"
        );
        assertEq(reserves.deployedTo(tokenId), 0, "the facility is fully written down");
    }

    struct Figures {
        uint256 pool;
        uint256 coverage;
        uint256 absorbed;
        uint256 covered;
        uint256 depositorLoss;
        uint256 supply;
        uint256 vaultHeld;
    }

    /// @dev The observable state the cascade moves: both junior layers, supply, the vault's holding.
    function _postCascadeFigures() internal view returns (Figures memory f) {
        f.pool = curator.poolBalance(FILM);
        f.coverage = sGrove.coverageReserve();
        f.supply = usdfr.totalSupply();
        f.vaultHeld = usdfr.balanceOf(address(vault));
    }

    function _assertFiguresEqual(Figures memory a, Figures memory b, string memory ctx) internal pure {
        assertEq(a.pool, b.pool, string(abi.encodePacked("layer 1: ", ctx)));
        assertEq(a.coverage, b.coverage, string(abi.encodePacked("layer 2: ", ctx)));
        assertEq(a.supply, b.supply, string(abi.encodePacked("supply: ", ctx)));
        assertEq(a.vaultHeld, b.vaultHeld, string(abi.encodePacked("layer 3: ", ctx)));
    }

    /// @dev The exact F-18-02 revert: `PointsHook_InsufficientGas(available, 500_000)` with the
    ///      offered gas strictly under the floor. The measured `available` is logged for the record.
    function _assertHookFloorRevert(bytes memory data, string memory tag) internal {
        assertEq(
            bytes4(data),
            PointsHook_InsufficientGas.selector,
            string(abi.encodePacked(tag, ": exact error is the hook floor"))
        );
        (uint256 available, uint256 required) = _decodeTwoWords(data);
        assertEq(required, 500_000, string(abi.encodePacked(tag, ": the floor is PointsHookGas.MINIMUM_GAS")));
        assertLt(available, 500_000, string(abi.encodePacked(tag, ": the next balance change arrived under the floor")));
        emit log_named_uint(
            string(abi.encodePacked(tag, " reverted PointsHook_InsufficientGas(available, 500000); available")),
            available
        );
    }

    /// @dev The cascade figures the code must produce for a facility loss, from live reads.
    function _expectedFacilityFigures(uint256 loss) internal view returns (Figures memory f) {
        f.pool = curator.poolBalance(FILM);
        f.coverage = sGrove.coverageReserve();
        f.absorbed = loss < f.pool ? loss : f.pool;
        uint256 residual = loss - f.absorbed;
        f.covered = residual < f.coverage ? residual : f.coverage;
        f.depositorLoss = residual - f.covered;
    }

    /// @dev Every privileged door into the window, tried by the unprivileged attacker. Each refuses
    ///      with its exact error and the production points modules stay wired.
    function _everyPrivilegedDoorRefusesCarol(uint256 tokenId) internal {
        (,,,,,,, address ledger) = defaultManager.modules();
        vm.startPrank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        usdfr.setPointsModule(address(hostile));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        curator.setPointsModule(address(hostile));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.UPGRADER_ROLE)
        );
        points.upgradeToAndCall(address(hostile), "");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.realizeLoss(tokenId, 1, keccak256("carol"));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        sGrove.coverShortfall(tokenId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        curator.absorbLoss(FILM, 1);
        vm.expectRevert(CommitmentLedger.CommitmentLedger_DirectCall.selector);
        CommitmentLedger(ledger).coverDelegate(address(sGrove), address(usdfr), tokenId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, carol)
        );
        defaultManager.drawForSeniorExit(1);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, carol)
        );
        defaultManager.absorbReserveLoss(uint256(1) << 255, 1);
        vm.stopPrank();
        assertEq(usdfr.pointsModule(), address(points), "the production points module is still wired");
        assertEq(curator.pointsModule(), address(points), "the curator's points module is still wired");
    }

    /// @dev Every USDfr and USDC movement an unprivileged actor can make, landed in the block before
    ///      the cascade. All of them are sequential calls: none can execute inside the window.
    function _everyAdjacentMovementLandsSequentially(uint256 performingFacility) internal {
        PullDonor donor = new PullDonor(IERC20(address(usdfr)));
        vm.startPrank(carol);
        require(usdfr.transfer(address(defaultManager), 1), "carol -> DM");
        require(usdfr.transfer(address(reserves), 1), "carol -> RM");
        require(usdfr.transfer(address(sGrove), 1), "carol -> sGROVE");
        usdfr.approve(address(donor), 1);
        donor.pull(carol, address(defaultManager), 1);
        IERC20(USDC).approve(address(reserves), 1e6);
        reserves.recapitalize(1e6);
        vm.stopPrank();
        vm.prank(alice);
        require(usdfr.transfer(address(defaultManager), 1), "alice -> DM");
        uint256 aliceShares = _stake(alice, 1_000e18);
        vm.startPrank(alice);
        vault.approve(address(queue), aliceShares);
        queue.requestRedeem(aliceShares);
        vm.stopPrank();
        _repay(performingFacility, 0, 100_000e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2, I3 liveness: a gas-burning points module INSIDE the window.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Governance installs a points module that burns the forwarded gas inside the
    ///         `coverDelegate` window (only when sGROVE's USDfr lands at the manager) and returns.
    ///         The window itself survives (nothing moved), but every frame on the stack keeps only
    ///         EIP-150's 1/64 of its gas, and the token's F-18-02 floor demands 500,000 at the NEXT
    ///         balance change (the manager's self-burn). The exact transaction budget below which
    ///         `realizeLoss` reverts is binary-searched under snapshots and asserted from both sides:
    ///         one step under it the loss is not booked (`PointsHook_InsufficientGas`), at it the
    ///         cascade completes with figures identical to the benign run. A benign run costs
    ///         925,618 gas; the burner forces a budget many times that, but not beyond the fork
    ///         block's 60,000,000 limit, so this is griefing of the operator's gas, not a brick.
    function test_atk_gasBurningPointsModuleInsideTheRealizeLossWindow() public onFork {
        uint256 tokenId = _facilityCascadeBook(300_000e18, 500_000e18);
        uint256 loss = 1_000_000e18;
        bytes memory call =
            abi.encodeCall(defaultManager.realizeLoss, (tokenId, loss, _attestLoss(tokenId, loss, bytes32(0))));

        // Benign reference: the production module.
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        (bool ok,) = address(defaultManager).call{gas: TX_BUDGET_30M}(call);
        uint256 benignCost = g - gasleft();
        assertTrue(ok, "control: the cascade completes under the production module");
        Figures memory benign = _postCascadeFigures();
        assertEq(benign.pool, 0, "control: layer 1 exhausted");
        assertEq(benign.coverage, 0, "control: layer 2 exhausted");
        assertTrue(vm.revertToState(snap), "snapshot revert failed");
        emit log_named_uint("A2 benign realizeLoss cost", benignCost);

        // Hostile: burn inside the window, and ONLY inside it.
        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(defaultManager), address(sGrove), false);
        usdfr.setPointsModule(address(hostile));
        Figures memory before = _postCascadeFigures();

        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(defaultManager), call, address(0));
        emit log_named_uint("A2 in-window burner: minimum completing budget", threshold);
        assertGt(threshold, 0, "A2: some budget at or under the block limit completes the cascade");
        assertGt(threshold, 5 * benignCost, "A2: the burner forces a budget over five times the benign cost");
        _assertHookFloorRevert(failure, "A2 realizeLoss one step under the threshold");
        assertEq(reserves.deployedTo(tokenId), 1_000_000e18, "the loss was NOT booked under the threshold");
        _assertFiguresEqual(_postCascadeFigures(), before, "nothing moved in the reverted attempts");

        (ok,) = address(defaultManager).call{gas: threshold}(call);
        assertTrue(ok, "A2: at the threshold realizeLoss completes");
        assertEq(hostile.usdfrHookFires(), 1, "the burner ran exactly once, inside the window");
        _assertFiguresEqual(_postCascadeFigures(), benign, "figures identical to the benign run");
        assertEq(before.supply - usdfr.totalSupply(), loss, "exactly the loss left supply");
        assertEq(reserves.deployedTo(tokenId), 0, "the loss is booked at the threshold");
    }

    /// @notice The same burner installed on the CuratorModule, whose `onCuratorLoss` hook has NO gas
    ///         cap (a bare `try`, CuratorModule.sol:628). The hook fires AFTER the curator's transfer
    ///         and BEFORE the layer-two window opens, so it cannot break the equality, but it leaves
    ///         each frame 1/64 and sGROVE's transfer then needs the 500,000 hook floor. The exact
    ///         threshold is searched and asserted from both sides as above.
    function test_atk_gasBurningCuratorHookAheadOfTheRealizeLossWindow() public onFork {
        uint256 tokenId = _facilityCascadeBook(300_000e18, 500_000e18);
        uint256 loss = 1_000_000e18;
        bytes memory call =
            abi.encodeCall(defaultManager.realizeLoss, (tokenId, loss, _attestLoss(tokenId, loss, bytes32(0))));

        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(0), address(0), true);
        curator.setPointsModule(address(hostile));
        Figures memory before = _postCascadeFigures();

        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(defaultManager), call, address(0));
        emit log_named_uint("A2b curator-hook burner: minimum completing budget", threshold);
        assertGt(threshold, 0, "A2b: some budget at or under the block limit completes the cascade");
        assertGt(threshold, 5_000_000, "A2b: the burner forces a budget over five times the benign cost");
        _assertHookFloorRevert(failure, "A2b realizeLoss one step under the threshold");
        assertEq(reserves.deployedTo(tokenId), 1_000_000e18, "the loss was NOT booked under the threshold");
        _assertFiguresEqual(_postCascadeFigures(), before, "nothing moved in the reverted attempts");

        (bool ok,) = address(defaultManager).call{gas: threshold}(call);
        assertTrue(ok, "A2b: at the threshold realizeLoss completes");
        assertEq(hostile.curatorHookFires(), 1, "the curator hook burner ran exactly once");
        assertEq(curator.poolBalance(FILM), 0, "layer 1 exhausted, as in the benign run");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 exhausted, as in the benign run");
        assertEq(before.supply - usdfr.totalSupply(), loss, "exactly the loss left supply");
        assertEq(reserves.deployedTo(tokenId), 0, "the loss is booked at the threshold");
    }

    /// @notice The degenerate burner: it burns on EVERY USDfr movement into the manager, not just
    ///         inside the window. Two consecutive junior deliveries leave each frame (1/64)^2 of the
    ///         budget, so NO budget up to the block gas limit carries the cascade to its self-burn:
    ///         a compromised module bricks `realizeLoss` outright on this fork block. Asserted by
    ///         searching every budget up to the block limit and finding none that completes.
    function test_atk_gasBurningEveryDeliveryBricksRealizeLossEvenAtTheBlockLimit() public onFork {
        uint256 tokenId = _facilityCascadeBook(300_000e18, 500_000e18);
        uint256 loss = 1_000_000e18;
        bytes memory call =
            abi.encodeCall(defaultManager.realizeLoss, (tokenId, loss, _attestLoss(tokenId, loss, bytes32(0))));

        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(defaultManager), address(0), false);
        usdfr.setPointsModule(address(hostile));
        Figures memory before = _postCascadeFigures();

        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(defaultManager), call, address(0));
        assertEq(
            threshold,
            0,
            "A2c: burning both junior deliveries must brick realizeLoss at every budget up to the block limit"
        );
        // At the block limit itself the second delivery is starved of the floor by the first burn.
        _assertHookFloorRevert(failure, "A2c realizeLoss at the block limit");
        _assertFiguresEqual(_postCascadeFigures(), before, "nothing moved in the reverted attempts");
        assertEq(reserves.deployedTo(tokenId), 1_000_000e18, "the loss was NOT booked at the block gas limit");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3, I3 liveness and I2: ONE WEI inside each strict window.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice CommitmentLedger.sol:116 on `realizeLoss`. Governance installs a module that lands one
    ///         wei at the manager while sGROVE's delivery is in flight. `received` measures
    ///         `covered + 1`, the equality fails OUTSIDE the token's try/catch, and the attested
    ///         1,000,000 USDfr loss cannot be booked: `DefaultManager_BackstopContractViolated
    ///         (700,000e18, 500,000e18, 500,000e18 + 1)`. A wei landing OUTSIDE the window (during
    ///         the curator's delivery) is tolerated and the figures are exact.
    function test_atk_oneWeiInsideTheRealizeLossWindowBricksTheCascade() public onFork {
        uint256 tokenId = _facilityCascadeBook(300_000e18, 500_000e18);
        uint256 loss = 1_000_000e18;
        _armWeiDonor();

        // ── inside the window: sGROVE -> DefaultManager ──
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(sGrove), false);
        uint256 residual = loss - 300_000e18;
        uint256 covered = 500_000e18;
        uint256 supplyBefore = usdfr.totalSupply();
        bytes32 evidence = _attestLoss(tokenId, loss, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentLedger.DefaultManager_BackstopContractViolated.selector, residual, covered, covered + 1
            )
        );
        defaultManager.realizeLoss(tokenId, loss, evidence);
        assertEq(reserves.deployedTo(tokenId), 1_000_000e18, "ONE WEI: the attested loss was NOT booked");
        assertEq(curator.poolBalance(FILM), 300_000e18, "no layer-1 capital moved in the reverted attempt");
        assertEq(sGrove.coverageReserve(), 500_000e18, "no layer-2 reserve moved in the reverted attempt");
        assertEq(usdfr.totalSupply(), supplyBefore, "no supply moved in the reverted attempt");
        assertEq(hostile.usdfrHookFires(), 0, "the module's record rolled back with the cascade");

        // ── outside the window: CuratorModule -> DefaultManager (precedes coverDelegate) ──
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(curator), false);
        uint256 dmBefore = usdfr.balanceOf(address(defaultManager));
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit LossRealized(tokenId, FILM, loss, 300_000e18, covered, 200_000e18);
        defaultManager.realizeLoss(tokenId, loss, evidence);
        assertEq(hostile.usdfrHookFires(), 1, "the module acted once, during the curator delivery");
        assertEq(
            usdfr.balanceOf(address(defaultManager)),
            dmBefore + 1,
            "the out-of-window wei sits at the manager, unburned"
        );
        assertEq(supplyBefore - usdfr.totalSupply(), loss, "exactly the loss left supply");
        assertEq(reserves.deployedTo(tokenId), 0, "the loss is booked when the wei lands outside the window");
    }

    /// @notice The third door into the window: `PointsModule.upgradeToAndCall` (UPGRADER_ROLE, held
    ///         by the timelock). The production proxy is upgraded in place to the hostile
    ///         implementation, so `usdfr.pointsModule()` and `curator.pointsModule()` never move and
    ///         a monitor watching the two setters sees nothing. One wei from the upgraded proxy
    ///         during sGROVE's delivery bricks `realizeLoss` with the identical
    ///         `DefaultManager_BackstopContractViolated(700,000e18, 500,000e18, 500,000e18 + 1)`;
    ///         the same wei during the curator's delivery is tolerated and the figures are exact.
    ///         A failure here would mean the upgrade route differs from the setter route, which is
    ///         the one assumption A1's refusal of carol at `upgradeToAndCall` rests on.
    function test_atk_upgradedPointsModuleReachesTheWindowWithoutTheSetter() public onFork {
        uint256 tokenId = _facilityCascadeBook(300_000e18, 500_000e18);
        uint256 loss = 1_000_000e18;
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address productionImpl = address(uint160(uint256(vm.load(address(points), implSlot))));
        assertTrue(
            productionImpl != address(0) && productionImpl != address(hostile),
            "precondition: production implementation"
        );

        // The proxy is the donor now: fund it the only way an outsider could, a holder's transfer.
        vm.prank(alice);
        require(usdfr.transfer(address(points), 2), "alice -> points proxy");

        vm.prank(timelock);
        points.upgradeToAndCall(address(hostile), "");
        assertEq(
            address(uint160(uint256(vm.load(address(points), implSlot)))),
            address(hostile),
            "the proxy now runs the hostile code"
        );
        assertEq(usdfr.pointsModule(), address(points), "the token's setter never moved");
        assertEq(curator.pointsModule(), address(points), "the curator's setter never moved");
        WindowHostilePointsModule upgraded = WindowHostilePointsModule(address(points));

        // ── inside the window: sGROVE -> DefaultManager ──
        upgraded.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(sGrove), false);
        uint256 supplyBefore = usdfr.totalSupply();
        bytes32 evidence = _attestLoss(tokenId, loss, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentLedger.DefaultManager_BackstopContractViolated.selector,
                loss - 300_000e18,
                500_000e18,
                500_000e18 + 1
            )
        );
        defaultManager.realizeLoss(tokenId, loss, evidence);
        assertEq(reserves.deployedTo(tokenId), 1_000_000e18, "UPGRADE DOOR: the attested loss was NOT booked");
        assertEq(curator.poolBalance(FILM), 300_000e18, "no layer-1 capital moved in the reverted attempt");
        assertEq(sGrove.coverageReserve(), 500_000e18, "no layer-2 reserve moved in the reverted attempt");
        assertEq(usdfr.totalSupply(), supplyBefore, "no supply moved in the reverted attempt");
        assertEq(upgraded.usdfrHookFires(), 0, "the upgraded module's record rolled back with the cascade");

        // ── outside the window: the curator's delivery precedes coverDelegate ──
        upgraded.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(curator), false);
        uint256 dmBefore = usdfr.balanceOf(address(defaultManager));
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit LossRealized(tokenId, FILM, loss, 300_000e18, 500_000e18, 200_000e18);
        defaultManager.realizeLoss(tokenId, loss, evidence);
        assertEq(upgraded.usdfrHookFires(), 1, "the upgraded module acted once, during the curator delivery");
        assertEq(
            usdfr.balanceOf(address(defaultManager)),
            dmBefore + 1,
            "the out-of-window wei sits at the manager, unburned"
        );
        assertEq(supplyBefore - usdfr.totalSupply(), loss, "exactly the loss left supply");
        assertEq(reserves.deployedTo(tokenId), 0, "the loss is booked when the wei lands outside the window");
        assertEq(usdfr.pointsModule(), address(points), "the token's setter still never moved");
    }

    /// @notice ReserveCascadeLib.sol:194 and :203 on the live custody-loss path (`ratifyAndOpen`).
    ///         One wei landing at the ReserveManager during the curator's pro-rata delivery reverts
    ///         `ReserveManager_LossAbsorberContractViolated(300,000e18, 300,000e18 + 1)`, whether
    ///         the wei comes from the token hook or from the curator's own `onCuratorLoss` hook
    ///         (which fires inside `absorbGlobalLoss`, so inside the same window); during sGROVE's
    ///         delivery, `(500,000e18, 500,000e18 + 1)`. An adjudicated 1,000,000 USDC custody loss
    ///         stays recognised-but-unabsorbed, with supply un-burned. The gas burner is then
    ///         measured in each window separately: the exact minimum completing budget for :194
    ///         and for :203 is searched and asserted from both sides, and at that budget the
    ///         allocation is exact, under the deterministic custody incident id.
    function test_atk_oneWeiInsideTheCustodyCascadeWindows() public onFork {
        (uint256 armId, bytes32 evidence, uint256 loss) = _custodyLossBook(300_000e18, 500_000e18);
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 backingBefore = reserves.totalBackingValue();
        assertEq(
            controller.totalUSDfr(), backingBefore, "precondition: no surplus, the whole loss needs supply reduction"
        );
        uint256 curatorAbsorbed = 300_000e18;
        uint256 backstopCovered = 500_000e18;
        uint256 seniorBurned = loss - curatorAbsorbed - backstopCovered;
        uint256 incidentId = type(uint256).max - armId;
        _armWeiDonor();

        // ── :194, the wei from the token hook ──
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(reserves), address(curator), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_LossAbsorberContractViolated.selector,
                curatorAbsorbed,
                curatorAbsorbed + 1
            )
        );
        reserves.ratifyAndOpen(armId, evidence, loss);
        _assertCustodyLossUnabsorbed(supplyBefore, backingBefore, "after the :194 attempt");

        // ── :194, the wei from the curator hook (CuratorModule.sol:682, inside absorbGlobalLoss) ──
        usdfr.setPointsModule(address(points));
        curator.setPointsModule(address(hostile));
        hostile.configureCuratorDonation(address(reserves));
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_LossAbsorberContractViolated.selector,
                curatorAbsorbed,
                curatorAbsorbed + 1
            )
        );
        reserves.ratifyAndOpen(armId, evidence, loss);
        _assertCustodyLossUnabsorbed(supplyBefore, backingBefore, "after the curator-hook :194 attempt");
        assertEq(hostile.curatorHookFires(), 0, "the curator hook's record rolled back with the cascade");
        curator.setPointsModule(address(points));
        _armWeiDonor();

        // ── :203 ──
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(reserves), address(sGrove), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_LossAbsorberContractViolated.selector,
                backstopCovered,
                backstopCovered + 1
            )
        );
        reserves.ratifyAndOpen(armId, evidence, loss);
        _assertCustodyLossUnabsorbed(supplyBefore, backingBefore, "after the :203 attempt");

        // ── gas burner inside :194: the exact threshold, from both sides, under a snapshot ──
        CustodyExpect memory e = CustodyExpect({
            armId: armId,
            evidence: evidence,
            loss: loss,
            supplyBefore: supplyBefore,
            backingBefore: backingBefore,
            curatorAbsorbed: curatorAbsorbed,
            backstopCovered: backstopCovered,
            seniorBurned: seniorBurned,
            incidentId: incidentId
        });
        // ── gas burner inside :194 (under a snapshot, so :203 starts from the same book) ──
        uint256 snap = vm.snapshotState();
        _custodyBurnerThreshold(e, address(curator), ":194");
        assertTrue(vm.revertToState(snap), "snapshot revert failed");
        // ── gas burner inside :203 ──
        _custodyBurnerThreshold(e, address(sGrove), ":203");
    }

    struct CustodyExpect {
        uint256 armId;
        bytes32 evidence;
        uint256 loss;
        uint256 supplyBefore;
        uint256 backingBefore;
        uint256 curatorAbsorbed;
        uint256 backstopCovered;
        uint256 seniorBurned;
        uint256 incidentId;
    }

    /// @dev The burner in one custody window (`from` -> ReserveManager): the exact minimum completing
    ///      budget, asserted from both sides, and the exact allocation at the threshold under the
    ///      deterministic custody incident id (topic-checked).
    function _custodyBurnerThreshold(CustodyExpect memory e, address from, string memory tag) internal {
        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(reserves), from, false);
        bytes memory call = abi.encodeCall(reserves.ratifyAndOpen, (e.armId, e.evidence, e.loss));
        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(reserves), call, address(0));
        emit log_named_uint(string(abi.encodePacked("custody ", tag, " burner: minimum completing budget")), threshold);
        assertGt(
            threshold,
            0,
            string(
                abi.encodePacked(
                    "custody ", tag, " burner: some budget at or under the block limit completes the cascade"
                )
            )
        );
        assertGt(
            threshold,
            5_000_000,
            string(abi.encodePacked("custody ", tag, " burner: the burner forces an oversized budget"))
        );
        _assertHookFloorRevert(
            failure, string(abi.encodePacked("custody ratifyAndOpen one step under the ", tag, " threshold"))
        );
        _assertCustodyLossUnabsorbed(
            e.supplyBefore,
            e.backingBefore,
            string(abi.encodePacked("after the under-threshold ", tag, " burner attempts"))
        );

        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossAllocated(e.incidentId, e.loss, 0, e.curatorAbsorbed, e.backstopCovered, e.seniorBurned, 0);
        (bool ok, bytes memory data) = address(reserves).call{gas: threshold}(call);
        assertTrue(
            ok,
            string(abi.encodePacked("custody ", tag, " burner at the threshold must complete; got ", vm.toString(data)))
        );
        (uint256 openedId,) = abi.decode(data, (uint256, uint256));
        assertEq(openedId, e.incidentId, "the incident id the reserve opened is the one the event carried");
        assertEq(hostile.usdfrHookFires(), 1, string(abi.encodePacked("the burner ran exactly once, inside ", tag)));
        assertEq(curator.poolBalance(FILM), 0, "layer 1 exhausted");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 exhausted");
        assertEq(e.supplyBefore - usdfr.totalSupply(), e.loss, "exactly the recognised loss left supply");
        assertEq(e.backingBefore - reserves.totalBackingValue(), e.loss, "backing fell by exactly the custody loss");
        assertEq(reserves.reserveDeficit(), 0, "no residual deficit latched");
    }

    /// @notice ReserveRoundingLib.sol:164, reached through `declareDefault` one day after funding,
    ///         when the interpolated segment exceeds the canonical grid entitlement by
    ///         887,750,154,989 wei and the reserve allocates that sub-unit loss through the cascade.
    ///         One wei during the curator leg reverts `AccrualRounding_DeltaMismatch(6, ...)`, from
    ///         the token hook and equally from the curator's `onCuratorLoss` hook (CuratorModule.sol
    ///         :628, inside the `absorbLoss` frame the window straddles). Either way the DEFAULT
    ///         DECLARATION itself reverts, so the class freeze never arms.
    ///         The gas burner inside :164 is then measured like every other window: the exact
    ///         minimum completing budget is searched and asserted from both sides. One step under it
    ///         the declaration reverts `PointsHook_InsufficientGas` at the reserve's burn of the
    ///         absorbed amount, so this window is bricked below its threshold exactly like the
    ///         others; `_forwardGas` (retain max(1/8, 450,000) at each forwarded call) narrows the
    ///         griefing band (measured 3.2x the benign declaration here against 4.3x with the
    ///         retention weakened to 1/64) but does not close it, and nothing here credits it with
    ///         more than that. The lower bound asserted, over twice the benign cost, is live: a cap
    ///         on the forwarded gas collapses the threshold under it.
    function test_atk_oneWeiInsideTheRoundingAllocationWindows() public onFork {
        _armWeiDonor();

        // ── :164, the wei from the token hook ──
        uint256 tokenId = _roundingBook(300_000e18, 500_000e18);
        (uint256 roundingLoss, uint256 benignCost) = _benignRounding(tokenId);
        assertEq(roundingLoss, 887_750_154_989, "the rounding instant is pinned to the fork timestamp");
        emit log_named_uint("rounding benign declareDefault cost", benignCost);
        uint256 rmBefore = usdfr.balanceOf(address(reserves));
        bytes32 payload = keccak256(abi.encode(tokenId, keccak256("mw-rounding")));
        _attest(tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, payload);

        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(reserves), address(curator), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveRoundingLib.AccrualRounding_DeltaMismatch.selector,
                uint8(6),
                rmBefore + roundingLoss,
                rmBefore + roundingLoss + 1
            )
        );
        defaultManager.declareDefault(tokenId, keccak256("mw-rounding"));
        assertEq(curator.poolBalance(FILM), 300_000e18, "no layer-1 capital moved in the reverted declaration");
        assertEq(curator.unresolvedDefaults(FILM), 0, "the class freeze never armed: the declaration was lost");

        // ── :164, the wei from the curator hook (CuratorModule.sol:628, inside absorbLoss) ──
        usdfr.setPointsModule(address(points));
        curator.setPointsModule(address(hostile));
        hostile.configureCuratorDonation(address(reserves));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveRoundingLib.AccrualRounding_DeltaMismatch.selector,
                uint8(6),
                rmBefore + roundingLoss,
                rmBefore + roundingLoss + 1
            )
        );
        defaultManager.declareDefault(tokenId, keccak256("mw-rounding"));
        assertEq(curator.poolBalance(FILM), 300_000e18, "no layer-1 capital moved in the curator-hook attempt");
        assertEq(curator.unresolvedDefaults(FILM), 0, "the class freeze never armed after the curator-hook attempt");
        assertEq(hostile.curatorHookFires(), 0, "the curator hook's record rolled back with the declaration");
        curator.setPointsModule(address(points));
        _armWeiDonor();

        // ── gas burner inside :164: the exact threshold, from both sides ──
        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(reserves), address(curator), false);
        bytes memory call = abi.encodeCall(defaultManager.declareDefault, (tokenId, keccak256("mw-rounding")));
        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(defaultManager), call, address(0));
        emit log_named_uint("rounding :164 burner: minimum completing budget", threshold);
        assertGt(
            threshold, 0, "rounding :164 burner: some budget at or under the block limit completes the declaration"
        );
        assertGt(
            threshold, 2 * benignCost, "rounding :164 burner: the burner forces a budget over twice the benign cost"
        );
        _assertHookFloorRevert(failure, "rounding declareDefault one step under the :164 threshold");
        assertEq(curator.poolBalance(FILM), 300_000e18, "no layer-1 capital moved in the under-threshold attempts");
        assertEq(curator.unresolvedDefaults(FILM), 0, "the class freeze never armed in the under-threshold attempts");

        (bool ok, bytes memory data) = address(defaultManager).call{gas: threshold}(call);
        assertTrue(
            ok, string(abi.encodePacked("rounding :164 burner at the threshold must complete; got ", vm.toString(data)))
        );
        assertEq(hostile.usdfrHookFires(), 1, "the burner ran exactly once, inside :164");
        assertEq(curator.poolBalance(FILM), 300_000e18 - roundingLoss, "layer 1 absorbed exactly the rounding loss");
        assertEq(curator.unresolvedDefaults(FILM), 1, "the declaration landed");
    }

    /// @notice ReserveRoundingLib.sol:181 in isolation: no curator capital, so the rounding loss is
    ///         offered to sGROVE and the wei lands during its delivery: `AccrualRounding_DeltaMismatch
    ///         (9, ...)` and the declaration is lost. The burner inside :181 is threshold-searched and
    ///         asserted from both sides with the same lower bound as :164 (measured 3.1x the benign
    ///         declaration; 3.9x with the retention weakened to 1/64); one step under the threshold
    ///         the declaration reverts `PointsHook_InsufficientGas` at the reserve's burn.
    function test_atk_oneWeiInsideTheRoundingBackstopWindow() public onFork {
        _armWeiDonor();
        uint256 tokenId = _roundingBook(0, 500_000e18);
        (uint256 roundingLoss, uint256 benignCost) = _benignRounding(tokenId);
        assertEq(roundingLoss, 887_750_154_989, "the rounding instant is pinned to the fork timestamp");
        emit log_named_uint("rounding benign declareDefault cost, empty curator", benignCost);
        assertEq(curator.poolBalance(FILM), 0, "precondition: layer 1 is empty");
        uint256 rmBefore = usdfr.balanceOf(address(reserves));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, keccak256("mw-r2")))
        );

        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(reserves), address(sGrove), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveRoundingLib.AccrualRounding_DeltaMismatch.selector,
                uint8(9),
                rmBefore + roundingLoss,
                rmBefore + roundingLoss + 1
            )
        );
        defaultManager.declareDefault(tokenId, keccak256("mw-r2"));
        assertEq(sGrove.coverageReserve(), 500_000e18, "no layer-2 reserve moved in the reverted declaration");
        assertEq(curator.unresolvedDefaults(FILM), 0, "the class freeze never armed: the declaration was lost");

        // ── gas burner inside :181: the exact threshold, from both sides ──
        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(reserves), address(sGrove), false);
        bytes memory call = abi.encodeCall(defaultManager.declareDefault, (tokenId, keccak256("mw-r2")));
        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(defaultManager), call, address(0));
        emit log_named_uint("rounding :181 burner: minimum completing budget", threshold);
        assertGt(
            threshold, 0, "rounding :181 burner: some budget at or under the block limit completes the declaration"
        );
        assertGt(
            threshold, 2 * benignCost, "rounding :181 burner: the burner forces a budget over twice the benign cost"
        );
        _assertHookFloorRevert(failure, "rounding declareDefault one step under the :181 threshold");
        assertEq(sGrove.coverageReserve(), 500_000e18, "no layer-2 reserve moved in the under-threshold attempts");
        assertEq(curator.unresolvedDefaults(FILM), 0, "the class freeze never armed in the under-threshold attempts");

        (bool ok, bytes memory data) = address(defaultManager).call{gas: threshold}(call);
        assertTrue(
            ok, string(abi.encodePacked("rounding :181 burner at the threshold must complete; got ", vm.toString(data)))
        );
        assertEq(hostile.usdfrHookFires(), 1, "the burner ran exactly once, inside :181");
        assertEq(sGrove.coverageReserve(), 500_000e18 - roundingLoss, "layer 2 absorbed exactly the rounding loss");
        assertEq(curator.unresolvedDefaults(FILM), 1, "the declaration landed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4, I3 liveness of the under-backed exit: the FLOOR versus the nested window.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `MintRedeemController._drawJuniorForExit` measures the manager's balance across
    ///         `drawForSeniorExit` as a FLOOR (SWEEP-2 S2-F5). One wei during the curator leg is
    ///         tolerated: the exit settles at the same price as the benign run and the wei sits at
    ///         the manager unburned. But `drawForSeniorExit` reaches `coverDelegate`, whose STRICT
    ///         window is nested inside the floor: one wei during sGROVE's leg reverts the exit with
    ///         `DefaultManager_BackstopContractViolated`, so every under-backed exit large enough to
    ///         reach layer two is bricked by the same module S2-F5 was written to disarm.
    function test_atk_exitDrawFloorToleratesTheWeiButTheNestedLayerTwoWindowDoesNot() public onFork {
        uint256 pool = 20_000e18;
        _exitBook(pool, 400_000e18, 300_000e18);
        uint256 redeemAmount = 1_000_000e18;

        // The draw target the controller will compute, from the same reads it uses.
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 deficit = supply - backing;
        uint256 target = Math.mulDiv(redeemAmount, deficit, backing, Math.Rounding.Ceil);
        if (target > deficit) target = deficit;
        assertGt(target, pool, "precondition: the exit draw must reach layer two");
        uint256 residual = target - pool;

        // Benign reference, measured with the PRODUCTION points module wired (the hostile module is
        // installed only after this snapshot is taken, so the reference carries no double at all).
        assertEq(usdfr.pointsModule(), address(points), "control: the production module is wired for the reference");
        uint256 snap = vm.snapshotState();
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit SeniorExitDrawn(target, pool, residual);
        vm.prank(alice);
        uint256 benignCost = gasleft();
        uint256 benignOut = controller.redeem(redeemAmount, 0, block.timestamp);
        benignCost -= gasleft();
        assertGt(benignOut, 0, "control: the under-backed exit settles under the production module");
        assertTrue(vm.revertToState(snap), "snapshot revert failed");
        emit log_named_uint("exit benign redeem cost, production points module", benignCost);

        // ── the FLOOR: wei during the curator leg is tolerated ──
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(curator), false);
        _armWeiDonor();
        uint256 dmBefore = usdfr.balanceOf(address(defaultManager));
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit SeniorExitDrawn(target, pool, residual);
        vm.prank(alice);
        uint256 weiOut = controller.redeem(redeemAmount, 0, block.timestamp);
        assertEq(hostile.usdfrHookFires(), 1, "the module acted once, during the curator delivery");
        assertEq(weiOut, benignOut, "S2-F5 in force: the exit settles at the benign price despite the wei");
        assertEq(
            usdfr.balanceOf(address(defaultManager)), dmBefore + 1, "the donated wei sits at the manager, unburned"
        );
        assertEq(curator.poolBalance(FILM), 0, "layer 1 drawn to exhaustion for the exit");
        assertEq(sGrove.coverageReserve(), 400_000e18 - residual, "layer 2 drawn exactly the residual");
        assertTrue(vm.revertToState(snap), "snapshot revert failed");

        // ── the NESTED strict window: wei during sGROVE's leg bricks the exit ──
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(sGrove), false);
        usdfr.setPointsModule(address(hostile));
        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentLedger.DefaultManager_BackstopContractViolated.selector, residual, residual, residual + 1
            )
        );
        controller.redeem(redeemAmount, 0, block.timestamp);
        assertEq(usdfr.balanceOf(alice), aliceBefore, "the exit did not settle: alice still holds her USDfr");
        assertEq(curator.poolBalance(FILM), pool, "no layer-1 capital moved in the reverted exit");
        assertEq(sGrove.coverageReserve(), 400_000e18, "no layer-2 reserve moved in the reverted exit");

        // ── the gas burner inside the nested window: the exact threshold, from both sides ──
        hostile.configure(WindowHostilePointsModule.Mode.BurnGas, address(defaultManager), address(sGrove), false);
        bytes memory call = abi.encodeWithSignature("redeem(uint256,uint256,uint256)", redeemAmount, 0, block.timestamp);
        (uint256 threshold, bytes memory failure) = _minimumCompletingBudget(address(controller), call, alice);
        emit log_named_uint("exit in-window burner: minimum completing budget", threshold);
        assertGt(threshold, 0, "exit burner: some budget at or under the block limit settles the exit");
        assertGt(threshold, 3 * benignCost, "exit burner: the burner forces a budget over three times the benign cost");
        _assertHookFloorRevert(failure, "exit redeem one step under the threshold");
        assertEq(usdfr.balanceOf(alice), aliceBefore, "the exit did not settle under the threshold");

        vm.prank(alice);
        (bool ok, bytes memory data) = address(controller).call{gas: threshold}(call);
        assertTrue(ok, string(abi.encodePacked("exit burner at the threshold must complete; got ", vm.toString(data))));
        assertEq(abi.decode(data, (uint256)), benignOut, "the exit settles at the benign price at the threshold");
        assertEq(hostile.usdfrHookFires(), 1, "the burner ran exactly once, inside the nested window");
    }

    // ─────────────────────────────────────────────────────────────────────
    // The retained `absorbReserveLoss` entry: unreachable in production, characterised anyway.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `DefaultManager.absorbReserveLoss` is an ABI retained for compatibility that no
    ///         production module calls: the live custody cascade runs inside the ReserveManager.
    ///         Executed proof: the live custody path never moves a wei through the manager, and the
    ///         entry refuses every caller but the reserve. The window is then characterised by
    ///         impersonating the reserve (a test capability, not a protocol path): one wei during
    ///         sGROVE's delivery reverts `DefaultManager_BackstopContractViolated`.
    function test_atk_absorbReserveLossIsUnreachableAndItsWindowIsCharacterised() public onFork {
        (uint256 armId, bytes32 evidence, uint256 loss) = _custodyLossBook(300_000e18, 500_000e18);

        // The live custody cascade: the manager's USDfr balance is untouched throughout.
        uint256 snap = vm.snapshotState();
        uint256 dmBefore = usdfr.balanceOf(address(defaultManager));
        (uint256 openedId,) = reserves.ratifyAndOpen(armId, evidence, loss);
        assertEq(
            usdfr.balanceOf(address(defaultManager)), dmBefore, "live custody cascade never routes through the manager"
        );
        assertEq(curator.poolBalance(FILM), 0, "the live cascade did draw layer 1, inside the reserve");
        assertEq(openedId, type(uint256).max - armId, "custody incident id derives from the arm");
        assertTrue(vm.revertToState(snap), "snapshot revert failed");

        // Every non-reserve caller is refused, including the servicer/admin harness itself.
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, ops)
        );
        defaultManager.absorbReserveLoss(openedId, loss);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, carol)
        );
        defaultManager.absorbReserveLoss(openedId, loss);

        // Characterise the window under impersonation of the reserve.
        _armWeiDonor();
        hostile.configure(WindowHostilePointsModule.Mode.DonateWei, address(defaultManager), address(sGrove), false);
        uint256 residual = loss - 300_000e18;
        vm.prank(address(reserves));
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentLedger.DefaultManager_BackstopContractViolated.selector, residual, 500_000e18, 500_000e18 + 1
            )
        );
        defaultManager.absorbReserveLoss(openedId, loss);
        assertEq(curator.poolBalance(FILM), 300_000e18, "nothing moved in the reverted compatibility call");
        assertEq(sGrove.coverageReserve(), 500_000e18, "nothing moved in the reverted compatibility call");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Post `amount` (18-dec) curator first-loss on FILM AS ops (the anchor curator approved on
    ///      every class by the deploy script).
    function _postFirstLossOps(uint256 classId, uint256 amount) internal {
        _mintFromUSDC(ops, amount / 1e12);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
    }

    /// @dev Fund the sGROVE coverage reserve (layer 2) with `amount` (18-dec) AS ops.
    function _fundBackstopOps(uint256 amount) internal {
        _mintFromUSDC(ops, amount / 1e12);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
    }

    /// @dev Originate and fund a FILM facility under explicit concentration keys so two facilities
    ///      can coexist. Mirrors the fixture's `_originateAndFund`.
    function _originateAndFundFilm(bytes32 borrowerId, bytes32 stateId, uint256 principal)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(tokenId, borrowerId, stateId, principal, 7500, maturity, keccak256("ucc-ref"));
        vm.prank(ops);
        uint256 id =
            bridge.originate(ops, _forkTerms(borrowerId, stateId, principal, 7500, maturity, keccak256("ucc-ref")));
        require(id == tokenId, "ATK_MW: tokenId drift");
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    /// @dev Senior 4,000,000 staked; layer 1 `firstLoss`; layer 2 `coverage`; a 1,000,000 FILM
    ///      facility declared in default at the funding instant (no accrued interest, no rounding).
    function _facilityCascadeBook(uint256 firstLoss, uint256 coverage) internal returns (uint256 tokenId) {
        _mintFromUSDC(bob, 5_000_000e6);
        _stake(bob, 4_000_000e18);
        _postFirstLossOps(FILM, firstLoss);
        _fundBackstopOps(coverage);
        tokenId = _originateAndFund(1_000_000e18);
        _declareDefault(tokenId, keccak256("mw-default"));
    }

    /// @dev Senior 4,000,000 staked; layer 1 `firstLoss`; layer 2 `coverage`; a 1,000,000 USDC
    ///      custody theft armed by the guardian. Returns the arm the reserve admin must ratify.
    function _custodyLossBook(uint256 firstLoss, uint256 coverage)
        internal
        returns (uint256 armId, bytes32 evidence, uint256 loss)
    {
        _mintFromUSDC(bob, 5_000_000e6);
        _stake(bob, 4_000_000e18);
        _postFirstLossOps(FILM, firstLoss);
        _fundBackstopOps(coverage);
        uint256 lossUnits = 1_000_000e6;
        loss = reserves.normalizeUSDC(lossUnits);
        deal(USDC, address(reserves), reserves.idleUSDC() - lossUnits);
        evidence = keccak256("mw-custody-theft");
        (armId,) = reserves.armReserveLossFreeze(evidence);
    }

    /// @dev A funded FILM facility aged `ROUNDING_WARP` so its declaration allocates a rounding loss.
    function _roundingBook(uint256 firstLoss, uint256 coverage) internal returns (uint256 tokenId) {
        _mintFromUSDC(bob, 5_000_000e6);
        _stake(bob, 4_000_000e18);
        if (firstLoss != 0) _postFirstLossOps(FILM, firstLoss);
        _fundBackstopOps(coverage);
        tokenId = _originateAndFund(1_000_000e18);
        _warp(ROUNDING_WARP);
    }

    /// @dev Under-backed book for the exit draw: alice holds 3,000,000 USDfr, layer 1 `firstLoss`,
    ///      layer 2 `coverage`, a 1,000,000 facility carrying a `mark` conservative impairment.
    function _exitBook(uint256 firstLoss, uint256 coverage, uint256 mark) internal returns (uint256 tokenId) {
        _mintFromUSDC(alice, 3_000_000e6);
        _postFirstLossOps(FILM, firstLoss);
        _fundBackstopOps(coverage);
        tokenId = _originateAndFund(1_000_000e18);
        reserves.recognizePrincipalImpairment(tokenId, mark, keccak256("mw-mark"));
        assertGt(controller.totalUSDfr(), controller.backingValue(), "precondition: under-backed");
    }

    /// @dev Installs the hostile module through the real DEFAULT_ADMIN setter: the
    ///      governance-compromise premise, exercised on the production path and nothing else.
    function _armWeiDonor() internal {
        usdfr.setPointsModule(address(hostile));
    }

    /// @dev Runs the declaration under a snapshot with the production module wired, reads the
    ///      `AccrualRoundingAllocated` amount and the gas the declaration itself cost, and reverts.
    ///      The hostile module is re-installed afterwards (it was wired before the snapshot).
    function _benignRounding(uint256 tokenId) internal returns (uint256 amount, uint256 cost) {
        uint256 snap = vm.snapshotState();
        hostile.configure(WindowHostilePointsModule.Mode.Idle, address(0), address(0), false);
        usdfr.setPointsModule(address(points));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, keccak256("mw-benign")))
        );
        vm.recordLogs();
        uint256 g = gasleft();
        (bool ok, bytes memory data) = address(defaultManager).call{gas: TX_BUDGET_30M}(
            abi.encodeCall(defaultManager.declareDefault, (tokenId, keccak256("mw-benign")))
        );
        cost = g - gasleft();
        assertTrue(
            ok, string(abi.encodePacked("control: the benign declaration must complete; got ", vm.toString(data)))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "AccrualRoundingAllocated(uint256,uint64,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reserves) || logs[i].topics.length == 0 || logs[i].topics[0] != topic) {
                continue;
            }
            uint256[7] memory v = abi.decode(logs[i].data, (uint256[7]));
            amount = v[0];
            seen = true;
        }
        assertTrue(seen, "the rounding allocation must be reached at the pinned instant");
        assertTrue(vm.revertToState(snap), "snapshot revert failed");
        usdfr.setPointsModule(address(hostile));
    }

    function _assertCustodyLossUnabsorbed(uint256 supplyBefore, uint256 backingBefore, string memory ctx)
        internal
        view
    {
        assertEq(usdfr.totalSupply(), supplyBefore, string(abi.encodePacked("supply untouched ", ctx)));
        assertEq(reserves.totalBackingValue(), backingBefore, string(abi.encodePacked("backing untouched ", ctx)));
        assertEq(curator.poolBalance(FILM), 300_000e18, string(abi.encodePacked("layer 1 untouched ", ctx)));
        assertEq(sGrove.coverageReserve(), 500_000e18, string(abi.encodePacked("layer 2 untouched ", ctx)));
        assertTrue(reserves.reserveLossExitsLocked(), string(abi.encodePacked("the arm still stands ", ctx)));
    }

    /// @dev Binary-searches, to a 1,000-gas step, the smallest transaction budget at or under the
    ///      block gas limit at which `call` completes. Every probe runs under a snapshot that is
    ///      reverted, so the search leaves no state (and no hostile-module counters) behind.
    ///      Completion is monotone in the budget for a burner that always spends to its floor: more
    ///      gas only ever leaves each frame a larger EIP-150 remainder. Returns the threshold (zero
    ///      if the block limit itself fails) and the revert data observed one step under it (or at
    ///      the block limit when nothing completes).
    function _minimumCompletingBudget(address target, bytes memory call, address caller)
        internal
        returns (uint256 threshold, bytes memory failure)
    {
        uint256 step = 1_000;
        uint256 hi = block.gaslimit;
        (bool ok, bytes memory data) = _probe(target, call, caller, hi);
        if (!ok) return (0, data);
        uint256 lo = 1_000_000;
        (ok, data) = _probe(target, call, caller, lo);
        require(!ok, "the search floor already completes: raise the burner or lower the floor");
        failure = data;
        // Invariant: lo fails, hi completes.
        while (hi - lo > step) {
            uint256 mid = lo + (hi - lo) / 2;
            (ok, data) = _probe(target, call, caller, mid);
            if (ok) {
                hi = mid;
            } else {
                lo = mid;
                failure = data;
            }
        }
        threshold = hi;
    }

    function _probe(address target, bytes memory call, address caller, uint256 budget)
        private
        returns (bool ok, bytes memory data)
    {
        uint256 snap = vm.snapshotState();
        if (caller != address(0)) vm.prank(caller);
        (ok, data) = target.call{gas: budget}(call);
        require(vm.revertToState(snap), "probe snapshot revert failed");
    }

    function _decodeTwoWords(bytes memory data) internal pure returns (uint256 a, uint256 b) {
        require(data.length == 4 + 64, "unexpected revert data length");
        assembly ("memory-safe") {
            a := mload(add(data, 0x24))
            b := mload(add(data, 0x44))
        }
    }
}
