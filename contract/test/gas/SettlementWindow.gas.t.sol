// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {SettlementFixture} from "../utils/SettlementFixture.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice GAS-002: a settlement batch of 20 accounts (2 series each) fits a 30M transaction. GAS-003: finalizing a
///         group with 64 series (its snapshot loop) and sweeping it stay well inside it too.
contract SettlementWindowGasTest is SettlementFixture {
    uint256[] internal accts;
    bytes32[] internal series;

    function setUp() public {
        _deployClearingMarket();
        for (uint256 k; k < 64; ++k) {
            series.push(_series(ethUsdc, k % 2 == 0 ? OptionType.CALL : OptionType.PUT, 3000e18 + k * 50e18, EXP30));
        }
        for (uint256 i; i < 20; ++i) {
            uint256 a = _account(makeAddr(string(abi.encode(i))));
            _deposit(a, alice, 10_000e6);
            _hold(a, series[i % 64], -1e18);
            _hold(a, series[(i + 7) % 64], 1e18);
            accts.push(a);
        }
        vm.warp(EXP30 + 1);
        MockSettlementOracleLike(settlementOracle).setPrice(ETH_CFG, EXP30, 4321e18);
    }

    function test_GAS003_finalize64Series() public {
        uint256 g = gasleft();
        window.finalizeGroup(group30, "");
        uint256 used = g - gasleft();
        console.log("finalizeGroup, 64 series:", used);
        assertLt(used, 30_000_000);
    }

    function test_GAS002_settleBatchOf20() public {
        window.finalizeGroup(group30, "");
        uint256 g = gasleft();
        window.settleAccountsGroup(accts, group30);
        uint256 used = g - gasleft();
        console.log("settleAccountsGroup, 20 accounts x 2 series:", used);
        assertEq(ledger.participants(group30), 0);
        assertLt(used, 30_000_000);
    }
}

interface MockSettlementOracleLike {
    function setPrice(bytes32 configId, uint64 expiry, uint256 price) external;
}
