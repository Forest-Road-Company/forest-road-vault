// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal balance-backed stand-in for CuratorModule's classless loss surface.
contract MockReserveLossCurator {
    IERC20 public immutable usdfr;
    address public immutable vault;
    address public immutable reserves;
    uint8 public reportMode;

    constructor(IERC20 usdfr_, address vault_, address reserves_) {
        usdfr = usdfr_;
        vault = vault_;
        reserves = reserves_;
    }

    function setReportMode(uint8 mode) external {
        reportMode = mode;
    }

    function modules() external view returns (address, address, address) {
        return (address(usdfr), address(1), vault);
    }

    function reserveManager() external view returns (address) {
        return reserves;
    }

    function absorbGlobalLoss(uint256 loss) external returns (uint256 absorbed, uint256 residual) {
        if (reportMode == 1) return (0, 0);
        uint256 balance = usdfr.balanceOf(address(this));
        absorbed = loss < balance ? loss : balance;
        residual = loss - absorbed;
        if (reportMode == 2 && absorbed == 0) return (loss, 0);
        if (absorbed != 0) require(usdfr.transfer(msg.sender, absorbed));
    }
}

contract MockReserveLossTimelock {
    uint256 public minDelay = 2 days;

    function setMinDelay(uint256 delay_) external {
        minDelay = delay_;
    }

    function getMinDelay() external view returns (uint256) {
        return minDelay;
    }
}

contract MockReserveLossGovernor {
    uint256 public votingDelay = 1 days;
    uint256 public votingPeriod = 7 days;
    address public timelock;
    bool public invalidClockMode;
    bool public clockReverts;

    constructor(address timelock_) {
        timelock = timelock_;
    }

    function setVotingDelay(uint256 value) external {
        votingDelay = value;
    }

    function setVotingPeriod(uint256 value) external {
        votingPeriod = value;
    }

    function setTimelock(address value) external {
        timelock = value;
    }

    function setInvalidClockMode(bool value) external {
        invalidClockMode = value;
    }

    function setClockReverts(bool value) external {
        clockReverts = value;
    }

    function clock() external view returns (uint48) {
        if (clockReverts) revert("clock unavailable");
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() external view returns (string memory) {
        return invalidClockMode ? "mode=blocknumber&from=default" : "mode=timestamp";
    }
}
