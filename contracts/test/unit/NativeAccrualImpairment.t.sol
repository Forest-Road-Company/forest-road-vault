// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {ConservativeImpairmentMath} from "../../src/ConservativeImpairmentMath.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {ICommitmentLedger} from "../../src/interfaces/ICommitmentLedger.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {LedgerCuratorPools, LedgerBackstopReserve} from "./CommitmentLedger.t.sol";

/// @dev Encodes BOTH inputs to the existing registry clamp; agreement cannot hide a wrong
///      past-due priority behind a zero or fully clipped final senior mark.
contract NativeAccrualMarkProbe {
    function conservativeSeniorMark(uint256 pastDueSenior, uint256 residual, address, uint256)
        external
        pure
        returns (uint256)
    {
        return (residual << 128) | pastDueSenior;
    }
}

/// @dev Test-only seeded native state plus the real native event ledger. No production getter,
///      storage declaration, booking authority or pointer is replaced by this harness.
contract NativeAccrualRiskHarness {
    DefaultManager.DefaultStorage private native;
    mapping(uint256 => uint256) private extra;
    CommitmentLedger public immutable ledger;

    constructor(address curator, address backstop_, address registry) {
        ledger = new CommitmentLedger(address(this));
        native.commitmentLedger = ICommitmentLedger(address(ledger));
        native.curator = ICuratorModule(curator);
        native.backstop = ICascadeBackstop(backstop_);
        native.registry = ICollateralRegistry(registry);
        native.accrualReserve = IContinuousAccrual(address(this));
    }

    function cohort(uint256 classId, uint256 recorded, uint256 unposted) external {
        native.pastDuePrincipal[classId] = recorded;
        extra[classId] = unposted;
    }

    function add(uint256 id, uint256 classId, uint256 principal, uint256 history) external {
        native.declaredDefaultedPrincipal[classId] += principal;
        ledger.register(id, classId, principal);
        if (history != 0) ledger.sync(id, principal, principal, history);
    }

    function reduce(uint256 id, uint256 amount, bool retire) external {
        (uint256 classId,,, uint256 principal) = ledger.eventInfo(id);
        if (amount > principal) amount = principal;
        native.declaredDefaultedPrincipal[classId] -= retire ? principal : amount;
        if (retire) ledger.release(id);
        else ledger.updatePrincipal(id, principal - amount);
    }

    function fast() external view returns (uint256) {
        return DefaultAccrualLib.nativeSeniorImpairment(native);
    }

    function accruedPastDue(uint256 classId) external view returns (uint256) {
        return extra[classId];
    }

    function pastDuePrincipal(uint256 classId) external view returns (uint256) {
        return native.pastDuePrincipal[classId] + extra[classId];
    }

    function backstop() external view returns (address) {
        return address(native.backstop);
    }

    function pastDueReliefAnchor() external pure returns (uint256) {
        return 0;
    }

    function modules() external view returns (address, address, address, address, address, address, address, address) {
        return (
            address(0),
            address(native.registry),
            address(0),
            address(0),
            address(native.curator),
            address(0),
            address(0),
            address(ledger)
        );
    }
}

contract NativeAccrualImpairmentTest is Test {
    LedgerCuratorPools private curator;
    LedgerBackstopReserve private backstop;
    NativeAccrualRiskHarness private source;
    ConservativeImpairmentMath private referenceMath;

    function setUp() public {
        curator = new LedgerCuratorPools();
        backstop = new LedgerBackstopReserve();
        source =
            new NativeAccrualRiskHarness(address(curator), address(backstop), address(new NativeAccrualMarkProbe()));
        referenceMath = new ConservativeImpairmentMath();
    }

    /// @dev Independently executed native ledger walks both event orders. Random per-class demand,
    ///      streamed risk, curator capital, prior draw history, recovery and release must all agree.
    function testFuzz_fiveClassAccrualMatchesNativeEventLadders(bytes32 seed, uint8 size, uint64 coverage) public {
        uint256 count = bound(size, 1, 100);
        uint256 reserve = bound(coverage, 0, 100_000_000);
        backstop.setCoverageReserve(reserve);
        for (uint256 classId = 1; classId <= 5; ++classId) {
            uint256 r = uint256(keccak256(abi.encode(seed, classId)));
            curator.setPoolBalance(classId, r % 10_000_000);
            source.cohort(classId, (r >> 64) % 1_000_000, (r >> 128) % 1_000_000);
        }
        for (uint256 id = 1; id <= count; ++id) {
            uint256 r = uint256(keccak256(abi.encode(seed, id, "declared")));
            source.add(id, 1 + r % 5, (r >> 32) % 1_000_000, (r >> 96) % 1000);
        }
        assertEq(source.fast(), referenceMath.pendingSeniorImpairment(address(source)), "before recovery");
        source.reduce(1 + uint256(seed) % count, uint256(seed) % 1_000_000, uint256(seed) & 1 != 0);
        // Replenishment and withdrawal affect only the actual live shared reserve; historical
        // draw counters cannot become a second deduction or survive as per-event limits.
        backstop.setCoverageReserve(reserve / 2);
        assertEq(source.fast(), referenceMath.pendingSeniorImpairment(address(source)), "after recovery and draw");
        backstop.setCoverageReserve(reserve + 100_000_000);
        assertEq(source.fast(), referenceMath.pendingSeniorImpairment(address(source)), "after replenishment");
    }
}
