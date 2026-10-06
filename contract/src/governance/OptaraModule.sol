// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {NotAuthorized, ZeroAddress} from "../libraries/Errors.sol";

/// @title OptaraModule
/// @notice Base for every upgradeable Optara PM module (docs/ARCHITECTURE.md §7, docs/SECURITY.md §4).
///         - Implementations can never be initialized directly (constructor disables initializers).
///         - Storage is ERC-7201 namespaced; this base owns only the ProtocolControl reference.
///         - Roles and pause bits are read from the single ProtocolControl.
///         - Reentrancy guard uses transient storage (EIP-1153; supported by Monad), so it adds no storage slot.
abstract contract OptaraModule is Initializable, ReentrancyGuardTransient {
    /// @custom:storage-location erc7201:optara.storage.OptaraModule
    struct OptaraModuleStorage {
        IProtocolControl control;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.OptaraModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MODULE_STORAGE_SLOT = 0xde0b22c4fea5bfbfa5981692ca05b7ede90474910f477f8232f271db7a585b00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __OptaraModule_init(IProtocolControl control_) internal onlyInitializing {
        if (address(control_) == address(0)) revert ZeroAddress();
        _moduleStorage().control = control_;
    }

    /// @notice The ProtocolControl this module reads roles and pause bits from.
    function control() public view returns (IProtocolControl) {
        return _moduleStorage().control;
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    function _checkRole(bytes32 role) internal view {
        if (!_moduleStorage().control.hasRole(role, msg.sender)) revert NotAuthorized(msg.sender);
    }

    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        return _moduleStorage().control.hasRole(role, account);
    }

    /// @dev Reverts `ActionPaused(bit)` if the bit is paused globally, for `asset` or for `productId` (0 = skip).
    function _requireNotPaused(uint8 bit, address asset, bytes32 productId) internal view {
        _moduleStorage().control.requireNotPaused(bit, asset, productId);
    }

    function _moduleStorage() private pure returns (OptaraModuleStorage storage $) {
        assembly {
            $.slot := MODULE_STORAGE_SLOT
        }
    }
}
