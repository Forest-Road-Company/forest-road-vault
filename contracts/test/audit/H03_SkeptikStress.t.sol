// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CuratorModule} from "../../src/CuratorModule.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev Durable skeptic stress rig. The shipped H-03 handler escalates any loss past
///      half the pool to a FULL wipe, so a partial absorption can at most halve the pool and the
///      renormalisation divisor D stays tiny. The 2-wei tolerance is derived for GENERAL D, so
///      the shipped campaign never exercises the regime where the derivation is tightest.
///      This handler removes that cap: partial losses run to 1 wei of standing balance, three curators
///      share the pool, and posts go down to 1 wei. It records the MAXIMUM observed
///      overstatement rather than asserting a guessed bound.
contract H03StressHandler is Test {
    CuratorModule internal curator;
    PointsModule internal points;
    IERC20 internal usdfr;

    address[3] public curators;
    uint256[2] public classIds;

    /// @dev Largest observed (cachedBalance - livePostedOf) over an UNFROZEN position.
    uint256 public maxUnfrozenOverstatement;
    /// @dev Largest observed over ANY position (diagnostic; frozen ones are skipped by the invariant).
    uint256 public maxAnyOverstatement;
    /// @dev Largest normalisation shift actually exercised (D = 2**shift).
    uint256 public maxShift;
    /// @dev Number of postFirstLoss calls that fired a renormalisation.
    uint256 public normalisations;
    /// @dev Number of those that fired with D > 2 (the regime the shipped handler cannot reach).
    uint256 public deepNormalisations;

    uint256 internal constant MAX_POOL_SHARES = 1e50;

    constructor(
        CuratorModule curator_,
        PointsModule points_,
        IERC20 usdfr_,
        address[3] memory cs,
        uint256[2] memory ids
    ) {
        curator = curator_;
        points = points_;
        usdfr = usdfr_;
        curators = cs;
        classIds = ids;
    }

    function curatorCount() external pure returns (uint256) {
        return 3;
    }

    function classCount() external pure returns (uint256) {
        return 2;
    }

    function curatorAt(uint256 i) external view returns (address) {
        return curators[i];
    }

    function classAt(uint256 i) external view returns (uint256) {
        return classIds[i];
    }

    // ── observation ──────────────────────────────────────────────────────

    function _observe() internal {
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                uint256 t = points.curatorTracked(curators[i], classIds[j]);
                uint256 p = curator.postedOf(classIds[j], curators[i]);
                if (t <= p) continue;
                uint256 d = t - p;
                if (d > maxAnyOverstatement) maxAnyOverstatement = d;
                (bool frozen,) = points.curatorFreezeStatus(curators[i], classIds[j]);
                if (!frozen && d > maxUnfrozenOverstatement) maxUnfrozenOverstatement = d;
            }
        }
    }

    /// @dev Records the divisor the NEXT post in this class will renormalise by.
    function _recordPendingShift(uint256 cls) internal {
        uint256 b = curator.poolBalance(cls);
        if (b == 0) return;
        uint256 ratio = curator.poolShares(cls) / b;
        if (ratio < 2) return;
        uint256 shift = 0;
        while ((uint256(1) << (shift + 1)) <= ratio) ++shift;
        normalisations += 1;
        if (shift > 1) deepNormalisations += 1;
        if (shift > maxShift) maxShift = shift;
    }

    // ── ops ──────────────────────────────────────────────────────────────

    function post(uint256 cSeed, uint256 clsSeed, uint256 amount) external {
        address who = curators[cSeed % 3];
        uint256 cls = classIds[clsSeed % 2];
        if (curator.poolShares(cls) > MAX_POOL_SHARES) return;
        uint256 bal = usdfr.balanceOf(who);
        if (bal == 0) return;
        // 1 wei floor: the rounding regime, not the realistic-size regime.
        amount = bound(amount, 1, bal > 1e18 ? 1e18 : bal);
        _recordPendingShift(cls);
        vm.prank(who);
        curator.postFirstLoss(cls, amount);
        _observe();
    }

    function withdraw(uint256 cSeed, uint256 clsSeed, uint256 amount) external {
        address who = curators[cSeed % 3];
        uint256 cls = classIds[clsSeed % 2];
        uint256 posted = curator.postedOf(cls, who);
        if (posted == 0) return;
        uint256 free = curator.headroom(cls);
        uint256 cap = posted < free ? posted : free;
        if (cap == 0) return;
        amount = bound(amount, 1, cap);
        vm.prank(who);
        curator.withdrawFirstLoss(cls, amount);
        _observe();
    }

    /// @dev THE DIFFERENCE FROM THE SHIPPED HANDLER: no 50% escalation. A partial absorption may
    ///      take the pool down to a single wei, which is what produces a large renormalisation
    ///      divisor on the following post.
    function absorbLoss(uint256 clsSeed, uint256 loss) external {
        uint256 cls = classIds[clsSeed % 2];
        uint256 pool = curator.poolBalance(cls);
        if (pool == 0) return;
        loss = bound(loss, 1, pool);
        curator.absorbLoss(cls, loss);
        _observe();
    }

    /// @dev Deliberately biased toward deep-but-partial absorptions (leaves 1..1e6 wei standing),
    ///      which is exactly the state that yields D >> 2.
    function absorbDeepLoss(uint256 clsSeed, uint256 leave) external {
        uint256 cls = classIds[clsSeed % 2];
        uint256 pool = curator.poolBalance(cls);
        if (pool < 2) return;
        leave = bound(leave, 1, pool - 1 > 1000 ? 1000 : pool - 1);
        curator.absorbLoss(cls, pool - leave);
        _observe();
    }

    /// @dev A partial absorption that NEVER wipes the pool. A wipe advances `pool.round` and
    ///      resets shares, destroying the distressed-ratio state before a normalisation can fire;
    ///      that is why the first stress pass produced only 13 normalisations in 32,768 calls.
    ///      This keeps the class permanently in the partial-loss regime.
    function absorbPartialLoss(uint256 clsSeed, uint256 loss) external {
        uint256 cls = classIds[clsSeed % 2];
        uint256 pool = curator.poolBalance(cls);
        if (pool < 2) return;
        loss = bound(loss, 1, pool - 1);
        curator.absorbLoss(cls, loss);
        _observe();
    }

    /// @dev Dust-sized posts. Rounding error is absolute (wei), so the SMALLEST pools are where a
    ///      1-2 wei drift is most likely to compound into something larger.
    function postDust(uint256 cSeed, uint256 clsSeed, uint256 amount) external {
        address who = curators[cSeed % 3];
        uint256 cls = classIds[clsSeed % 2];
        if (curator.poolShares(cls) > MAX_POOL_SHARES) return;
        if (usdfr.balanceOf(who) < 1_000_000) return;
        amount = bound(amount, 1, 1_000_000);
        _recordPendingShift(cls);
        vm.prank(who);
        curator.postFirstLoss(cls, amount);
        _observe();
    }

    function pokeCheckpoint(uint256 cSeed) external {
        points.checkpoint(curators[cSeed % 3]);
        _observe();
    }

    function pokeReconcile(uint256 cSeed) external {
        address who = curators[cSeed % 3];
        points.reconcile(who);
        for (uint256 j = 0; j < 2; ++j) {
            assertEq(
                points.curatorTracked(who, classIds[j]),
                curator.postedOf(classIds[j], who),
                "RECONCILE DID NOT SNAP THE CACHED BALANCE TO LIVE postedOf"
            );
        }
        _observe();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 120 days));
        _observe();
    }
}

