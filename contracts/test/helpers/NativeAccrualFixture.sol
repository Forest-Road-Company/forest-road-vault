// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProductionCreditFixture} from "./ProductionCreditFixture.sol";
import {AccrualDebtReference} from "./AccrualDebtReference.sol";
import {ContinuousAccrualDeployment} from "../../script/ContinuousAccrualDeployment.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

interface NativeAccrualCoverageFunding {
    function fundCoverage(uint256 amount) external;
    function coverageReserve() external view returns (uint256);
}

interface NativeAccrualMintableAsset {
    function mint(address recipient, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Fresh native modules with the production oracle and genuine fixture signatures.
///      Each chain's ProductionCreditFixture supplies its actual loss topology.
abstract contract NativeAccrualFixture is ProductionCreditFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    uint256 internal constant SENIOR_CAPITAL = 1_000_000e18;
    uint256 internal constant CURATOR_CAPITAL = 10_000e18;
    uint256 internal constant COVERAGE_CAPITAL = 5_000e18;
    uint64 internal nativeStart;
    uint256 internal receiptSequence;
    uint256 internal nativeId;
    uint256 internal nativeWrittenOff;
    AccrualDebtReference.Note internal nativeReference;

    function setUp() public virtual override {
        super.setUp();
        _prepareNativeAsset();
        vm.startPrank(admin);
        ContinuousAccrualDeployment.configure(
            address(reserves),
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
        vm.stopPrank();
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

    function _nativeAsset() internal view returns (address) {
        return address(usdc);
    }

    function _prepareNativeAsset() internal virtual {}

    function _nativeBackstop() internal view returns (address) {
        return address(sGrove);
    }

    function _nativeScale() internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(_nativeAsset()).decimals());
    }

    function _fixtureFilmTenor() internal pure override returns (uint64) {
        return 365 days;
    }

    function _fixturePaymentInterval() internal pure override returns (uint64) {
        return 90 days;
    }

    function _nativeFund(uint256 principal) internal {
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
            : principal + (principal * 1400 * _fixtureFilmTenor() / (10_000 * n.year)) / n.scale * n.scale;
        n.open(nativeStart);
        nativeReference = n;
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _nativeAdvance(uint64 at) internal {
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(at);
        nativeReference = n;
        vm.warp(at);
        bool fresh;
        uint256 batches;
        while (!fresh) {
            (, fresh) = reserves.checkpointAccrual(32);
            assertLt(++batches, 32, "native maintenance failed to converge");
        }
        reserves.serviceAccruedLoan(nativeId);
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _nativeReceipt(uint256 principal, uint256 interest) internal {
        AccrualDebtReference.Note memory n = nativeReference;
        uint256 total = principal + interest;
        uint64 due;
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        if (total != n.principal + n.interest) {
            due = n.pik ? f.nextPaymentDue : f.nextPaymentDue + f.paymentInterval;
            if (due > f.maturity) due = f.maturity;
        }
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: nativeId,
            paymentId: keccak256(abi.encode("native-accrual-receipt", nativeId, ++receiptSequence)),
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: due
        });
        _submitNativeReceipt(payment, total / n.scale);
        n.pay(principal, interest, uint64(block.timestamp));
        nativeReference = n;
        vm.prank(servicer);
        waterfall.distribute(payment);
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _submitNativeReceipt(IWaterfallEngine.Payment memory payment, uint256 units) internal {
        NativeAccrualMintableAsset(_nativeAsset()).mint(borrower, units);
        vm.prank(borrower);
        assertTrue(NativeAccrualMintableAsset(_nativeAsset()).approve(address(reserves), units), "receipt approval");
        _attest(
            nativeId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(
                abi.encode(
                    payment.paymentId,
                    nativeId,
                    _nativeAsset(),
                    borrower,
                    units,
                    payment.interest,
                    payment.principal,
                    payment.nextPaymentDue
                )
            ),
            uint64(block.timestamp)
        );
    }

    function _nativeAmendRate(uint16 rate) internal {
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: rate,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendment = keccak256(abi.encode("native-accrual-amendment", nativeId, ++receiptSequence));
        _attest(
            nativeId,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendment, nativeId, a)),
            uint64(block.timestamp)
        );
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(uint64(block.timestamp));
        n.rate = rate;
        if (!n.pik) {
            n.ceiling = n.principal + n.interest
                + (n.principal * rate * (n.maturity - block.timestamp) / (10_000 * n.year)) / n.scale * n.scale;
        }
        n.restart(uint64(block.timestamp));
        nativeReference = n;
        vm.prank(originator);
        bridge.amendTerms(nativeId, amendment, a);
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _nativeDeclare() internal {
        AccrualDebtReference.Note memory n = nativeReference;
        n.stop(uint64(block.timestamp));
        nativeReference = n;
        _attestDefault(nativeId);
        vm.prank(servicer);
        defaultManager.declareDefault(nativeId, FILM_REF);
        assertEq(reserves.deployedTo(nativeId), n.principal + n.interest, "default omitted earned native face");
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _nativeLoss(uint256 amount) internal {
        uint256 curatorBefore = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        uint256 coverageBefore =
            _nativeBackstop() == address(0) ? 0 : NativeAccrualCoverageFunding(_nativeBackstop()).coverageReserve();
        uint256 vaultBefore = vault.totalAssets();
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 first = amount < curatorBefore ? amount : curatorBefore;
        uint256 second = amount - first < coverageBefore ? amount - first : coverageBefore;
        uint256 senior = amount - first - second;
        _realizeLoss(nativeId, amount, bytes32(0));
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), curatorBefore - first, "curator must pay first");
        if (_nativeBackstop() != address(0)) {
            assertEq(
                NativeAccrualCoverageFunding(_nativeBackstop()).coverageReserve(),
                coverageBefore - second,
                "shared reserve must pay second"
            );
        }
        assertEq(vault.totalAssets(), vaultBefore - senior, "senior must pay only the residual");
        assertEq(controller.totalUSDfr(), supplyBefore - amount, "loss burn conservation including unissued claims");
        AccrualDebtReference.Note memory n = nativeReference;
        uint256 principal = amount < n.principal ? amount : n.principal;
        n.principal -= principal;
        n.interest -= amount - principal;
        nativeReference = n;
        nativeWrittenOff += amount;
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _nativePayAll() internal {
        AccrualDebtReference.Note memory n = nativeReference;
        _nativeReceipt(n.pik ? n.principal + n.interest : n.principal, n.pik ? 0 : n.interest);
    }

    function _assertNativeDebt() internal view {
        IAccrualLifecycle.Debt memory actual = reserves.accruedDebt(nativeId);
        assertTrue(actual.known, "funded facility not registered");
        assertEq(actual.principal, nativeReference.principal, "native principal differs from reference");
        assertEq(actual.interest, nativeReference.interest, "native interest differs from reference");
        assertEq(
            actual.principal + actual.interest + nativeReference.paid + nativeWrittenOff,
            nativeReference.original + nativeReference.earned,
            "native debt conservation"
        );
    }

    function _assertNativeBacking() internal view {
        assertEq(controller.totalUSDfr(), controller.backingValue(), "native accrual changed paired surplus");
        assertEq(reserves.totalBackingValue(), controller.backingValue(), "native backing source mismatch");
        assertFalse(reserves.accrualDelivery().active, "delivery permit left open");
    }
}
