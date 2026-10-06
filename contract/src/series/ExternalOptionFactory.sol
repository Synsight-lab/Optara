// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IExternalOptionFactory} from "../interfaces/IExternalOptionFactory.sol";
import {ExternalOptionWrapper} from "./ExternalOptionWrapper.sol";
import {NotAuthorized, ZeroAddress, NotAContract} from "../libraries/Errors.sol";

/// @title ExternalOptionFactory
/// @notice Deploys one immutable ExternalOptionWrapper clone per series at a deterministic address (salt = seriesId)
///         and initializes it in the same call. Every clone gets the same fixed minter and burners.
/// @dev Module addresses are fixed at initialization (DEPLOYMENT.md §2: proxy addresses are known in advance);
///      changing them needs an upgrade. Clones already deployed keep the addresses they were given.
contract ExternalOptionFactory is OptaraModule, IExternalOptionFactory {
    /// @custom:storage-location erc7201:optara.storage.ExternalOptionFactory
    struct FactoryStorage {
        address wrapperImplementation;
        address registry;
        address clearing;
        address settlementWindow;
        address liquidationModule;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.ExternalOptionFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x410f7efa686c2d3e8125c9a3ab9d84d0b687fa072b1df568264ad30c3edfef00;

    function initialize(
        IProtocolControl control_,
        address wrapperImplementation_,
        address registry_,
        address clearing_,
        address settlementWindow_,
        address liquidationModule_
    ) external initializer {
        __OptaraModule_init(control_);
        if (wrapperImplementation_.code.length == 0) revert NotAContract(wrapperImplementation_);
        if (
            registry_ == address(0) || clearing_ == address(0) || settlementWindow_ == address(0)
                || liquidationModule_ == address(0)
        ) revert ZeroAddress();
        FactoryStorage storage $ = _s();
        $.wrapperImplementation = wrapperImplementation_;
        $.registry = registry_;
        $.clearing = clearing_;
        $.settlementWindow = settlementWindow_;
        $.liquidationModule = liquidationModule_;
    }

    /// @inheritdoc IExternalOptionFactory
    function deployWrapper(bytes32 seriesId, string calldata name, string calldata symbol)
        external
        nonReentrant
        returns (address wrapper)
    {
        FactoryStorage storage $ = _s();
        if (msg.sender != $.registry) revert NotAuthorized(msg.sender);
        wrapper = Clones.cloneDeterministic($.wrapperImplementation, seriesId);
        ExternalOptionWrapper(wrapper)
            .initialize(seriesId, name, symbol, $.clearing, $.settlementWindow, $.liquidationModule);
        emit WrapperDeployed(seriesId, wrapper, name, symbol);
    }

    /// @inheritdoc IExternalOptionFactory
    function predictWrapper(bytes32 seriesId) external view returns (address) {
        return Clones.predictDeterministicAddress(_s().wrapperImplementation, seriesId);
    }

    function wrapperImplementation() external view returns (address) {
        return _s().wrapperImplementation;
    }

    function registry() external view returns (address) {
        return _s().registry;
    }

    function clearing() external view returns (address) {
        return _s().clearing;
    }

    function settlementWindow() external view returns (address) {
        return _s().settlementWindow;
    }

    function liquidationModule() external view returns (address) {
        return _s().liquidationModule;
    }

    function _s() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
