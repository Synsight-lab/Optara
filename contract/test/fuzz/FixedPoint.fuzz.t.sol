// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MathHarness} from "../harness/MathHarness.sol";

/// @notice Fuzz tests for FixedPoint: conversions bracket the exact value and round in the stated direction
///         (docs/MATH.md §1–§2).
contract FixedPointFuzzTest is Test {
    MathHarness internal h;

    function setUp() public {
        h = new MathHarness();
    }

    function testFuzz_toNative_bracketsExactValue(uint256 x, uint8 d) public view {
        d = uint8(bound(d, 0, 18));
        uint256 sc = h.scale(d);
        uint256 down = h.toNativeDown(x, d);
        uint256 up = h.toNativeUp(x, d);
        assertLe(down * sc, x);
        assertTrue(up == down || up == down + 1);
        assertEq(up == down, x % sc == 0);
    }

    function testFuzz_toWadRoundTrip(uint128 native, uint8 d) public view {
        d = uint8(bound(d, 0, 18));
        uint256 w = h.toWad(native, d);
        assertEq(h.toNativeDown(w, d), native);
        assertEq(h.toNativeUp(w, d), native);
    }

    function testFuzz_bps_upMinusDownAtMostOne(uint128 x, uint16 bps) public view {
        uint256 down = h.bpsDown(x, bps);
        uint256 up = h.bpsUp(x, bps);
        assertTrue(up == down || up == down + 1);
        assertLe(down * 10_000, uint256(x) * bps);
        assertGe(up * 10_000, uint256(x) * bps);
    }
}
