// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExternalOptionFactory
/// @notice Deploys one ExternalOptionWrapper clone per series, at an address derived from the series id.
interface IExternalOptionFactory {
    event WrapperDeployed(bytes32 indexed seriesId, address indexed wrapper, string name, string symbol);

    /// @dev OptionSeriesRegistry only.
    function deployWrapper(bytes32 seriesId, string calldata name, string calldata symbol)
        external
        returns (address wrapper);

    function predictWrapper(bytes32 seriesId) external view returns (address);
    function wrapperImplementation() external view returns (address);
    function registry() external view returns (address);
    function clearing() external view returns (address);
    function settlementWindow() external view returns (address);
    function liquidationModule() external view returns (address);
}
