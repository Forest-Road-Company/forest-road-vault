// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev End-to-end credit-layer lifecycles over the FULL protocol stack with the
///      production role topology (no test-era EOA credit grants): the brief's
///      integration flows "originate → attest → mint NFT → fund → repay → waterfall"
///      and "default → cascade → remedy" (CLAUDE.md §1.1), plus the ADR-0015
///      margin-call/liquidation fast path.
contract CreditLayerFlowTest is CreditLayerFixture {
    uint256 internal constant FILM = 1;

    function _stake(address who, uint256 usdcAmount) internal returns (uint256 shares) {
        _mintUSDfrTo(who, usdcAmount * 1e12); // mints fresh USDC, then USDfr
        vm.startPrank(who);
        usdfr.approve(address(vault), usdcAmount * 1e12);
        shares = vault.deposit(usdcAmount * 1e12, who);
        vm.stopPrank();
    }

    /// @notice Deposit → stake → originate → fund → amortize with interest → close →
    ///         curator exit. Yield accrues via the exchange
    ///         rate; every balance reconciles; backing holds throughout.
    function test_flow_performingLifecycle() public {
        // depositors and the anchor curator arrive
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        uint256 rate0 = vault.currentExchangeRate();

        // originate + fund a 1.5M film facility
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 1_500_000e18);
        _fundFacility(id, 1_500_000e18);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active));
        assertTrue(controller.backingInvariantHolds());

        // three amortizing payments: interest + principal
        uint256 rate = rate0;
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(block.timestamp + 90 days);
            _repay(id, 52_500e18, 500_000e18); // quarterly interest on 1.5M @14%
            assertGe(vault.currentExchangeRate(), rate, "rate never falls while performing");
            rate = vault.currentExchangeRate();
            assertTrue(controller.backingInvariantHolds());
        }
        assertGt(rate, rate0, "stakers actually earned yield");

        // facility closed: exposure and outstanding principal are zero
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.classExposure(FILM), 0);
        assertEq(registry.borrowerExposure(BORROWER_1), 0);

        // with zero exposure, all curator capital is free
        assertEq(curator.headroom(FILM), 1_000_000e18);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1_000_000e18);
        assertEq(usdfr.balanceOf(anchorCurator), 1_000_000e18, "curator made whole");
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice Default → acceleration → partial recovery via waterfall → shortfall
    ///         through the full three-layer cascade — each layer bearing exactly its
    ///         share, the exchange rate falling only at the explicit loss event.
    function test_flow_defaultRecoveryAndFullCascade() public {
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, FILM, 250_000e18);
        _mintUSDfrTo(bob, 100_000e18);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), 100_000e18); // seeded backstop

        uint256 id = _liveFilmFacility(1_000_000e18);
        _repay(id, 35_000e18, 0); // one performing payment first
        uint256 rateBeforeDefault = vault.currentExchangeRate();

        // default + acceleration (the on-chain half of UCC enforcement) — the
        // attested DefaultDeclared fact gates the declaration (Phase G)
        _attestDefault(id);
        vm.startPrank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        defaultManager.accelerate(id);
        vm.stopPrank();

        // the assigned receivable is sold into the secondary market for 600k
        _repay(id, 0, 600_000e18);
        assertEq(reserves.deployedTo(id), 400_000e18);
        assertEq(vault.currentExchangeRate(), rateBeforeDefault, "recovery is not a loss");

        // 400k shortfall: curator 250k -> backstop 100k -> depositors 50k
        uint256 vaultAssetsBefore = usdfr.balanceOf(address(vault));
        vm.prank(servicer);
        _realizeLoss(id, 400_000e18, FILM_REF);

        assertEq(curator.poolBalance(FILM), 0, "layer 1 wiped");
        assertEq(usdfr.balanceOf(address(backstopMock)), 0, "layer 2 drained");
        assertEq(vaultAssetsBefore - usdfr.balanceOf(address(vault)), 50_000e18, "layer 3 exact");
        assertLt(vault.currentExchangeRate(), rateBeforeDefault, "explicit loss moved the rate");
        assertEq(registry.classExposure(FILM), 0, "book cleaned");
        assertEq(reserves.deployedTo(id), 0);
        assertTrue(controller.backingInvariantHolds());

        // The final write-off is terminal; the NFT and LossRealized event retain the history.
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved));
    }

    /// @notice ADR-0015 fast path end-to-end: healthy → mark slide → margin call →
    ///         cure by top-up → deeper slide → liquidation → custodian proceeds →
    ///         residual shortfall through the cascade.
    function test_flow_mtmMarginCallCureThenLiquidation() public {
        uint256 DA = Config.CLASS_DIGITAL_ASSETS;
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, DA, 100_000e18);

        uint256 id = _originateDigital(500_000e18, 1_000_000e18); // 50% draw
        _fundFacility(id, 500_000e18);

        // crypto book slides: mark 750k → LTV 66.7% breaches the 65% margin call
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.marginCall(id);
        uint64 deadline = defaultManager.cureDeadline(id);
        assertEq(deadline, uint64(block.timestamp) + Config.DEFAULT_MARGIN_CURE_WINDOW);

        // desk tops up collateral within the window: fresh mark cures
        vm.warp(block.timestamp + 6 hours);
        _setValuation(id, 900_000e18, uint64(block.timestamp)); // 55.5%
        defaultManager.clearMarginCall(id);
        assertEq(defaultManager.cureDeadline(id), 0);

        // a gap move: mark 590k → LTV 84.7% ≥ 80% — immediate liquidation, no cure
        vm.warp(block.timestamp + 1 days);
        _setValuation(id, 590_000e18, uint64(block.timestamp));
        defaultManager.liquidate(id);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted));

        // custodian liquidates the pledged book: 460k recovered, attested in
        _repay(id, 0, 460_000e18);

        // 40k shortfall absorbed inside the class's first-loss — depositors whole
        uint256 rateBefore = vault.currentExchangeRate();
        vm.prank(servicer);
        _realizeLoss(id, 40_000e18, FILM_REF);
        assertEq(curator.poolBalance(DA), 60_000e18);
        assertEq(vault.currentExchangeRate(), rateBefore, "first-loss did its job");
        assertEq(registry.classExposure(DA), 0);
        assertEq(registry.borrowerExposure(BORROWER_DESK), 0, "related-party exposure closed");
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice The liquidity cycle (ADR-0010): deployment drains idle liquidity, the
    ///         queue throttles exits to what the treasury can actually honor, and
    ///         repayments re-open the gate — the QEV mechanic end-to-end.
    function test_flow_liquidityCycle_queueThrottledByDeployment() public {
        uint256 shares = _stake(alice, 1_000_000e6); // 1M staked
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 900_000e18);
        _fundFacility(id, 900_000e18); // deploys 900k of the 1M idle

        // alice queues her full exit; only limited stables remain idle, and the daily
        // heartbeat budget throttles the first fill.
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        queue.requestRedeem(shares);
        vm.stopPrank();

        uint256 firstBudget = queue.availableLiquidity();
        vm.warp(queue.eligibleToSettleAt(0));
        queue.closeEpoch(10);
        (, uint256 remaining, uint256 claimable,,) = queue.request(0);
        // idle stables = 1M in - 882k out (900k principal net of 18k fee retained @ 2% OID)
        assertEq(claimable, firstBudget, "throttled to configured daily liquidity");
        assertGt(remaining, 0, "the rest waits for the book to amortize");

        // the facility repays in full (+ interest): idle liquidity floods back, and
        // governance opens the per-epoch gate fully for the wind-down
        _repay(id, 30_000e18, 900_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(uint256(queue.epochEndsAt()) + 1);
        queue.closeEpoch(10);
        (, remaining, claimable,,) = queue.request(0);
        assertEq(remaining, 0, "fully served once liquidity returned");

        vm.prank(alice);
        uint256 assets = queue.claim(0); // accumulated: throttled fill + the rest
        // she exits with principal + her yield share, all the way to USDC
        assertGt(assets, 1_000_000e18, "principal plus yield through the cycle");
        vm.prank(alice);
        controller.redeem(assets);
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice Losses in one class never touch another class's first-loss pool.
    function test_flow_classIsolation_lossesDoNotCrossPools() public {
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_DIGITAL_ASSETS, 200_000e18);

        uint256 id = _liveFilmFacility(250_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _realizeLoss(id, 250_000e18, FILM_REF);

        assertEq(curator.poolBalance(FILM), 50_000e18, "film pool absorbed the film loss");
        assertEq(curator.poolBalance(Config.CLASS_DIGITAL_ASSETS), 200_000e18, "digital-assets pool untouched");
    }
}
