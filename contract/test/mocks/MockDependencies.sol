// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ISettlementConfigs,
    IRiskSets,
    ISettlementState,
    IReserveStatus
} from "../../src/interfaces/IExternalDependencies.sol";

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

    /// @dev Product-agnostic stand-in: the product binding is tested with the real PortfolioRiskManager.
    function isRiskSetForProduct(bytes32, bytes32 id) external view returns (bool) {
        return enabled[id];
    }
}

/// @notice Stand-in for SettlementWindow's finalized prices until BUILD_PLAN step 11.
contract MockSettlementState is ISettlementState {
    mapping(bytes32 => uint256) public price;
    mapping(bytes32 => bool) public finalized;

    function finalize(bytes32 groupId, uint256 priceWad) external {
        (finalized[groupId], price[groupId]) = (true, priceWad);
    }

    function settlementPriceOf(bytes32 groupId) external view returns (bool, uint256) {
        return (finalized[groupId], price[groupId]);
    }
}

/// @notice Stand-in for the insurance/keeper reserve check until BUILD_PLAN step 8.
contract MockReserveStatus is IReserveStatus {
    mapping(address => bool) public unhealthy;

    function setHealthy(address asset, bool healthy) external {
        unhealthy[asset] = !healthy;
    }

    function reservesHealthy(address asset) external view returns (bool) {
        return !unhealthy[asset];
    }
}

/// @notice Takes a 1% fee on every transfer (TESTING.md §4): deposits of it must revert NonExactTransfer.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FOT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0), cut);
            value -= cut;
        }
        super._update(from, to, value);
    }
}
