// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {QA} from "../../script/QA.s.sol";

contract QAManifestHarness is QA {
    function loadBoundManifest(string calldata path, uint256 forkSourceChainId) external view returns (string memory) {
        return _loadBoundManifestFor(path, forkSourceChainId);
    }

    function _canonicalManifestPath(uint256 manifestChainId) internal view override returns (string memory) {
        if (manifestChainId == 31337) return "deployments/fixtures/qa-31337.json";
        return super._canonicalManifestPath(manifestChainId);
    }
}

contract QAManifestBindingTest is Test {
    QAManifestHarness private qa;

    function setUp() public {
        qa = new QAManifestHarness();
    }

    function test_liveSepoliaAcceptsOnlyCanonicalManifest() public {
        vm.chainId(11155111);
        string memory manifest = qa.loadBoundManifest("", 0);
        assertEq(vm.parseJsonUint(manifest, ".chainId"), 11155111);

        vm.expectRevert(bytes("QA MANIFEST NOT CANONICAL"));
        qa.loadBoundManifest("deployments/archive/11155111-block-11340997.json", 0);
    }

    function test_manifestChainMustMatchConnectedChain() public {
        vm.chainId(11155111);
        vm.expectRevert(bytes("QA MANIFEST CHAIN MISMATCH"));
        qa.loadBoundManifest("deployments/fixtures/qa-31337.json", 0);
    }

    function test_localDeploymentUsesCanonicalLocalManifest() public {
        vm.chainId(31337);
        string memory manifest = qa.loadBoundManifest("", 0);
        assertEq(vm.parseJsonUint(manifest, ".chainId"), 31337);
    }

    function test_localSepoliaForkRequiresExplicitSourceAndCanonicalSepoliaManifest() public {
        vm.chainId(31337);
        string memory manifest = qa.loadBoundManifest("deployments/11155111.json", 11155111);
        assertEq(vm.parseJsonUint(manifest, ".chainId"), 11155111);

        vm.expectRevert(bytes("QA MANIFEST NOT CANONICAL"));
        qa.loadBoundManifest("deployments/archive/11155111-block-11340997.json", 11155111);
    }

    function test_forkSourceCannotOverrideLiveSepolia() public {
        vm.chainId(11155111);
        vm.expectRevert(bytes("QA FORK SOURCE ON LIVE CHAIN"));
        qa.loadBoundManifest("deployments/11155111.json", 11155111);
    }

    function test_mainnetAndUnknownChainsAreRejected() public {
        vm.chainId(1);
        vm.expectRevert(bytes("MAINNET FORBIDDEN"));
        qa.loadBoundManifest("", 0);

        vm.chainId(10);
        vm.expectRevert(bytes("QA UNSUPPORTED CHAIN"));
        qa.loadBoundManifest("", 0);
    }
}
