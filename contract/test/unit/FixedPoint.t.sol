// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {MathHarness} from "../harness/MathHarness.sol";

/// @notice Unit tests for FixedPoint (docs/MATH.md §1–§2, §4).
contract FixedPointTest is Test {
    MathHarness internal h;

    function setUp() public {
        h = new MathHarness();
    }

    function test_scale() public view {
        assertEq(h.scale(18), 1);
        assertEq(h.scale(6), 1e12);
        assertEq(h.scale(0), 1e18);
    }

    function test_scale_revertsAbove18Decimals() public {
        vm.expectRevert(abi.encodeWithSelector(FixedPoint.DecimalsTooLarge.selector, uint8(19)));
        h.scale(19);
    }

    function test_toWad_isExact() public view {
        assertEq(h.toWad(1_000_000, 6), 1e18); // 1 USDC
        assertEq(h.toWad(7, 0), 7e18);
        assertEq(h.toWad(123, 18), 123);
    }

    function test_toNative_roundsInStatedDirection() public view {
        // 1.0000005 USDC in WAD → 1.000000 down, 1.000001 up
        uint256 x = 1_000_000_500_000_000_000;
        assertEq(h.toNativeDown(x, 6), 1_000_000);
        assertEq(h.toNativeUp(x, 6), 1_000_001);
        // exact values don't round up
        assertEq(h.toNativeUp(1e18, 6), 1_000_000);
        assertEq(h.toNativeUp(0, 6), 0);
        assertEq(h.toNativeUp(1, 6), 1);
    }

    function test_yearsUntil() public view {
        assertEq(h.yearsUntil(1000 + FixedPoint.YEAR, 1000), 1e18);
        assertEq(h.yearsUntil(100, 100), 0);
        assertEq(h.yearsUntil(100, 200), 0); // past expiry clamps to 0
        // one second rounds down to 31,709,791,983 wei-years
        assertEq(h.yearsUntil(1, 0), 1e18 / FixedPoint.YEAR);
    }

    function test_bps() public view {
        assertEq(h.bpsDown(1001, 5000), 500);
        assertEq(h.bpsUp(1001, 5000), 501);
        assertEq(h.bpsUp(1000, 5000), 500);
    }
}
