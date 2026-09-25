// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleConfig} from "../libraries/OptaraTypes.sol";

/// @notice Settlement adapter interface (ARCHITECTURE.md section 13, ORACLE_AND_SETTLEMENT.md sections 24-25, 32).
/// Verifies caller-supplied, untrusted provider data against an immutable config's observation rule.
interface ISettlementOracle {
    /// @notice Verify `oracleData` for `oracleConfigId` at `expiry` and return the normalized pair price.
    /// @dev Reverts on invalid data. Payable for pull oracles that charge an update fee.
    function verifySettlementPrice(bytes32 oracleConfigId, uint64 expiry, bytes calldata oracleData)
        external
        payable
        returns (uint256 priceWad, uint64 observationTimestamp);

    /// @notice Non-mutating preview of the same verification, for clients. Advisory only.
    function quoteSettlementPrice(bytes32 oracleConfigId, uint64 expiry, bytes calldata oracleData)
        external
        view
        returns (uint256 priceWad, uint64 observationTimestamp);

    /// @notice Called by the registry at registration; reverts if the adapter-specific parameters are invalid.
    function validateConfig(OracleConfig calldata config) external view;
}
