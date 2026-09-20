// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract QueueQuoteAsset is ERC20 {
    constructor() ERC20("Quote asset", "QUOTE") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/// @dev Fixed rational quote isolates the actual queue selection and allocation from changing NAV.
///      Real-vault integration remains in RedemptionQueueTest and the existing floor regressions.
contract QueueLinearVault is ERC20 {
    QueueQuoteAsset private immutable asset;
    uint256 public numerator = 1;
    uint256 public denominator = 1;

    constructor(QueueQuoteAsset token) ERC20("Quote shares", "SHARES") {
        asset = token;
    }

    function setRate(uint256 n, uint256 d) external {
        numerator = n;
        denominator = d;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function accrueFees() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function prepareRedemptionPricing(uint256) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return previewRedeem(shares);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, numerator, denominator);
    }

    function previewWithdraw(uint256 value) external view returns (uint256) {
        return Math.mulDiv(value, denominator, numerator, Math.Rounding.Ceil);
    }

    function convertToSharesAtRedemption(uint256 value) external view returns (uint256) {
        return Math.mulDiv(value, denominator, numerator);
    }

    function redemptionTotalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function impairmentSource() external pure returns (address) {
        return address(0);
    }

    function unvestedYield() external pure returns (uint256) {
        return 0;
    }

    function lastFeeAccrual() external view returns (uint256) {
        return block.timestamp;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 amount) {
        require(msg.sender == owner, "queue owns the selected shares");
        amount = previewRedeem(shares);
        _burn(owner, shares);
        require(asset.transfer(receiver, amount), "quote transfer");
    }
}

contract QueueQuoteReserve {
    uint256 public idleReserve = 1e12;

    function reserveLossExitsLocked() external pure returns (bool) {
        return false;
    }
}

contract QueueWithholdingBoundTest is Test {
    uint256 private constant MARGIN = 1e12;
    QueueQuoteAsset private asset;
    QueueLinearVault private vault;
    RedemptionQueue private queue;

    function setUp() public {
        asset = new QueueQuoteAsset();
        vault = new QueueLinearVault(asset);
        QueueQuoteReserve reserves = new QueueQuoteReserve();
        queue = RedemptionQueue(
            address(
                new ERC1967Proxy(
                    address(new RedemptionQueue()),
                    abi.encodeCall(
                        RedemptionQueue.initialize,
                        (address(this), address(this), address(this), address(vault), address(asset), address(reserves))
                    )
                )
            )
        );
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, address(this));
        queue.setEpochLiquidityBps(10_000);
        queue.setMinRedemptionValue(0);
        vault.approve(address(queue), type(uint256).max);
        asset.mint(address(vault), MARGIN);
    }

    function _prepare(uint256 n, uint256 d, uint256 first, uint256 tail) private returns (uint256 second) {
        vault.setRate(n, d);
        second = (MARGIN * d + n - 1) / n + tail;
        vault.mint(address(this), first + second);
        queue.requestRedeem(first);
        queue.requestRedeem(second);
        vm.warp(queue.eligibleToSettleAt(0) + 1);
        assertEq(vault.previewRedeem(tail), 0, "shape must discard the reduced fill");
        assertGt(vault.previewRedeem(first), 0, "shape must retain an earlier fill");
        assertGt(vault.previewRedeem(first + second), MARGIN, "shape must refuse complete head");
    }

    function _check(uint256 n, uint256 d, uint256 first, uint256 tail) private returns (uint256 shortfall) {
        uint256 second = _prepare(n, d, first, tail);
        vm.recordLogs();
        queue.closeEpoch(2);
        uint256 withheld = _readWithheld(vm.getRecordedLogs());
        uint256 claimable;
        {
            (, uint256 left, uint256 paid,,) = queue.request(0);
            (, uint256 nextLeft, uint256 nextClaimable,,) = queue.request(1);
            assertEq(left, 0);
            assertEq(nextLeft, second, "zero-quote fill must not burn shares");
            assertEq(nextClaimable, 0);
            claimable = paid;
        }
        uint256 cappedShares = MARGIN * d / n;
        uint256 cappedQuote = cappedShares * n / d;
        uint256 credited = claimable + withheld;
        assertLe(credited, cappedQuote, "withholding invented floor credit");
        assertLe(cappedQuote - credited, 1, "floor credit lost more than one asset wei");
        assertEq(claimable, first * n / d, "aggregate receipt mismatch");
        assertEq(queue.totalQueuedShares(), second);
        assertEq(queue.currentEpoch(), 2);
        assertEq(queue.claim(0), claimable);
        assertEq(asset.balanceOf(address(this)), claimable);
        assertEq(asset.balanceOf(address(queue)), 0, "claims do not conserve receipt");
        shortfall = cappedQuote - credited;
    }

    function _readWithheld(Vm.Log[] memory logs) private view returns (uint256 withheld) {
        uint256 eventsSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(queue)
                    && logs[i].topics[0] == keccak256("SettlementWithheld(uint256,uint256,uint256)")
            ) {
                withheld = abi.decode(logs[i].data, (uint256));
                ++eventsSeen;
            }
        }
        assertEq(eventsSeen, 1, "production withholding branch not reached");
    }

    function test_discardedZeroQuoteCanLoseExactlyOneWeiOfFloorCredit() public {
        assertEq(_check(2, 3, 2, 1), 1);
    }

    function test_exactFloorBoundaryRefusesConservativelyAndRollsBack() public {
        uint256 second = _prepare(2, 3, 2, 1);
        queue.setMinRedemptionValue(MARGIN);
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(2);
        assertEq(queue.head(), 0);
        assertEq(queue.currentEpoch(), 1);
        assertEq(queue.totalQueuedShares(), second + 2);
        assertEq(asset.balanceOf(address(queue)), 0);
        assertFalse(queue.isSettling());
    }

    function testFuzz_discardedFillNeverOvercreditsAndLosesAtMostOneWei(
        uint32 nSeed,
        uint32 dSeed,
        uint32 firstSeed,
        uint32 tailSeed
    ) public {
        uint256 n = uint256(nSeed) % 1_000_000 + 1;
        uint256 d = n * (uint256(dSeed) % 1_000_000 + 2) + uint256(firstSeed) % n;
        uint256 unit = (d + n - 1) / n;
        uint256 first = unit * (uint256(firstSeed) % 100_000 + 1);
        uint256 tail = uint256(tailSeed) % unit;
        _check(n, d, first, tail);
    }
}
