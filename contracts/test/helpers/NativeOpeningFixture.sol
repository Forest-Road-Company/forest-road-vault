// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture, NativeAccrualCoverageFunding} from "./NativeAccrualFixture.sol";
import {ProductionCreditFixture} from "./ProductionCreditFixture.sol";
import {AccrualDebtReference} from "./AccrualDebtReference.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Legacy funding through real native modules before binding continuous recognition.
///      The independent note model supplies signed openings and subsequent contractual debt.
abstract contract NativeOpeningFixture is NativeAccrualFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function setUp() public virtual override {
        ProductionCreditFixture.setUp();
        _prepareNativeAsset();
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, CURATOR_CAPITAL);
        _mintUSDfrTo(alice, SENIOR_CAPITAL);
        vm.startPrank(alice);
        usdfr.approve(address(vault), SENIOR_CAPITAL);
        vault.deposit(SENIOR_CAPITAL, alice);
        vm.stopPrank();
        address coverage = _nativeBackstop();
        if (coverage != address(0)) {
            _mintUSDfrTo(bob, COVERAGE_CAPITAL);
            vm.startPrank(bob);
            usdfr.approve(coverage, COVERAGE_CAPITAL);
            NativeAccrualCoverageFunding(coverage).fundCoverage(COVERAGE_CAPITAL);
            vm.stopPrank();
        }
        nativeStart = uint64(block.timestamp);
        _assertNativeBacking();
    }

    function _legacyFund(uint256 principal) internal {
        nativeId = _originateFilm(BORROWER_1, STATE_GA, principal);
        _fundFacility(nativeId, principal);
        AccrualDebtReference.Note memory n;
        n.principal = principal;
        n.scale = _nativeScale();
        n.year = 360 days;
        n.rate = 1400;
        n.interval = 90 days;
        n.due = nativeStart + n.interval;
        n.maturity = nativeStart + _fixtureFilmTenor();
        n.pik = _pikFacilities();
        n.ceiling = n.pik
            ? type(uint256).max / 10_000
            : principal + principal * 1400 * _fixtureFilmTenor() / (10_000 * n.year) / n.scale * n.scale;
        n.open(nativeStart);
        nativeReference = n;
        assertFalse(reserves.accrualSnapshot().enabled, "fixture funded an enabled book");
        assertEq(reserves.deployedTo(nativeId), principal, "legacy native face");
    }

    function _bindOpeningConsumers() internal {
        vm.startPrank(admin);
        reserves.configureContinuousAccrual(
            IContinuousAccrual.Modules({
                token: address(usdfr),
                controller: address(controller),
                vault: address(vault),
                waterfall: address(waterfall),
                bridge: address(bridge),
                registry: address(registry),
                defaultManager: address(defaultManager)
            })
        );
        usdfr.setAccrualReserve(address(reserves));
        controller.enableContinuousAccrual();
        vault.setAccrualReserve(address(reserves));
        registry.setAccrualReserve(address(reserves));
        bridge.setAccrualReserve(address(reserves));
        waterfall.setAccrualReserve(address(reserves));
        defaultManager.setAccrualReserve(address(reserves));
        realOracle.grantRole(Roles.CREDIT_ROLE, address(reserves));
        vm.stopPrank();
    }

    function _beginOpening(uint256[] memory ids) internal {
        _step(0, abi.encode(ids));
    }

    function _beginOne() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = nativeId;
        _beginOpening(ids);
    }

    function _step(uint8 action, bytes memory body) internal {
        vm.prank(admin);
        reserves.prepareContinuousAccrualMigration(abi.encode(action, body));
    }

    function _referenceOpening() internal view returns (IAccrualMigration.Opening memory) {
        AccrualDebtReference.Note memory n = nativeReference;
        return IAccrualMigration.Opening({
            facilityId: nativeId,
            principal: n.principal,
            interest: n.interest,
            frozenPikBasis: n.pik ? n.frozenBasis : 0,
            periodStart: n.epochStart,
            nextCapitalization: n.pik ? n.due : 0,
            approvalRef: bytes32(0)
        });
    }

    function _openingPayload(IAccrualMigration.Opening memory opening) internal view returns (bytes32) {
        ClaimBridge.Facility memory f = bridge.facility(opening.facilityId);
        bytes32 record = keccak256(
            abi.encode(
                reserves.accrualMigration().sessionKey,
                opening.facilityId,
                _nativeAsset(),
                reserves.deployedTo(opening.facilityId),
                keccak256(abi.encode(f))
            )
        );
        return keccak256(
            abi.encode(
                keccak256("AccrualOpening(bytes32 frozenRecord,bytes32 opening)"),
                record,
                keccak256(abi.encode(opening))
            )
        );
    }

    function _signOpening(IAccrualMigration.Opening memory opening) internal {
        _attest(
            opening.facilityId,
            IAttestationOracle.AttestationKind.AccrualOpening,
            _openingPayload(opening),
            reserves.accrualMigration().cutoff
        );
    }

    function _importOne(IAccrualMigration.Opening memory opening) internal {
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](1);
        batch[0] = opening;
        _step(1, abi.encode(batch));
    }

    function _prepareOne(uint64 at) internal {
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(at);
        nativeReference = n;
        vm.warp(at);
        _bindOpeningConsumers();
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signOpening(opening);
        _importOne(opening);
    }

    function _enableOpening() internal {
        vm.prank(admin);
        reserves.enableContinuousAccrual();
        assertFalse(reserves.accrualMigration().active, "migration remained active");
        assertTrue(reserves.accrualSnapshot().enabled, "complete book not enabled");
    }
}
