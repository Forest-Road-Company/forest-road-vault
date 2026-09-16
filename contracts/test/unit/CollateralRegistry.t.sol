// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CollateralFixture} from "../helpers/CollateralFixture.sol";

contract CollateralRegistryTest is CollateralFixture {
    bytes32 internal constant REGISTRY_STORAGE_LOCATION =
        0xd1052ad481f6f823017e987ee43475f3a84883a50e791c5b4260ba144e440700;

    // ── init / setClass ──────────────────────────────────────────────────

    function test_initialize_zeroAddressReverts() public {
        CollateralRegistry impl = new CollateralRegistry();
        vm.expectRevert(CollateralRegistry.Registry_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(CollateralRegistry.initialize, (address(0), admin)));
    }

    function test_setClass_fiveGenesisClassesLive() public view {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertTrue(registry.classParams(c).active, "genesis class inactive");
        }
        // the fifth class is marked-to-market, per ADR-0015 — not a receivable clone
        assertEq(
            uint8(registry.classParams(Config.CLASS_DIGITAL_ASSETS).model),
            uint8(ICollateralRegistry.CollateralModel.MarkedToMarket)
        );
    }

    function test_setClass_unknownIdReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_UnknownClass.selector, 6));
        registry.setClass(6, _receivable("X", 5000, 1000, 3, 365 days, 3000));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_UnknownClass.selector, 0));
        registry.setClass(0, _receivable("X", 5000, 1000, 3, 365 days, 3000));
    }

    function test_setClass_badParamsRevert() public {
        vm.startPrank(admin);
        // zero LTV
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setClass(1, _receivable("X", 0, 1000, 3, 365 days, 3000));
        // receivable class carrying margin params
        ICollateralRegistry.ClassParams memory p = _receivable("X", 5000, 1000, 3, 365 days, 3000);
        p.marginCallLtvBps = 6000;
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setClass(1, p);
        // MTM class with incoherent thresholds (margin call below draw ceiling)
        ICollateralRegistry.ClassParams memory m = registry.classParams(Config.CLASS_DIGITAL_ASSETS);
        m.marginCallLtvBps = m.maxLtvBps; // must be strictly greater
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setClass(Config.CLASS_DIGITAL_ASSETS, m);
        // MTM class without a freshness bound
        m = registry.classParams(Config.CLASS_DIGITAL_ASSETS);
        m.maxMarkAge = 0;
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setClass(Config.CLASS_DIGITAL_ASSETS, m);
        vm.stopPrank();
    }

    function test_setClass_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, originator, bytes32(0))
        );
        vm.prank(originator);
        registry.setClass(1, _receivable("X", 5000, 1000, 3, 365 days, 3000));
    }

    function test_setClass_modelImmutableAfterConfiguration() public {
        ICollateralRegistry.ClassParams memory receivableToMtm = registry.classParams(1);
        receivableToMtm.model = ICollateralRegistry.CollateralModel.MarkedToMarket;
        receivableToMtm.marginCallLtvBps = 8500;
        receivableToMtm.liquidationLtvBps = 9000;
        receivableToMtm.maxMarkAge = 1 days;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_ModelImmutable.selector, 1));
        registry.setClass(1, receivableToMtm);

        ICollateralRegistry.ClassParams memory mtmToReceivable = registry.classParams(Config.CLASS_DIGITAL_ASSETS);
        mtmToReceivable.model = ICollateralRegistry.CollateralModel.Receivable;
        mtmToReceivable.marginCallLtvBps = 0;
        mtmToReceivable.liquidationLtvBps = 0;
        mtmToReceivable.maxMarkAge = 0;

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ModelImmutable.selector, Config.CLASS_DIGITAL_ASSETS)
        );
        registry.setClass(Config.CLASS_DIGITAL_ASSETS, mtmToReceivable);
    }

    function test_setClass_sameModelUpdateAllowed() public {
        ICollateralRegistry.ClassParams memory updated = registry.classParams(1);
        updated.maxLtvBps -= 1;

        vm.prank(admin);
        registry.setClass(1, updated);

        assertEq(registry.classParams(1).maxLtvBps, updated.maxLtvBps);
    }

    function test_F4_setClassAcceptsExactMaxLtvAndRejectsOneAbove() public {
        ICollateralRegistry.ClassParams memory p = registry.classParams(1);
        p.maxLtvBps = uint16(Config.BPS);
        vm.prank(admin);
        registry.setClass(1, p);
        assertEq(registry.classParams(1).maxLtvBps, Config.BPS);

        p.maxLtvBps = uint16(Config.BPS) + 1;
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        vm.prank(admin);
        registry.setClass(1, p);
    }

    // ── exposure + concentration ─────────────────────────────────────────

    function test_recordExposure_tracksAllDimensions() public {
        vm.prank(creditModule);
        registry.recordExposureIncrease(1, BORROWER_1, STATE_GA, 1_000e18);
        assertEq(registry.classExposure(1), 1_000e18);
        assertEq(registry.borrowerExposure(BORROWER_1), 1_000e18);
        assertEq(registry.stateExposure(STATE_GA), 1_000e18);
        assertEq(registry.totalBookExposure(), 1_000e18);

        vm.prank(creditModule);
        registry.recordExposureDecrease(1, BORROWER_1, STATE_GA, 400e18);
        assertEq(registry.classExposure(1), 600e18);
        assertEq(registry.totalBookExposure(), 600e18);
    }

    function test_recordExposure_onlyCreditRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, originator, Roles.CREDIT_ROLE
            )
        );
        vm.prank(originator);
        registry.recordExposureIncrease(1, BORROWER_1, STATE_GA, 1);
    }

    function test_concentration_bootstrapFloorAdmitsYoungBook() public {
        // below the floor (default 25M), the first facility passes despite being
        // 100% of the book — the floor exists exactly for genesis
        vm.prank(creditModule);
        registry.recordExposureIncrease(1, BORROWER_1, STATE_GA, 1_000e18);
        assertEq(registry.classExposure(1), 1_000e18);
    }

    function test_headroomClampsAPreBoundOversizedLegacyFloor() public {
        uint256 maxSafeExposure = type(uint256).max / Config.BPS;
        vm.store(address(registry), bytes32(uint256(REGISTRY_STORAGE_LOCATION) + 7), bytes32(maxSafeExposure + 1));

        uint256 room = registry.concentrationHeadroom(1, BORROWER_1, STATE_GA);
        assertLe(room, maxSafeExposure, "defensive read clamps an oversized pre-upgrade floor");
    }

    /// @dev Builds a 3,200-unit diversified book (classes 1-4 × 800, distinct
    ///      borrowers) and THEN lowers the bootstrap floor under it, so relative limits
    ///      are the binding constraint for the next add.
    /// @dev AUDIT FIX M-02 (round 2): the book is built at the launch floor and the floor
    ///      is lowered afterwards. It can no longer be built at `floor = 800e18` — every
    ///      dimension is now capped at `limitBps` of `max(book, floor)`, so 800e18 into a
    ///      class capped at 3500bps of an 800e18 floor (= 280e18) is correctly rejected.
    ///      That is the point of the fix: the floor is a floor on the ASSUMED BOOK SIZE,
    ///      not a per-bucket exemption that let any dimension grow to the floor unchecked.
    function _buildBook() internal {
        vm.startPrank(creditModule);
        registry.recordExposureIncrease(1, BORROWER_1, STATE_GA, 800e18);
        registry.recordExposureIncrease(2, BORROWER_2, bytes32(0), 800e18);
        registry.recordExposureIncrease(3, keccak256("b3"), bytes32(0), 800e18);
        registry.recordExposureIncrease(4, keccak256("b4"), bytes32(0), 800e18);
        vm.stopPrank();
        vm.prank(admin);
        registry.setConcentrationFloor(800e18);
    }

    function test_concentration_classLimitEnforced() public {
        _buildBook(); // total 3200; class 5 cap 20% of post-add book
        vm.startPrank(creditModule);
        // 801/4001 = 20.02% > 20% AND above the 800 floor → binds
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector, Config.CLASS_DIGITAL_ASSETS, 801e18, 2000
            )
        );
        registry.recordExposureIncrease(Config.CLASS_DIGITAL_ASSETS, keccak256("fr-sub"), bytes32(0), 801e18);
        // 800/4000 = 20.00% exactly is admissible for the CLASS — but it has to be split so
        // that no single borrower blows its own (tighter, 1500bps) cap on the way in
        registry.recordExposureIncrease(Config.CLASS_DIGITAL_ASSETS, keccak256("fr-sub-b"), bytes32(0), 200e18);
        registry.recordExposureIncrease(Config.CLASS_DIGITAL_ASSETS, keccak256("fr-sub"), bytes32(0), 600e18);
        vm.stopPrank();
        assertEq(registry.classExposure(Config.CLASS_DIGITAL_ASSETS), 800e18);
        assertEq(registry.classConcentrationBps(Config.CLASS_DIGITAL_ASSETS), 2000, "exactly at the class cap");
    }

    function test_concentration_borrowerLimitEnforced() public {
        _buildBook(); // BORROWER_1 sits at 800 == floor
        vm.startPrank(creditModule);
        // +1 pushes BORROWER_1 to 801 > floor; 801/3201 = 25% > 15% → binds
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, BORROWER_1, 801e18, 1500
            )
        );
        registry.recordExposureIncrease(2, BORROWER_1, bytes32(0), 1e18);
        // a fresh borrower below the floor is fine
        registry.recordExposureIncrease(2, keccak256("b5"), bytes32(0), 300e18);
        vm.stopPrank();
    }

    function test_concentration_stateLimitEnforced() public {
        _buildBook(); // STATE_GA sits at 800 == floor; book 3200
        vm.startPrank(creditModule);
        // +401 → GA 1201 > floor; 1201/3601 = 33% > 25% → binds
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_StateConcentrationExceeded.selector, STATE_GA, 1201e18, 2500
            )
        );
        registry.recordExposureIncrease(1, keccak256("b6"), STATE_GA, 401e18);
        // +200 → GA 1000 > floor but 1000/3400 = 29.4%... still over; use NV instead:
        // fresh state below floor passes, and zero stateId is never state-limited
        registry.recordExposureIncrease(1, keccak256("b6"), STATE_NV, 200e18);
        registry.recordExposureIncrease(3, keccak256("b7"), bytes32(0), 100e18);
        vm.stopPrank();
    }

    function test_concentration_inactiveClassReverts() public {
        ICollateralRegistry.ClassParams memory p = registry.classParams(1);
        p.active = false;
        vm.prank(admin);
        registry.setClass(1, p);
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_ClassInactive.selector, 1));
        registry.recordExposureIncrease(1, BORROWER_1, STATE_GA, 1e18);
    }

    function test_exposureDecrease_underflowReverts() public {
        vm.prank(creditModule);
        vm.expectRevert(ICollateralRegistry.Registry_ExposureUnderflow.selector);
        registry.recordExposureDecrease(1, BORROWER_1, STATE_GA, 1);
    }

    function test_limits_settersValidateAndEmit() public {
        vm.startPrank(admin);
        registry.setBorrowerLimit(2000);
        registry.setStateLimit(3000);
        registry.setConcentrationFloor(123e18);
        (uint16 b, uint16 s, uint256 f) = registry.limits();
        assertEq(b, 2000);
        assertEq(s, 3000);
        assertEq(f, 123e18);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setBorrowerLimit(0);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setStateLimit(10_001);
        vm.stopPrank();
    }

    function test_syncConcentrationBreaches_checksExplicitStateIds() public {
        bytes32[] memory borrowers = new bytes32[](0);
        bytes32[] memory states = new bytes32[](1);
        states[0] = STATE_GA;
        registry.syncConcentrationBreaches(borrowers, states);
        bool[] memory over = registry.overConcentratedStates(states);
        assertFalse(over[0]);
    }

    function test_classParams_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_UnknownClass.selector, 6));
        registry.classParams(6);
    }

    function test_setClass_badConcentrationLimitReverts() public {
        vm.prank(admin);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setClass(1, _receivable("X", 5000, 1000, 3, 365 days, 0)); // zero limit
    }

    function test_checkConcentration_viewMatchesWritePath() public {
        // the view variant: passes quietly under the floor, reverts over a limit
        registry.checkConcentration(1, BORROWER_1, STATE_GA, 1_000e18);
        _buildBook();
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector, Config.CLASS_DIGITAL_ASSETS, 801e18, 2000
            )
        );
        registry.checkConcentration(Config.CLASS_DIGITAL_ASSETS, keccak256("fr-sub"), bytes32(0), 801e18);
        // unknown class through the internal path
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_UnknownClass.selector, 6));
        registry.checkConcentration(6, BORROWER_1, bytes32(0), 1);
    }

    function test_upgrade_authorizedOnly() public {
        address newImpl = address(new CollateralRegistry());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, originator, Roles.UPGRADER_ROLE
            )
        );
        vm.prank(originator);
        registry.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        registry.upgradeToAndCall(newImpl, "");
        assertTrue(registry.classParams(1).active);
    }
}
