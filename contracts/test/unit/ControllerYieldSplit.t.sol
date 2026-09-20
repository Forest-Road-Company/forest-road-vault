// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Records attempts to open a new baseline during each token mint callback.
contract YieldSplitCallback {
    IMintRedeemController private immutable controller;
    uint256 public callbacks;
    uint256 public opened;
    bytes4 public firstRefusal;
    bytes4 public secondRefusal;

    constructor(IMintRedeemController controller_) {
        controller = controller_;
    }

    function onUSDfrTransfer(address, address, uint256) external {
        (bool ok, bytes memory reason) =
            address(controller).call(abi.encodeCall(IMintRedeemController.beginPairedYield, ()));
        ++callbacks;
        if (ok) ++opened;
        else if (callbacks == 1) firstRefusal = bytes4(reason);
        else secondRefusal = bytes4(reason);
    }
}

/// @notice Independent arithmetic for one complete issuance and its two recipient legs.
contract ControllerYieldSplitTest is TokenLayerFixture {
    function _book(uint256 backing, uint256 recognized, uint256 retention) private {
        vm.mockCall(address(reserves), abi.encodeWithSignature("totalBackingValue()"), abi.encode(backing));
        vm.mockCall(address(reserves), abi.encodeWithSignature("recognizedBackingValue()"), abi.encode(recognized));
        vm.mockCall(address(reserves), abi.encodeWithSignature("exitPrepaidAbsorption()"), abi.encode(retention));
    }

    function _supply(uint256 amount) private {
        vm.prank(address(controller));
        usdfr.mint(alice, amount);
    }

    function _begin() private {
        vm.prank(creditModule);
        controller.beginPairedYield();
    }

    function _split(uint256 total, uint256 fee) private {
        vm.prank(creditModule);
        controller.mintYieldSplit(address(vault), total, feeRecipient, fee);
    }

    function _shortfall(uint256 supply_, uint256 backing) private pure returns (uint256) {
        return supply_ > backing ? supply_ - backing : 0;
    }

    function testFuzz_completeSplitMatchesIndependentBackingRules(uint256 seed) public {
        uint256 supply_ = 1 + seed % 1e24;
        seed = uint256(keccak256(abi.encode(seed)));
        uint256 raw = seed % (2 * supply_ + 1);
        uint256 recognized = (seed >> 80) % (raw + 1);
        uint256 total = 1 + (seed >> 128) % 1e23;
        uint256 fee = (seed >> 64) % (total + 1);
        uint256 retention = seed & 1 == 0 ? 0 : total;
        _supply(supply_);
        _book(raw, recognized, retention);
        _begin();
        seed = uint256(keccak256(abi.encode(seed)));
        uint256 rawAfter = raw + seed % (2 * total + 1);
        uint256 recognizedAfter = recognized + (seed >> 64) % (2 * total + 1);
        if (recognizedAfter > rawAfter) recognizedAfter = rawAfter;
        _book(rawAfter, recognizedAfter, retention);
        bool allowed = _shortfall(supply_ + total, rawAfter) <= _shortfall(supply_, raw)
            && _shortfall(supply_ + total, recognizedAfter) <= _shortfall(supply_, recognized);
        if (retention != 0) {
            uint256 surplusBefore = recognized > supply_ ? recognized - supply_ : 0;
            uint256 surplusAfter = recognizedAfter > supply_ + total ? recognizedAfter - supply_ - total : 0;
            allowed = allowed && surplusBefore == surplusAfter;
        }
        if (!allowed) vm.expectRevert();
        _split(total, fee);
        assertEq(usdfr.totalSupply(), supply_ + (allowed ? total : 0));
        assertEq(usdfr.balanceOf(feeRecipient), allowed ? fee : 0);
        assertEq(usdfr.balanceOf(address(vault)), allowed ? total - fee : 0);
    }

    /// @notice A neutral asset/supply movement cannot hide a changed retention obligation.
    function testFuzz_pairedRetentionMustRemainAtItsOpeningValue(uint128 initial, uint128 finalValue) public {
        uint256 beforeRetention = uint256(initial);
        uint256 afterRetention = uint256(finalValue);
        _supply(100e18);
        _book(100e18, 100e18, beforeRetention);
        _begin();
        _book(200e18, 200e18, afterRetention);
        if (afterRetention != beforeRetention) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "Controller_PairedRetentionChanged(uint256,uint256)", beforeRetention, afterRetention
                )
            );
        }
        _split(100e18, 10e18);
        if (afterRetention != beforeRetention) {
            assertEq(usdfr.totalSupply(), 100e18, "refused split minted supply");
            assertEq(usdfr.balanceOf(feeRecipient), 0, "refused split paid a fee");
            _book(200e18, 200e18, beforeRetention);
            _split(100e18, 10e18);
        }
        assertEq(usdfr.totalSupply(), 200e18);
        assertEq(usdfr.balanceOf(feeRecipient), 10e18);
        assertEq(usdfr.balanceOf(address(vault)), 90e18);
    }

    function test_zeroRetentionCannotEraseAnOpenPairRequirement() public {
        _book(0, 0, 1);
        _begin();
        _book(100e18, 100e18, 0);
        vm.expectRevert(
            abi.encodeWithSignature("Controller_PairedRetentionChanged(uint256,uint256)", uint256(1), uint256(0))
        );
        _split(100e18, 10e18);
        vm.prank(admin);
        controller.clearStalePairedYield();
        _book(0, 0, 0);
        _begin();
        _book(100e18, 100e18, 0);
        _split(100e18, 10e18);
        assertEq(usdfr.totalSupply(), 100e18);
    }

    function test_bothLegsRemainNeutralWithAShortfallAndRetention() public {
        _supply(100e18);
        _book(50e18, 40e18, 20e18);
        _begin();
        _book(150e18, 140e18, 20e18);
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.YieldMinted(feeRecipient, 10e18 + 1);
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.YieldMinted(address(vault), 90e18 - 1);
        _split(100e18, 10e18 + 1);
        assertEq(usdfr.balanceOf(feeRecipient), 10e18 + 1);
        assertEq(usdfr.balanceOf(address(vault)), 90e18 - 1);
        assertEq(usdfr.totalSupply(), 200e18);
    }

    function test_partialPairedIssuanceCannotCreateRetainedSurplus() public {
        _book(0, 0, 1);
        _begin();
        _book(100e18, 100e18, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_SeniorRetentionBreached.selector, uint256(0), uint256(1)
            )
        );
        _split(100e18 - 1, 10e18);
        assertEq(usdfr.totalSupply(), 0);
        _split(100e18, 10e18);
        assertEq(usdfr.totalSupply(), 100e18);
        vm.expectRevert(IMintRedeemController.Controller_PairedYieldRequired.selector);
        _split(1, 0);
    }

    function test_rolesPauseAndCallerBoundBaselineAreRequired() public {
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, Roles.CREDIT_ROLE)
        );
        vm.prank(alice);
        controller.mintYieldSplit(address(vault), 1, feeRecipient, 0);
        vm.expectRevert(IMintRedeemController.Controller_PairedYieldRequired.selector);
        _split(1, 0);
        _book(0, 0, 0);
        _begin();
        vm.prank(admin);
        controller.grantRole(Roles.CREDIT_ROLE, bob);
        vm.expectRevert(IMintRedeemController.Controller_PairedYieldRequired.selector);
        vm.prank(bob);
        controller.mintYieldSplit(address(vault), 1, feeRecipient, 0);
        vm.prank(guardian);
        controller.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _split(1, 0);
        vm.prank(guardian);
        controller.unpause();
        _book(1, 1, 0);
        _split(1, 0);
    }

    function test_invalidSplitOrDestinationCannotConsumeTheBaseline() public {
        _book(0, 0, 0);
        _begin();
        _book(100, 100, 0);
        vm.prank(admin);
        controller.setYieldSink(address(vault), false);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotYieldSink.selector, address(vault)));
        _split(100, 10);
        assertEq(usdfr.totalSupply(), 0);
        vm.prank(admin);
        controller.setYieldSink(address(vault), true);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        _split(0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_InvalidYieldSplit.selector, uint256(100), uint256(101)
            )
        );
        _split(100, 101);
        vm.prank(admin);
        controller.setYieldSink(feeRecipient, false);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotYieldSink.selector, feeRecipient));
        _split(100, 10);
        assertEq(usdfr.totalSupply(), 0);
        vm.prank(admin);
        controller.setYieldSink(feeRecipient, true);
        _split(100, 10);
    }

    function test_secondMintFailureRestoresFirstMintAndBaseline() public {
        _book(0, 0, 0);
        _begin();
        _book(100, 100, 0);
        vm.prank(admin);
        controller.setYieldSink(carol, true);
        bytes memory refusal = abi.encodeWithSignature("Fixture_MintRefused()");
        vm.mockCallRevert(address(usdfr), abi.encodeWithSignature("mint(address,uint256)", carol, uint256(90)), refusal);
        vm.expectRevert(refusal);
        vm.prank(creditModule);
        controller.mintYieldSplit(carol, 100, feeRecipient, 10);
        assertEq(usdfr.balanceOf(feeRecipient), 0);
        assertEq(usdfr.totalSupply(), 0);
        _split(100, 10);
        assertEq(usdfr.balanceOf(feeRecipient), 10);
        assertEq(usdfr.balanceOf(address(vault)), 90);
    }

    function test_zeroAndSharedRecipientLegsConserveTheTotal() public {
        for (uint256 mode; mode < 3; ++mode) {
            uint256 snap = vm.snapshotState();
            _book(0, 0, 0);
            _begin();
            _book(100, 100, 0);
            if (mode == 0) {
                _split(100, 0);
            } else if (mode == 1) {
                _split(100, 100);
            } else {
                vm.prank(creditModule);
                controller.mintYieldSplit(feeRecipient, 100, feeRecipient, 37);
            }
            assertEq(usdfr.totalSupply(), 100);
            assertEq(usdfr.balanceOf(feeRecipient), mode == 0 ? 0 : 100);
            assertEq(usdfr.balanceOf(address(vault)), mode == 0 ? 100 : 0);
            assertTrue(vm.revertToStateAndDelete(snap));
        }
    }

    function test_ordinaryMintKeepsBothDeficitChecksAndAbsoluteRetention() public {
        _supply(100);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            if (mode == 0) _book(100, 100, 0);
            else if (mode == 1) _book(50, 50, 0);
            else if (mode == 2) _book(200, 50, 0);
            else _book(200, 200, 100);
            if (mode == 0) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IMintRedeemController.Controller_BackingInvariantViolated.selector, uint256(101), uint256(100)
                    )
                );
            } else if (mode == 1) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IMintRedeemController.Controller_DeficitWorsened.selector, uint256(50), uint256(51)
                    )
                );
            } else if (mode == 2) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IMintRedeemController.Controller_RecognizedDeficitWorsened.selector, uint256(50), uint256(51)
                    )
                );
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IMintRedeemController.Controller_SeniorRetentionBreached.selector, uint256(100), uint256(99)
                    )
                );
            }
            vm.prank(creditModule);
            controller.mintYield(feeRecipient, 1);
            assertEq(usdfr.totalSupply(), 100);
            assertTrue(vm.revertToStateAndDelete(snap));
        }
        _book(110, 110, 0);
        vm.prank(creditModule);
        controller.mintYield(feeRecipient, 10);
        assertEq(usdfr.totalSupply(), 110);
    }

    function test_callbacksCannotOpenANestedBaselineBetweenMints() public {
        YieldSplitCallback callback = new YieldSplitCallback(IMintRedeemController(address(controller)));
        vm.startPrank(admin);
        controller.grantRole(Roles.CREDIT_ROLE, address(callback));
        usdfr.setPointsModule(address(callback));
        vm.stopPrank();
        _book(0, 0, 0);
        _begin();
        _book(100, 100, 0);
        _split(100, 10);
        assertEq(callback.callbacks(), 2, "both mint callbacks must execute");
        assertEq(callback.opened(), 0);
        bytes4 refusal = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        assertEq(callback.firstRefusal(), refusal);
        assertEq(callback.secondRefusal(), refusal);
        assertEq(usdfr.totalSupply(), 100);
    }
}
