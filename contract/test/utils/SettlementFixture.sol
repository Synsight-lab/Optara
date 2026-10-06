// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidationFixture} from "./LiquidationFixture.sol";
import {MockSettlementOracle} from "../mocks/MockDependencies.sol";

/// @notice LiquidationFixture plus the real SettlementWindow at the `settlementWindow` address, which is then also
///         the risk manager's and clearing's settlement state. The window's oracle is a MockSettlementOracle.
abstract contract SettlementFixture is LiquidationFixture {
    function _deployRealSettlement() internal pure override returns (bool) {
        return true;
    }

    /// @dev Sets the ETH 30-day group's settlement price and finalizes it (as `msg.sender` = this test).
    function _finalize30(uint256 priceWad) internal {
        MockSettlementOracle(settlementOracle).setPrice(ETH_CFG, EXP30, priceWad);
        window.finalizeGroup(group30, "");
    }
}
