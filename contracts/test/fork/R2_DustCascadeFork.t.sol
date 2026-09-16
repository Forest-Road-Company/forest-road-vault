// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title R2_DustCascadeFork — live safety assertion for F-9's dust redistribution path.
/// @notice Runs only on the pinned local mainnet fork; never broadcasts.
contract R2_DustCascadeForkTest is ForkLifecycleFixture {
    uint256 internal constant LOSS_UNITS = 1e7;

    function test_fork_dustCascade_liveCustodyDraw_completesWithoutOverAllocation() public onFork {
        _mintFromUSDC(ops, 1_000_000e6);
        uint256[5] memory b = [uint256(1e18), 2e18, 3e18, 4e18, 7e18];
        for (uint256 i; i < 5; ++i) {
            uint256 classId = i + 1;
            usdfr.approve(address(curator), b[i]);
            curator.postFirstLoss(classId, b[i]);
        }

        _mintFromUSDC(alice, 10_000e6);
        _stake(alice, 1_000e18);
        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 loss = reserves.normalizeUSDC(LOSS_UNITS);
        uint256[5] memory bal;
        for (uint256 i; i < 5; ++i) {
            bal[i] = curator.poolBalance(i + 1);
        }
        uint256[5] memory expectedFinal = _modelSplit(bal, loss);

        deal(USDC, address(reserves), reserves.idleUSDC() - LOSS_UNITS);
        uint256 supplyBefore = controller.totalUSDfr();
        bytes32 evidence = keccak256("R2-dust-cascade-custody-incident");
        (uint256 armId,) = reserves.armReserveLossFreeze(evidence);
        (, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidence, loss);
        assertEq(actualLoss, loss);

        uint256 totalDebited;
        for (uint256 i; i < 5; ++i) {
            uint256 after_ = curator.poolBalance(i + 1);
            uint256 debit = bal[i] - after_;
            assertLe(debit, bal[i]);
            assertEq(after_, expectedFinal[i]);
            totalDebited += debit;
        }
        assertEq(totalDebited, loss);
        assertEq(supplyBefore - controller.totalUSDfr(), loss);
        assertGe(vault.totalAssets(), vaultAssetsBefore);
        assertTrue(controller.backingInvariantHolds());
    }

    function _modelSplit(uint256[5] memory bal, uint256 loss) private pure returns (uint256[5] memory expectedFinal) {
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            total += bal[i];
        }
        assertLt(loss, total);
        uint256[5] memory alloc;
        uint256 allocated;
        for (uint256 i; i < 5; ++i) {
            alloc[i] = Math.mulDiv(loss, bal[i], total);
            allocated += alloc[i];
        }
        uint256 dust = loss - allocated;
        assertGe(dust, 2);
        uint256 d = dust;
        for (uint256 i; i < 5 && d != 0; ++i) {
            uint256 remainingCapacity = bal[i] - alloc[i];
            if (remainingCapacity == 0) continue;
            uint256 add = d < remainingCapacity ? d : remainingCapacity;
            alloc[i] += add;
            d -= add;
        }
        assertEq(d, 0);
        for (uint256 i; i < 5; ++i) {
            assertLe(alloc[i], bal[i]);
            expectedFinal[i] = bal[i] - alloc[i];
        }
    }
}
