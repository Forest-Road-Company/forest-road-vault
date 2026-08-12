// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IReserveLossAbsorber — reserve-loss allocation shape and retained compatibility hook
/// @notice The bound implementation remains ReserveManager's canonical loss-book identity and this
///         interface defines the allocation record shared by its live custody cascade. In the
///         current tree ReserveManager performs that cascade internally; no production source calls
///         `absorbReserveLoss`.
interface IReserveLossAbsorber {
    /// @notice Exact allocation of one reserve-custody backing reduction.
    /// @dev `curatorAbsorbed + backstopCovered + seniorBurned` is the supply burned. Together
    ///      with `residualDeficit`, it must equal the portion not absorbed by existing surplus.
    struct ReserveLossAllocation {
        uint256 surplusAbsorbed;
        uint256 curatorAbsorbed;
        uint256 backstopCovered;
        uint256 seniorBurned;
        uint256 residualDeficit;
    }

    /// @notice The ReserveManager this absorber is bound to.
    /// @dev Used when wiring the hook so a loss absorber cannot be installed against the wrong
    ///      reserve accounting source.
    function reserveLossSource() external view returns (address);

    /// @notice Retained compatibility entry for allocating a pending reserve-backing loss.
    /// @dev The entry remains caller- and namespace-guarded, but the live production path is
    ///      `ReserveManager._absorbRecognizedReserveLoss -> _drawJuniorReserveLoss`. The retained
    ///      entry emits no transition event and must not be counted as coverage of that live path.
    /// @param incidentId Governance-opened upper-namespace event id reused by every partial
    ///        write-down belonging to the same custody incident.
    /// @param requiredSupplyReduction The supply that must be burned or latched as a residual
    ///        deficit, in 18-decimal USDfr units.
    function absorbReserveLoss(uint256 incidentId, uint256 requiredSupplyReduction)
        external
        returns (ReserveLossAllocation memory allocation);
}
