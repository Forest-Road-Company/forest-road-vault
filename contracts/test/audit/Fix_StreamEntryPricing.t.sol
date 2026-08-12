// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @notice The optional yield stream belongs to incumbent shares and cannot be skimmed on entry.
contract FixStreamEntryPricingTest is CreditLayerFixture {
    uint64 internal constant STREAM_PERIOD = 7 days;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault.setYieldVestingPeriod(STREAM_PERIOD);
    }

    function _stake(address who, uint256 amount) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _parkStream() internal returns (uint256 base, uint256 stream, uint256 held) {
        _stake(alice, 1_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        _repay(id, 400_000e18, 0);
        base = vault.totalAssets();
        stream = vault.unvestedYield();
        held = usdfr.balanceOf(address(vault));
        assertGt(stream, 0, "precondition: an excluded stream must exist");
        assertEq(held, base + stream, "physical balance must be realised base plus stream");
    }

    function _depositAndMature(uint256 amount) internal returns (uint256 value) {
        uint256 shares = _stake(bob, amount);
        vm.warp(block.timestamp + uint256(STREAM_PERIOD) + 1);
        value = vault.convertToAssets(shares);
    }

    /// @dev The predecessor test accepted a positive residual and misstated its maximum.
    ///      Sweep both extremes: no deposit size may earn value from the incumbent stream.
    function test_entrySkimIsClosedAcrossDepositSizes() public {
        (uint256 base,,) = _parkStream();
        uint256 parked = vm.snapshotState();

        uint256[5] memory amounts = [base / 1000, base / 100, base / 10, base, base * 1000];
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 amount = amounts[i] - (amounts[i] % 1e12);
            assertGt(amount, 0, "sweep point rounded to zero");
            uint256 value = _depositAndMature(amount);
            assertLe(value, amount, "entrant captured yield earned before entry");
            assertLe(amount - value, amount / 5 + 2, "entry conservatism escaped the fee bound");

            if (i + 1 != amounts.length) {
                assertTrue(vm.revertToState(parked), "failed to restore the identical parked stream");
                parked = vm.snapshotState();
            }
        }
    }

    function test_depositCannotDiluteIncumbentsWhenTheStreamVests() public {
        (uint256 base,,) = _parkStream();
        uint256 parked = vm.snapshotState();

        vm.warp(block.timestamp + uint256(STREAM_PERIOD) + 1);
        uint256 incumbentWithoutEntry = vault.convertToAssets(vault.balanceOf(alice));

        assertTrue(vm.revertToState(parked), "failed to restore parked stream");
        uint256 amount = base / 10;
        uint256 entrantValue = _depositAndMature(amount);
        uint256 incumbentWithEntry = vault.convertToAssets(vault.balanceOf(alice));

        assertLe(entrantValue, amount, "entrant received incumbent stream value");
        assertGe(incumbentWithEntry + 2, incumbentWithoutEntry, "entry diluted the incumbent");
    }

    function test_previewDepositPricesThePhysicalPreEntryBalance() public {
        (, uint256 stream, uint256 held) = _parkStream();
        uint256 amount = 10_000e18;
        uint256 quoted = vault.previewDeposit(amount);

        // The servicing transaction checkpointed fees, so concrete and fee-adjusted supply
        // coincide here; reconstruct the exact ERC-4626 virtual-term quote.
        uint256 expected = amount * (vault.totalSupply() + 10 ** 6) / (held + 1);
        assertEq(quoted, expected, "deposit quote did not include physical stream backing");
        assertGt(stream, 0, "test stopped exercising the stream distinction");
    }

    function test_mintPathCannotCaptureTheOldStream() public {
        _parkStream();
        uint256 shares = vault.totalSupply() / 10;
        uint256 assets = vault.previewMint(shares);

        uint256 funding = ((assets + 1e12 - 1) / 1e12) * 1e12;
        _mintUSDfrTo(bob, funding);
        vm.startPrank(bob);
        usdfr.approve(address(vault), assets);
        uint256 paid = vault.mint(shares, bob);
        vm.stopPrank();
        assertEq(paid, assets, "previewMint diverged from execution");

        vm.warp(block.timestamp + uint256(STREAM_PERIOD) + 1);
        assertLe(vault.convertToAssets(shares), paid, "mint path captured incumbent stream value");
    }
}
