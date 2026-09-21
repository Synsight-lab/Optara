// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOptionSeriesFactory} from "../../src/interfaces/IOptionSeriesFactory.sol";

/// @notice The minimum a vault needs from the factory, so vault tests do not depend on the real factory.
contract MockFactory is IOptionSeriesFactory {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    address public override feeRecipient;
    mapping(bytes32 => address) public override vaultOf;
    mapping(bytes32 => address) public override kuruMarketOf;

    function setRole(bytes32 role, address account, bool granted) external {
        _roles[role][account] = granted;
    }

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return _roles[role][account];
    }

    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function setVault(bytes32 seriesId, address vault) external {
        vaultOf[seriesId] = vault;
    }

    function setKuruMarket(bytes32 seriesId, address market) external {
        kuruMarketOf[seriesId] = market;
    }
}
