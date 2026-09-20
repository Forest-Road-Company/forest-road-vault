// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";

contract NativeOpeningBatchesTest is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function test_oneHundredLoansMigrateInBoundedBatchesWithoutPartialNav() public {
        _migrate(100, 8);
    }

    function test_oneHundredAndOneLiveRowsAreRefusedBeforeTheBookIsFrozen() public {
        uint256[] memory ids = new uint256[](101);
        for (uint256 i; i < ids.length; ++i) {
            _legacyFund(500e18);
            ids[i] = nativeId;
        }
        _bindOpeningConsumers();
        vm.expectRevert(ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        _beginOpening(ids);
        assertFalse(reserves.accrualMigration().active, "oversized roster froze admission");
        assertEq(registry.totalBookExposure(), 50_500e18, "oversized roster changed existing exposure");
    }

    function testFuzz_batchPartitionDoesNotChangeTheCompletedBook(uint8 countSeed, uint8 batchSeed) public {
        _migrate(uint256(countSeed) % 17 + 1, uint256(batchSeed) % 8 + 1);
    }

    function _migrate(uint256 count, uint256 batchSize) private {
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            _legacyFund(500e18);
            ids[i] = nativeId;
        }
        vm.warp(nativeStart + 45 days);
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(uint64(block.timestamp));
        nativeReference = n;
        _bindOpeningConsumers();
        uint256 before_ = gasleft();
        _beginOpening(ids);
        uint256 beginGas = before_ - gasleft();
        IAccrualMigration.Opening[] memory all = new IAccrualMigration.Opening[](count);
        for (uint256 i; i < count; ++i) {
            all[i] = IAccrualMigration.Opening(ids[i], n.principal, n.interest, 0, n.epochStart, 0, bytes32(0));
            _signOpening(all[i]);
        }
        if (count == 100) {
            IAccrualMigration.Opening[] memory tooLarge = new IAccrualMigration.Opening[](9);
            for (uint256 i; i < tooLarge.length; ++i) {
                tooLarge[i] = all[i];
            }
            vm.expectRevert(ReserveMigrationLib.AccrualMigration_InvalidBatch.selector);
            _step(1, abi.encode(tooLarge));
            assertEq(reserves.accrualMigration().imported, 0, "oversized batch imported a prefix");
        }
        uint256 maximumBatchGas;
        for (uint256 first; first < count; first += batchSize) {
            uint256 length = count - first < batchSize ? count - first : batchSize;
            IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](length);
            for (uint256 j; j < length; ++j) {
                batch[j] = all[first + j];
            }
            before_ = gasleft();
            _step(1, abi.encode(batch));
            uint256 used = before_ - gasleft();
            if (used > maximumBatchGas) maximumBatchGas = used;
            IAccrualMigration.Progress memory p = reserves.accrualMigration();
            assertEq(p.imported, first + length, "batch progress");
            assertEq(p.importedOriginalFace, (first + length) * 500e18, "batch original-face total");
            assertTrue(p.active, "batch exposed partial NAV");
        }
        assertLt(beginGas, 10_000_000, "bounded roster gas");
        assertLt(maximumBatchGas, 15_000_000, "bounded import gas");
        _enableOpening();
        uint256 expectedFace = count * (n.principal + n.interest);
        assertEq(registry.totalBookExposure(), expectedFace, "complete batch exposure");
        assertEq(reserves.accrualSnapshot().gross, count * n.earned, "batch partition changed income");
        assertEq(reserves.accrualSnapshot().feeUnissued, count * n.earned / 10, "batch partition changed fees");
        for (uint256 i; i < count; ++i) {
            assertEq(reserves.deployedTo(ids[i]), n.principal + n.interest);
        }
        _assertNativeBacking();
        if (count == 100) {
            emit log_named_uint("100-row begin gas in native fixture", beginGas);
            emit log_named_uint("maximum eight-row import gas in native fixture", maximumBatchGas);
        }
    }
}
