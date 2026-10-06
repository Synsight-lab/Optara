// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IProtocolControl
/// @notice Central roles, scoped pause bits and manual product close-only flags (docs/PROTOCOL_SPEC.md §11).
interface IProtocolControl is IAccessControl {
    /// @notice Pause scope. GLOBAL uses id 0; ASSET uses the settlement asset address as id; PRODUCT the productId.
    enum Scope {
        GLOBAL,
        ASSET,
        PRODUCT
    }

    event Paused(Scope indexed scope, bytes32 indexed id, uint256 bits, address indexed by);
    event Unpaused(Scope indexed scope, bytes32 indexed id, uint256 bits, address indexed by);
    event ProductCloseOnlySet(bytes32 indexed productId, bool closeOnly, address indexed by);

    function pause(Scope scope, bytes32 id, uint256 bits) external;
    function unpause(Scope scope, bytes32 id, uint256 bits) external;
    function setProductCloseOnly(bytes32 productId, bool closeOnly) external;

    function pausedBits(Scope scope, bytes32 id) external view returns (uint256);
    /// @notice True if `bit` is paused globally, for `asset` (if non-zero) or for `productId` (if non-zero).
    function isPaused(uint8 bit, address asset, bytes32 productId) external view returns (bool);
    /// @notice Reverts `ActionPaused(bit)` if `isPaused(bit, asset, productId)`.
    function requireNotPaused(uint8 bit, address asset, bytes32 productId) external view;
    /// @notice The manual close-only flag (guardian, governance or emergency upgrade). Automatic causes such as a
    ///         stale surface are evaluated by PortfolioRiskManager on top of this flag.
    function isProductCloseOnly(bytes32 productId) external view returns (bool);
    function upgradeAdmin() external view returns (address);
}
