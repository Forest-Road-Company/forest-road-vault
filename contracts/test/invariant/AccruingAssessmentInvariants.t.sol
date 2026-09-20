// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {MutableImpairmentSource} from "../unit/AssessedImpairmentSource.t.sol";

/// @notice Event-owned reference ledger; expected values never read assessment storage or hashes.
contract AccruingAssessmentHandler is Test {
    MutableImpairmentSource public base;
    AssessedImpairmentSource public source;
    uint256 private gross = 1_500e18;
    uint256 private overdue = 100e18;
    uint256 private capital = 100e18;
    uint256 private riskEpisode;
    uint256 private assessed;
    uint256 private feeMark;
    uint256 private assessedOverdue;
    uint256 private assessedCapital;
    uint256 private assessedEpisode;
    uint256 private expires;
    bool private present;
    uint256 public grewWhileActive;
    uint256 public published;
    uint256 public capacityChanges;
    uint256 public riskChanges;
    uint256 public clears;
    uint256 public expiries;

    constructor() {
        base = new MutableImpairmentSource();
        base.set(gross);
        base.setCohortExposure(overdue);
        base.setBackstop(capital, gross - capital);
        source = AssessedImpairmentSource(
            address(
                new ERC1967Proxy(
                    address(new AssessedImpairmentSource()),
                    abi.encodeCall(AssessedImpairmentSource.initialize, (address(this), address(this), address(base)))
                )
            )
        );
    }

    function grow(uint256 seed) public {
        uint256 amount = 1 + seed % 10e18;
        if (_active()) ++grewWhileActive;
        gross += amount;
        overdue += amount;
        // Under full junior coverage, gross growth may still leave the net mark at zero.
        base.growPastDue(amount);
        base.setBackstop(capital, _net());
        check();
    }

    function changeCapacity(uint256 seed) public {
        capital = seed % 3_000e18;
        base.setBackstop(capital, _net());
        ++capacityChanges;
        check();
    }

    function changeRisk() public {
        ++riskEpisode;
        base.touch();
        ++riskChanges;
        check();
    }

    function publish(uint256 seed) public {
        assessed = seed % (_net() + 1);
        assessedOverdue = overdue;
        assessedCapital = capital;
        assessedEpisode = riskEpisode;
        feeMark = assessed + gross - _net();
        expires = block.timestamp + 7 days;
        present = true;
        source.setAssessment(assessed, uint64(expires), keccak256(abi.encode("stateful-recovery", ++published)));
        check();
    }

    function clear() public {
        present = false;
        source.clearAssessment();
        ++clears;
        check();
    }

    function advance(uint256 seed) public {
        bool before_ = _active();
        vm.warp(block.timestamp + seed % (8 days + 1));
        if (before_ && !_active()) ++expiries;
        check();
    }

    function _net() private view returns (uint256) {
        return gross > capital ? gross - capital : 0;
    }

    function _active() private view returns (bool) {
        return present && block.timestamp <= expires && riskEpisode == assessedEpisode && capital >= assessedCapital;
    }

    function check() public view {
        bool active = _active();
        uint256 expectedNet = _net();
        uint256 expectedFee = gross;
        if (active) {
            uint256 additionalIncome = overdue - assessedOverdue;
            uint256 reserved = assessed + additionalIncome;
            if (reserved < expectedNet) expectedNet = reserved;
            expectedFee = feeMark + additionalIncome;
        }
        assertEq(source.pendingSeniorImpairment(), expectedNet, "event model: redemption reserve drift");
        assertEq(source.performanceFeeImpairment(), expectedFee, "event model: performance reserve drift");
        (,,, bool actualActive,) = source.currentAssessment();
        assertEq(actualActive, active, "event model: validity drift");
        assertGe(expectedFee, expectedNet, "gross fee impairment fell below redemption impairment");
    }
}

contract AccruingAssessmentInvariants is Test {
    AccruingAssessmentHandler private handler;

    function setUp() public {
        handler = new AccruingAssessmentHandler();
        handler.publish(500e18);
        handler.grow(1e18);
        handler.changeCapacity(200e18);
        handler.changeRisk();
        handler.publish(400e18);
        handler.advance(8 days);
        handler.clear();
        handler.publish(500e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.grow.selector;
        selectors[1] = handler.changeCapacity.selector;
        selectors[2] = handler.changeRisk.selector;
        selectors[3] = handler.publish.selector;
        selectors[4] = handler.clear.selector;
        selectors[5] = handler.advance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_growingBookMatchesTheIndependentEventLedger() public view {
        handler.check();
    }

    function afterInvariant() public view {
        assertGt(handler.grewWhileActive(), 0, "no active assessment accrued");
        assertGt(handler.published(), 0);
        assertGt(handler.capacityChanges(), 0);
        assertGt(handler.riskChanges(), 0);
        assertGt(handler.clears(), 0);
        assertGt(handler.expiries(), 0);
    }
}
