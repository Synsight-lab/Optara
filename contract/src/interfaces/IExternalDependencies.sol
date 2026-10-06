// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What OptionSeriesRegistry needs from SettlementOracle (implemented in BUILD_PLAN step 6).
interface ISettlementConfigs {
    /// @return True if the config exists, is approved and is for this underlying and settlement asset.
    function isConfigUsable(bytes32 configId, address underlying, address settlementAsset) external view returns (bool);
}

/// @notice What OptionSeriesRegistry needs from PortfolioRiskManager (implemented in BUILD_PLAN step 7).
interface IRiskSets {
    /// @return True if `riskParameterSetId` is the enabled risk set assigned to `productId` (every series of a
    ///         product uses its product's one set, so all legs of a risk bucket share one scenario set).
    function isRiskSetForProduct(bytes32 productId, bytes32 riskParameterSetId) external view returns (bool);
}

/// @notice What PortfolioRiskManager needs from SettlementWindow (implemented in BUILD_PLAN step 11).
interface ISettlementState {
    /// @return finalized True once the group's price is fixed. @return priceWad The settlement price used for payoffs
    ///         (already capped per group, MATH.md §14).
    function settlementPriceOf(bytes32 groupId) external view returns (bool finalized, uint256 priceWad);
}

/// @notice What PortfolioRiskManager needs from the insurance fund / fee controller (implemented in BUILD_PLAN step 8).
interface IReserveStatus {
    /// @return True if the insurance fund and keeper reserve for `asset` are at or above their minimums.
    function reservesHealthy(address asset) external view returns (bool);
}
