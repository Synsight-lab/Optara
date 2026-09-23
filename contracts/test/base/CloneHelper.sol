// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {OptionSeriesVault} from "../../src/OptionSeriesVault.sol";
import {SeriesConfig, FeeConfig} from "../../src/Types.sol";

/// @notice Deploys vaults the same way `VaultDeployer` does in production: ONE implementation, reused as an
///         EIP-1167 clone for every series, never `new OptionSeriesVault(...)` with constructor arguments,
///         which no longer exists. Shared by every test that needs a vault without going through the real
///         factory + `VaultDeployer`.
/// @dev Deploying a fresh implementation on every clone (instead of reusing one, as here) would also work,
///      but would put an extra CREATE ahead of the real state-changing call inside `deployVaultClone` -
///      `vm.expectRevert()` watches the next call, so tests asserting that `initialize` reverts on bad input
///      need that to still be the very next call after `Clones.clone`, exactly as production's single-shared-
///      implementation design naturally gives.
library CloneHelper {
    function deployImplementation() internal returns (address) {
        return address(new OptionSeriesVault());
    }

    /// @dev A clone with no `initialize` call yet. Exists so a test can `vm.expectRevert()` immediately
    ///      before `initialize` itself: `Clones.clone` is a CREATE, and `vm.expectRevert()` watches the very
    ///      next call - if a CREATE happens while it is armed, it watches THAT instead (`Clones.clone` never
    ///      reverts, so the expectation goes unmet). Cloning first, with no expectation armed, keeps
    ///      `initialize` as the one and only call under watch.
    function cloneUninitialized(address implementation) internal returns (OptionSeriesVault) {
        return OptionSeriesVault(Clones.clone(implementation));
    }

    function deployVaultClone(
        address implementation,
        address factory_,
        bytes32 seriesId_,
        SeriesConfig memory c,
        FeeConfig memory fees
    ) internal returns (OptionSeriesVault v) {
        v = OptionSeriesVault(Clones.clone(implementation));
        v.initialize(factory_, seriesId_, c, fees);
    }
}
