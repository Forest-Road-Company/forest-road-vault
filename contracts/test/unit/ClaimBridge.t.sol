// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CollateralFixture} from "../helpers/CollateralFixture.sol";

contract ReentrantFacilityReceiver is IERC721Receiver {
    ClaimBridge internal immutable bridge;

    constructor(ClaimBridge bridge_) {
        bridge = bridge_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        bridge.cancelPending(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ClaimBridgeTest is CollateralFixture {
    bytes32 private constant BRIDGE_STORAGE_LOCATION =
        0xc9c2da543a2a10e4b712709fb6548fb2c0c97cecbac3457453966d18f1663f00;

    function test_initialize_rejectsEveryZeroPrincipal() public {
        ClaimBridge impl = new ClaimBridge();
        address[5] memory args = [admin, guardian, admin, address(registry), address(oracle)];
        for (uint256 i; i < args.length; ++i) {
            address saved = args[i];
            args[i] = address(0);
            vm.expectRevert(ClaimBridge.Bridge_ZeroAddress.selector);
            new ERC1967Proxy(
                address(impl), abi.encodeCall(ClaimBridge.initialize, (args[0], args[1], args[2], args[3], args[4]))
            );
            args[i] = saved;
        }
    }

    function test_setRequiredMintAttestations_rejectsUnknownAndCreditlessMasks() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadAttestationMask.selector, 0));
        bridge.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, 0);
        uint256 unknownMask = BIT_CREDIT | (1 << 255);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadAttestationMask.selector, unknownMask));
        bridge.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, unknownMask);
        vm.stopPrank();
    }

    function test_pauseUnpauseAndInterfaceSupport() public {
        vm.prank(guardian);
        bridge.pause();
        assertTrue(bridge.paused());

        vm.prank(guardian);
        bridge.unpause();
        assertFalse(bridge.paused());
        assertTrue(bridge.supportsInterface(type(IERC721).interfaceId));
        assertFalse(bridge.supportsInterface(0xffffffff));
    }

    function test_upgrade_onlyUpgraderRole() public {
        address unauthorized = makeAddr("unauthorized");
        address newImpl = address(new ClaimBridge());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, Roles.UPGRADER_ROLE
            )
        );
        vm.prank(unauthorized);
        bridge.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        bridge.upgradeToAndCall(newImpl, "");
    }

    function test_originate_recordsCompleteSignedFacility() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 1_000_000e18);
        ClaimBridge.Facility memory f = bridge.facility(id);

        assertEq(bridge.ownerOf(id), custodian);
        assertEq(f.classId, Config.CLASS_FILM_TAX_CREDITS);
        assertEq(f.borrowerId, BORROWER_1);
        assertEq(f.stateId, STATE_GA);
        assertEq(f.principal, 1_000_000e18);
        assertEq(f.interestRateBps, FILM_RATE_BPS);
        assertEq(f.fundingRecipient, custodian);
        assertEq(f.paymentInterval, 30 days);
        assertEq(f.paymentScheduleHash, keccak256("fixture-schedule"));
        assertEq(uint8(f.rateType), uint8(ClaimBridge.RateType.Fixed));
        assertEq(uint8(f.state), uint8(ClaimBridge.LoanState.Pending));
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), f.principal);
    }

    function test_originate_rejectsStateTagOutsideTaxCreditClass() public {
        ClaimBridge.OriginationTerms memory terms = _terms(
            Config.CLASS_RENEWABLE_ENERGY,
            BORROWER_1,
            STATE_GA,
            1_000_000e18,
            7_000,
            FILM_RATE_BPS,
            uint64(block.timestamp + 365 days),
            FILM_REF
        );
        _attestTerms(1, terms);

        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);
    }

    function test_originate_cannotEnterCustodyEventNamespace() public {
        bytes32 nextIdSlot = bytes32(uint256(BRIDGE_STORAGE_LOCATION) + 2);
        vm.store(address(bridge), nextIdSlot, bytes32(uint256(1 << 255)));

        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_FacilityEventNamespaceExhausted.selector, uint256(1 << 255))
        );
        vm.prank(originator);
        bridge.originate(custodian, _filmTerms(FILM_RATE_BPS));
    }

    function test_originate_interestRateIsPerFacilityAndSigned() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(1500);
        _attestTerms(1, terms);

        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        assertEq(bridge.facility(id).interestRateBps, 1500);
    }

    function test_originate_receiverCannotReenterFacilityLifecycle() public {
        ReentrantFacilityReceiver receiver = new ReentrantFacilityReceiver(bridge);
        vm.prank(admin);
        bridge.grantRole(Roles.ORIGINATOR_ROLE, address(receiver));

        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        _attestTerms(1, terms);

        vm.prank(originator);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        bridge.originate(address(receiver), terms);

        assertEq(registry.totalBookExposure(), 0);
        assertEq(bridge.totalOriginated(), 0);
    }

    function test_originate_anySignedTermMismatchReverts() public {
        ClaimBridge.OriginationTerms memory signedTerms = _filmTerms(1500);
        _attestTerms(1, signedTerms);
        bytes32 attested = bridge.creditTermsHash(signedTerms);
        ClaimBridge.OriginationTerms memory attempted = signedTerms;
        attempted.interestRateBps = 1499;

        bytes32 expected = bridge.creditTermsHash(attempted);
        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, 1, expected, attested));
        bridge.originate(custodian, attempted);
    }

    function test_originate_missingDocumentaryAttestationReverts() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        oracle.setPayload(
            1,
            IAttestationOracle.AttestationKind.AssignmentExecuted,
            bridge.creditTermsHash(terms),
            uint64(block.timestamp),
            true
        );
        oracle.setPayload(
            1,
            IAttestationOracle.AttestationKind.CreditIssued,
            bridge.creditTermsHash(terms),
            uint64(block.timestamp),
            true
        );

        vm.prank(originator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.UCCFiled
            )
        );
        bridge.originate(custodian, terms);
    }

    function test_originate_rejectsZeroOrExcessiveRate() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(0);
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms.interestRateBps = 10_001;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);
    }

    function test_originate_rejectsUnsignedOperationalGaps() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.fundingRecipient = address(0);
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms = _filmTerms(FILM_RATE_BPS);
        terms.paymentScheduleHash = bytes32(0);
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms = _filmTerms(FILM_RATE_BPS);
        terms.nextPaymentDue = terms.maturity + 1;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);
    }

    function test_originate_rejectsPastAndOverlongMaturity() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.maturity = uint64(block.timestamp);
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms = _filmTerms(FILM_RATE_BPS);
        terms.maturity = uint64(block.timestamp + 731 days);
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);
    }

    function test_FT_originateRejectsNextPaymentDueExactlyNow() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.nextPaymentDue = uint64(block.timestamp);

        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        vm.prank(originator);
        bridge.originate(custodian, terms);
    }

    function test_originate_rejectsZeroHolderAndLtvBounds() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_ZeroAddress.selector);
        bridge.originate(address(0), terms);

        terms.ltvBps = 0;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms.ltvBps = 8001;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);
    }

    function test_originate_fixedRateRejectsIndexReference() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.rateIndexRef = keccak256("SOFR");
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);
    }

    function test_originate_variableRateRequiresIndexAndFixedRateForbidsIt() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.rateType = ClaimBridge.RateType.Variable;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms.rateIndexRef = keccak256("SOFR");
        _attestTerms(1, terms);
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        assertEq(bridge.facility(id).rateIndexRef, keccak256("SOFR"));
    }

    function test_originate_renewableFlagAndTermsHashMustAgree() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.renewable = true;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(custodian, terms);

        terms.renewalTermsHash = keccak256("renewal-policy");
        _attestTerms(1, terms);
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        assertTrue(bridge.facility(id).renewable);
    }

    function test_cancelPending_releasesExposureAndBurnsNFT() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(originator);
        bridge.cancelPending(id);

        assertEq(registry.totalBookExposure(), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Cancelled));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        bridge.ownerOf(id);
    }

    function test_cancelPending_onlyOriginator() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, custodian, Roles.ORIGINATOR_ROLE
            )
        );
        bridge.cancelPending(id);
    }

    function test_setNextPaymentDue_rejectsPendingFacility() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_InvalidTransition.selector,
                id,
                ClaimBridge.LoanState.Pending,
                ClaimBridge.LoanState.Pending
            )
        );
        bridge.setNextPaymentDue(id, uint64(block.timestamp + 31 days));
    }

    function test_checkFundable_rejectsNonPendingAndInactiveClass() public {
        uint256 activeId = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(creditModule);
        bridge.transitionState(activeId, ClaimBridge.LoanState.Active);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_NotPending.selector, activeId));
        bridge.checkFundable(activeId);

        uint256 pendingId = _originateFilm(BORROWER_2, STATE_NV, 400_000e18);
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        p.active = false;
        vm.prank(admin);
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_ClassInactive.selector, Config.CLASS_FILM_TAX_CREDITS)
        );
        bridge.checkFundable(pendingId);
    }

    function test_checkFundable_rejectsPassedNextPaymentDue() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        uint64 nextPaymentDue = bridge.facility(id).nextPaymentDue;

        vm.warp(uint256(nextPaymentDue) - 1);
        bridge.checkFundable(id);

        vm.warp(nextPaymentDue);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.checkFundable(id);
    }

    function test_FT_checkFundableRejectsMaturityExactlyNowWithSpecificError() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        uint64 maturity = bridge.facility(id).maturity;

        vm.warp(maturity);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_FacilityMatured.selector, id));
        bridge.checkFundable(id);
    }

    function test_FT_mtmOriginationAcceptsMarkAtExactMaxAge() public {
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 nowTs = uint64(block.timestamp);
        uint64 maturity = nowTs + 180 days;
        ClaimBridge.OriginationTerms memory terms = _terms(
            Config.CLASS_DIGITAL_ASSETS,
            BORROWER_1,
            bytes32(0),
            500_000e18,
            5000,
            DIGITAL_RATE_BPS,
            maturity,
            keccak256("digital-custody-control")
        );
        bytes32 termsHash = bridge.creditTermsHash(terms);
        oracle.setPayload(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, nowTs, true);
        oracle.setPayload(nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, nowTs, true);
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.Valuation, true);
        oracle.setValuation(nextId, 1_000_000e18, nowTs - 1 days);

        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);

        assertEq(id, nextId, "a mark exactly maxMarkAge old is fresh for origination");
    }

    function test_FT_checkFundableAcceptsMarkAtExactMaxAge() public {
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 originatedAt = uint64(block.timestamp);
        uint64 maturity = originatedAt + 180 days;
        ClaimBridge.OriginationTerms memory terms = _terms(
            Config.CLASS_DIGITAL_ASSETS,
            BORROWER_1,
            bytes32(0),
            500_000e18,
            5000,
            DIGITAL_RATE_BPS,
            maturity,
            keccak256("digital-custody-control-funding")
        );
        bytes32 termsHash = bridge.creditTermsHash(terms);
        oracle.setPayload(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, originatedAt, true);
        oracle.setPayload(nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, originatedAt, true);
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.Valuation, true);
        oracle.setValuation(nextId, 1_000_000e18, originatedAt);
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);

        vm.warp(uint256(originatedAt) + 1 days);
        bridge.checkFundable(id);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Pending));
    }

    function test_transitionAndDueDate_rejectInvalidLifecycleChanges() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_InvalidTransition.selector,
                id,
                ClaimBridge.LoanState.Pending,
                ClaimBridge.LoanState.Repaid
            )
        );
        bridge.transitionState(id, ClaimBridge.LoanState.Repaid);

        vm.prank(creditModule);
        bridge.transitionState(id, ClaimBridge.LoanState.Active);
        ClaimBridge.Facility memory f = bridge.facility(id);
        vm.startPrank(creditModule);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.setNextPaymentDue(id, f.nextPaymentDue);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.setNextPaymentDue(id, f.maturity + 1);
        vm.stopPrank();
    }

    function test_amendTerms_rejectsLifecycleAndStructuralMismatches() public {
        uint256 pendingId = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: FILM_RATE_BPS,
            maturity: uint64(block.timestamp + 300 days),
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 31 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("schedule-v2"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0)
        });
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(pendingId, keccak256("pending"), a);

        vm.prank(creditModule);
        bridge.transitionState(pendingId, ClaimBridge.LoanState.Active);
        ClaimBridge.Facility memory f = bridge.facility(pendingId);

        a.maturity = f.maturity + 1;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(pendingId, keccak256("non-renewable-extension"), a);

        a.maturity = f.maturity;
        a.rateType = ClaimBridge.RateType.Variable;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(pendingId, keccak256("missing-index"), a);

        a.rateType = ClaimBridge.RateType.Fixed;
        a.rateIndexRef = keccak256("SOFR");
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(pendingId, keccak256("fixed-index"), a);

        a.rateIndexRef = bytes32(0);
        a.renewable = true;
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(pendingId, keccak256("missing-renewal-terms"), a);
    }

    function test_transferRestrictionAndUnknownTokenBounds() public {
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 0));
        bridge.facility(0);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 999));
        bridge.facility(999);

        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(creditModule);
        bridge.transitionState(id, ClaimBridge.LoanState.Active);
        vm.prank(custodian);
        vm.expectRevert(ClaimBridge.Bridge_TransferRestricted.selector);
        bridge.transferFrom(custodian, originator, id);
    }

    function test_amendTerms_rejectsInvalidCoreTerms() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.renewable = true;
        terms.renewalTermsHash = keccak256("renewal-v1");
        _attestTerms(1, terms);
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        vm.prank(creditModule);
        bridge.transitionState(id, ClaimBridge.LoanState.Active);

        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: 0,
            maturity: uint64(block.timestamp + 500 days),
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: true,
            paymentScheduleHash: keccak256("schedule-v2"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: keccak256("renewal-v2")
        });
        vm.prank(originator);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(id, keccak256("bad-amendment"), a);
    }

    function test_amendTerms_requiresExactSingleUseAttestation() public {
        ClaimBridge.OriginationTerms memory terms = _filmTerms(FILM_RATE_BPS);
        terms.renewable = true;
        terms.renewalTermsHash = keccak256("renewal-v1");
        _attestTerms(1, terms);
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        vm.prank(creditModule);
        bridge.transitionState(id, ClaimBridge.LoanState.Active);

        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: 1550,
            maturity: uint64(block.timestamp + 500 days),
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: true,
            paymentScheduleHash: keccak256("schedule-v2"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: keccak256("renewal-v2")
        });
        bytes32 amendmentId = keccak256("amendment-1");

        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, id));
        bridge.amendTerms(id, amendmentId, a);

        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, id, a)),
            uint64(block.timestamp),
            true
        );
        vm.prank(originator);
        bridge.amendTerms(id, amendmentId, a);
        assertEq(bridge.facility(id).interestRateBps, 1550);
        assertEq(bridge.facility(id).maturity, a.maturity);

        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, id));
        bridge.amendTerms(id, amendmentId, a);
    }

    function _filmTerms(uint16 rateBps) internal view returns (ClaimBridge.OriginationTerms memory) {
        return _terms(
            Config.CLASS_FILM_TAX_CREDITS,
            BORROWER_1,
            STATE_GA,
            1_000_000e18,
            FILM_LTV_BPS,
            rateBps,
            uint64(block.timestamp + 365 days),
            FILM_REF
        );
    }

    function _attestTerms(uint256 facilityId, ClaimBridge.OriginationTerms memory terms) internal {
        bytes32 termsHash = bridge.creditTermsHash(terms);
        oracle.setPayload(
            facilityId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, uint64(block.timestamp), true
        );
        oracle.setPayload(
            facilityId, IAttestationOracle.AttestationKind.UCCFiled, termsHash, uint64(block.timestamp), true
        );
        oracle.setPayload(
            facilityId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, uint64(block.timestamp), true
        );
    }
}
