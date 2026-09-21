// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockAggregator} from "../../test/mocks/MockAggregator.sol";

/// @notice LOCAL ONLY. Deploys test tokens and a mock Chainlink feed so the whole runbook can be rehearsed on a
///         local Anvil chain. Never use on a real network.
contract DeployMocks is Script {
    function run() external {
        vm.startBroadcast();
        MockERC20 mon = new MockERC20("Wrapped MON", "WMON", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAggregator feed = new MockAggregator(8);
        feed.push((uint80(1) << 64) | 1, 10e8, block.timestamp);
        vm.stopBroadcast();
        console.log("WMON", address(mon));
        console.log("USDC", address(usdc));
        console.log("FEED", address(feed));
    }
}
