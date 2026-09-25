// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PairStatus, ExposureScope, SeriesBounds} from "../libraries/OptaraTypes.sol";

/// @notice Prospective configuration, roles and scoped pauses (ACCESS_CONTROL.md, PROTOCOL_SPEC.md sections 29-31, 37, 42).
/// Nothing here can change an existing series' economics, a finalized price, or a group's snapshotted buffer.
interface IOptaraConfig {
    event AssetApproved(address indexed asset, uint8 decimals, string symbol);
    event AssetDisabled(address indexed asset, address caller);
    event AssetReenabled(address indexed asset, address caller);
    event UnderlyingApproved(address indexed underlying, string symbol);
    event UnderlyingStatusChanged(address indexed underlying, bool approved, address caller);
    event PairApproved(bytes32 indexed pairId, address indexed underlying, address indexed asset);
    event PairDisabled(bytes32 indexed pairId, PairStatus newStatus, address caller);
    event PairEnabled(bytes32 indexed pairId, address caller);
    event SeriesBoundsChanged(bytes32 indexed pairId, SeriesBounds bounds);
    event ExposureLimitChanged(ExposureScope indexed scope, bytes32 indexed key, uint256 oldLimitN, uint256 newLimitN);
    event PositionLimitsChanged(uint32 maxSeriesPerGroup, uint32 maxGroupsPerAccount, uint32 maxSeriesPerAccount);
    event BufferDefaultsChanged(address indexed asset, uint16 bufferBps, uint256 fixedBufferNative);
    event PauseStateChanged(bytes32 indexed scope, uint256 oldBits, uint256 newBits, address caller);

    function GOVERNANCE_ROLE() external view returns (bytes32);
    function CONFIG_ROLE() external view returns (bytes32);
    function SERIES_CREATOR_ROLE() external view returns (bytes32);
    function ORACLE_CONFIG_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function UNPAUSER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);

    function isPaused(uint256 action, address asset, bytes32 oracleConfigId) external view returns (bool);
    function assetInfo(address asset) external view returns (bool known, bool newRiskEnabled, uint8 decimals);
    function assetSymbol(address asset) external view returns (string memory);
    function bufferDefaults(address asset) external view returns (uint16 bufferBps, uint256 fixedBufferNative);
    function underlyingInfo(address underlying) external view returns (bool approved, string memory symbol);
    function pairInfo(bytes32 pairId) external view returns (PairStatus status, address underlying, address asset);
    function seriesBounds(bytes32 pairId) external view returns (SeriesBounds memory);
    function exposureLimits(bytes32 pairId, bytes32 oracleConfigId, address asset)
        external
        view
        returns (uint256 seriesLimitN, uint256 pairLimitN, uint256 oracleLimitN, uint256 assetLimitN);
    function positionLimits()
        external
        view
        returns (uint32 maxSeriesPerGroup, uint32 maxGroupsPerAccount, uint32 maxSeriesPerAccount);
    function pairIdOf(address underlying, address asset) external pure returns (bytes32);
}
