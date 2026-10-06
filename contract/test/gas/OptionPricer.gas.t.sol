// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";

/// @notice Gas benchmarks for the pricing primitives (TESTING.md §6). The risk check prices every leg in every
///         scenario, so Black-76 cost × scenarios × legs drives GAS-001 (`maxRiskCheckGas`).
/// @dev Calls the library internally (as the risk manager will), so no external-call overhead is included.
contract OptionPricerGasTest is Test {
    uint256 internal constant T30 = 30 days * 1e18 / FixedPoint.YEAR;

    /// @dev Regression guard: one in-the-money-ish Black-76 price must stay under 7k gas.
    function test_gas_black76() public view {
        uint256 g = gasleft();
        uint256 p = OptionPricer.black76(true, 4000e18, 4500e18, 0.6e18, T30);
        uint256 used = g - gasleft();
        console.log("black76 gas", used, "price", p);
        assertLt(used, 7_000);
    }

    function test_gas_normCdf() public view {
        uint256 g = gasleft();
        uint256 n = OptionPricer.normCdf(-0.35e18);
        uint256 used = g - gasleft();
        console.log("normCdf gas", used, "N", n);
        assertLt(used, 2_000);
    }

    function test_gas_surfaceIv() public view {
        uint64 report = 1_800_000_000;
        OptionPricer.IvQuery memory q = OptionPricer.IvQuery({
            k: 0.117e18,
            kLo: 0,
            kHi: 0.3e18,
            wALo: 0.02e18,
            wAHi: 0.025e18,
            wBLo: 0.05e18,
            wBHi: 0.06e18,
            tenorA: report + 7 days,
            tenorB: report + 60 days,
            expiry: report + 30 days,
            reportTime: report,
            minIv: 0.1e18,
            maxIv: 5e18
        });
        uint256 g = gasleft();
        uint256 s = OptionPricer.surfaceIv(q);
        uint256 used = g - gasleft();
        console.log("surfaceIv gas", used, "sigma", s);
        assertLt(used, 6_000);
    }
}
