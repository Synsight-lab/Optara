// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISettlementConfigs, IRiskSets} from "../../src/interfaces/IExternalDependencies.sol";

/// @notice ERC-20 with configurable decimals (stablecoins of 6 and 18 decimals, TESTING.md §4).
contract MockERC20 is ERC20 {
    uint8 internal immutable DECIMALS;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        DECIMALS = d;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for SettlementOracle until BUILD_PLAN step 6.
contract MockSettlementConfigs is ISettlementConfigs {
    struct Cfg {
        address underlying;
        address settlementAsset;
        bool usable;
    }

    mapping(bytes32 => Cfg) public configs;

    function set(bytes32 id, address underlying, address settlementAsset, bool usable) external {
        configs[id] = Cfg(underlying, settlementAsset, usable);
    }

    function isConfigUsable(bytes32 id, address underlying, address settlementAsset) external view returns (bool) {
        Cfg memory c = configs[id];
        return c.usable && c.underlying == underlying && c.settlementAsset == settlementAsset;
    }
}

/// @notice Stand-in for PortfolioRiskManager's risk sets until BUILD_PLAN step 7.
contract MockRiskSets is IRiskSets {
    mapping(bytes32 => bool) public enabled;

    function set(bytes32 id, bool on) external {
        enabled[id] = on;
    }

    function isRiskSetEnabled(bytes32 id) external view returns (bool) {
        return enabled[id];
    }
}
