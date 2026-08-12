// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract F1802GasBurnerPoints is IPointsModule {
    function onSharesTransfer(address, address, uint256) external override {
        for (uint256 i = 1;; ++i) {
            assembly {
                sstore(0, i)
            }
        }
    }

    function onUSDfrTransfer(address, address, uint256) external override {
        for (uint256 i = 1;; ++i) {
            assembly {
                sstore(0, i)
            }
        }
    }

    function onCuratorStakeChange(address, uint256, uint256) external pure override {}

    function onCuratorLoss(uint256, uint256, uint256) external pure override {}
}

/// @notice Regression for F-18-02: caller-selected gas must not let a financial transfer
///         commit while the real points module atomically drops both accounting legs.
contract FixF1802PointsHookGasFloorTest is TokenLayerFixture {
    PointsModule internal points;

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
        vm.startPrank(admin);
        vault.setPointsModule(address(points));
        usdfr.setPointsModule(address(points));
        vm.stopPrank();
    }

    function test_F1802_usdfrGasCapCannotCommitWithoutBothPointsLegs() public {
        _mintUSDfr(alice, 1_000e6);
        _mintUSDfr(bob, 1_000e6);
        vm.warp(block.timestamp + 30 days);

        bool sawSuccessfulTransfer;
        for (uint256 gasCap = 75_000; gasCap <= 750_000; gasCap += 250) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(usdfr).call{gas: gasCap}(abi.encodeCall(usdfr.transfer, (bob, 100e18)));
            if (ok) {
                sawSuccessfulTransfer = true;
                (, uint256 aliceTracked) = points.trackedBalances(alice);
                (, uint256 bobTracked) = points.trackedBalances(bob);
                bool ledgerMatches = aliceTracked == usdfr.balanceOf(alice) && bobTracked == usdfr.balanceOf(bob);
                if (!ledgerMatches) emit log_named_uint("unsafe USDfr gas cap", gasCap);
                assertTrue(ledgerMatches, "successful USDfr transfer dropped both points legs");
            }
            assertTrue(vm.revertToState(snapshot), "USDfr probe snapshot");
        }
        assertTrue(sawSuccessfulTransfer, "USDfr scan must include a sufficiently funded transfer");
    }

    function test_F1802_susdfrGasCapCannotCommitWithoutBothPointsLegs() public {
        uint256 assets = _mintUSDfr(alice, 1_000e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);
        vm.stopPrank();
        uint256 bobAssets = _mintUSDfr(bob, 1_000e6);
        vm.startPrank(bob);
        usdfr.approve(address(vault), bobAssets);
        vault.deposit(bobAssets, bob);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        uint256 moved = shares / 10;

        bool sawSuccessfulTransfer;
        for (uint256 gasCap = 75_000; gasCap <= 850_000; gasCap += 250) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(vault).call{gas: gasCap}(abi.encodeCall(vault.transfer, (bob, moved)));
            if (ok) {
                sawSuccessfulTransfer = true;
                (uint256 aliceTracked,) = points.trackedBalances(alice);
                (uint256 bobTracked,) = points.trackedBalances(bob);
                bool ledgerMatches = aliceTracked == vault.balanceOf(alice) && bobTracked == vault.balanceOf(bob);
                if (!ledgerMatches) emit log_named_uint("unsafe sUSDfr gas cap", gasCap);
                assertTrue(ledgerMatches, "successful sUSDfr transfer dropped both points legs");
            }
            assertTrue(vm.revertToState(snapshot), "sUSDfr probe snapshot");
        }
        assertTrue(sawSuccessfulTransfer, "sUSDfr scan must include a sufficiently funded transfer");
    }

    function test_F1802_reservedEpilogueKeepsBothTokensFailOpenForGasBurningModule() public {
        _mintUSDfr(alice, 1_000e6);
        uint256 assets = usdfr.balanceOf(alice);
        vm.startPrank(alice);
        usdfr.approve(address(vault), assets / 2);
        uint256 shares = vault.deposit(assets / 2, alice);
        vm.stopPrank();

        F1802GasBurnerPoints burner = new F1802GasBurnerPoints();
        vm.startPrank(admin);
        usdfr.setPointsModule(address(burner));
        vault.setPointsModule(address(burner));
        vm.stopPrank();

        vm.prank(alice);
        (bool usdfrOk,) = address(usdfr).call{gas: 800_000}(abi.encodeCall(usdfr.transfer, (bob, 1e18)));
        assertTrue(usdfrOk, "reserved gas must finish USDfr catch and epilogue");
        assertEq(usdfr.balanceOf(bob), 1e18, "USDfr value moved despite bad optional hook");

        vm.prank(alice);
        (bool sharesOk,) = address(vault).call{gas: 800_000}(abi.encodeCall(vault.transfer, (bob, shares / 10)));
        assertTrue(sharesOk, "reserved gas must finish sUSDfr catch and unlock epilogue");
        assertEq(vault.balanceOf(bob), shares / 10, "shares moved despite bad optional hook");
    }
}
