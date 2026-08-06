// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockAttestationOracle} from "./MockAttestationOracle.sol";

/// @dev Deploys registry + bridge behind proxies and seeds the FIVE genesis classes
///      with launch-default parameters (as the deploy script will).
abstract contract CollateralFixture is Test {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal originator = makeAddr("originator");
    address internal creditModule = makeAddr("creditModule");
    address internal custodian = makeAddr("spvCustodian");

    CollateralRegistry internal registry;
    ClaimBridge internal bridge;
    MockAttestationOracle internal oracle;

    bytes32 internal BORROWER_1 = keccak256("borrower-1");
    bytes32 internal BORROWER_2 = keccak256("borrower-2");
    bytes32 internal STATE_GA = keccak256("US-GA");
    bytes32 internal STATE_NV = keccak256("US-NV");

    // AttestationKind bit helpers
    uint256 internal constant BIT_ASSIGNMENT = 1 << uint256(IAttestationOracle.AttestationKind.AssignmentExecuted);
    uint256 internal constant BIT_UCC = 1 << uint256(IAttestationOracle.AttestationKind.UCCFiled);
    uint256 internal constant BIT_CREDIT = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
    uint256 internal constant BIT_VALUATION = 1 << uint256(IAttestationOracle.AttestationKind.Valuation);

    /// @dev Film fixture terms, named so attested and originated copies can be diverged.
    uint16 internal constant FILM_LTV_BPS = 7500;
    uint16 internal constant FILM_RATE_BPS = 1400;
    uint16 internal constant DIGITAL_RATE_BPS = 1000;
    bytes32 internal constant FILM_REF = keccak256("ucc-ref");

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        registry = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(new CollateralRegistry()), abi.encodeCall(CollateralRegistry.initialize, (admin, admin))
                )
            )
        );
        oracle = new MockAttestationOracle();
        bridge = ClaimBridge(
            address(
                new ERC1967Proxy(
                    address(new ClaimBridge()),
                    abi.encodeCall(ClaimBridge.initialize, (admin, guardian, admin, address(registry), address(oracle)))
                )
            )
        );

        vm.startPrank(admin);
        bridge.grantRole(Roles.ORIGINATOR_ROLE, originator);
        bridge.grantRole(Roles.CREDIT_ROLE, creditModule);
        registry.grantRole(Roles.CREDIT_ROLE, address(bridge)); // bridge records exposure
        registry.grantRole(Roles.CREDIT_ROLE, creditModule); // credit layer decreases on repayment

        // ── genesis classes (launch defaults; economic review pending) ────
        registry.setClass(
            Config.CLASS_FILM_TAX_CREDITS, _receivable("Film & TV Tax Credits", 8000, 1400, 0, 730 days, 3500)
        );
        registry.setClass(
            Config.CLASS_RENEWABLE_ENERGY, _receivable("Renewable Energy", 7500, 1200, 0, 1825 days, 3500)
        );
        registry.setClass(Config.CLASS_LIFE_SCIENCES, _receivable("Life Sciences", 6000, 1600, 0, 2555 days, 3000));
        registry.setClass(Config.CLASS_REAL_ESTATE, _receivable("Real Estate", 7000, 1100, 0, 3650 days, 3500));
        ICollateralRegistry.ClassParams memory da = ICollateralRegistry.ClassParams({
            name: "Digital Assets",
            model: ICollateralRegistry.CollateralModel.MarkedToMarket,
            active: true,
            maxLtvBps: 5000, // conservative initial draw ceiling
            maxMaturity: 365 days,
            concentrationLimitBps: 2000, // related-party class capped at 20% of book
            marginCallLtvBps: 6500,
            liquidationLtvBps: 8000,
            maxMarkAge: 1 days
        });
        registry.setClass(Config.CLASS_DIGITAL_ASSETS, da);

        // mint-gate requirements per class
        bridge.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        bridge.setRequiredMintAttestations(Config.CLASS_RENEWABLE_ENERGY, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        bridge.setRequiredMintAttestations(Config.CLASS_LIFE_SCIENCES, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        bridge.setRequiredMintAttestations(Config.CLASS_REAL_ESTATE, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        // AUDIT FIX (H-4): CreditIssued is the TERMS quorum and is mandatory on every gate.
        bridge.setRequiredMintAttestations(Config.CLASS_DIGITAL_ASSETS, BIT_ASSIGNMENT | BIT_VALUATION | BIT_CREDIT);
        vm.stopPrank();
    }

    function _receivable(string memory name, uint16 maxLtv, uint16, uint16, uint64 maxMaturity, uint16 concLimit)
        internal
        pure
        returns (ICollateralRegistry.ClassParams memory)
    {
        return ICollateralRegistry.ClassParams({
            name: name,
            model: ICollateralRegistry.CollateralModel.Receivable,
            active: true,
            maxLtvBps: maxLtv,
            maxMaturity: maxMaturity,
            concentrationLimitBps: concLimit,
            marginCallLtvBps: 0,
            liquidationLtvBps: 0,
            maxMarkAge: 0
        });
    }

    /// @dev Satisfies the film-class mint gate for the NEXT facility id and originates.
    function _originateFilm(bytes32 borrowerId, bytes32 stateId, uint256 principal) internal returns (uint256 id) {
        uint64 maturity = uint64(block.timestamp + 365 days);
        uint256 nextId = bridge.totalOriginated() + 1;
        _attestFilmGate(nextId, borrowerId, stateId, principal, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF);
        ClaimBridge.OriginationTerms memory terms = _terms(
            Config.CLASS_FILM_TAX_CREDITS,
            borrowerId,
            stateId,
            principal,
            FILM_LTV_BPS,
            FILM_RATE_BPS,
            maturity,
            FILM_REF
        );
        vm.prank(originator);
        id = bridge.originate(custodian, terms);
    }

    /// @dev AUDIT FIX (H-4) TEST-DESIGN GAP. Satisfies the film gate at `facilityId` for the
    ///      terms passed here — SEPARATELY from the terms `originate` is called with, so a test
    ///      can attest one facility and originate another. Previously this fixture satisfied the
    ///      gate at `nextId` inline, making attestation and terms agree by construction.
    function _attestFilmGate(
        uint256 facilityId,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint16 ltvBps,
        uint16 interestRateBps,
        uint64 maturity,
        bytes32 offchainRef
    ) internal {
        oracle.setSatisfied(facilityId, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        oracle.setSatisfied(facilityId, IAttestationOracle.AttestationKind.UCCFiled, true);
        oracle.setPayload(
            facilityId,
            IAttestationOracle.AttestationKind.CreditIssued,
            bridge.creditTermsHash(
                _terms(
                    Config.CLASS_FILM_TAX_CREDITS,
                    borrowerId,
                    stateId,
                    principal,
                    ltvBps,
                    interestRateBps,
                    maturity,
                    offchainRef
                )
            ),
            uint64(block.timestamp),
            true
        );
    }

    function _terms(
        uint256 classId,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint16 ltvBps,
        uint16 rateBps,
        uint64 maturity,
        bytes32 offchainRef
    ) internal view returns (ClaimBridge.OriginationTerms memory) {
        return ClaimBridge.OriginationTerms({
            classId: classId,
            borrowerId: borrowerId,
            stateId: stateId,
            principal: principal,
            ltvBps: ltvBps,
            interestRateBps: rateBps,
            maturity: maturity,
            fundingRecipient: custodian,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("fixture-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: offchainRef
        });
    }
}
