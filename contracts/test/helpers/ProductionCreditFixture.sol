// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {SGrove} from "../../src/SGrove.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "./RealOracleFixture.sol";

/// @dev Full credit fixture with both production synchronization dependencies: genuine EIP-712
///      attestations and the real capped sGROVE cascade layer.
abstract contract ProductionCreditFixture is RealOracleFixture {
    address internal productionTreasury = makeAddr("production-credit-treasury");
    GroveToken internal grove;
    SGrove internal sGrove;

    function setUp() public virtual override {
        super.setUp();
        grove = GroveToken(
            address(
                new ERC1967Proxy(
                    address(new GroveToken()), abi.encodeCall(GroveToken.initialize, (admin, admin, productionTreasury))
                )
            )
        );
        sGrove = SGrove(
            address(
                new ERC1967Proxy(
                    address(new SGrove()),
                    abi.encodeCall(
                        SGrove.initialize, (admin, guardian, admin, address(grove), address(usdfr), address(vault))
                    )
                )
            )
        );
        vm.startPrank(admin);
        sGrove.grantRole(Roles.CREDIT_ROLE, address(defaultManager));
        sGrove.grantRole(Roles.CREDIT_ROLE, address(reserves));
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(sGrove));
        defaultManager.setBackstop(address(sGrove));
        reserves.setReserveLossModules(
            address(curator),
            address(sGrove),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
        vm.stopPrank();
    }
}

/// @dev Test-only signer driver. Production consumers remain wired to AttestationOracle; this
///      contract merely produces and submits genuine sorted m-of-n EIP-712 bundles for handlers.
contract SignedOracleDriver is Test {
    AttestationOracle internal oracle;
    address internal admin;
    uint256 internal pk1;
    uint256 internal pk2;
    uint256 internal nonce;

    constructor(AttestationOracle oracle_, address admin_, uint256 pk1_, uint256 pk2_) {
        oracle = oracle_;
        admin = admin_;
        pk1 = pk1_;
        pk2 = pk2_;
    }

    function setSatisfied(uint256 facilityId, IAttestationOracle.AttestationKind kind, bool ok) external {
        if (!ok) {
            vm.prank(admin);
            oracle.revoke(facilityId, kind);
            return;
        }
        _attest(
            facilityId,
            kind,
            keccak256(abi.encode("production-invariant-fact", facilityId, kind, ++nonce)),
            uint64(block.timestamp)
        );
    }

    function setPayload(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        uint64 asOf,
        bool ok
    ) external {
        if (!ok) {
            vm.prank(admin);
            oracle.revoke(facilityId, kind);
            return;
        }
        ++nonce;
        _attest(facilityId, kind, payload, asOf);
    }

    function _attest(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        private
    {
        IAttestationOracle.AttestationInput memory input = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: nonce
        });
        bytes32 digest = oracle.attestationDigest(input);
        uint8 threshold = oracle.threshold(kind);
        bytes[] memory signatures = new bytes[](threshold);
        (uint256 first, uint256 second) = vm.addr(pk1) < vm.addr(pk2) ? (pk1, pk2) : (pk2, pk1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(first, digest);
        signatures[0] = abi.encodePacked(r, s, v);
        if (threshold > 1) {
            (v, r, s) = vm.sign(second, digest);
            signatures[1] = abi.encodePacked(r, s, v);
        }
        oracle.attest(input, signatures);
    }
}
