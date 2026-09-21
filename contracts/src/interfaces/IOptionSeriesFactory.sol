// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What the vault and the guard need from the factory. Roles live on the factory only.
interface IOptionSeriesFactory {
    function hasRole(bytes32 role, address account) external view returns (bool);

    function feeRecipient() external view returns (address);

    function vaultOf(bytes32 seriesId) external view returns (address);

    function kuruMarketOf(bytes32 seriesId) external view returns (address);
}
