// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Roles
/// @notice Role identifiers held in ProtocolControl (docs/ACCESS_CONTROL.md §1).
/// @dev GOVERNANCE is the AccessControl default admin role, so governance alone grants and revokes every role.
///      Governance is a timelock (parameterTimelock), so everything it does is delayed; the instant roles
///      (GUARDIAN, RISK_ADMIN for conservative changes) can only reduce risk.
library Roles {
    bytes32 internal constant GOVERNANCE = 0x00; // == AccessControl.DEFAULT_ADMIN_ROLE
    bytes32 internal constant GUARDIAN = keccak256("optara.role.GUARDIAN");
    bytes32 internal constant RISK_ADMIN = keccak256("optara.role.RISK_ADMIN");
    bytes32 internal constant SERIES_CREATOR = keccak256("optara.role.SERIES_CREATOR");
    bytes32 internal constant ORACLE_ADMIN = keccak256("optara.role.ORACLE_ADMIN");
    bytes32 internal constant VENUE_ADMIN = keccak256("optara.role.VENUE_ADMIN");
}
