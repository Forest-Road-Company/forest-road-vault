// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationOracle} from "../src/AttestationOracle.sol";
import {ClaimBridge} from "../src/ClaimBridge.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {CuratorModule} from "../src/CuratorModule.sol";
import {DefaultManager} from "../src/DefaultManager.sol";
import {MintRedeemController} from "../src/MintRedeemController.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {SGrove} from "../src/SGrove.sol";
import {SUSDfr} from "../src/sUSDfr.sol";
import {USDfr} from "../src/USDfr.sol";
import {WaterfallEngine} from "../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {IMintRedeemController} from "../src/interfaces/IMintRedeemController.sol";
import {IWaterfallEngine} from "../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../src/libraries/Config.sol";

interface ITestnetUSDC is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title QA — current-stack, baseline-relative Sepolia lifecycle rehearsal
/// @notice Exercises actual production ABIs: USDC mint → USDfr → sUSDfr → signed complete
///         origination → OID funding → exact atomic payment → first loss/backstop → exact
///         signed default and loss → queued redemption. No mainnet execution is permitted.
contract QA is Script {
    struct Stack {
        USDfr usdfr;
        SUSDfr vault;
        MintRedeemController controller;
        ReserveManager reserves;
        RedemptionQueue queue;
        ClaimBridge bridge;
        CuratorModule curator;
        WaterfallEngine waterfall;
        DefaultManager defaults;
        AttestationOracle oracle;
        SGrove sGrove;
        IERC20 grove;
        ComplianceRegistry compliance;
        ITestnetUSDC usdc;
    }

    uint256 private operationsKey;
    uint256 private attester1Key;
    uint256 private secondAttesterKey;
    address private actor;
    uint256 private nonce;

    function run() external {
        string memory manifest = _loadBoundManifest();
        Stack memory s = _load(manifest);

        operationsKey = vm.envUint("TESTNET_OPS_ADMIN_PRIVATE_KEY");
        actor = vm.addr(operationsKey);
        require(actor == vm.parseJsonAddress(manifest, ".opsAdmin"), "TESTNET_OPS_ADMIN_PRIVATE_KEY mismatch");

        // The bootstrap deployer is also testnet attester #1, but it is deliberately not the
        // lifecycle transaction sender on a split-key deployment. All ORIGINATOR_ROLE and
        // SERVICER_ROLE calls below are broadcast by the manifest ops admin; this key is used
        // only to produce the first quorum signature.
        attester1Key = vm.envUint("TESTNET_DEPLOYER_PRIVATE_KEY");
        require(
            vm.addr(attester1Key) == vm.parseJsonAddress(manifest, ".attester1"),
            "TESTNET_DEPLOYER_PRIVATE_KEY is not manifest attester1"
        );
        secondAttesterKey =
            vm.envOr("ATTESTER_2_PRIVATE_KEY", uint256(keccak256(abi.encode(attester1Key, "fr-testnet-attester-2"))));
        require(vm.addr(secondAttesterKey) == vm.parseJsonAddress(manifest, ".attester2"), "ATTESTER_2 key mismatch");
        vm.startBroadcast(operationsKey);
        // A fresh split-key deployment deliberately removes the bootstrap deployer's seed-only
        // allowlist entry and does not pre-allowlist the ops EOA. Make that operational mutation
        // explicit at invocation time: a rehearsal may opt in, while an accidental live run
        // cannot silently expand KYC state merely by possessing the ops key.
        if (!s.compliance.isAllowed(actor)) {
            require(vm.envOr("QA_ALLOWLIST_OPS", false), "QA ops is not KYC-allowed; set QA_ALLOWLIST_OPS=true");
            s.compliance.setAllowed(actor, true);
        }
        require(s.compliance.isAllowed(actor), "QA ops KYC setup failed");
        uint256 tokenId = _positiveLifecycle(s);
        vm.stopBroadcast();

        if (!vm.envOr("BROADCAST_ONLY", false)) _negativeChecks(s, tokenId);
        console2.log("QA PASSED; facility", tokenId);
    }

    /// @dev Binds QA to the canonical deployment receipt for the connected chain. A local
    ///      chain-ID-31337 Sepolia fork must opt in explicitly with
    ///      QA_FORK_SOURCE_CHAIN_ID=11155111; the distinct local chain ID remains the broadcast
    ///      safety boundary. DEPLOYMENT_MANIFEST may select a path, but never different content.
    function _loadBoundManifest() internal view returns (string memory manifest) {
        return _loadBoundManifestFor(
            vm.envOr("DEPLOYMENT_MANIFEST", string("")), vm.envOr("QA_FORK_SOURCE_CHAIN_ID", uint256(0))
        );
    }

    function _loadBoundManifestFor(string memory requestedPath, uint256 forkSourceChainId)
        internal
        view
        returns (string memory manifest)
    {
        require(block.chainid != 1, "MAINNET FORBIDDEN");
        require(block.chainid == 11155111 || block.chainid == 31337, "QA UNSUPPORTED CHAIN");

        uint256 manifestChainId = block.chainid;
        if (block.chainid == 31337) {
            require(forkSourceChainId == 0 || forkSourceChainId == 11155111, "QA INVALID FORK SOURCE CHAIN");
            if (forkSourceChainId != 0) manifestChainId = forkSourceChainId;
        } else {
            require(forkSourceChainId == 0, "QA FORK SOURCE ON LIVE CHAIN");
        }

        string memory canonicalPath = _canonicalManifestPath(manifestChainId);
        if (bytes(requestedPath).length == 0) requestedPath = canonicalPath;

        string memory canonicalManifest = vm.readFile(canonicalPath);
        manifest = vm.readFile(requestedPath);
        require(vm.parseJsonUint(manifest, ".chainId") == manifestChainId, "QA MANIFEST CHAIN MISMATCH");
        require(keccak256(bytes(manifest)) == keccak256(bytes(canonicalManifest)), "QA MANIFEST NOT CANONICAL");
    }

    /// @dev Virtual only so the unit-test harness can bind local-chain checks to a committed,
    ///      immutable fixture instead of depending on the gitignored receipt produced by a
    ///      developer's latest Anvil deployment. Production QA keeps this exact path.
    function _canonicalManifestPath(uint256 manifestChainId) internal view virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(manifestChainId), ".json");
    }

    function _positiveLifecycle(Stack memory s) private returns (uint256 tokenId) {
        // The run is baseline-relative: every assertion checks deltas, never pristine totals.
        uint256 supplyBefore = s.usdfr.totalSupply();
        s.usdc.mint(actor, 60_000e6);
        s.usdc.approve(address(s.controller), 60_000e6);
        uint256 minted = s.controller.mint(60_000e6);
        require(minted == 60_000e18, "mint normalization");
        require(s.usdfr.totalSupply() - supplyBefore == minted, "mint supply delta");

        s.usdfr.approve(address(s.vault), 20_000e18);
        uint256 shares = s.vault.deposit(20_000e18, actor);
        require(shares != 0, "stake shares");

        tokenId = _originate(s, 10_000e18);
        uint256 actorUSDCBefore = s.usdc.balanceOf(actor);
        s.waterfall.fund(tokenId, 10_000e6);
        require(s.usdc.balanceOf(actor) - actorUSDCBefore == 9_800e6, "2% OID net");
        require(s.reserves.deployedTo(tokenId) == 10_000e18, "funded face");

        _repay(s, tokenId);
        require(s.reserves.deployedTo(tokenId) == 8_000e18, "principal payment");

        s.usdfr.approve(address(s.curator), 5_000e18);
        s.curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 5_000e18);
        uint256 groveBalance = s.grove.balanceOf(actor);
        if (groveBalance >= 1_000e18) {
            s.grove.approve(address(s.sGrove), 1_000e18);
            s.sGrove.stake(1_000e18);
        }
        s.usdfr.approve(address(s.sGrove), 3_000e18);
        s.sGrove.fundCoverage(3_000e18);

        bytes32 evidence = keccak256(abi.encode("QA_DEFAULT_EVIDENCE", tokenId));
        _attest(
            s.oracle,
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, evidence))
        );
        uint256 unresolvedBefore = s.curator.unresolvedDefaults(Config.CLASS_FILM_TAX_CREDITS);
        s.defaults.declareDefault(tokenId, evidence);
        require(
            s.curator.unresolvedDefaults(Config.CLASS_FILM_TAX_CREDITS) == unresolvedBefore + 1, "default freeze delta"
        );

        uint256 loss = 2_000e18;
        _attest(
            s.oracle,
            tokenId,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(tokenId, loss, evidence))
        );
        uint256 curatorBefore = s.curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        s.defaults.realizeLoss(tokenId, loss, evidence);
        require(s.curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS) == curatorBefore - loss, "curator-first cascade");

        uint256 redeemShares = s.vault.previewWithdraw(1_000e18);
        s.vault.approve(address(s.queue), redeemShares);
        uint256 requestId = s.queue.requestRedeem(redeemShares);
        require(requestId < s.queue.totalRequests(), "queue request");
    }

    function _repay(Stack memory s, uint256 tokenId) private {
        uint256 interest = 1_000e18;
        uint256 principal = 2_000e18;
        uint64 nextDue = _nextDue(s, tokenId, principal);
        bytes32 paymentId = keccak256(abi.encode("QA_PAYMENT", block.chainid, tokenId, block.number));
        uint256 usdcAmount = (interest + principal) / 1e12;
        bytes32 payload =
            keccak256(abi.encode(paymentId, tokenId, address(s.usdc), actor, usdcAmount, interest, principal, nextDue));
        _attest(s.oracle, tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload);
        s.usdc.approve(address(s.reserves), usdcAmount);
        s.waterfall.distribute(
            IWaterfallEngine.Payment({
                tokenId: tokenId,
                paymentId: paymentId,
                payer: actor,
                interest: interest,
                principal: principal,
                nextPaymentDue: nextDue
            })
        );
    }

    function _originate(Stack memory s, uint256 principal) private returns (uint256 tokenId) {
        tokenId = s.bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = ClaimBridge.OriginationTerms({
            classId: Config.CLASS_FILM_TAX_CREDITS,
            borrowerId: keccak256("BORROWER_QA"),
            stateId: keccak256("GA"),
            principal: principal,
            ltvBps: 7500,
            interestRateBps: 1400,
            maturity: uint64(block.timestamp + 365 days),
            fundingRecipient: actor,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("QA_AMORTIZATION_SCHEDULE"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("QA_CREDIT_FILE")
        });
        bytes32 termsHash = s.bridge.creditTermsHash(terms);
        _attest(s.oracle, tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(s.oracle, tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(s.oracle, tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        uint256 originated = s.bridge.originate(actor, terms);
        require(originated == tokenId && s.bridge.ownerOf(tokenId) == actor, "origination");
    }

    function _nextDue(Stack memory s, uint256 tokenId, uint256 principal) private view returns (uint64) {
        ClaimBridge.Facility memory f = s.bridge.facility(tokenId);
        if (principal == s.reserves.deployedTo(tokenId)) return 0;
        uint64 next = f.nextPaymentDue + f.paymentInterval;
        return next > f.maturity ? f.maturity : next;
    }

    function _negativeChecks(Stack memory s, uint256 tokenId) private {
        address stranger = address(0xDeaD01);
        require(!s.compliance.isAllowed(stranger), "negative actor unexpectedly KYC");
        vm.prank(stranger);
        (bool ok, bytes memory reason) = address(s.controller).call(abi.encodeCall(MintRedeemController.mint, (1e6)));
        require(!ok, "non-KYC mint succeeded");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, stranger)),
            "non-KYC mint returned wrong error"
        );

        IWaterfallEngine.Payment memory fake = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: keccak256("UNATTESTED"),
            payer: actor,
            interest: 1e18,
            principal: 0,
            nextPaymentDue: 0
        });
        vm.prank(actor);
        (ok, reason) = address(s.waterfall).call(abi.encodeCall(IWaterfallEngine.distribute, (fake)));
        require(!ok, "unattested payment succeeded");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId)),
            "unattested payment returned wrong error"
        );
    }

    function _attest(
        AttestationOracle oracle,
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload
    ) private {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 2 hours),
            nonce: uint256(keccak256(abi.encode(block.chainid, facilityId, kind, ++nonce, block.number)))
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 low, uint256 high) = vm.addr(attester1Key) < vm.addr(secondAttesterKey)
            ? (attester1Key, secondAttesterKey)
            : (secondAttesterKey, attester1Key);
        uint8 threshold = oracle.threshold(kind);
        bytes[] memory signatures = new bytes[](threshold);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(low, digest);
        signatures[0] = abi.encodePacked(r, ss, v);
        if (threshold > 1) {
            (v, r, ss) = vm.sign(high, digest);
            signatures[1] = abi.encodePacked(r, ss, v);
        }
        oracle.attest(a, signatures);
    }

    function _load(string memory m) private view returns (Stack memory s) {
        s.usdfr = USDfr(vm.parseJsonAddress(m, ".usdfr"));
        s.vault = SUSDfr(vm.parseJsonAddress(m, ".vault"));
        s.controller = MintRedeemController(vm.parseJsonAddress(m, ".controller"));
        s.reserves = ReserveManager(vm.parseJsonAddress(m, ".reserves"));
        s.queue = RedemptionQueue(vm.parseJsonAddress(m, ".queue"));
        s.bridge = ClaimBridge(vm.parseJsonAddress(m, ".bridge"));
        s.curator = CuratorModule(vm.parseJsonAddress(m, ".curator"));
        s.waterfall = WaterfallEngine(vm.parseJsonAddress(m, ".waterfall"));
        s.defaults = DefaultManager(vm.parseJsonAddress(m, ".defaultManager"));
        s.oracle = AttestationOracle(vm.parseJsonAddress(m, ".oracle"));
        s.sGrove = SGrove(vm.parseJsonAddress(m, ".sGrove"));
        s.grove = IERC20(vm.parseJsonAddress(m, ".grove"));
        s.compliance = ComplianceRegistry(vm.parseJsonAddress(m, ".compliance"));
        s.usdc = ITestnetUSDC(
            vm.keyExistsJson(m, ".stable")
                ? vm.parseJsonAddress(m, ".stable")
                : vm.parseJsonAddress(m, ".stable_TESTNET_MOCK")
        );
    }
}
