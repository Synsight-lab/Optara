// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {LiquidationFixture} from "../utils/LiquidationFixture.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice GAS-003 for LiquidationModule: a slice of an 8-leg ETH bucket in a 16-leg account (two underlyings),
///         into a liquidator that then holds those 8 legs. A slice computes the account's risk twice and the
///         liquidator's once (DD-31), so the budget is 3 × the 8,000,000 risk check.
contract LiquidationModuleGasTest is LiquidationFixture {
    uint256 internal acct;
    uint256 internal liq;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _deployClearingMarket();
        _setSpot(btcUsdc, 90_000e18);
        uint256[] memory k = new uint256[](3);
        uint256[] memory iv = new uint256[](3);
        (k[0], k[1], k[2]) = (80_000e18, 90_000e18, 100_000e18);
        (iv[0], iv[1], iv[2]) = (0.55e18, 0.5e18, 0.52e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        _setSurface(btcUsdc, 90_000e18, k, iv, tenors);

        acct = _account(alice);
        liq = _account(keeper);
        _deposit(liq, keeper, 10_000_000e6);
        _deposit(acct, alice, 1000e6);
        uint256[4] memory ethStrikes = [uint256(3500e18), 4000e18, 4500e18, 5000e18];
        uint256[4] memory btcStrikes = [uint256(80_000e18), 90_000e18, 95_000e18, 100_000e18];
        for (uint256 i; i < 4; ++i) {
            _hold(acct, _series(ethUsdc, OptionType.CALL, ethStrikes[i], EXP30), -2e18);
            _hold(acct, _series(ethUsdc, OptionType.PUT, ethStrikes[i], T0 + 45 days), -2e18);
            _hold(acct, _series(btcUsdc, OptionType.CALL, btcStrikes[i], EXP30), 0.01e18);
            _hold(acct, _series(btcUsdc, OptionType.PUT, btcStrikes[i], T0 + 45 days), 0.01e18);
        }
        assertEq(ledger.seriesOf(acct).length, 16);
        liquidation.startAuction(acct, weth, _empty());
    }

    function test_GAS003_sliceAtMaxPositions() public {
        vm.prank(keeper);
        uint256 g = gasleft();
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, type(uint256).max, _empty());
        uint256 used = g - gasleft();
        console.log("liquidateSlice, 8 of 16 legs:", used);
        assertEq(ledger.seriesOf(liq).length, 8);
        assertLt(used, 24_000_000);
    }
}
