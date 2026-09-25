// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleConfig, OracleConfigStatus} from "../libraries/OptaraTypes.sol";

interface IOracleRegistry {
    event OracleConfigApproved(
        bytes32 indexed configId, address indexed underlying, address indexed settlementAsset, address adapter
    );
    /// @notice Emitted when a config stops accepting new series (suspended or retired). Existing groups are unaffected.
    event OracleConfigDisabled(bytes32 indexed configId, OracleConfigStatus newStatus, address caller);
    event OracleConfigStatusChanged(
        bytes32 indexed configId, OracleConfigStatus oldStatus, OracleConfigStatus newStatus, address caller
    );

    function getConfig(bytes32 configId) external view returns (OracleConfig memory);
    function statusOf(bytes32 configId) external view returns (OracleConfigStatus);
    function isApprovedForNewRisk(bytes32 configId) external view returns (bool);
    function adapterOf(bytes32 configId) external view returns (address);
    function finalizationDelays(bytes32 configId) external view returns (uint64 minDelay, uint64 maxDelay);
    function observationWindow(bytes32 configId, uint64 expiry) external view returns (uint64 start, uint64 end);
    function validateSeriesExpiry(bytes32 configId, uint64 expiry) external view;
}
