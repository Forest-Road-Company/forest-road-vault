// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SGrove} from "../../src/SGrove.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ForkLifecycleFixture — the FULL protocol, deployed onto a pinned mainnet fork
/// @notice Every other fork suite builds on this. It exists because the in-memory fixtures use
///         `MockERC20` for the approved stable, and `script/QA.s.sol` — the only end-to-end
///         lifecycle we had — was last run against a Sepolia stack that predates ADR-0022/0023/
///         0025, PM-R-02/07/11, L-02 and H-02. Neither exercised current code against real
///         token behaviour, and neither ever completed the TIME-GATED steps (the 21-day
///         redemption cooldown, the 30-day epoch, the 21-day sGROVE unbond, the 2-day timelock)
///         because waiting them out on a live testnet is impractical.
///
///         Here they are all reachable: `vm.warp` costs nothing, so the claim and unstake paths
///         that have never been executed end-to-end anywhere are executed here.
///
/// @dev DEPLOYMENT MODEL. This inherits `Deploy` and calls its internal phases
///      (`_deployAll`/`_wire`/`_seed`) directly — the same pattern `test/integration/
///      ProdDeploy.t.sol` uses — so the topology under test is the REAL deploy script's, not a
///      hand-rolled approximation. Anything the deploy script gets wrong, these tests inherit.
///
///      MAINNET SAFETY (CLAUDE.md prime directive 1). This forks mainnet, so `block.chainid`
///      is 1 inside these tests. That is safe and is NOT a mainnet deployment: `forge test`
///      never broadcasts (no `--broadcast`), the fork is local and ephemeral, and nothing here
///      touches a real key. `Deploy.run()` — which carries the chain-id-1 hard revert — is
///      deliberately NOT called; we invoke the internal phases. **Never add `run()` to this
///      file, and never run these with a broadcast flag.** The guard exists for the scripted
///      path and must stay there.
///
///      The fork block is PINNED (CLAUDE.md §1.4) so results are reproducible.
abstract contract ForkLifecycleFixture is Test, Deploy {
    // ── canonical mainnet tokens at the pinned block ─────────────────────
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6-dec
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6-dec, non-standard
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18-dec
    uint256 internal constant FORK_BLOCK = 25_500_000;

    /// @dev Individual suites may select a later pinned block when their rehearsal depends on
    ///      production control contracts that did not yet exist at `FORK_BLOCK`. The default
    ///      remains unchanged for every existing lifecycle suite.
    function _forkBlock() internal pure virtual returns (uint256) {
        return FORK_BLOCK;
    }

    // ── attester keys (the 2-of-n quorum signs for real, EIP-712) ────────
    uint256 internal constant PK1 = 0xA11CE;
    uint256 internal constant PK2 = 0xB0B;

    // ── actors ───────────────────────────────────────────────────────────
    address internal ops; // == address(this): deployer, opsAdmin, originator, servicer
    address internal attesterA; // signing attester #1 (PK1)
    address internal attester2Addr; // signing attester #2 (PK2)
    address internal alice = makeAddr("forkAlice"); // KYC'd depositor
    address internal bob = makeAddr("forkBob"); // KYC'd depositor
    address internal carol = makeAddr("forkCarol"); // NOT KYC'd
    address internal borrower = makeAddr("forkBorrower");

    // ── deployed system ──────────────────────────────────────────────────
    D internal dep;
    ComplianceRegistry internal compliance;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    PointsModule internal points;
    CollateralRegistry internal registry;
    AttestationOracle internal oracle;
    ClaimBridge internal bridge;
    CuratorModule internal curator;
    WaterfallEngine internal waterfall;
    DefaultManager internal defaultManager;
    RedemptionQueue internal queue;
    GroveToken internal grove;
    SGrove internal sGrove;
    address internal timelock;

    bool internal forkReady;
    uint256 internal attestationNonce;

    /// @dev Guards every fork test. Unlike the previous `forkOnly` pattern — which silently
    ///      returned and let the test report PASS while executing NOTHING — this SKIPS
    ///      explicitly, so a run without an RPC key can never be mistaken for a run that
    ///      actually exercised the protocol.
    modifier onFork() {
        vm.skip(!forkReady);
        _;
    }

    function setUp() public virtual {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return; // tests SKIP (not pass) via `onFork`
        vm.createSelectFork(url, _forkBlock());
        forkReady = true;

        // `Deploy`'s internal phases execute as `msg.sender`, which inside a forge test is
        // the test contract — so the deployer MUST be `address(this)` or every role lands on
        // an address that cannot then use it. The two ATTESTER keys are separate, because a
        // real 2-of-n bundle has to be SIGNED and the test contract has no private key.
        ops = address(this);
        attesterA = vm.addr(PK1);
        attester2Addr = vm.addr(PK2);

        Ctx memory c;
        c.deployer = ops;
        c.opsAdmin = ops; // testnet shape: one operator holds the ops roles
        c.frTreasury = ops;
        c.feeRecipient = ops;
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true; // retains DEFAULT_ADMIN so tests can turn parameters

        dep = _deployAll(c);
        _wire(dep, c);
        _seed(dep, c);

        compliance = ComplianceRegistry(dep.compliance);
        usdfr = USDfr(dep.usdfr);
        reserves = ReserveManager(dep.reserves);
        controller = MintRedeemController(dep.controller);
        vault = SUSDfr(dep.vault);
        points = PointsModule(dep.points);
        registry = CollateralRegistry(dep.registry);
        oracle = AttestationOracle(dep.oracle);
        bridge = ClaimBridge(dep.bridge);
        curator = CuratorModule(dep.curator);
        waterfall = WaterfallEngine(dep.waterfall);
        defaultManager = DefaultManager(dep.defaultManager);
        queue = RedemptionQueue(dep.queue);
        grove = GroveToken(dep.grove);
        sGrove = SGrove(dep.sGrove);
        timelock = dep.timelock;

        // The deploy granted ATTESTER_ROLE to `c.deployer` (the keyless test contract) and to
        // `attester2Addr`. Add the first SIGNING key so a genuine 2-of-n bundle can be formed.
        oracle.grantRole(Roles.ATTESTER_ROLE, attesterA);

        // KYC the depositors. `_seed` retires the deployer's bootstrap KYC, so this is the
        // ordinary operator path, not a leftover privilege.
        compliance.setAllowed(alice, true);
        compliance.setAllowed(bob, true);
        compliance.setAllowed(ops, true);

        // Fund the actors with REAL USDC by writing balances on the fork.
        deal(USDC, alice, 5_000_000e6);
        deal(USDC, bob, 5_000_000e6);
        deal(USDC, carol, 1_000_000e6);
        deal(USDC, ops, 5_000_000e6);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Mint USDfr from REAL USDC. Returns the 18-dec USDfr minted.
    function _mintFromUSDC(address who, uint256 usdcAmount) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(USDC).approve(address(controller), usdcAmount);
        out = controller.mint(usdcAmount);
        vm.stopPrank();
    }

    /// @dev Stake USDfr into the sUSDfr vault.
    function _stake(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdfr.approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev A REAL 2-of-n EIP-712 attestation, signed by both attester keys and relayed.
    ///      Signatures must be sorted ascending by signer address (the oracle enforces it).
    function _attest(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload) internal {
        _attestAt(facilityId, kind, payload, uint64(block.timestamp));
    }

    /// @dev As `_attest`, with an explicit attested observation time (`asOf`).
    function _attestAt(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        internal
    {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        // (signatures must be sorted ascending by signer address; the oracle enforces it)
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(lo, digest);
        sigs[1] = _sign(hi, digest);
        oracle.attest(a, sigs);
    }

    function _sign(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Satisfies the FILM mint gate at `facilityId` for the terms passed here — kept
    ///      separate from the `originate` call so a fork test can attest one set of terms and
    ///      originate another (AUDIT FIX H-4: divergence must be expressible).
    function _attestFilmGate(
        uint256 facilityId,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint16 ltvBps,
        uint64 maturity,
        bytes32 offchainRef
    ) internal {
        _attest(facilityId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("assign"));
        _attest(facilityId, IAttestationOracle.AttestationKind.UCCFiled, keccak256("ucc"));
        _attest(
            facilityId,
            IAttestationOracle.AttestationKind.CreditIssued,
            bridge.creditTermsHash(_forkTerms(borrowerId, stateId, principal, ltvBps, maturity, offchainRef))
        );
    }

    /// @dev Originate a FILM facility through the real m-of-n mint gate, then fund it.
    ///      `principal` is 18-dec; the stable leg converts at 1e12.
    function _originateAndFund(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(
            tokenId, keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref")
        );

        vm.prank(ops);
        uint256 id = bridge.originate(
            ops,
            _forkTerms(keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref"))
        );
        require(id == tokenId, "fork fixture: tokenId drift");

        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    /// @dev Deliver repayment stables into the treasury and reconcile them (ADR-0025), then
    ///      spend a REAL PaymentReceived attestation through the waterfall.
    function _repay(uint256 tokenId, uint256 interest, uint256 principalRepaid) internal {
        uint256 stableAmount = (interest + principalRepaid) / 1e12;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        uint64 nextDue = principalRepaid == reserves.deployedTo(tokenId) ? 0 : f.nextPaymentDue + f.paymentInterval;
        bytes32 paymentId = keccak256(abi.encode("fork-payment", tokenId, interest, principalRepaid));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, interest, principalRepaid, nextDue))
        );
        vm.prank(ops);
        waterfall.distribute(
            IWaterfallEngine.Payment({
                tokenId: tokenId,
                paymentId: paymentId,
                payer: borrower,
                interest: interest,
                principal: principalRepaid,
                nextPaymentDue: nextDue
            })
        );
    }

    /// @dev Declare a default using the exact evidence-bound payload required by the
    ///      clean-v1 DefaultManager. Keeping this in the shared fork fixture prevents
    ///      lifecycle suites from accidentally testing the pre-binding shortcut.
    function _declareDefault(uint256 tokenId, bytes32 evidenceHash) internal {
        _attest(
            tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(tokenId, evidenceHash))
        );
        vm.prank(ops);
        defaultManager.declareDefault(tokenId, evidenceHash);
    }

    /// @dev Realize a loss using a fresh exact LossRealized attestation. A distinct
    ///      attestation is required for every chunk because the amount is value-bearing.
    function _attestLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash) internal {
        _attest(
            tokenId, IAttestationOracle.AttestationKind.LossRealized, keccak256(abi.encode(tokenId, loss, evidenceHash))
        );
    }

    function _realizeLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash) internal {
        _attestLoss(tokenId, loss, evidenceHash);
        vm.prank(ops);
        defaultManager.realizeLoss(tokenId, loss, evidenceHash);
    }

    function _forkTerms(
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint16 ltvBps,
        uint64 maturity,
        bytes32 offchainRef
    ) internal view returns (ClaimBridge.OriginationTerms memory) {
        return _forkTermsFor(
            Config.CLASS_FILM_TAX_CREDITS, borrowerId, stateId, principal, ltvBps, 1400, maturity, offchainRef
        );
    }

    function _forkTermsFor(
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
            fundingRecipient: borrower,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("fork-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: offchainRef
        });
    }

    /// @dev The facility NFT is `_safeMint`ed to the originator, which here is this contract,
    ///      so it must accept ERC-721. Returning the selector is the whole requirement.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev Fast-forward `secs` on the fork, keeping block numbers moving so anything
    ///      block-sensitive behaves plausibly.
    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12); // ~12s mainnet blocks
    }

    function _deployUSDC() internal pure override returns (address) {
        return USDC;
    }

    function _fundSeedUSDC(address asset, address recipient, uint256 amount) internal override {
        deal(asset, recipient, IERC20(asset).balanceOf(recipient) + amount);
    }
}
