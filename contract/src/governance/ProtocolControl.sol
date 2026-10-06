// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {Roles} from "./Roles.sol";
import {PauseBits} from "./PauseBits.sol";
import {NotAuthorized, ZeroAddress, ActionPaused, InvalidScope, InvalidPauseBits} from "../libraries/Errors.sol";

/// @title ProtocolControl
/// @notice One place for every role, every pause bit (global, per settlement asset, per product) and the manual
///         product close-only flags (docs/ACCESS_CONTROL.md, docs/PROTOCOL_SPEC.md §11–§12).
/// @dev Guardian and governance may pause and set close-only (instant, risk-reducing). Only governance unpauses and
///      clears close-only. UpgradeAdmin may set close-only when an emergency upgrade is scheduled.
contract ProtocolControl is Initializable, AccessControlUpgradeable, IProtocolControl {
    /// @custom:storage-location erc7201:optara.storage.ProtocolControl
    struct ProtocolControlStorage {
        mapping(bytes32 scopeKey => uint256 bits) paused;
        mapping(bytes32 productId => bool) closeOnly;
        address upgradeAdmin;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.ProtocolControl")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x6c38be8bf973fb881542bc2e4a5457541646e342eb50eaf5aac96ae556b93f00;

    constructor() {
        _disableInitializers();
    }

    /// @param initialAdmin Receives GOVERNANCE (the default admin role). In deployment this is the deployer, which
    ///        grants GOVERNANCE to the governance timelock and the other roles, then renounces (DEPLOYMENT.md §2).
    /// @param upgradeAdmin_ UpgradeAdmin, allowed to set products close-only for emergency upgrades.
    function initialize(address initialAdmin, address upgradeAdmin_) external initializer {
        if (initialAdmin == address(0) || upgradeAdmin_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(Roles.GOVERNANCE, initialAdmin);
        _s().upgradeAdmin = upgradeAdmin_;
    }

    // ------------------------------------------------------------------------------------------------- pauses

    /// @inheritdoc IProtocolControl
    function pause(Scope scope, bytes32 id, uint256 bits) external {
        if (!hasRole(Roles.GUARDIAN, msg.sender) && !hasRole(Roles.GOVERNANCE, msg.sender)) {
            revert NotAuthorized(msg.sender);
        }
        _checkBits(bits);
        _s().paused[_scopeKey(scope, id)] |= bits;
        emit Paused(scope, id, bits, msg.sender);
    }

    /// @inheritdoc IProtocolControl
    function unpause(Scope scope, bytes32 id, uint256 bits) external {
        if (!hasRole(Roles.GOVERNANCE, msg.sender)) revert NotAuthorized(msg.sender);
        _checkBits(bits);
        _s().paused[_scopeKey(scope, id)] &= ~bits;
        emit Unpaused(scope, id, bits, msg.sender);
    }

    /// @inheritdoc IProtocolControl
    function pausedBits(Scope scope, bytes32 id) external view returns (uint256) {
        return _s().paused[_scopeKey(scope, id)];
    }

    /// @inheritdoc IProtocolControl
    function isPaused(uint8 bit, address asset, bytes32 productId) public view returns (bool) {
        ProtocolControlStorage storage $ = _s();
        uint256 mask = $.paused[_scopeKey(Scope.GLOBAL, 0)];
        if (asset != address(0)) mask |= $.paused[_scopeKey(Scope.ASSET, bytes32(uint256(uint160(asset))))];
        if (productId != 0) mask |= $.paused[_scopeKey(Scope.PRODUCT, productId)];
        return mask & (uint256(1) << bit) != 0;
    }

    /// @inheritdoc IProtocolControl
    function requireNotPaused(uint8 bit, address asset, bytes32 productId) external view {
        if (isPaused(bit, asset, productId)) revert ActionPaused(bit);
    }

    // ------------------------------------------------------------------------------------------------- close-only

    /// @inheritdoc IProtocolControl
    function setProductCloseOnly(bytes32 productId, bool closeOnly) external {
        bool isGovernance = hasRole(Roles.GOVERNANCE, msg.sender);
        if (closeOnly) {
            if (!isGovernance && !hasRole(Roles.GUARDIAN, msg.sender) && msg.sender != _s().upgradeAdmin) {
                revert NotAuthorized(msg.sender);
            }
        } else if (!isGovernance) {
            revert NotAuthorized(msg.sender);
        }
        _s().closeOnly[productId] = closeOnly;
        emit ProductCloseOnlySet(productId, closeOnly, msg.sender);
    }

    /// @inheritdoc IProtocolControl
    function isProductCloseOnly(bytes32 productId) external view returns (bool) {
        return _s().closeOnly[productId];
    }

    /// @inheritdoc IProtocolControl
    function upgradeAdmin() external view returns (address) {
        return _s().upgradeAdmin;
    }

    // ------------------------------------------------------------------------------------------------- internal

    /// @dev GLOBAL must use id 0. ASSET ids are addresses (upper 96 bits zero). Keys are domain-separated hashes.
    function _scopeKey(Scope scope, bytes32 id) private pure returns (bytes32) {
        if (scope == Scope.GLOBAL) {
            if (id != 0) revert InvalidScope();
        } else if (id == 0 || (scope == Scope.ASSET && uint256(id) >> 160 != 0)) {
            revert InvalidScope();
        }
        return keccak256(abi.encode(scope, id));
    }

    function _checkBits(uint256 bits) private pure {
        if (bits == 0 || bits & ~PauseBits.ALL != 0) revert InvalidPauseBits(bits);
    }

    function _s() private pure returns (ProtocolControlStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
