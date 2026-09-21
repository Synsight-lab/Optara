// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OptionSeriesFactory} from "../src/OptionSeriesFactory.sol";
import {ADMIN_ROLE} from "../src/Types.sol";

/// @notice Final step: give the ADMIN role to the multisig or timelock and renounce the deployer's own.
///         Run this only after every pair is configured and checked. The deployer keeps nothing afterward.
///
/// Required env: FACTORY, NEW_ADMIN
contract HandOverAdmin is Script {
    function run() external {
        OptionSeriesFactory factory = OptionSeriesFactory(vm.envAddress("FACTORY"));
        address newAdmin = vm.envAddress("NEW_ADMIN");
        require(newAdmin != address(0), "zero admin");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(newAdmin != broadcaster, "new admin is the deployer");

        factory.grantRole(ADMIN_ROLE, newAdmin);
        require(factory.hasRole(ADMIN_ROLE, newAdmin), "grant failed");
        factory.renounceRole(ADMIN_ROLE, broadcaster);
        require(!factory.hasRole(ADMIN_ROLE, broadcaster), "deployer still admin");
        vm.stopBroadcast();

        console.log("ADMIN is now", newAdmin);
    }
}
