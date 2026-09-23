// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {SeriesConfig, FeeConfig} from "./Types.sol";
import {Unauthorized} from "./Errors.sol";
import {OptionSeriesVault} from "./OptionSeriesVault.sol";

error AlreadyBound();

/// @title VaultDeployer
/// @notice Deploys one `OptionSeriesVault` implementation, then produces every series as a cheap EIP-1167
///         minimal proxy clone of it. Only the factory that bound it can deploy through it. It holds no
///         funds and no state other than the bound factory and the implementation address.
/// @dev The factory binds itself in its own constructor. Whoever calls `bind` first becomes the factory, and
///      the factory verifies `deployer.factory() == address(this)` right after, so a front-run bind makes the
///      factory deployment revert instead of silently using a deployer someone else controls.
///
///      `implementation` is a real, deployed `OptionSeriesVault` whose own constructor calls
///      `_disableInitializers()` (see OptionSeriesVault.sol), so it can never itself be mistaken for a real
///      series: nobody can call `initialize` on it, cloned or not. Every series is `Clones.clone(implementation)`
///      immediately followed by `initialize(...)` in the same call - no other transaction can run in between,
///      so a clone can never be observed, let alone initialized, before this function initializes it itself.
contract VaultDeployer {
    address public immutable implementation;
    address public factory;

    constructor() {
        implementation = address(new OptionSeriesVault());
    }

    function bind() external {
        if (factory != address(0)) revert AlreadyBound();
        factory = msg.sender;
    }

    function deploy(bytes32 seriesId, SeriesConfig calldata c, FeeConfig calldata fees) external returns (address vault) {
        if (msg.sender != factory) revert Unauthorized();
        vault = Clones.clone(implementation);
        OptionSeriesVault(vault).initialize(msg.sender, seriesId, c, fees);
    }
}
