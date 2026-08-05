// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title Per-borrower concentration-limit override (Forest Road direction, 2026-07-21)
/// @notice THE PROBLEM. `borrowerLimitBps` is a single global number (15% at launch) applied to
///         a GLOBALLY-tracked `borrowerExp`. It assumes a vertical has many borrowers. That is
///         false for Digital Assets (ADR-0015), which is a SINGLE borrower by construction --
///         Forest Road's own trading subsidiary. With one borrower the class and borrower
///         dimensions measure exactly the same exposure, so the tighter one binds: the class's
///         own 20% limit was UNREACHABLE and the vertical was silently capped at 15%.
///
///         THE FIX. Governance may set a per-borrower override, named and evented, rather than
///         relaxing the global limit for every borrower in the book. `overridden` is a separate
///         flag rather than treating 0 as "unset", so an override of 0 bps (admit no new
///         exposure -- a wind-down borrower) stays expressible.
contract BorrowerLimitOverrideTest is Test {
    CollateralRegistry internal reg;

    address internal admin = makeAddr("admin");
    address internal credit = makeAddr("credit");

    bytes32 internal constant DA_BORROWER = keccak256("forest-road-digital-assets");
    bytes32 internal constant OTHER_BORROWER = keccak256("borrower-other");
    bytes32 internal constant NO_STATE = bytes32(0);

    uint256 internal constant DA = Config.CLASS_DIGITAL_ASSETS;
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    function setUp() public {
        reg = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(new CollateralRegistry()), abi.encodeCall(CollateralRegistry.initialize, (admin, admin))
                )
            )
        );
        vm.startPrank(admin);
        reg.grantRole(Roles.CREDIT_ROLE, credit);
        reg.setClass(DA, _mtmClass("Digital Assets", 2000));
        reg.setClass(FILM, _receivableClass("Filler (class limit disabled)", 10_000));
        // Pin the bootstrap floor AT the book size these tests build (1,000,000). With
        // `base = max(book, floor)` that makes every dimension's cap a stable absolute number
        // for the whole test -- 150,000 per borrower (1500bps), 200,000 for the Digital Assets
        // class (2000bps) -- instead of moving as the book is assembled. The rule is continuous
        // at the floor, so `book == floor` gives the same answer either way.
        reg.setConcentrationFloor(1_000_000e18);
        vm.stopPrank();
    }

    /// @dev Builds `amount` of filler book WITHOUT tripping the global 15% borrower limit, by
    ///      spreading it over enough distinct borrowers. The filler class limit is 100%, so the
    ///      class dimension never binds and these tests isolate the borrower dimension.
    function _fillBook(uint256 amount) internal {
        uint256 n = 10;
        uint256 each = amount / n;
        for (uint256 i = 0; i < n; ++i) {
            vm.prank(credit);
            reg.recordExposureIncrease(FILM, keccak256(abi.encode("filler", i)), NO_STATE, each);
        }
    }

    // ── the problem, demonstrated ────────────────────────────────────────

    /// @notice Without an override, the borrower limit binds BEFORE the class limit, so the
    ///         Digital Assets class limit is dead configuration.
    function test_singleBorrowerVertical_isCappedByTheBorrowerLimitNotTheClassLimit() public {
        // Build a book so the relative limits bind: 1,000,000 total.
        _fillBook(850_000e18);

        // The class allows 20% of the post-trade book; the borrower allows 15%.
        // Adding 150_000 takes the book to 1,000,000 with DA at 150,000 = exactly 15%.
        vm.prank(credit);
        reg.recordExposureIncrease(DA, DA_BORROWER, NO_STATE, 150_000e18);
        assertEq(reg.borrowerExposure(DA_BORROWER), 150_000e18, "at the 15% borrower limit");

        // One more wei is refused -- and the error names the BORROWER dimension, not the class,
        // even though the class still has headroom to 20%.
        vm.prank(credit);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector,
                DA_BORROWER,
                150_000e18 + 1,
                uint256(1500)
            )
        );
        reg.recordExposureIncrease(DA, DA_BORROWER, NO_STATE, 1);
    }

    // ── the fix ──────────────────────────────────────────────────────────

    /// @notice With the override at the class limit, the CLASS limit becomes the binding one.
    function test_override_letsTheClassLimitBind() public {
        vm.prank(admin);
        reg.setBorrowerLimitOverride(DA_BORROWER, 2000); // match the Digital Assets class limit

        (uint16 limitBps, bool overridden) = reg.effectiveBorrowerLimitBps(DA_BORROWER);
        assertEq(limitBps, 2000, "override in force");
        assertTrue(overridden, "flagged as overridden");

        // Other borrowers are untouched by this -- the whole point of a per-borrower override.
        (uint16 otherLimit, bool otherOverridden) = reg.effectiveBorrowerLimitBps(OTHER_BORROWER);
        assertEq(otherLimit, 1500, "global limit still applies to everyone else");
        assertFalse(otherOverridden, "not overridden");

        _fillBook(800_000e18);
        // 200,000 of a 1,000,000 book is 20% -- previously refused at 15%, now admitted.
        vm.prank(credit);
        reg.recordExposureIncrease(DA, DA_BORROWER, NO_STATE, 200_000e18);
        assertEq(reg.borrowerExposure(DA_BORROWER), 200_000e18, "the vertical reached its class limit");

        // And the CLASS limit now binds, as intended.
        vm.prank(credit);
        vm.expectRevert();
        reg.recordExposureIncrease(DA, DA_BORROWER, NO_STATE, 1);
    }

    /// @notice The override is bounded, timelocked-governance-only, and evented.
    function test_override_accessControlAndBounds() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        reg.setBorrowerLimitOverride(DA_BORROWER, 2000);

        vm.prank(admin);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        reg.setBorrowerLimitOverride(DA_BORROWER, uint16(Config.BPS) + 1);

        vm.expectEmit(true, false, false, true);
        emit ICollateralRegistry.BorrowerLimitOverrideSet(DA_BORROWER, 2000);
        vm.prank(admin);
        reg.setBorrowerLimitOverride(DA_BORROWER, 2000);
    }

    /// @notice An override of ZERO is a real setting (admit no new exposure), not "unset".
    /// @dev This is why `overridden` is a separate flag. Two bugs earlier in this same session
    ///      came from overloading 0 as a sentinel; the pattern is deliberately not repeated.
    function test_override_ofZeroIsDistinctFromUnset() public {
        vm.prank(admin);
        reg.setBorrowerLimitOverride(DA_BORROWER, 0);
        (uint16 limitBps, bool overridden) = reg.effectiveBorrowerLimitBps(DA_BORROWER);
        assertEq(limitBps, 0, "zero is honoured as a limit");
        assertTrue(overridden, "and is distinguishable from 'no override'");

        vm.prank(credit);
        vm.expectRevert();
        reg.recordExposureIncrease(DA, DA_BORROWER, NO_STATE, 1);

        // The global limit would have allowed it, proving the override is what bound.
        vm.prank(credit);
        reg.recordExposureIncrease(FILM, OTHER_BORROWER, NO_STATE, 1);
    }

    /// @notice Clearing returns the borrower to the global limit, and refuses if none is set.
    function test_clearOverride_returnsToTheGlobalLimit() public {
        vm.prank(admin);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        reg.clearBorrowerLimitOverride(DA_BORROWER);

        vm.prank(admin);
        reg.setBorrowerLimitOverride(DA_BORROWER, 2000);

        vm.expectEmit(true, false, false, false);
        emit ICollateralRegistry.BorrowerLimitOverrideCleared(DA_BORROWER);
        vm.prank(admin);
        reg.clearBorrowerLimitOverride(DA_BORROWER);

        (uint16 limitBps, bool overridden) = reg.effectiveBorrowerLimitBps(DA_BORROWER);
        assertEq(limitBps, 1500, "back to the global limit");
        assertFalse(overridden, "flag cleared");
    }

    /// @notice DISCLOSURE MUST MATCH ADMISSION. The breach views and the headroom view resolve
    ///         the same per-borrower limit the admission check uses — otherwise a borrower
    ///         admitted at 20% would be reported as permanently "over limit" at 15%.
    function test_disclosureUsesTheSameLimitAsAdmission() public {
        vm.prank(admin);
        reg.setBorrowerLimitOverride(DA_BORROWER, 2000);

        _fillBook(800_000e18);
        vm.prank(credit);
        reg.recordExposureIncrease(DA, DA_BORROWER, NO_STATE, 200_000e18);

        (, bool borrowerOver,) = reg.isOverConcentrated(DA, DA_BORROWER, NO_STATE);
        assertFalse(borrowerOver, "20% is within this borrower's OWN limit");

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = DA_BORROWER;
        assertFalse(reg.overConcentratedBorrowers(ids)[0], "not reported over while overridden");

        // The decisive check: the SAME exposure must read as a breach once the override is
        // removed. If disclosure read the global limit while admission read the override (or
        // vice versa) this pair could not both hold.
        vm.prank(admin);
        reg.clearBorrowerLimitOverride(DA_BORROWER);
        (, bool overNow,) = reg.isOverConcentrated(DA, DA_BORROWER, NO_STATE);
        assertTrue(overNow, "20% IS a breach of the global 15% limit");
        assertTrue(reg.overConcentratedBorrowers(ids)[0], "and the batch view agrees");

        // Headroom is the exact inverse of admission: it returns the binding minimum across
        // all three dimensions, and with this borrower at its own 20% limit it is zero.
        assertEq(reg.concentrationHeadroom(DA, DA_BORROWER, NO_STATE), 0, "at its own limit, so no headroom remains");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _receivableClass(string memory name, uint16 limitBps)
        internal
        pure
        returns (ICollateralRegistry.ClassParams memory)
    {
        return ICollateralRegistry.ClassParams({
            name: name,
            model: ICollateralRegistry.CollateralModel.Receivable,
            active: true,
            maxLtvBps: 8000,
            maxMaturity: 730 days,
            concentrationLimitBps: limitBps,
            marginCallLtvBps: 0,
            liquidationLtvBps: 0,
            maxMarkAge: 0
        });
    }

    function _mtmClass(string memory name, uint16 limitBps)
        internal
        pure
        returns (ICollateralRegistry.ClassParams memory)
    {
        return ICollateralRegistry.ClassParams({
            name: name,
            model: ICollateralRegistry.CollateralModel.MarkedToMarket,
            active: true,
            maxLtvBps: 5000,
            maxMaturity: 365 days,
            concentrationLimitBps: limitBps,
            marginCallLtvBps: 6500,
            liquidationLtvBps: 8000,
            maxMarkAge: 1 days
        });
    }
}
