// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MisbehavingBackstop} from "../helpers/MockCascadeBackstop.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract ToggleCapacityBackstop is ICascadeBackstop {
    bool internal unavailable;
    uint256 internal capacity;

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function setCapacity(uint256 value) external {
        capacity = value;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function coverageCapacity() external view returns (uint256) {
        if (unavailable) revert("capacity unavailable");
        return capacity;
    }

    function coverageCapacityAt(uint256 reserve) external view returns (uint256) {
        if (unavailable) revert("capacity unavailable");
        return reserve < capacity ? reserve : capacity;
    }

    function coverageCapParameters() external view returns (uint16 proportionalBps, uint256 absoluteCap) {
        if (unavailable) revert("capacity unavailable");
        return (uint16(Config.BPS), capacity);
    }

    function coverageReserve() external view returns (uint256) {
        // One unreadable state, one diagnostic: W7's ladder reads the shared reserve before it
        // asks for any event's counterfactual cap, while the pre-W7 aggregate read did the reverse.
        if (unavailable) revert("capacity unavailable");
        return capacity;
    }

    function coverShortfall(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function remainingCoverage(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MalformedCapacityBackstop {
    function coverageCapacity() external pure {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract CoverageOnlyBackstop {
    function coverageCapacity() external pure returns (uint256) {
        return 1_000e18;
    }
}

/// @dev AUDIT R14-05. Declares the interface correctly but returns a SHORT word from
///      `coverageCapacity()`. Before this mock existed the identity pre-check short-circuited
///      ahead of the length comparison in `_isBackstopReadable`, so the only short-return
///      fixture (`MalformedCapacityBackstop`, which declares no ERC-165) never reached it and
///      the `returndatasize() < 0x20` half of that predicate was untested. This mock is the
///      only fixture that can exercise it.
contract DeclaredButMalformedBackstop {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function coverageCapacity() external pure {
        assembly ("memory-safe") {
            mstore(0x00, 1)
            return(0x00, 16) // half a word: well-formed identity, malformed valuation
        }
    }

    function coverShortfall(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev W7 pair-return counterpart of `DeclaredButMalformedBackstop`: every other capability is
///      present, but `coverageCapParameters()` returns only one of its two ABI words.
contract DeclaredButShortCapParametersBackstop {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function coverageCapacity() external pure returns (uint256) {
        return 1;
    }

    function coverageCapacityAt(uint256) external pure returns (uint256) {
        return 1;
    }

    function coverageCapParameters() external pure {
        assembly ("memory-safe") {
            mstore(0x00, 10000)
            return(0x00, 0x20)
        }
    }

    function coverageReserve() external pure returns (uint256) {
        return 1;
    }

    function remainingCoverage(uint256) external pure returns (uint256) {
        return 0;
    }

    function coverShortfall(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev AUDIT R14-04. Models an ALREADY-DEPLOYED backstop that predates the ERC-165 identity
///      gate: fully functional capacity, no interface declaration. It starts declaring so it
///      can be installed through the ordinary validated path, then drops the declaration.
contract DroppableIdentityBackstop {
    bool internal declares = true;
    uint256 internal capacity;

    function setDeclares(bool value) external {
        declares = value;
    }

    function setCapacity(uint256 value) external {
        capacity = value;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (!declares) return false;
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function coverageCapacity() external view returns (uint256) {
        return capacity;
    }

    function coverageCapacityAt(uint256 reserve) external view returns (uint256) {
        return reserve < capacity ? reserve : capacity;
    }

    function coverageCapParameters() external view returns (uint16 proportionalBps, uint256 absoluteCap) {
        return (uint16(Config.BPS), capacity);
    }

    function coverageReserve() external view returns (uint256) {
        return capacity;
    }

    function remainingCoverage(uint256) external pure returns (uint256) {
        return 0;
    }

    function coverShortfall(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract DefaultManagerTest is CreditLayerFixture {
    uint256 internal constant FILM = 1;
    uint256 internal constant DEFAULT_MANAGER_STORAGE_ROOT =
        0x336a2060fa754acf2cdfdb8c351983bf3b455537ad219c0e1b705a95a2f8a200;
    uint256 internal constant LIVE_DEFAULT_COVERAGE_CONSUMED_SLOT = DEFAULT_MANAGER_STORAGE_ROOT + 15;
    uint256 internal constant COMMITMENT_LEDGER_SLOT = DEFAULT_MANAGER_STORAGE_ROOT + 28;

    // ── helpers ──────────────────────────────────────────────────────────

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev A live digital-assets facility: principal 500k against a 1M mark (LTV 50%).
    function _liveDigitalFacility() internal returns (uint256 id) {
        _mintUSDfr(alice, 500_000e6);
        id = _originateDigital(500_000e18, 1_000_000e18);
        _fundFacility(id, 500_000e18);
    }

    function _defaulted(uint256 principal) internal returns (uint256 id) {
        id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    // ── initialize ───────────────────────────────────────────────────────

    function test_initialize_zeroAddressReverts() public {
        DefaultManager impl = new DefaultManager();
        DefaultManager.InitModules memory m = DefaultManager.InitModules({
            bridge: address(bridge),
            registry: address(registry),
            reserves: address(reserves),
            controller: address(controller),
            curator: address(curator),
            oracle: address(oracle),
            usdfr: address(usdfr),
            vault: address(vault)
        });
        m.curator = address(0);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(DefaultManager.initialize, (admin, guardian, admin, m)));
        m.curator = address(curator);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(DefaultManager.initialize, (address(0), guardian, admin, m)));
    }

    function test_initialize_seedsCureWindowsAndWiring() public view {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(defaultManager.cureWindow(c), Config.DEFAULT_MARGIN_CURE_WINDOW);
        }
        (address b, address r, address rs, address c_, address cu, address o, address v, address ledger) =
            defaultManager.modules();
        assertEq(b, address(bridge));
        assertEq(r, address(registry));
        assertEq(rs, address(reserves));
        assertEq(c_, address(controller));
        assertEq(cu, address(curator));
        assertEq(o, address(oracle));
        assertEq(v, address(vault));
        assertGt(ledger.code.length, 0);
        assertEq(defaultManager.backstop(), address(backstopMock));
    }

    function test_initializeCommitmentLedger_migratesAnUndrawnPreLedgerProxy() public {
        // A proxy upgraded from the pre-ledger implementation has the append-only tail at zero.
        // Fabricate that exact state without replacing the implementation or bypassing access
        // control; the governed migration must deploy and wire one child exactly once.
        vm.store(address(defaultManager), bytes32(COMMITMENT_LEDGER_SLOT), bytes32(0));
        vm.prank(admin);
        defaultManager.initializeCommitmentLedger();

        (,,,,,,, address ledger) = defaultManager.modules();
        assertGt(ledger.code.length, 0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerAlreadySet.selector, ledger)
        );
        defaultManager.initializeCommitmentLedger();
    }

    function test_initializeCommitmentLedger_refusesToEraseConsumedCoverage() public {
        vm.store(address(defaultManager), bytes32(COMMITMENT_LEDGER_SLOT), bytes32(0));
        vm.store(address(defaultManager), bytes32(LIVE_DEFAULT_COVERAGE_CONSUMED_SLOT), bytes32(uint256(1)));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe.selector, 1)
        );
        defaultManager.initializeCommitmentLedger();
    }

    function test_initializeCommitmentLedger_refusesToEraseUndrawnDefaults() public {
        _defaulted(100_000e18);
        vm.store(address(defaultManager), bytes32(COMMITMENT_LEDGER_SLOT), bytes32(0));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe.selector, 100_000e18)
        );
        defaultManager.initializeCommitmentLedger();
    }

    // ── declareDefault / accelerate ──────────────────────────────────────

    function test_declareDefault_freezesAndEmitsRemedy() public {
        vm.prank(admin);
        defaultManager.setRemedyRef(FILM, keccak256("ucc-enforcement-playbook"));
        uint256 id = _liveFilmFacility(100_000e18);

        _attestDefault(id);
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.DefaultDeclared(id, FILM, keccak256("ucc-enforcement-playbook"));
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.RemedyInitiated(id, FILM, keccak256("ucc-enforcement-playbook"));
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted));
        // the dual-record freeze: the position NFT cannot move
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_PositionFrozen.selector, id));
        bridge.transferFrom(custodian, admin, id);
        // AUDIT FIX (R4-EC2): declaring the default froze curator withdrawals for the class
        assertEq(curator.unresolvedDefaults(FILM), 1, "curator withdrawals frozen on default");
    }

    function test_declareDefault_supersedesActiveMarginCall() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp)); // LTV 66.7% > 65%
        defaultManager.marginCall(id);
        assertGt(defaultManager.cureDeadline(id), 0);

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(defaultManager.cureDeadline(id), 0, "margin call cleared by default declaration");
    }

    function test_declareDefault_wrongStateReverts() public {
        _mintUSDfr(alice, 100_000e6);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18); // Pending
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 id2 = _defaulted(100_000e18); // already Defaulted
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id2));
        vm.prank(servicer);
        defaultManager.declareDefault(id2, FILM_REF);
    }

    function test_markPastDue_rejectsPendingReceivable() public {
        _mintUSDfr(alice, 100_000e6);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.markPastDue(id);
    }

    /// @dev Phase G (ADR-0020): the role alone is not enough — the attested
    ///      DefaultDeclared fact gates whether a default can be declared at all.
    function test_declareDefault_withoutAttestationReverts() public {
        uint256 id = _liveFilmFacility(100_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    function test_declareDefault_onlyServicer() public {
        uint256 id = _liveFilmFacility(100_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.SERVICER_ROLE)
        );
        vm.prank(alice);
        defaultManager.declareDefault(id, FILM_REF);
    }

    function test_accelerate_fromDefaultedOnly() public {
        uint256 id = _defaulted(100_000e18);
        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.Accelerated(id);
        vm.prank(servicer);
        defaultManager.accelerate(id);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Accelerated));

        uint256 live = _liveFilmFacility(50_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotInDefault.selector, live));
        vm.prank(servicer);
        defaultManager.accelerate(live);
    }

    function test_accelerate_onlyServicer() public {
        uint256 id = _defaulted(100_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.SERVICER_ROLE)
        );
        vm.prank(alice);
        defaultManager.accelerate(id);
    }

    // ── realizeLoss: the three-layer cascade ─────────────────────────────

    function test_realizeLoss_layer1Only_curatorAbsorbsAll() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18);
        _stakeVault(alice, 100_000e18);
        uint256 id = _defaulted(300_000e18);
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 supplyBefore = usdfr.totalSupply();

        _attestLoss(id, 300_000e18, FILM_REF);
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.LossRealized(id, FILM, 300_000e18, 300_000e18, 0, 0);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);

        assertEq(curator.poolBalance(FILM), 200_000e18, "curator pool bears it all");
        assertEq(usdfr.totalSupply(), supplyBefore - 300_000e18, "supply burned == loss");
        assertEq(reserves.deployedTo(id), 0, "principal written down");
        assertEq(registry.classExposure(FILM), 0, "exposure released");
        assertEq(
            uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "a full write-off is terminal"
        );
        assertEq(vault.currentExchangeRate(), rateBefore, "depositors untouched");
        assertTrue(controller.backingInvariantHolds());
    }

    // ── ADR-0022 conservative-redemption-NAV impairment engine ────────────

    function test_impairment_declareAddsRealizeRemoves() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18);
        _stakeVault(alice, 100_000e18);
        uint256 id = _defaulted(300_000e18);
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 300_000e18, "declare adds outstanding to the pool");

        _realizeLoss(id, 300_000e18, FILM_REF);
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "realize removes the realized portion");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no unrealized default left");
        assertEq(defaultManager.performanceFeeImpairment(), 0, "gross fee impairment releases with realization");
    }

    function test_impairment_pendingSeniorImpairment_netsCuratorThenSGrove() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18); // layer 1 (per class) = 100k
        _fundBackstop(50_000e18); // layer 2 (global sGROVE per-event capacity) = 50k
        _stakeVault(alice, 400_000e18);
        _defaulted(300_000e18); // 300k at risk
        // (300k − 100k curator) − 50k sGROVE = 150k reaches senior
        assertEq(defaultManager.pendingSeniorImpairment(), 150_000e18, "nets curator first, then sGROVE");
        assertEq(
            defaultManager.performanceFeeImpairment(),
            300_000e18,
            "fee impairment excludes both contributed junior layers"
        );
    }

    function test_impairment_fullyCoveredByJuniors_isZero() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18); // curator alone covers the 300k
        _stakeVault(alice, 100_000e18);
        _defaulted(300_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "juniors fully cover, senior unmarked");
        assertEq(defaultManager.performanceFeeImpairment(), 300_000e18, "junior cover is not senior performance");
    }

    function test_reserveWriteDownUsesCuratorThenBackstopThenSenior() public {
        _postFirstLoss(anchorCurator, FILM, 10e18);
        _fundBackstop(10e18);
        _stakeVault(alice, 100e18);

        _armReserveLoss(10);
        _createReserveShortfall(25e18);
        _ratifyCurrentReserveLoss(25e18);

        assertEq(curator.poolBalance(FILM), 0, "curator first-loss must be exhausted first");
        assertEq(usdfr.balanceOf(address(backstopMock)), 0, "sGROVE reserve must absorb second");
        assertEq(vault.totalAssets(), 95e18, "senior absorbs only the final residual");
        assertEq(usdfr.totalSupply(), 95e18, "supply falls by the custody loss");
        assertEq(reserves.totalBackingValue(), 95e18, "backing falls by the paired amount");
        assertTrue(controller.backingInvariantHolds(), "C-01: no supply-over-backing gap");
    }

    function test_reserveWriteDownBeyondVaultCapacitySucceedsWhenJuniorsCover() public {
        _mintUSDfrTo(alice, 100e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 40e18);
        vault.deposit(40e18, alice);
        vm.stopPrank();

        _postFirstLoss(anchorCurator, FILM, 30e18);
        _fundBackstop(20e18);
        _armReserveLoss(11);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);

        assertEq(curator.poolBalance(FILM), 0, "layer 1 supplies 30");
        assertEq(usdfr.balanceOf(address(backstopMock)), 0, "layer 2 supplies 20");
        assertEq(vault.totalAssets(), 40e18, "senior is untouched when juniors cover");
        assertEq(usdfr.totalSupply(), 100e18, "the 50 junior tokens were burned");
        assertEq(reserves.totalBackingValue(), 100e18, "the full loss was recorded");
        assertTrue(controller.backingInvariantHolds(), "junior coverage preserves backing");
    }

    function test_reserveWriteDownAllocatesCuratorsBySnapshotPoolBalanceWithDeterministicDust() public {
        uint256[5] memory posted = [uint256(1e18), 1e18, 1e18, 1e18, 2e18];
        for (uint256 i = 0; i < posted.length; ++i) {
            _postFirstLoss(anchorCurator, i + 1, posted[i]);
        }

        _armReserveLoss(12);
        _createReserveShortfall(1e12); // one native USDC unit; deliberately indivisible by six
        _ratifyCurrentReserveLoss(1e12);

        uint256[5] memory absorbed =
            [uint256(166_666_666_669), 166_666_666_666, 166_666_666_666, 166_666_666_666, 333_333_333_333];
        uint256 sum;
        for (uint256 i = 0; i < posted.length; ++i) {
            assertEq(curator.poolBalance(i + 1), posted[i] - absorbed[i], "pool-weighted allocation drift");
            sum += absorbed[i];
        }
        assertEq(sum, 1e12, "all rounding dust must have a deterministic home");
        assertEq(vault.totalAssets(), 0, "junior capacity prevents senior loss");
        assertEq(reserves.reserveDeficit(), 0);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_reserveWriteDownReusesOneSharedReserveAcrossPartialIncidentWrites() public {
        _fundBackstop(50e18);
        _stakeVault(alice, 20e18);
        (, uint256 expectedIncidentId) = _armReserveLoss(13);

        _createReserveShortfall(30e18);
        (uint256 incidentId,) = _ratifyCurrentReserveLoss(30e18);
        _createReserveShortfall(30e18);
        (uint256 repeatedIncidentId,) = _ratifyCurrentReserveLoss(30e18);
        assertEq(incidentId, expectedIncidentId);
        assertEq(repeatedIncidentId, incidentId, "every tranche must reuse the arm-derived incident id");

        (uint256 drawn, uint256 cap) = backstopMock.eventCoverage(incidentId);
        assertEq(cap, 50e18, "event view must equal cumulative draw once reserve is empty");
        assertEq(drawn, 50e18, "splitting cannot deliver more than the shared reserve");
        assertEq(vault.totalAssets(), 10e18, "senior receives only the amount above the shared reserve");
        assertEq(reserves.reserveDeficit(), 0);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_reserveWriteDownCannotMutateF1801FacilityConsumptionAccounting() public {
        _fundBackstop(200e18);
        _stakeVault(alice, 100e18);
        uint256 tokenId = _defaulted(300e18);
        _attestLoss(tokenId, 50e18, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(tokenId, 50e18, FILM_REF);

        uint256 consumedByFacility = defaultManager.coverageConsumedByDefault(tokenId);
        uint256 drawnPrincipal = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 liveConsumed = defaultManager.liveDefaultCoverageConsumed();
        uint256 capacityFloor = defaultManager.liveDefaultCapacityFloor();
        assertGt(consumedByFacility, 0, "fixture must arm F-18-01 accounting");
        assertEq(capacityFloor, 250e18, "compatibility view must expose the live remaining-principal claim");
        assertEq(
            capacityFloor,
            defaultManager.liveDefaultCoverageRemaining(),
            "compatibility and canonical observability must agree"
        );

        (, uint256 expectedIncidentId) = _armReserveLoss(14);
        _createReserveShortfall(20e18);
        (uint256 incidentId,) = _ratifyCurrentReserveLoss(20e18);
        assertEq(incidentId, expectedIncidentId);

        assertEq(defaultManager.coverageConsumedByDefault(tokenId), consumedByFacility);
        assertEq(defaultManager.drawnDefaultPrincipal(FILM), drawnPrincipal);
        assertEq(defaultManager.liveDefaultCoverageConsumed(), liveConsumed);
        assertEq(
            defaultManager.liveDefaultCapacityFloor(),
            capacityFloor,
            "an unrelated custody loss cannot mutate the facility commitment"
        );

        (uint256 custodyDrawn,) = backstopMock.eventCoverage(incidentId);
        (uint256 facilityDrawn,) = backstopMock.eventCoverage(tokenId);
        assertEq(custodyDrawn, 20e18, "custody incident uses its own upper-namespace cap");
        assertEq(facilityDrawn, consumedByFacility, "facility event remains in the lower namespace");
        assertLt(tokenId, 1 << 255);
        assertGe(incidentId, 1 << 255);
    }

    function test_unabsorbableReserveWriteDownExhaustsCascadeThenRecordsDeficit() public {
        _postFirstLoss(anchorCurator, FILM, 10e18);
        _fundBackstop(10e18);
        _stakeVault(alice, 10e18);
        _mintUSDfrTo(alice, 20e18); // deliberately unstaked supply beyond all absorber capacity
        _armReserveLoss(15);

        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);

        assertEq(curator.poolBalance(FILM), 0);
        assertEq(usdfr.balanceOf(address(backstopMock)), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(reserves.reserveDeficit(), 20e18, "unabsorbed remainder is recorded, not rolled back");
        assertFalse(controller.backingInvariantHolds(), "genuine insolvency freezes mint/redeem");
    }

    function test_laterReserveLossStillConsumesRefilledJuniorCapitalWhileDeficitIsLatched() public {
        _postFirstLoss(anchorCurator, FILM, 10e18);
        _fundBackstop(10e18);
        _stakeVault(alice, 10e18);
        _mintUSDfrTo(alice, 20e18);
        _armReserveLoss(16);

        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);
        assertEq(reserves.reserveDeficit(), 20e18);

        vm.prank(alice);
        usdfr.transfer(anchorCurator, 5e18);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), 5e18);
        curator.postFirstLoss(FILM, 5e18);
        vm.stopPrank();

        vm.startPrank(admin);
        reserves.grantRole(Roles.CONTROLLER_ROLE, admin);
        vm.stopPrank();
        usdc.mint(bob, 10e6);
        vm.prank(bob);
        usdc.approve(address(reserves), 10e6);
        vm.prank(admin);
        reserves.depositUSDC(bob, 10e6);
        vm.prank(admin);
        reserves.revokeRole(Roles.CONTROLLER_ROLE, admin);

        _createReserveShortfall(5e18);
        _ratifyCurrentReserveLoss(5e18);

        assertEq(curator.poolBalance(FILM), 0, "later custody loss must consult refilled layer 1");
        assertEq(usdfr.totalSupply(), 15e18, "refilled junior capital was burned despite the old deficit");
        assertEq(reserves.totalBackingValue(), 5e18);
        assertEq(reserves.reserveDeficit(), 10e18, "latch tracks the measured remaining deficit");
    }

    function test_onDefaultResolved_revertsUnlessResolved() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18);
        _stakeVault(alice, 100_000e18);
        uint256 id = _defaulted(300_000e18); // Defaulted, not Resolved
        vm.prank(admin);
        defaultManager.grantRole(Roles.CREDIT_ROLE, address(this));
        // defensive check: a CREDIT_ROLE caller cannot clear a still-defaulted loan's
        // contribution (which would UNDER-mark impairment — the unsafe direction)
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotResolved.selector, id));
        defaultManager.onDefaultResolved(id);
    }

    function test_realizeLoss_layer2_backstopCoversResidual() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        _fundBackstop(500_000e18);
        _stakeVault(alice, 100_000e18);
        uint256 id = _defaulted(300_000e18);
        uint256 rateBefore = vault.currentExchangeRate();

        _attestLoss(id, 300_000e18, FILM_REF);
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.LossRealized(id, FILM, 300_000e18, 100_000e18, 200_000e18, 0);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);

        assertEq(curator.poolBalance(FILM), 0, "layer 1 fully drained FIRST");
        assertEq(usdfr.balanceOf(address(backstopMock)), 300_000e18, "backstop paid the residual");
        assertEq(vault.currentExchangeRate(), rateBefore, "depositors still whole");
        assertTrue(controller.backingInvariantHolds());
    }

    function test_realizeLoss_layer3_depositorPrincipalLast() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        _fundBackstop(50_000e18);
        _stakeVault(alice, 400_000e18);
        uint256 id = _defaulted(300_000e18);
        uint256 rateBefore = vault.currentExchangeRate();

        _attestLoss(id, 300_000e18, FILM_REF);
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.LossRealized(id, FILM, 300_000e18, 100_000e18, 50_000e18, 150_000e18);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);

        assertEq(curator.poolBalance(FILM), 0, "layer 1 exhausted");
        assertEq(usdfr.balanceOf(address(backstopMock)), 0, "layer 2 exhausted");
        assertEq(usdfr.balanceOf(address(vault)), 250_000e18, "vault bears exactly the rest");
        assertLt(vault.currentExchangeRate(), rateBefore, "rate falls ONLY here (explicit loss event)");
        assertTrue(controller.backingInvariantHolds());
    }

    function test_realizeLoss_noBackstopWired_layer1ToLayer3() public {
        vm.prank(admin);
        defaultManager.setBackstop(address(0));
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        _stakeVault(alice, 400_000e18);
        uint256 id = _defaulted(300_000e18);

        _attestLoss(id, 300_000e18, FILM_REF);
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.LossRealized(id, FILM, 300_000e18, 100_000e18, 0, 200_000e18);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_realizeLoss_partialLoss_facilityKeepsRemainder() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18);
        uint256 id = _defaulted(300_000e18);
        // recovery came in for 200k first (via waterfall), shortfall is 100k
        _repay(id, 0, 200_000e18);
        _realizeLoss(id, 100_000e18, FILM_REF);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.classExposure(FILM), 0);
        assertEq(curator.poolBalance(FILM), 400_000e18);
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Resolved),
            "cash-first then final write-off resolves"
        );
    }

    function test_realizeLoss_beyondAllLayersRevertsLoudly() public {
        // tiny curator pool, no backstop funds, tiny vault: loss cannot be realized
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        _stakeVault(alice, 1_000e18);
        uint256 id = _defaulted(300_000e18);
        _attestLoss(id, 300_000e18, FILM_REF);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 299_000e18, 1_000e18
            )
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);
    }

    function test_realizeLoss_lossBeyondOutstandingReverts() public {
        uint256 id = _defaulted(100_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsOutstanding.selector, id, 100_001e18, 100_000e18
            )
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 100_001e18, FILM_REF);
    }

    function test_realizeLoss_zeroReverts() public {
        uint256 id = _defaulted(100_000e18);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAmount.selector);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 0, FILM_REF);
    }

    function test_realizeLoss_requiresDefaultedOrAccelerated() public {
        uint256 id = _liveFilmFacility(100_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotInDefault.selector, id));
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 1e18, FILM_REF);
    }

    function test_realizeLoss_worksFromAccelerated() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18);
        uint256 id = _defaulted(100_000e18);
        vm.prank(servicer);
        defaultManager.accelerate(id);
        _realizeLoss(id, 100_000e18, FILM_REF);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Resolved),
            "full accelerated write-off resolves"
        );
    }

    function test_realizeLoss_onlyServicer() public {
        uint256 id = _defaulted(100_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.SERVICER_ROLE)
        );
        vm.prank(alice);
        defaultManager.realizeLoss(id, 1e18, FILM_REF);
    }

    // ── realizeLoss: backstop contract enforcement ───────────────────────

    function test_realizeLoss_backstopReportsWithoutDelivering_reverts() public {
        MisbehavingBackstop bad = new MisbehavingBackstop(IERC20(address(usdfr)), 0);
        vm.prank(admin);
        defaultManager.setBackstop(address(bad));
        uint256 id = _defaulted(100_000e18);
        _attestLoss(id, 100_000e18, FILM_REF);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_BackstopContractViolated.selector, 100_000e18, 100_000e18, 0
            )
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 100_000e18, FILM_REF);
    }

    function test_realizeLoss_backstopOverReports_reverts() public {
        MisbehavingBackstop bad = new MisbehavingBackstop(IERC20(address(usdfr)), 1);
        vm.prank(admin);
        defaultManager.setBackstop(address(bad));
        uint256 id = _defaulted(100_000e18);
        _attestLoss(id, 100_000e18, FILM_REF);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_BackstopContractViolated.selector, 100_000e18, 100_000e18 + 1, 0
            )
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 100_000e18, FILM_REF);
    }

    // ── marked-to-market: marginCall ─────────────────────────────────────

    function test_marginCall_breachStartsCureWindow() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp)); // LTV 66.67%

        (uint256 ltv,) = defaultManager.currentLtvBps(id);
        assertEq(ltv, 6666);

        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.MarginCalled(id, 6666, uint64(block.timestamp + 1 days));
        defaultManager.marginCall(id); // permissionless — no prank needed
        assertEq(defaultManager.cureDeadline(id), uint64(block.timestamp + 1 days));
    }

    function test_marginCall_healthyLtvReverts() public {
        uint256 id = _liveDigitalFacility(); // LTV 50% < 65%
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 5000, 6500)
        );
        defaultManager.marginCall(id);
    }

    function test_marginCall_exactThresholdTriggers() public {
        uint256 id = _liveDigitalFacility();
        // LTV exactly 65%: 500k / x = 0.65 → x = 769_230.769230…e18; pick mark so
        // floor(500k×10000/mark) == 6500: mark = 769_230e18 → ltv = 6500 (floor)
        _setValuation(id, 769_230e18, uint64(block.timestamp));
        (uint256 ltv,) = defaultManager.currentLtvBps(id);
        assertEq(ltv, 6500);
        defaultManager.marginCall(id); // >= threshold: breach
        assertGt(defaultManager.cureDeadline(id), 0);
    }

    function test_marginCall_staleMarkReverts() public {
        uint256 id = _liveDigitalFacility();
        uint64 asOf = uint64(block.timestamp);
        _setValuation(id, 750_000e18, asOf);
        vm.warp(block.timestamp + 30 days); // way past maxMarkAge (1 day)
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ValuationStale.selector, id, asOf, 1 days)
        );
        defaultManager.marginCall(id);
    }

    function test_marginCall_doubleCallReverts() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.marginCall(id);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_AlreadyMarginCalled.selector, id));
        defaultManager.marginCall(id);
    }

    function test_marginCall_receivableClassReverts() public {
        uint256 id = _liveFilmFacility(100_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.marginCall(id);
    }

    function test_marginCall_zeroMarkReverts() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 0, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, id));
        defaultManager.marginCall(id);
    }

    function test_marginCall_nonLiveStateReverts() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 600_000e18, uint64(block.timestamp));
        defaultManager.liquidate(id); // now Defaulted
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.marginCall(id);
    }

    // ── marked-to-market: clearMarginCall ────────────────────────────────

    function test_clearMarginCall_freshHealthyMarkCures() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.marginCall(id);

        // collateral topped up: fresh mark back to 1M (LTV 50%)
        _setValuation(id, 1_000_000e18, uint64(block.timestamp));
        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.MarginCallCleared(id, 5000);
        defaultManager.clearMarginCall(id);
        assertEq(defaultManager.cureDeadline(id), 0);
    }

    function test_clearMarginCall_paydownCures() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.marginCall(id);

        // borrower pays down half the principal: LTV 250k/750k = 33%
        _repay(id, 0, 250_000e18);
        _setValuation(id, 750_000e18, uint64(block.timestamp)); // fresh mark
        defaultManager.clearMarginCall(id);
        assertEq(defaultManager.cureDeadline(id), 0);
    }

    function test_clearMarginCall_staleMarkReverts() public {
        uint256 id = _liveDigitalFacility();
        uint64 markTime = uint64(block.timestamp);
        _setValuation(id, 750_000e18, markTime);
        defaultManager.marginCall(id);
        _setValuation(id, 1_000_000e18, markTime); // healthy but…
        vm.warp(block.timestamp + 2 days); // …now stale (maxMarkAge 1 day)
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ValuationStale.selector, id, markTime, 1 days)
        );
        defaultManager.clearMarginCall(id);
    }

    function test_clearMarginCall_stillBreachedReverts() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.marginCall(id);
        _setValuation(id, 760_000e18, uint64(block.timestamp)); // still 65.8%
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 6578, 6500)
        );
        defaultManager.clearMarginCall(id);
    }

    function test_clearMarginCall_noActiveCallReverts() public {
        uint256 id = _liveDigitalFacility();
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoMarginCall.selector, id));
        defaultManager.clearMarginCall(id);
    }

    // ── marked-to-market: liquidate ──────────────────────────────────────

    function test_liquidate_hardBreachImmediate() public {
        vm.prank(admin);
        defaultManager.setRemedyRef(Config.CLASS_DIGITAL_ASSETS, keccak256("custodian-liquidation"));
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 600_000e18, uint64(block.timestamp)); // LTV 83% ≥ 80%

        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.LiquidationInitiated(id, 8333);
        vm.expectEmit(true, true, false, true);
        emit IDefaultManager.RemedyInitiated(id, Config.CLASS_DIGITAL_ASSETS, keccak256("custodian-liquidation"));
        defaultManager.liquidate(id); // permissionless

        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted));
        // AUDIT FIX (R4-EC2): the MTM liquidation path also freezes curator withdrawals
        assertEq(curator.unresolvedDefaults(Config.CLASS_DIGITAL_ASSETS), 1, "liquidation froze curator");
    }

    function test_liquidate_cureExpiryStillBreached() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp)); // 66.7%: between thresholds
        defaultManager.marginCall(id);

        // not liquidatable while the cure window runs (66.7% < 80%)
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 6666, 8000)
        );
        defaultManager.liquidate(id);

        vm.warp(block.timestamp + 1 days + 1); // cure window expires, still breached
        // Liquidation is value-destructive and must use a fresh professional mark.
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.liquidate(id);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted));
        assertEq(defaultManager.cureDeadline(id), 0, "margin call state cleaned up");
    }

    function test_liquidate_cureExpiryButRecovered_reverts() public {
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp));
        defaultManager.marginCall(id);
        vm.warp(block.timestamp + 1 days + 1);
        // LTV recovered below the margin-call threshold before anyone liquidated:
        // expiry alone must NOT liquidate a healthy facility
        _setValuation(id, 1_000_000e18, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 5000, 8000)
        );
        defaultManager.liquidate(id);
    }

    function test_liquidate_noBreachNoCallReverts() public {
        uint256 id = _liveDigitalFacility(); // healthy 50%
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 5000, 8000)
        );
        defaultManager.liquidate(id);
    }

    function test_liquidate_staleMarkReverts() public {
        uint256 id = _liveDigitalFacility();
        uint64 asOf = uint64(block.timestamp);
        _setValuation(id, 600_000e18, asOf);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ValuationStale.selector, id, asOf, 1 days)
        );
        defaultManager.liquidate(id);
    }

    function test_liquidate_receivableClassReverts() public {
        uint256 id = _liveFilmFacility(100_000e18);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.liquidate(id);
    }

    /// @dev The full ADR-0015 fast path: breach → liquidate → recovery via waterfall →
    ///      shortfall through the cascade.
    function test_liquidate_thenRecoveryAndCascade() public {
        _postFirstLoss(anchorCurator, Config.CLASS_DIGITAL_ASSETS, 200_000e18);
        uint256 id = _liveDigitalFacility(); // 500k outstanding
        _setValuation(id, 600_000e18, uint64(block.timestamp));
        defaultManager.liquidate(id);

        // custodian liquidates collateral for 420k; proceeds attested in
        _repay(id, 0, 420_000e18);
        assertEq(reserves.deployedTo(id), 80_000e18);

        // remaining 80k is the realized shortfall — curator absorbs it
        _realizeLoss(id, 80_000e18, FILM_REF);
        assertEq(curator.poolBalance(Config.CLASS_DIGITAL_ASSETS), 120_000e18);
        assertEq(registry.classExposure(Config.CLASS_DIGITAL_ASSETS), 0);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_onDefaultRecovery_zeroOutstandingReleasesCoverageDefensively() public {
        uint256 id = _defaulted(100_000e18);
        vm.prank(address(defaultManager));
        reserves.recordPrincipalWritedown(id, 100_000e18);

        vm.prank(address(waterfall));
        defaultManager.onDefaultRecovery(id);
        assertEq(defaultManager.defaultedContribution(id), 0);
    }

    // ── governance setters ───────────────────────────────────────────────

    function test_setRemedyRef_setsAndGuards() public {
        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.RemedyRefSet(FILM, keccak256("ref"));
        vm.prank(admin);
        defaultManager.setRemedyRef(FILM, keccak256("ref"));
        assertEq(defaultManager.remedyRef(FILM), keccak256("ref"));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_UnknownClass.selector, 6));
        defaultManager.setRemedyRef(6, keccak256("ref"));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, servicer, bytes32(0))
        );
        vm.prank(servicer);
        defaultManager.setRemedyRef(FILM, keccak256("ref"));
    }

    function test_setCureWindow_setsAndGuards() public {
        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.CureWindowSet(Config.CLASS_DIGITAL_ASSETS, 6 hours);
        vm.prank(admin);
        defaultManager.setCureWindow(Config.CLASS_DIGITAL_ASSETS, 6 hours);
        assertEq(defaultManager.cureWindow(Config.CLASS_DIGITAL_ASSETS), 6 hours);

        vm.startPrank(admin);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAmount.selector);
        defaultManager.setCureWindow(Config.CLASS_DIGITAL_ASSETS, 0);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_UnknownClass.selector, 0));
        defaultManager.setCureWindow(0, 1 days);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, servicer, bytes32(0))
        );
        vm.prank(servicer);
        defaultManager.setCureWindow(FILM, 1 days);
    }

    function test_setBackstop_zeroAllowedAndGuarded() public {
        vm.expectEmit(true, false, false, true);
        emit IDefaultManager.BackstopSet(address(0));
        vm.prank(admin);
        defaultManager.setBackstop(address(0));
        assertEq(defaultManager.backstop(), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, servicer, bytes32(0))
        );
        vm.prank(servicer);
        defaultManager.setBackstop(address(backstopMock));
    }

    function test_setBackstop_replacesUnreadableOldBackstop() public {
        ToggleCapacityBackstop oldBackstop = new ToggleCapacityBackstop();
        oldBackstop.setCapacity(300_000e18);
        vm.prank(admin);
        defaultManager.setBackstop(address(oldBackstop));

        _stakeVault(alice, 1_000_000e18);
        _defaulted(400_000e18);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            100_000e18,
            "precondition: live impairment must read the outgoing backstop"
        );

        oldBackstop.setUnavailable(true);
        vm.expectRevert("capacity unavailable");
        defaultManager.pendingSeniorImpairment();

        vm.prank(admin);
        defaultManager.setBackstop(address(backstopMock));

        assertEq(defaultManager.backstop(), address(backstopMock), "broken old capacity read cannot block repair");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            400_000e18,
            "replacement restores a live NAV read using its own capacity"
        );
        assertEq(
            vault.impairmentSource(),
            address(assessedImpairmentSource),
            "backstop repair leaves production assessment wiring intact"
        );
    }

    function test_setBackstop_readableRotationAccruesManagementFeeAgainstOutgoingNav() public {
        ToggleCapacityBackstop oldBackstop = new ToggleCapacityBackstop();
        oldBackstop.setCapacity(300_000e18);
        vm.prank(admin);
        defaultManager.setBackstop(address(oldBackstop));

        _stakeVault(alice, 1_000_000e18);
        _defaulted(400_000e18);
        vm.prank(admin);
        vault.setManagementFee(200);
        vm.warp(block.timestamp + 365 days);

        uint256 outgoingMarkedAssets = vault.redemptionTotalAssets();
        uint256 effectiveSupply = vault.totalSupply() + 1e6;
        uint256 annualRetentionWad = uint256(FixedPointMathLib.powWad(int256(0.98e18), int256(1e18)));
        uint256 managementAssets =
            Math.mulDiv(outgoingMarkedAssets, 1e18 - annualRetentionWad, 1e18, Math.Rounding.Floor);
        uint256 expectedShares =
            Math.mulDiv(managementAssets, effectiveSupply, outgoingMarkedAssets + 1 - managementAssets);

        vm.prank(admin);
        defaultManager.setBackstop(address(backstopMock));

        assertEq(
            vault.balanceOf(feeRecipient),
            expectedShares,
            "elapsed management fee must use the readable outgoing backstop NAV"
        );
        assertLt(
            vault.redemptionTotalAssets(),
            outgoingMarkedAssets,
            "the fixture must distinguish outgoing and replacement NAV"
        );
    }

    function test_setBackstop_rejectsInvalidIncomingAddressEvenWithHealthyBook() public {
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_InvalidBackstop.selector, alice));
        vm.prank(admin);
        defaultManager.setBackstop(alice);

        MalformedCapacityBackstop malformed = new MalformedCapacityBackstop();
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_InvalidBackstop.selector, address(malformed))
        );
        vm.prank(admin);
        defaultManager.setBackstop(address(malformed));

        CoverageOnlyBackstop coverageOnly = new CoverageOnlyBackstop();
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_InvalidBackstop.selector, address(coverageOnly))
        );
        vm.prank(admin);
        defaultManager.setBackstop(address(coverageOnly));

        // AUDIT R14-05: the short-return half of the capacity probe. This candidate passes
        // the ERC-165 identity gate, so it is the only fixture that reaches the
        // `returndatasize() < 0x20` comparison in `_isBackstopReadable`.
        DeclaredButMalformedBackstop declaredMalformed = new DeclaredButMalformedBackstop();
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_InvalidBackstop.selector, address(declaredMalformed))
        );
        vm.prank(admin);
        defaultManager.setBackstop(address(declaredMalformed));

        DeclaredButShortCapParametersBackstop shortPair = new DeclaredButShortCapParametersBackstop();
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_InvalidBackstop.selector, address(shortPair))
        );
        vm.prank(admin);
        defaultManager.setBackstop(address(shortPair));

        assertEq(defaultManager.backstop(), address(backstopMock));
    }

    /// @notice AUDIT R14-04 MUTATION-KILLER. Identity is an INSTALLATION question; readability
    ///         is a VALUATION question. An incumbent that predates the identity gate is still
    ///         perfectly readable, so rotating away from it must bill the elapsed management
    ///         fee against the OUTGOING NAV — the ordinary checkpoint-first path — rather than
    ///         the broken-backstop incident path. Re-gating `_isBackstopReadable` on ERC-165
    ///         flips this to the replacement NAV and the assertion fails.
    function test_setBackstop_preIdentityIncumbentStillAccruesAgainstOutgoingNav() public {
        DroppableIdentityBackstop incumbent = new DroppableIdentityBackstop();
        incumbent.setCapacity(300_000e18);
        vm.prank(admin);
        defaultManager.setBackstop(address(incumbent));
        // Now it looks like a contract compiled before the identity gate existed.
        incumbent.setDeclares(false);

        _stakeVault(alice, 1_000_000e18);
        _defaulted(400_000e18);
        vm.prank(admin);
        vault.setManagementFee(200);
        vm.warp(block.timestamp + 365 days);

        uint256 outgoingMarkedAssets = vault.redemptionTotalAssets();
        uint256 effectiveSupply = vault.totalSupply() + 1e6;
        uint256 annualRetentionWad = uint256(FixedPointMathLib.powWad(int256(0.98e18), int256(1e18)));
        uint256 managementAssets =
            Math.mulDiv(outgoingMarkedAssets, 1e18 - annualRetentionWad, 1e18, Math.Rounding.Floor);
        uint256 expectedShares =
            Math.mulDiv(managementAssets, effectiveSupply, outgoingMarkedAssets + 1 - managementAssets);

        vm.prank(admin);
        defaultManager.setBackstop(address(backstopMock));

        assertEq(defaultManager.backstop(), address(backstopMock), "rotation away from a pre-identity incumbent");
        assertEq(
            vault.balanceOf(feeRecipient),
            expectedShares,
            "a readable-but-undeclared incumbent must still be billed on the outgoing NAV"
        );
        assertLt(
            vault.redemptionTotalAssets(), outgoingMarkedAssets, "the fixture must distinguish outgoing and new NAV"
        );
    }

    // ── pause: permissionless triggers only ──────────────────────────────

    function test_pause_blocksTriggersNeverLossRecognition() public {
        _postFirstLoss(anchorCurator, Config.CLASS_DIGITAL_ASSETS, 600_000e18);
        uint256 id = _liveDigitalFacility();
        _setValuation(id, 750_000e18, uint64(block.timestamp));

        vm.prank(guardian);
        defaultManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.marginCall(id);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.clearMarginCall(id);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.liquidate(id);

        // role-gated remedy/loss paths keep working while paused (design note)
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _realizeLoss(id, 500_000e18, FILM_REF);
        assertEq(reserves.deployedTo(id), 0);

        vm.prank(guardian);
        defaultManager.unpause();
    }

    function test_pause_onlyGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        defaultManager.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        defaultManager.unpause();
    }

    // ── views ────────────────────────────────────────────────────────────

    function test_currentLtvBps_revertsWithoutMark() public {
        uint256 id = _liveFilmFacility(100_000e18); // receivables carry no mark
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, id));
        defaultManager.currentLtvBps(id);
    }

    // ── upgrade authorization ────────────────────────────────────────────

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new DefaultManager());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        defaultManager.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        defaultManager.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_doesNotClaimAnImpossibleBackstopOrderingGate() public {
        DroppableIdentityBackstop incumbent = new DroppableIdentityBackstop();
        incumbent.setCapacity(300_000e18);
        vm.prank(admin);
        defaultManager.setBackstop(address(incumbent));

        // It was installable before the identity gate existed. Dropping the declaration models a
        // still-live pre-ledger SGrove proxy; capability remains the only honest installation
        // requirement, while UUPS authorization itself makes no impossible in-place promise.
        incumbent.setDeclares(false);
        address newImpl = address(new DefaultManager());
        vm.prank(admin);
        defaultManager.upgradeToAndCall(newImpl, "");
        assertEq(defaultManager.backstop(), address(incumbent));
    }

    // ── fuzz: cascade ordering is exact for ANY capitalization ───────────

    /// @dev CASCADE ORDERING (CLAUDE.md §1.3): for any curator pool, backstop balance,
    ///      and loss, the split is exactly (min over layer 1, then min over layer 2,
    ///      then remainder) and total burns equal the loss.
    function testFuzz_realizeLoss_cascadeOrderingExact(uint256 pool, uint256 bstop, uint256 loss) public {
        pool = bound(pool, 0, 400_000e18);
        bstop = bound(bstop, 0, 400_000e18);
        loss = bound(loss, 1, 500_000e18);
        pool -= pool % 1e12;
        bstop -= bstop % 1e12;

        if (pool != 0) _postFirstLoss(anchorCurator, FILM, pool);
        if (bstop != 0) _fundBackstop(bstop);
        _stakeVault(alice, 600_000e18); // deep vault so layer 3 never reverts here

        uint256 id = _defaulted(500_000e18);
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 vaultBefore = usdfr.balanceOf(address(vault));

        _realizeLoss(id, loss, FILM_REF);

        uint256 expectAbsorbed = loss < pool ? loss : pool;
        uint256 expectCovered = (loss - expectAbsorbed) < bstop ? (loss - expectAbsorbed) : bstop;
        uint256 expectDepositor = loss - expectAbsorbed - expectCovered;

        assertEq(curator.poolBalance(FILM), pool - expectAbsorbed, "layer 1 exact");
        assertEq(usdfr.balanceOf(address(backstopMock)), bstop - expectCovered, "layer 2 exact");
        assertEq(vaultBefore - usdfr.balanceOf(address(vault)), expectDepositor, "layer 3 exact");
        assertEq(supplyBefore - usdfr.totalSupply(), loss, "total burned == loss");
        assertTrue(controller.backingInvariantHolds());
    }
}
