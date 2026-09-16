// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "../../src/libraries/Roles.sol";

interface IOracle {
    function attest(IAttestationOracle.AttestationInput calldata a, bytes[] calldata signatures) external;
    function attestationDigest(IAttestationOracle.AttestationInput calldata a) external view returns (bytes32);
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

/// @notice Rehearsal of the facility 1 origination against a pinned mainnet fork, required by
///         CLAUDE.md prime directive 1 as amended 2026-08-27 before any real signature or transfer.
///
///         Proves the terms encoding, the terms hash, the three attestation digests, the mint gate
///         and the funding accounting. It does NOT prove the production key path: the real attester
///         keys cannot sign here, so ATTESTER_ROLE is granted to two throwaway signers on the fork.
contract Facility1OriginationRehearsal is Test {
    address constant BRIDGE = 0x46FE513a20a1d4Fe77ecEcB763C6843D7AbBF32a;
    address constant ORACLE = 0x5e01d55B4B6c361Dd8b9B889F21A731E22281167;
    address constant WATERFALL = 0x243ffF766D2c32CD09b148C684a8c3536e37B3eA;
    address constant RESERVES = 0x35683472E609249A6750ecDB850EFfde8a88CFF1;
    address constant CONTROLLER = 0xbd2e71C8cf6D989E746116D5D0d622C44d498da5;
    address constant TIMELOCK = 0x263289d62352f9326456d1430466337484c806Dc;
    address constant OPS = 0x297e88C997c2e0EDF70A5F817AAdcA2858Aa6c04;
    address constant TREASURY = 0x0687a13c490B2573d4666fb3a7c21826a621215E;
    address constant RECIPIENT = 0xF6E0efD25be6f4302190Ea44DB596719Aa400588;

    uint256 constant PK1 = 0xA11CE;
    uint256 constant PK2 = 0xB0B;

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

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attest(IAttestationOracle.AttestationKind kind, bytes32 payload, uint256 sigs) internal {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: 1,
            kind: kind,
            payload: payload,
            asOf: 1787529600,
            expiry: 1790726400,
            nonce: 1
        });
        bytes32 digest = IOracle(ORACLE).attestationDigest(a);
        console2.log("  digest kind", uint256(uint8(kind)));
        console2.logBytes32(digest);
        // AUDIT SURFACE (found by this rehearsal): the oracle rejects `Oracle_UnorderedSigners`
        // unless signatures arrive in ASCENDING SIGNER ADDRESS order. Nothing in the origination
        // data sheet says so, and the real ceremony must order the two CreditIssued signatures the
        // same way.
        bytes[] memory signatures = new bytes[](sigs);
        if (sigs == 1) {
            signatures[0] = _sign(PK1, digest);
        } else {
            (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
            signatures[0] = _sign(lo, digest);
            signatures[1] = _sign(hi, digest);
        }
        IOracle(ORACLE).attest(a, signatures);
    }

    function test_rehearse_facility1() public {
        // Skip rather than fail when no fork RPC is configured. The `contracts` CI job
        // deliberately carries no RPC secret, so a hard envString turns an intended skip
        // into a red suite.
        string memory forkUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(forkUrl).length == 0);
        vm.createSelectFork(forkUrl, 25848835);

        // The production attesters cannot sign here. Grant the role to throwaway signers so the
        // rest of the sequence is exercised exactly as it will run.
        vm.startPrank(TIMELOCK);
        IAccessControl(ORACLE).grantRole(Roles.ATTESTER_ROLE, vm.addr(PK1));
        IAccessControl(ORACLE).grantRole(Roles.ATTESTER_ROLE, vm.addr(PK2));
        vm.stopPrank();

        ClaimBridge.OriginationTerms memory t = _terms();
        bytes32 termsHash = ClaimBridge(BRIDGE).creditTermsHash(t);
        console2.log("termsHash:");
        console2.logBytes32(termsHash);
        assertEq(
            termsHash,
            0x5027fcf72ba803e90bf89fa716ecfa319ff33710d3c2f12ae211e8783b1bc5f0,
            "terms hash drifted from the signed package"
        );

        _attest(IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, 1);
        _attest(IAttestationOracle.AttestationKind.UCCFiled, termsHash, 1);
        _attest(IAttestationOracle.AttestationKind.CreditIssued, termsHash, 2);

        uint256 backingBefore = IReserves(RESERVES).totalBackingValue();

        vm.prank(OPS);
        uint256 tokenId = ClaimBridge(BRIDGE).originate(TREASURY, t);
        assertEq(tokenId, 1, "first facility must be id 1");
        assertEq(ClaimBridge(BRIDGE).ownerOf(1), TREASURY, "NFT must land with the treasury");

        vm.prank(OPS);
        IWaterfall(WATERFALL).fund(1, 100_000_000); // exactly 100e6 USDC

        uint256 backingAfter = IReserves(RESERVES).totalBackingValue();
        console2.log("backing before / after:", backingBefore, backingAfter);
        assertTrue(IController(CONTROLLER).backingInvariantHolds(), "backing invariant must hold");
        assertGe(backingAfter, backingBefore, "capitalised fee must not reduce backing");
    }
}