/// @dev Stress rig for the proposed RENORMALISATION_DUST_WEI = 2 tolerance.
contract H03SkeptikStress is CreditLayerFixture {
    PointsModule internal points;
    H03StressHandler internal handler;

    address internal thirdCurator = makeAddr("thirdCurator");

    /// @dev The tolerance under attack.
    uint256 internal constant RENORMALISATION_DUST_WEI = 2;

    function setUp() public override {
        super.setUp();
        points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );

        address[3] memory cs = [anchorCurator, secondCurator, thirdCurator];
        uint256[2] memory ids = [Config.CLASS_FILM_TAX_CREDITS, Config.CLASS_RENEWABLE_ENERGY];

        handler = new H03StressHandler(curator, points, IERC20(address(usdfr)), cs, ids);

        vm.startPrank(admin);
        points.setCuratorModule(address(curator));
        curator.setPointsModule(address(points));
        curator.grantRole(Roles.CREDIT_ROLE, address(handler));
        for (uint256 i = 0; i < 3; ++i) {
            curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, cs[i], true);
            curator.setCuratorApproved(Config.CLASS_RENEWABLE_ENERGY, cs[i], true);
        }
        vm.stopPrank();
        vm.prank(complianceAdmin);
        compliance.setAllowed(thirdCurator, true);

        for (uint256 i = 0; i < 3; ++i) {
            _mintUSDfrTo(cs[i], 20_000_000e18);
            vm.prank(cs[i]);
            usdfr.approve(address(curator), type(uint256).max);
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = H03StressHandler.post.selector;
        selectors[1] = H03StressHandler.postDust.selector;
        selectors[2] = H03StressHandler.withdraw.selector;
        selectors[3] = H03StressHandler.absorbPartialLoss.selector;
        selectors[4] = H03StressHandler.absorbDeepLoss.selector;
        selectors[5] = H03StressHandler.pokeCheckpoint.selector;
        selectors[6] = H03StressHandler.pokeReconcile.selector;
        selectors[7] = H03StressHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Deterministic replay of the nine-call sequence shrunk from the tolerance-one
    ///      negative control (seed `H03-STRESS-TOL01`). It reaches two chained normalisations
    ///      without an intervening loss notification and leaves an unfrozen raw Points cache
    ///      exactly two wei above the live posted claim. This is the non-vacuity witness for the
    ///      two-wei bound; reducing the bound to one makes the final assertion fail.
    function test_skeptik_twoWeiWitnessProvesToleranceOneInsufficient() public {
        handler.postDust(
            2533053366312632727692781631308860051448741076595635989099193092011098492230, 0, type(uint256).max
        );
        handler.absorbDeepLoss(11526029825745540982827950178653462083289418618401598610956, 14286161358148437529374260);
        handler.post(894675389, 145874966945308122165886742922, 155659306188886011957210179136193477);
        handler.post(
            106853333309298, 23222918705323677423632295739570604227689342945253717162717914256, 634958232206557295
        );
        handler.withdraw(4754, 17744, 5573035233440673466300451813937);
        handler.post(
            0,
            73310092777054340843223399569013156678730548820,
            6411558736212462973188586043807046101184773050298062422494332352
        );
        handler.absorbDeepLoss(67706495945808739739809168381913694880, 6227166482039512786493865745288);
        handler.pokeReconcile(1143186725998893676251895177104537);
        handler.post(6288876234046273249941306300491382924120106444213109618692894531, 0, 0);

        assertGe(handler.deepNormalisations(), 2, "WITNESS DID NOT CHAIN DEEP NORMALISATIONS");
        assertEq(
            handler.maxUnfrozenOverstatement(),
            RENORMALISATION_DUST_WEI,
            "WITNESS DID NOT REQUIRE THE TWO-WEI TOLERANCE"
        );
        for (uint256 j = 0; j < handler.classCount(); ++j) {
            uint256 cls = handler.classAt(j);
            uint256 sum;
            for (uint256 i = 0; i < handler.curatorCount(); ++i) {
                sum += curator.postedOf(cls, handler.curatorAt(i));
            }
            assertLe(sum, curator.poolBalance(cls), "WITNESS BROKE POOL CLAIM CONSERVATION");
        }
    }

    /// @dev Deterministic replay of the exact twelve-call corpus Foundry persisted when
    ///      `invariant_skeptik_claimsNeverExceedPool` found a one-wei aggregate over-claim in the
    ///      first four-input default run. Keeping the sequence in-tree prevents a metadata/cache
    ///      change from hiding the already-discovered discriminator.
    function test_skeptik_savedAggregateCorpusRemainsPoolConserving() public {
        handler.post(1030490419, 8168, 5700);
        handler.absorbDeepLoss(
            17198528310115320537335372346075254881785301325802812967946, 8182963639697755773325946020639262
        );
        handler.absorbDeepLoss(33801559593845700094815346899429671104352873085946679956786687838830353100252, 13529);
        handler.absorbPartialLoss(21566, 10564);
        handler.absorbDeepLoss(1104, 2010);
        handler.absorbPartialLoss(
            7056651489537972304130923085925880736912691829476516118,
            1833770232318377734656818760014763977291608078694736190
        );
        handler.absorbPartialLoss(257438542756207371400148134156022, 534606276987231755476473746331929836133153785);
        handler.post(
            141196141720286812328605478593673793773705921588828222,
            3937758093031473080371399541372,
            2467443674161803184096367580569
        );
        handler.absorbDeepLoss(11222, 7043);
        handler.absorbDeepLoss(842873545243225591418947920246556863102616, 49536683165353027770752562);
        handler.absorbDeepLoss(13002, 2051);
        handler.postDust(
            1672044684509708850234097368423525903044209791402,
            490949866746769858695198070262,
            34310348282736832560388431791628422500379026833555391598475266707555484973
        );

        invariant_skeptik_claimsNeverExceedPool();
    }

    /// @dev The proposed tolerance, under a campaign that actually reaches D >> 2.
    function invariant_skeptik_toleranceHolds() public view {
        for (uint256 i = 0; i < handler.curatorCount(); ++i) {
            address w = handler.curatorAt(i);
            for (uint256 j = 0; j < handler.classCount(); ++j) {
                uint256 cls = handler.classAt(j);
                (bool frozen,) = points.curatorFreezeStatus(w, cls);
                if (frozen) continue;
                assertLe(
                    points.curatorTracked(w, cls),
                    curator.postedOf(cls, w) + RENORMALISATION_DUST_WEI,
                    "TOLERANCE=2 BREACHED UNDER DEEP-LOSS STRESS"
                );
            }
        }
    }

    /// @dev Value conservation (CLAUDE.md 1.3): the sum of every curator's live claim can never
    ///      exceed the pool that backs it. This is the property the rejected floor/ceil candidate
    ///      broke; it must survive the deep-loss regime under the SHIPPED rounding.
    function invariant_skeptik_claimsNeverExceedPool() public view {
        for (uint256 j = 0; j < handler.classCount(); ++j) {
            uint256 cls = handler.classAt(j);
            uint256 sum;
            for (uint256 i = 0; i < handler.curatorCount(); ++i) {
                sum += curator.postedOf(cls, handler.curatorAt(i));
            }
            assertLe(sum, curator.poolBalance(cls), "AGGREGATE CURATOR CLAIM EXCEEDS THE POOL");
        }
    }

    /// @dev Surfaces what the campaign ACTUALLY reached, so a pass cannot be mistaken for
    ///      coverage it does not have. Runs once, after the campaign, with the ghosts populated.
    function afterInvariant() public view {
        console.log("max UNFROZEN overstatement (wei):", handler.maxUnfrozenOverstatement());
        console.log("max ANY overstatement (wei):", handler.maxAnyOverstatement());
        console.log("renormalisations fired:", handler.normalisations());
        console.log("  of which D > 2:", handler.deepNormalisations());
        console.log("max shift (D = 2**shift):", handler.maxShift());
    }
}
