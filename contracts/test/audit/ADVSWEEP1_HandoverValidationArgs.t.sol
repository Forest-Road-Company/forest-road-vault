// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Handover, HandoverOps} from "../../script/Handover.s.sol";
import {Validate} from "../../script/Validate.s.sol";
import {GroveToken} from "../../src/GroveToken.sol";

/// @dev Test-only wrapper: `_validationArgs` is `internal view`, and the whole point of this
///      finding is that it must be driven as the REAL code path rather than re-implemented.
contract HandoverArgsHarness is Handover {
    function validationArgs(string memory manifest, Targets memory t, address deployer, address opsAdmin)
        external
        view
        returns (Validate.M memory)
    {
        return _validationArgs(manifest, t, deployer, opsAdmin);
    }
}

/// @title ADVSWEEP1 — `Handover._validationArgs` dropped `attester1` from the argument set
/// @notice ADVERSARIAL SWEEP ROUND 1 FINDING (deployment-ceremony group).
///
///         `Validate.M` is populated twice by hand: once by `Validate._load()` from the manifest,
///         and once by `Handover._validationArgs()`. The two lists must mirror; they did not.
///         `_load` reads `.attester1`; `_validationArgs` never assigned it. An unset field is
///         `address(0)`, and `Validate._attester1()` reads `address(0)` as "attester1 IS the
///         deployer":
///
///             function _attester1(M memory a) ... { return a.attester1 == address(0) ? a.deployer : a.attester1; }
///
///         `Validate._validateWiring` — which `validateHandover` runs — then asserts
///         `oracle.hasRole(ATTESTER_ROLE, _attester1(a))`, i.e. it asserted that the DEPLOYER
///         holds `ATTESTER_ROLE`. On the production shape that is false by construction:
///         `DeployMainnet` REQUIRES `c.attester1 != c.deployer` and never grants the bootstrap
///         deployer the role. So `Handover.run()` reverted with `"attester1"` on exactly the
///         topology the one-command exit exists to serve — and because `forge script` simulates
///         the whole of `run()` before broadcasting a single transaction, the handover would
///         never execute at all.
///
///         THIS IS THE SECOND INSTANCE OF THE SAME OMISSION IN THE SAME FUNCTION. The
///         `a.queueKeeper` assignment carries the note: "Omitting this field left the default
///         zero address in `Validate.M`, so every standalone handover failed after the role
///         transition even when the deployed queue topology was correct." `attester1` was the
///         next one along and nothing pinned the pair of lists against each other.
///
///         FAIL DIRECTION: closed. The handover reverts rather than granting anything, so no
///         privilege is lost or leaked — this is an availability defect in the governance-exit
///         tooling, not a value path.
contract Advsweep1HandoverValidationArgsTest is Test, Deploy {
    address internal ops = makeAddr("sweep1Ops");
    address internal treasury = makeAddr("sweep1Treasury");
    address internal fees = makeAddr("sweep1Fees");
    address internal attester1Addr = makeAddr("sweep1IndependentAttester1");
    address internal attester2Addr = makeAddr("sweep1IndependentAttester2");

    address internal currentTreasury;

    function treasuryOf(D memory) internal view returns (address) {
        return currentTreasury;
    }

    /// @dev The PRODUCTION shape: separate ops key, handed over, and — the point of this test —
    ///      an attester #1 that is NOT the deployer, exactly as `DeployMainnet` hard-requires.
    function _prodCtx() internal view returns (Ctx memory c) {
        c.deployer = address(this);
        c.opsAdmin = ops;
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = ops;
        c.frTreasury = treasury;
        c.feeRecipient = fees;
        c.attester1 = attester1Addr;
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = false;
    }

    function _handedOverStack() internal returns (D memory d, Ctx memory c) {
        c = _prodCtx();
        currentTreasury = c.frTreasury;
        d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
        vm.prank(treasury);
        GroveToken(d.grove).delegate(treasury);
    }

    /// @dev A manifest carrying every key `_validationArgs` reads — including `.attester1`,
    ///      which `Deploy._writeManifest` has always written. The key being PRESENT and the
    ///      argument set still not carrying it is what makes this an omission rather than a
    ///      missing input.
    function _manifest(D memory d, Ctx memory c) internal returns (string memory) {
        string memory j = "sweep1Manifest";
        vm.serializeAddress(j, "mtmExecutor", d.mtmExecutor);
        vm.serializeAddress(j, "proposalGuardian", c.proposalGuardian);
        vm.serializeAddress(j, "queueKeeper", c.queueKeeper);
        vm.serializeAddress(j, "attester1", _attester1(c));
        vm.serializeAddress(j, "attester2", c.attester2);
        vm.serializeAddress(j, "feeRecipient", c.feeRecipient);
        vm.serializeBool(j, "attester2_DERIVED_FROM_DEPLOYER_KEY", false);
        return vm.serializeAddress(j, "stable", d.stable);
    }

    function _targets(D memory d, Ctx memory c) internal pure returns (HandoverOps.Targets memory t) {
        t.compliance = d.compliance;
        t.usdfr = d.usdfr;
        t.reserves = d.reserves;
        t.controller = d.controller;
        t.vault = d.vault;
        t.points = d.points;
        t.registry = d.registry;
        t.oracle = d.oracle;
        t.bridge = d.bridge;
        t.curator = d.curator;
        t.waterfall = d.waterfall;
        t.defaultManager = d.defaultManager;
        t.assessedImpairmentSource = d.assessedImpairmentSource;
        t.queue = d.queue;
        t.sGrove = d.sGrove;
        t.grove = d.grove;
        t.timelock = d.timelock;
        t.governor = d.governor;
        t.votesAggregator = d.votesAggregator;
        t.frTreasury = c.frTreasury;
    }

    // ── the assertion ────────────────────────────────────────────────────

    /// @notice `Handover.run()` must be able to validate a PRODUCTION-shaped, handed-over stack
    ///         whose attester #1 is an independent key.
    /// @dev THE FIX THIS PINS is a single assignment in `Handover._validationArgs`:
    ///          a.attester1 = vm.keyExistsJson(manifest, ".attester1")
    ///              ? vm.parseJsonAddress(manifest, ".attester1") : address(0);
    ///      DELETE IT AND THIS TEST REDS with `"attester1"` — the bare revert string an operator
    ///      would have seen from a one-command exit that simply refused to run.
    function test_SWEEP1_handoverValidationRunsOnAProductionShapedIndependentAttesterSet() public {
        (D memory d, Ctx memory c) = _handedOverStack();

        HandoverArgsHarness h = new HandoverArgsHarness();
        Validate.M memory a = h.validationArgs(_manifest(d, c), _targets(d, c), c.deployer, c.opsAdmin);

        // The omitted field, named directly. `Validate._attester1` reads address(0) as "the
        // deployer is attester #1", which on this stack is false.
        assertEq(a.attester1, attester1Addr, "SWEEP1: _validationArgs dropped .attester1 from the argument set");
        assertTrue(attester1Addr != c.deployer, "PRECONDITION: attester #1 must not be the deployer");

        Validate v = new Validate();
        v.validateHandover(a);
    }

    /// @notice DISCRIMINATING CONTROL — and, unlike a control that never grants the thing it
    ///         claims to test, this one is executed and non-vacuous.
    /// @dev Proves the assertion above fails FOR THE STATED REASON and nothing else: the same
    ///      handed-over stack, the same argument set, with ONLY `attester1` zeroed, reverts with
    ///      `"attester1"`. If some other part of `validateHandover` were the real blocker, this
    ///      control would revert with a different string and the test above would not be
    ///      evidence for the finding.
    function test_SWEEP1_control_zeroingOnlyAttester1IsWhatBreaksHandoverValidation() public {
        (D memory d, Ctx memory c) = _handedOverStack();

        HandoverArgsHarness h = new HandoverArgsHarness();
        Validate.M memory a = h.validationArgs(_manifest(d, c), _targets(d, c), c.deployer, c.opsAdmin);

        a.attester1 = address(0); // the ONLY difference from the passing case above
        Validate v = new Validate();
        vm.expectRevert(bytes("attester1"));
        v.validateHandover(a);
    }

    /// @notice AUDIT FIX (SWEEP-1 VAC-F10) — THE NAMED CATCHING TEST FOR THE NEW
    ///         `impairmentMath` VALIDATION. `ConservativeImpairmentMath` is an EIP-170 extraction
    ///         deployed by `DefaultManager`'s CONSTRUCTOR and held as an immutable, so it lives in
    ///         the IMPLEMENTATION's runtime code and no proxy/wiring check reaches it. The whole
    ///         redemption-pricing path hard-depends on it — `pendingSeniorImpairment()` forwards to
    ///         it, and that feeds `redemptionTotalAssets`, `previewRedeem`, the ADR-0022 queue fill
    ///         and the ADR-0034 Y-bis exit draw — and NEITHER `Validate` NOR `ValidateMainnet`
    ///         looked at it (verified by grep: zero hits before this change).
    /// @dev DELETION MUTATION: remove
    ///      `require(impairmentMath != address(0), "defaultManager impairment math unset");`
    ///      from `Validate._validateWiring`. This test goes RED with
    ///      "next call did not revert as expected". The state is reached with `vm.mockCall` rather
    ///      than by constructing a broken proxy, because the immutable cannot be zeroed on a
    ///      correctly constructed implementation — which is exactly why nothing in the suite could
    ///      falsify the guard without this.
    function test_SWEEP1_validationRefusesADefaultManagerWhoseImpairmentMathIsUnset() public {
        (D memory d, Ctx memory c) = _handedOverStack();

        HandoverArgsHarness h = new HandoverArgsHarness();
        Validate.M memory a = h.validationArgs(_manifest(d, c), _targets(d, c), c.deployer, c.opsAdmin);

        Validate ok = new Validate();
        ok.validateHandover(a); // PRECONDITION: the stack validates before the mock

        vm.mockCall(d.defaultManager, abi.encodeWithSignature("impairmentMath()"), abi.encode(address(0)));
        Validate v = new Validate();
        vm.expectRevert(bytes("defaultManager impairment math unset"));
        v.validateHandover(a);
        vm.clearMockedCalls();
    }

    /// @notice The second limb: a populated but CODELESS pointer. A stale implementation whose
    ///         immutable survives as an address that no longer holds code is the realistic shape,
    ///         and "an address is set" is not the property that matters.
    /// @dev DELETION MUTATION: remove
    ///      `require(impairmentMath.code.length != 0, "defaultManager impairment math has no code");`
    ///      -> RED here with "next call did not revert as expected".
    function test_SWEEP1_validationRefusesACodelessImpairmentMathPointer() public {
        (D memory d, Ctx memory c) = _handedOverStack();

        HandoverArgsHarness h = new HandoverArgsHarness();
        Validate.M memory a = h.validationArgs(_manifest(d, c), _targets(d, c), c.deployer, c.opsAdmin);

        address codeless = makeAddr("sweep1-codeless-impairment-math");
        assertEq(codeless.code.length, 0, "PRECONDITION: the stand-in must genuinely have no code");
        vm.mockCall(d.defaultManager, abi.encodeWithSignature("impairmentMath()"), abi.encode(codeless));
        Validate v = new Validate();
        vm.expectRevert(bytes("defaultManager impairment math has no code"));
        v.validateHandover(a);
        vm.clearMockedCalls();
    }
}
