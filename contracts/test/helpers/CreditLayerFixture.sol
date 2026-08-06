// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockAttestationOracle} from "./MockAttestationOracle.sol";
import {MockCascadeBackstop} from "./MockCascadeBackstop.sol";
import {TokenLayerFixture} from "./TokenLayerFixture.sol";

/// @dev The FULL protocol stack for Phase E: token layer (TokenLayerFixture) +
///      collateral layer (registry/bridge/oracle, seeded like CollateralFixture) +
///      credit layer (CuratorModule/WaterfallEngine/DefaultManager) wired with the
///      production role topology. The Phase C test-era EOA CREDIT_ROLE grants on the
///      controller and reserves are REVOKED here — the real credit modules hold the
///      role, as the deploy script will wire it (NEXT_SESSION §4 note).
abstract contract CreditLayerFixture is TokenLayerFixture {
    address internal servicer = makeAddr("servicer");
    address internal anchorCurator = makeAddr("anchorCurator");
    address internal secondCurator = makeAddr("secondCurator");
    address internal originator = makeAddr("originator");
    address internal custodian = makeAddr("spvCustodian");

    CollateralRegistry internal registry;
    ClaimBridge internal bridge;
    IAttestationOracle internal oracle; // mock by default; RealOracleFixture overrides
    CuratorModule internal curator;
    WaterfallEngine internal waterfall;
    DefaultManager internal defaultManager;
    AssessedImpairmentSource internal assessedImpairmentSource;
    MockCascadeBackstop internal backstopMock;
    RedemptionQueue internal queue;

    bytes32 internal BORROWER_1 = keccak256("borrower-1");
    bytes32 internal BORROWER_2 = keccak256("borrower-2");
    bytes32 internal BORROWER_DESK = keccak256("forest-road-digital-desk"); // related party (ADR-0015)
    bytes32 internal STATE_GA = keccak256("US-GA");

    uint256 internal constant BIT_ASSIGNMENT = 1 << uint256(IAttestationOracle.AttestationKind.AssignmentExecuted);
    uint256 internal constant BIT_UCC = 1 << uint256(IAttestationOracle.AttestationKind.UCCFiled);
    uint256 internal constant BIT_CREDIT = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
    uint256 internal constant BIT_VALUATION = 1 << uint256(IAttestationOracle.AttestationKind.Valuation);

    /// @dev The film/digital fixture facility terms, named so the attested and the originated
    ///      copies can be compared (and deliberately diverged) in tests.
    uint16 internal constant FILM_LTV_BPS = 7500;
    uint16 internal constant DIGITAL_LTV_BPS = 5000;
    uint16 internal constant FILM_RATE_BPS = 1400;
    uint16 internal constant DIGITAL_RATE_BPS = 1000;
    bytes32 internal constant FILM_REF = keccak256("ucc-ref");
    bytes32 internal constant DIGITAL_REF = keccak256("custody-control-ref");

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_750_000_000);

        // ── collateral layer ─────────────────────────────────────────────
        registry = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(new CollateralRegistry()), abi.encodeCall(CollateralRegistry.initialize, (admin, admin))
                )
            )
        );
        oracle = _deployOracle();
        bridge = ClaimBridge(
            address(
                new ERC1967Proxy(
                    address(new ClaimBridge()),
                    abi.encodeCall(ClaimBridge.initialize, (admin, guardian, admin, address(registry), address(oracle)))
                )
            )
        );

        // ── credit layer ─────────────────────────────────────────────────
        curator = CuratorModule(
            address(
                new ERC1967Proxy(
                    address(new CuratorModule()),
                    abi.encodeCall(
                        CuratorModule.initialize,
                        (admin, guardian, admin, address(usdfr), address(registry), address(vault))
                    )
                )
            )
        );
        waterfall = WaterfallEngine(
            address(
                new ERC1967Proxy(
                    address(new WaterfallEngine()),
                    abi.encodeCall(
                        WaterfallEngine.initialize,
                        (
                            admin,
                            guardian,
                            admin,
                            WaterfallEngine.InitModules({
                                bridge: address(bridge),
                                registry: address(registry),
                                reserves: address(reserves),
                                controller: address(controller),
                                vault: address(vault),
                                feeRecipient: feeRecipient,
                                oracle: address(oracle)
                            })
                        )
                    )
                )
            )
        );
        defaultManager = DefaultManager(
            address(
                new ERC1967Proxy(
                    address(new DefaultManager()),
                    abi.encodeCall(
                        DefaultManager.initialize,
                        (
                            admin,
                            guardian,
                            admin,
                            DefaultManager.InitModules({
                                bridge: address(bridge),
                                registry: address(registry),
                                reserves: address(reserves),
                                controller: address(controller),
                                curator: address(curator),
                                oracle: address(oracle),
                                usdfr: address(usdfr),
                                vault: address(vault)
                            })
                        )
                    )
                )
            )
        );
        assessedImpairmentSource = AssessedImpairmentSource(
            address(
                new ERC1967Proxy(
                    address(new AssessedImpairmentSource()),
                    abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(defaultManager)))
                )
            )
        );
        backstopMock = new MockCascadeBackstop(IERC20(address(usdfr)));
        queue = RedemptionQueue(
            address(
                new ERC1967Proxy(
                    address(new RedemptionQueue()),
                    abi.encodeCall(
                        RedemptionQueue.initialize,
                        (admin, guardian, admin, address(vault), address(usdfr), address(reserves))
                    )
                )
            )
        );

        // ── genesis classes (mirrors CollateralFixture / the deploy script) ─
        vm.startPrank(admin);
        registry.setClass(
            Config.CLASS_FILM_TAX_CREDITS, _receivable("Film & TV Tax Credits", 8000, 1400, 0, 730 days, 3500)
        );
        registry.setClass(
            Config.CLASS_RENEWABLE_ENERGY, _receivable("Renewable Energy", 7500, 1200, 0, 1825 days, 3500)
        );
        registry.setClass(Config.CLASS_LIFE_SCIENCES, _receivable("Life Sciences", 6000, 1600, 0, 2555 days, 3000));
        registry.setClass(Config.CLASS_REAL_ESTATE, _receivable("Real Estate", 7000, 1100, 0, 3650 days, 3500));
        registry.setClass(
            Config.CLASS_DIGITAL_ASSETS,
            ICollateralRegistry.ClassParams({
                name: "Digital Assets",
                model: ICollateralRegistry.CollateralModel.MarkedToMarket,
                active: true,
                maxLtvBps: 5000,
                maxMaturity: 365 days,
                concentrationLimitBps: 2000,
                marginCallLtvBps: 6500,
                liquidationLtvBps: 8000,
                maxMarkAge: 1 days
            })
        );
        bridge.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        bridge.setRequiredMintAttestations(Config.CLASS_RENEWABLE_ENERGY, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        bridge.setRequiredMintAttestations(Config.CLASS_LIFE_SCIENCES, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        bridge.setRequiredMintAttestations(Config.CLASS_REAL_ESTATE, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        // AUDIT FIX (H-4): CreditIssued is the TERMS quorum and is mandatory on every gate.
        bridge.setRequiredMintAttestations(Config.CLASS_DIGITAL_ASSETS, BIT_ASSIGNMENT | BIT_VALUATION | BIT_CREDIT);

        // ── role topology (as the deploy script will wire it) ─────────────
        bridge.grantRole(Roles.ORIGINATOR_ROLE, originator);
        bridge.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // lifecycle transitions
        bridge.grantRole(Roles.CREDIT_ROLE, address(defaultManager)); // freeze transitions
        registry.grantRole(Roles.CREDIT_ROLE, address(bridge)); // exposure increases (mint gate)
        registry.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // exposure decreases (repayment)
        registry.grantRole(Roles.CREDIT_ROLE, address(defaultManager)); // exposure decreases (loss)
        reserves.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // deployment and repayments
        reserves.grantRole(Roles.CREDIT_ROLE, address(defaultManager)); // write-downs
        controller.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // mintYield
        controller.grantRole(Roles.CREDIT_ROLE, address(defaultManager)); // burnLoss
        curator.grantRole(Roles.CREDIT_ROLE, address(defaultManager)); // absorbLoss
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(curator));
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(defaultManager));
        waterfall.grantRole(Roles.SERVICER_ROLE, servicer);
        defaultManager.grantRole(Roles.SERVICER_ROLE, servicer);
        defaultManager.setBackstop(address(backstopMock));
        // ADR-0022 Option Y: the engine clears a facility's unrealized-impairment contribution
        // when a defaulted loan recovers in full, and the vault prices exits on what remains.
        defaultManager.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // onDefaultResolved
        waterfall.setDefaultManager(address(defaultManager));
        vault.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // ADR-0023: notifyYield
        // Production wiring consumes the governed assessment wrapper, whose conservative
        // base remains DefaultManager. Tests must not bypass this mandatory valuation layer.
        vault.setImpairmentSource(address(assessedImpairmentSource));
        vault.setRedemptionQueue(address(queue)); // ADR-0010: the sole vault exit

        _postWireOracle(); // real-oracle fixtures grant roles here (no-op for mock)

        // curator approvals: anchor everywhere, a second curator on film
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            curator.setCuratorApproved(classId, anchorCurator, true);
        }
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, secondCurator, true);

        // Phase C test-era EOA grants are revoked: only real modules hold CREDIT_ROLE
        // on the token layer now (the fixture proves the production topology works).
        reserves.revokeRole(Roles.CREDIT_ROLE, creditModule);
        controller.revokeRole(Roles.CREDIT_ROLE, creditModule);
        vm.stopPrank();

        // curators are KYC'd so they can mint USDfr to post as first-loss
        vm.startPrank(complianceAdmin);
        compliance.setAllowed(anchorCurator, true);
        compliance.setAllowed(secondCurator, true);
        vm.stopPrank();
    }

    // ── oracle plumbing (virtual: RealOracleFixture swaps in the real thing) ──

    /// @dev Deploys the attestation oracle this fixture runs against (default: mock).
    function _deployOracle() internal virtual returns (IAttestationOracle) {
        return IAttestationOracle(address(new MockAttestationOracle()));
    }

    /// @dev Post-deployment oracle wiring inside the admin prank (roles etc.).
    function _postWireOracle() internal virtual {}

    /// @dev Marks a fact satisfied (mock: direct set; real: m-of-n signatures).
    function _setSatisfied(uint256 facilityId, IAttestationOracle.AttestationKind kind, bool ok) internal virtual {
        MockAttestationOracle(address(oracle)).setSatisfied(facilityId, kind, ok);
    }

    /// @dev Records an attested mark (mock: direct set; real: 2-of-n signatures).
    function _setValuation(uint256 facilityId, uint256 value, uint64 asOf) internal virtual {
        MockAttestationOracle(address(oracle)).setValuation(facilityId, value, asOf);
    }

    /// @dev AUDIT FIX (H-4) TEST-DESIGN GAP. Records the CreditIssued TERMS commitment for
    ///      `facilityId` as an ARBITRARY hash. Taking the hash rather than the terms is
    ///      deliberate: the attested terms and the originated terms are now two independent
    ///      inputs, so DIVERGENCE BETWEEN THEM IS EXPRESSIBLE. Before this, every helper
    ///      satisfied the gate at `nextId` immediately before originating, which made
    ///      attestation and terms agree by construction and this bug class invisible.
    function _attestCreditTerms(uint256 facilityId, bytes32 termsHash) internal virtual {
        MockAttestationOracle(address(oracle)).setPayload(
            facilityId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, uint64(block.timestamp), true
        );
    }

    // ── helpers ──────────────────────────────────────────────────────────

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

    /// @dev Mints `amount` (18-dec) USDfr to `user` through the real KYC-gated path.
    function _mintUSDfrTo(address user, uint256 amount) internal {
        uint256 usdcAmount = amount / 1e12;
        require(usdcAmount * 1e12 == amount, "use whole USDC units");
        usdc.mint(user, usdcAmount);
        vm.startPrank(user);
        usdc.approve(address(controller), usdcAmount);
        controller.mint(usdcAmount);
        vm.stopPrank();
    }

    /// @dev Posts `amount` first-loss for `who` on `classId` (minting the USDfr first).
    function _postFirstLoss(address who, uint256 classId, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    /// @dev Satisfies the film mint gate for the NEXT id and originates a facility.
    function _originateFilm(bytes32 borrowerId, bytes32 stateId, uint256 principal) internal returns (uint256 id) {
        uint64 maturity = uint64(block.timestamp + 365 days);
        uint256 nextId = bridge.totalOriginated() + 1;
        _attestFilmGate(nextId, borrowerId, stateId, principal, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF);
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
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

    /// @dev Satisfies the film mint gate at `facilityId` for the terms passed here. Split out
    ///      from `_originateFilm` so a test can attest ONE set of terms and originate ANOTHER
    ///      (AUDIT FIX H-4 test-design gap).
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
        _setSatisfied(facilityId, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        _setSatisfied(facilityId, IAttestationOracle.AttestationKind.UCCFiled, true);
        _attestCreditTerms(
            facilityId,
            bridge.creditTermsHash(
                _facilityTerms(
                    Config.CLASS_FILM_TAX_CREDITS,
                    borrowerId,
                    stateId,
                    principal,
                    ltvBps,
                    interestRateBps,
                    maturity,
                    offchainRef
                )
            )
        );
    }

    /// @dev Originates a digital-assets (marked-to-market) facility against a fresh
    ///      attested mark of `markValue`.
    function _originateDigital(uint256 principal, uint256 markValue) internal returns (uint256 id) {
        uint64 maturity = uint64(block.timestamp + 180 days);
        uint256 nextId = bridge.totalOriginated() + 1;
        _setSatisfied(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        _setSatisfied(nextId, IAttestationOracle.AttestationKind.Valuation, true);
        _setValuation(nextId, markValue, uint64(block.timestamp));
        _attestCreditTerms(
            nextId,
            bridge.creditTermsHash(
                _facilityTerms(
                    Config.CLASS_DIGITAL_ASSETS,
                    BORROWER_DESK,
                    bytes32(0),
                    principal,
                    DIGITAL_LTV_BPS,
                    DIGITAL_RATE_BPS,
                    maturity,
                    DIGITAL_REF
                )
            )
        );
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            Config.CLASS_DIGITAL_ASSETS,
            BORROWER_DESK,
            bytes32(0),
            principal,
            DIGITAL_LTV_BPS,
            DIGITAL_RATE_BPS,
            maturity,
            DIGITAL_REF
        );
        vm.prank(originator);
        id = bridge.originate(custodian, terms);
    }

    /// @dev Funds a Pending facility with exactly its principal in USDC. Idle reserves
    ///      must already hold the liquidity (deposits from alice/bob in tests).
    function _fundFacility(uint256 tokenId, uint256 principal) internal {
        uint256 usdcAmount = principal / 1e12;
        vm.prank(servicer);
        waterfall.fund(tokenId, usdcAmount);
    }

    /// @dev Records the attested PaymentReceived fact committing to exactly this
    ///      receipt (the Phase G payment gate; real signatures in RealOracleFixture).
    function _attestPayment(uint256 tokenId, uint256 interest, uint256 principal) internal virtual {
        MockAttestationOracle(address(oracle)).setPayload(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(
                abi.encode(
                    _paymentId(tokenId, interest, principal),
                    tokenId,
                    address(usdc),
                    borrower,
                    (interest + principal) / 1e12,
                    interest,
                    principal,
                    _nextDue(tokenId, principal)
                )
            ),
            uint64(block.timestamp),
            true
        );
    }

    /// @dev Records the attested DefaultDeclared fact (the declareDefault gate).
    function _attestDefault(uint256 tokenId) internal virtual {
        MockAttestationOracle(address(oracle)).setPayload(
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, FILM_REF)),
            uint64(block.timestamp),
            true
        );
    }

    /// @dev Records the exact, single-use LossRealized commitment.
    function _attestLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash) internal virtual {
        MockAttestationOracle(address(oracle)).setPayload(
            tokenId,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(tokenId, loss, evidenceHash)),
            uint64(block.timestamp),
            true
        );
    }

    /// @dev Records the exact, single-use PastDueCured commitment.
    function _attestPastDueCure(uint256 tokenId, bytes32 evidenceHash) internal virtual {
        MockAttestationOracle(address(oracle)).setPayload(
            tokenId,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(tokenId, evidenceHash)),
            uint64(block.timestamp),
            true
        );
    }

    /// @dev Test convenience for a fully attested loss execution.
    function _realizeLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash) internal {
        _attestLoss(tokenId, loss, evidenceHash);
        vm.prank(servicer);
        defaultManager.realizeLoss(tokenId, loss, evidenceHash);
    }

    /// @dev Test convenience for a fully attested past-due cure.
    function _clearPastDue(uint256 tokenId, bytes32 evidenceHash) internal {
        _attestPastDueCure(tokenId, evidenceHash);
        vm.prank(servicer);
        defaultManager.clearPastDue(tokenId, evidenceHash);
    }

    /// @dev Prepares an attested repayment receipt and returns the exact payment that the
    ///      servicer must distribute. Splitting preparation from execution lets event-order
    ///      tests bind `expectEmit` to the waterfall call rather than to the USDC/oracle
    ///      setup logs.
    function _preparePayment(uint256 tokenId, uint256 interest, uint256 principal)
        internal
        returns (IWaterfallEngine.Payment memory payment)
    {
        uint256 usdcAmount = (interest + principal) / 1e12;
        usdc.mint(borrower, usdcAmount);
        vm.prank(borrower);
        usdc.approve(address(reserves), usdcAmount);
        _attestPayment(tokenId, interest, principal);
        payment = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: _paymentId(tokenId, interest, principal),
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: _nextDue(tokenId, principal)
        });
    }

    /// @dev Simulates an attested repayment receipt: the stables physically arrive in
    ///      the treasury, the fact is attested, then the servicer distributes.
    function _repay(uint256 tokenId, uint256 interest, uint256 principal) internal {
        IWaterfallEngine.Payment memory payment = _preparePayment(tokenId, interest, principal);
        vm.prank(servicer);
        waterfall.distribute(payment);
    }

    /// @dev Originates AND funds a film facility, seeding reserve liquidity from alice
    ///      (fresh USDC minted so the helper is always self-funding).
    function _liveFilmFacility(uint256 principal) internal returns (uint256 id) {
        _mintUSDfrTo(alice, principal); // seed idle liquidity to deploy
        id = _originateFilm(BORROWER_1, STATE_GA, principal);
        _fundFacility(id, principal);
    }

    function _facilityTerms(
        uint256 classId,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint16 ltvBps,
        uint16 rateBps,
        uint64 maturity,
        bytes32 offchainRef
    ) internal view returns (ClaimBridge.OriginationTerms memory t) {
        t = ClaimBridge.OriginationTerms({
            classId: classId,
            borrowerId: borrowerId,
            stateId: stateId,
            principal: principal,
            ltvBps: ltvBps,
            interestRateBps: rateBps,
            maturity: maturity,
            fundingRecipient: borrower,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("fixture-amortization-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: offchainRef
        });
    }

    function _paymentId(uint256 tokenId, uint256 interest, uint256 principal) internal pure returns (bytes32) {
        return keccak256(abi.encode("fixture-payment", tokenId, interest, principal));
    }

    function _nextDue(uint256 tokenId, uint256 principal) internal view returns (uint64) {
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        if (principal == reserves.deployedTo(tokenId)) return 0;
        uint64 next = f.nextPaymentDue + f.paymentInterval;
        return next > f.maturity ? f.maturity : next;
    }
}
