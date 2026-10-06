// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What OptionSeriesRegistry needs from SettlementOracle (implemented in BUILD_PLAN step 6).
interface ISettlementConfigs {
    /// @return True if the config exists, is approved and is for this underlying and settlement asset.
    function isConfigUsable(bytes32 configId, address underlying, address settlementAsset) external view returns (bool);
}

/// @notice What OptionSeriesRegistry needs from PortfolioRiskManager (implemented in BUILD_PLAN step 7).
interface IRiskSets {
    /// @return True if the risk parameter set exists and is enabled.
    function isRiskSetEnabled(bytes32 riskParameterSetId) external view returns (bool);
}
