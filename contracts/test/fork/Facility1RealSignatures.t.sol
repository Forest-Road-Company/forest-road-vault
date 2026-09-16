// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";

interface IOracle {
    function attest(IAttestationOracle.AttestationInput calldata a, bytes[] calldata signatures) external;
}

interface IWaterfall {
    function fund(uint256 tokenId, uint256 usdcAmount) external;
}

interface IReserves {
    function totalBackingValue() external view returns (uint256);
}

interface IController {
    function backingInvariantHolds() external view returns (bool);
}

/// @notice Replays the REAL KMS attester signatures against a mainnet fork before they are
///         broadcast. The rehearsal that preceded this used throwaway keys and granted them
///         ATTESTER_ROLE; this one grants nothing and impersonates nobody. The production
///         attesters must recover from these exact signature bytes, or the mint gate stays shut.
///
///         If this passes, the same three `attest` calls will succeed on mainnet.
contract Facility1RealSignatures is Test {
    address constant BRIDGE = 0x46FE513a20a1d4Fe77ecEcB763C6843D7AbBF32a;
    address constant ORACLE = 0x5e01d55B4B6c361Dd8b9B889F21A731E22281167;
    address constant WATERFALL = 0x243ffF766D2c32CD09b148C684a8c3536e37B3eA;
    address constant RESERVES = 0x35683472E609249A6750ecDB850EFfde8a88CFF1;
    address constant CONTROLLER = 0xbd2e71C8cf6D989E746116D5D0d622C44d498da5;
    address constant OPS = 0x297e88C997c2e0EDF70A5F817AAdcA2858Aa6c04;
    address constant TREASURY = 0x0687a13c490B2573d4666fb3a7c21826a621215E;
    address constant RECIPIENT = 0xF6E0efD25be6f4302190Ea44DB596719Aa400588;

    bytes constant SIG_ASSIGNMENT =
        hex"7230931e2061d47ef49f373eb146c7278ff977f2c3184d28a079d8af3540eace723b3de5846791ffae0b4e945653c4e1c5e4f6597e1f52bc69ed78e849c36fd21b";
    bytes constant SIG_UCC =
        hex"267a8a0c08b5eb94a75128f80baada456907758ea7e3a744b6866784c35917503df061063089bbb126c4d4d97f54e36b4b1fefa2f04f57dbc9b6f4178317a4ad1c";
    bytes constant SIG_CREDIT_A1 =
        hex"8d7ff0dffe8e5f193fc3af3f4fbb882fc9bada1be2c46263b2b893852b453a9a79aa74829c89f01deff8452ddb919b5b4e915bd92af995b6ce3c8ecdaefab3601c";
    bytes constant SIG_CREDIT_A2 =
        hex"644a09dc477a03b1ca89dd4efe41d4076165ba9a1b9afa8e3f0fec56d9e49f031fd50a3d270e06cd78a012c0f1fe56be9e8208d9aa5af70e535b6969c3ddbffb1c";

    function _terms() internal pure returns (ClaimBridge.OriginationTerms memory t) {
        t = ClaimBridge.OriginationTerms({
            classId: 2,
            borrowerId: bytes32(uint256(1)),
            stateId: bytes32(0),
            principal: 100e18,
            ltvBps: 5500,
            interestRateBps: 1675,
            maturity: 1874707200,
            fundingRecipient: RECIPIENT,
            paymentInterval: 7889400,
            nextPaymentDue: 1790726400,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Thirty360,
            renewable: false,
            paymentScheduleHash: 0xd6694762e3fb1746f2a6627abac995e529593b4638825eb3c8d6e0463f34d7e8,
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: 0x52452d3030310000000000000000000000000000000000000000000000000000
        });
    }

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        pure
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: 1,
            kind: kind,
            payload: payload,
            asOf: 1787529600,
            expiry: 1790726400,
            nonce: 1
        });
    }

    function test_realSignaturesSatisfyTheMintGate() public {
        // Skip rather than fail when no fork RPC is configured. The `contracts` CI job
        // deliberately carries no RPC secret, so a hard envString turns an intended skip
        // into a red suite.
        string memory forkUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(forkUrl).length == 0);
        vm.createSelectFork(forkUrl, 25848835);

        ClaimBridge.OriginationTerms memory t = _terms();
        bytes32 termsHash = ClaimBridge(BRIDGE).creditTermsHash(t);
        assertEq(
            termsHash,
            0x5027fcf72ba803e90bf89fa716ecfa319ff33710d3c2f12ae211e8783b1bc5f0,
            "terms hash drifted from what was signed"
        );

        // Anyone may relay a signed attestation; the signatures carry the authority.
        bytes[] memory one = new bytes[](1);
        one[0] = SIG_ASSIGNMENT;
        IOracle(ORACLE).attest(_input(IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash), one);

        one[0] = SIG_UCC;
        IOracle(ORACLE).attest(_input(IAttestationOracle.AttestationKind.UCCFiled, termsHash), one);

        bytes[] memory two = new bytes[](2);
        two[0] = SIG_CREDIT_A1; // 0x759C… sorts below 0xE2E5…
        two[1] = SIG_CREDIT_A2;
        IOracle(ORACLE).attest(_input(IAttestationOracle.AttestationKind.CreditIssued, termsHash), two);

        uint256 backingBefore = IReserves(RESERVES).totalBackingValue();

        vm.prank(OPS);
        uint256 tokenId = ClaimBridge(BRIDGE).originate(TREASURY, t);
        assertEq(tokenId, 1, "first facility must be id 1");
        assertEq(ClaimBridge(BRIDGE).ownerOf(1), TREASURY, "NFT must land with the treasury");

        vm.prank(OPS);
        IWaterfall(WATERFALL).fund(1, 100_000_000);

        uint256 backingAfter = IReserves(RESERVES).totalBackingValue();
        console2.log("backing before / after:", backingBefore, backingAfter);
        assertTrue(IController(CONTROLLER).backingInvariantHolds(), "backing invariant must hold");
        assertEq(backingAfter, backingBefore + 2e18, "capitalised 2% fee must raise backing by $2");
    }
}
