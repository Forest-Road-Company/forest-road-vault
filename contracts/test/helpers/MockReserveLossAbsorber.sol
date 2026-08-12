// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveLossAbsorber} from "../../src/interfaces/IReserveLossAbsorber.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";

/// @dev Token-layer test double for the production DefaultManager reserve-loss hook.
///      It models only senior absorption; ReserveManager owns surplus and deficit accounting.
contract MockReserveLossAbsorber is IReserveLossAbsorber {
    IMintRedeemController internal immutable controller;
    address internal immutable vault;
    address internal immutable reserves;

    constructor(IMintRedeemController controller_, address vault_, address reserves_) {
        controller = controller_;
        vault = vault_;
        reserves = reserves_;
    }

    function reserveLossSource() external view returns (address) {
        return reserves;
    }

    /// @dev ADR-0034 Y-bis. This double models NO junior layers, so it correctly draws nothing —
    ///      which is exactly the state in which `_drawJuniorForExit` must degrade to today's gross
    ///      price rather than revert. Present because the controller's draw is FAIL-CLOSED on a
    ///      source that cannot answer at all (see `_drawJuniorForExit`'s NatSpec).
    function drawForSeniorExit(uint256) external pure returns (uint256) {
        return 0;
    }

    function absorbReserveLoss(uint256 incidentId, uint256 requiredSupplyReduction)
        external
        returns (ReserveLossAllocation memory allocation)
    {
        require(msg.sender == reserves, "MockReserveLossAbsorber: reserve only");
        require(LossEventIds.isCustodyEvent(incidentId), "MockReserveLossAbsorber: incident namespace");
        uint256 vaultAssets = IsUSDfr(vault).totalAssets();
        allocation.seniorBurned = requiredSupplyReduction < vaultAssets ? requiredSupplyReduction : vaultAssets;
        if (allocation.seniorBurned != 0) controller.burnLoss(vault, allocation.seniorBurned);
        allocation.residualDeficit = requiredSupplyReduction - allocation.seniorBurned;
    }
}
