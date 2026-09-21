// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SeriesConfig, FeeConfig} from "./Types.sol";
import {Unauthorized} from "./Errors.sol";
import {OptionSeriesVault} from "./OptionSeriesVault.sol";

error AlreadyBound();

/// @title VaultDeployer
/// @notice Holds the vault's creation code so the factory stays under the contract size limit. Only the factory
///         that bound it can deploy through it. It holds no funds and no state other than the bound factory.
/// @dev The factory binds itself in its own constructor. Whoever calls `bind` first becomes the factory, and the
///      factory verifies `deployer.factory() == address(this)` right after, so a front-run bind makes the
///      factory deployment revert instead of silently using a deployer someone else controls.
contract VaultDeployer {
    address public factory;

    function bind() external {
        if (factory != address(0)) revert AlreadyBound();
        factory = msg.sender;
    }

    function deploy(bytes32 seriesId, SeriesConfig calldata c, FeeConfig calldata fees) external returns (address) {
        if (msg.sender != factory) revert Unauthorized();
        return address(new OptionSeriesVault(msg.sender, seriesId, c, fees));
    }
}
