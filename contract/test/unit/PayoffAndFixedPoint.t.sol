// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MathHarness} from "../utils/MathHarness.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";
import {PayoffMath} from "../../src/libraries/PayoffMath.sol";

/// @notice TEST_CASES.md Part I (PAY-*) and Part II (FIX-*). Expected values are hand-derived from MATH.md.
contract PayoffAndFixedPointTest is Test {
    uint256 constant W = 1e18;
    uint256 constant MAXN = uint256(type(int256).max);
    MathHarness m;

    function setUp() public {
        m = new MathHarness();
    }

    function _call(uint256 s) internal view returns (uint256) {
        return m.phi(OptionType.CALL, 10 * W, 5 * W, s);
    }

    function _put(uint256 s) internal view returns (uint256) {
        return m.phi(OptionType.PUT, 10 * W, 4 * W, s);
    }

    // ------------------------------------------------------------------ PAY: call K=10 C=5
    function test_PAY_001_callBelowStrike() public view {
        assertEq(_call(9 * W), 0);
    }

    function test_PAY_002_callAtStrike() public view {
        assertEq(_call(10 * W), 0);
    }

    function test_PAY_003_callLinearRegion() public view {
        assertEq(_call(12 * W), 2 * W);
    }

    function test_PAY_004_callOneUnitBelowCap() public view {
        assertEq(_call(14 * W), 4 * W);
        assertEq(_call(15 * W - 1), 5 * W - 1);
    }

    function test_PAY_005_callAtCapBoundary() public view {
        assertEq(_call(15 * W), 5 * W);
    }

    function test_PAY_006_callAboveCap() public view {
        assertEq(_call(20 * W), 5 * W);
    }

    function test_PAY_007_callExtremePrice() public view {
        assertEq(_call(type(uint256).max), 5 * W);
        assertEq(_call(type(uint128).max), 5 * W);
    }

    // ------------------------------------------------------------------ PAY: put K=10 C=4
    function test_PAY_008_putAboveStrike() public view {
        assertEq(_put(12 * W), 0);
    }

    function test_PAY_009_putAtStrike() public view {
        assertEq(_put(10 * W), 0);
    }

    function test_PAY_010_putLinearRegion() public view {
        assertEq(_put(8 * W), 2 * W);
    }

    function test_PAY_011_putCapBoundary() public view {
        assertEq(_put(6 * W), 4 * W);
    }

    function test_PAY_012_putBelowCapBoundary() public view {
        assertEq(_put(1 * W), 4 * W);
    }

    function test_PAY_013_putAtZero() public view {
        assertEq(_put(0), 4 * W);
    }

    /// OPTION_SPEC.md sections 29-30 tables.
    function test_PAY_optionSpecTables() public view {
        uint256[8] memory cs = [uint256(0), 8 * W, 10 * W, 11 * W, 125 * W / 10, 15 * W, 20 * W, 1000 * W];
        uint256[8] memory ce = [uint256(0), 0, 0, 1 * W, 25 * W / 10, 5 * W, 5 * W, 5 * W];
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(_call(cs[i]), ce[i]);
        }
        uint256[7] memory ps = [uint256(15 * W), 10 * W, 9 * W, 7 * W, 6 * W, 3 * W, 0];
        uint256[7] memory pe = [uint256(0), 0, 1 * W, 3 * W, 4 * W, 4 * W, 4 * W];
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(_put(ps[i]), pe[i]);
        }
    }

    function _boundTerms(uint256 k, uint256 c, bool isPut) internal pure returns (uint256, uint256) {
        k = bound(k, 1, type(uint128).max / 2);
        c = bound(c, 1, type(uint128).max / 2);
        if (isPut && c > k) c = k;
        return (k, c);
    }

    function testFuzz_PAY_014_callCapProperty(uint256 k, uint256 c, uint256 s) public view {
        (k, c) = _boundTerms(k, c, false);
        assertLe(m.phi(OptionType.CALL, k, c, s), c);
    }

    function testFuzz_PAY_015_putCapProperty(uint256 k, uint256 c, uint256 s) public view {
        (k, c) = _boundTerms(k, c, true);
        assertLe(m.phi(OptionType.PUT, k, c, s), c);
    }

    function testFuzz_PAY_016_callMonotonic(uint256 k, uint256 c, uint256 s1, uint256 s2) public view {
        (k, c) = _boundTerms(k, c, false);
        (s1, s2) = s1 <= s2 ? (s1, s2) : (s2, s1);
        assertLe(m.phi(OptionType.CALL, k, c, s1), m.phi(OptionType.CALL, k, c, s2));
    }

    function testFuzz_PAY_017_putMonotonic(uint256 k, uint256 c, uint256 s1, uint256 s2) public view {
        (k, c) = _boundTerms(k, c, true);
        (s1, s2) = s1 <= s2 ? (s1, s2) : (s2, s1);
        assertGe(m.phi(OptionType.PUT, k, c, s1), m.phi(OptionType.PUT, k, c, s2));
    }

    /// min(max(S-K,0),C) == max(S-K,0) - max(S-(K+C),0)  (MATH.md section 8, INV-PAYOFF-07)
    function testFuzz_PAY_018_callSpreadEquivalence(uint256 k, uint256 c, uint256 s) public view {
        (k, c) = _boundTerms(k, c, false);
        s = bound(s, 0, type(uint128).max);
        uint256 a = s > k ? s - k : 0;
        uint256 b = s > k + c ? s - (k + c) : 0;
        assertEq(m.phi(OptionType.CALL, k, c, s), a - b);
    }

    function testFuzz_PAY_019_putSpreadEquivalence(uint256 k, uint256 c, uint256 s) public view {
        (k, c) = _boundTerms(k, c, true);
        s = bound(s, 0, type(uint128).max);
        uint256 a = k > s ? k - s : 0;
        uint256 b = (k - c) > s ? (k - c) - s : 0;
        assertEq(m.phi(OptionType.PUT, k, c, s), a - b);
    }

    /// OPTION_SPEC.md section 31: ETH call K4000 C500 CS0.1 Q3 at 4800 pays exactly 150 USDC.
    function test_PAY_020_contractSizeScaling() public view {
        uint256 n = m.payoffNumerator(OptionType.CALL, 4000 * W, 500 * W, W / 10, 4800 * W, 3 * W);
        assertEq(n / m.nativeDenominator(6), 150e6);
        assertEq(n % m.nativeDenominator(6), 0);
        // Doubling contract size doubles the exact numerator.
        assertEq(m.payoffNumerator(OptionType.CALL, 4000 * W, 500 * W, W / 5, 4800 * W, 3 * W), 2 * n);
    }

    /// OPTION_SPEC.md section 32: 0.25 option pays 12.5 USDC before rounding.
    function test_PAY_021_quantityScaling() public view {
        uint256 n = m.payoffNumerator(OptionType.CALL, 4000 * W, 500 * W, W / 10, 4800 * W, W / 4);
        assertEq(n / m.nativeDenominator(6), 12_500_000);
        testFuzz_quantityLinearity(W / 3, W / 7);
    }

    function testFuzz_quantityLinearity(uint256 q1, uint256 q2) public view {
        q1 = bound(q1, 0, 1e30);
        q2 = bound(q2, 0, 1e30);
        uint256 a = m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, 13 * W, q1);
        uint256 b = m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, 13 * W, q2);
        assertEq(m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, 13 * W, q1 + q2), a + b);
    }

    /// Pure math returns zero for zero quantity; state-changing paths reject zero separately.
    function test_PAY_022_zeroQuantity() public view {
        assertEq(m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, 13 * W, 0), 0);
    }

    // ------------------------------------------------------------------ FIX
    function test_FIX_001_mulDivDownExact() public view {
        assertEq(m.mulDivDown(6, 4, 3), 8);
    }

    function test_FIX_002_mulDivDownRemainder() public view {
        assertEq(m.mulDivDown(7, 3, 4), 5);
    }

    function test_FIX_003_mulDivUpExact() public view {
        assertEq(m.mulDivUp(6, 4, 3), 8);
    }

    function test_FIX_004_mulDivUpRemainder() public view {
        assertEq(m.mulDivUp(7, 3, 4), 6);
        assertEq(m.ceilDiv(21, 4), 6);
        assertEq(m.ceilDiv(20, 4), 5);
        assertEq(m.ceilDiv(0, 4), 0);
    }

    function test_FIX_005_denominatorZeroReverts() public {
        vm.expectRevert(FixedPointMath.DivisionByZero.selector);
        m.mulDivDown(1, 1, 0);
        vm.expectRevert(FixedPointMath.DivisionByZero.selector);
        m.mulDivUp(1, 1, 0);
        vm.expectRevert(FixedPointMath.DivisionByZero.selector);
        m.ceilDiv(1, 0);
        vm.expectRevert(FixedPointMath.DivisionByZero.selector);
        m.floorDiv(1, 0);
        vm.expectRevert(FixedPointMath.DivisionByZero.selector);
        m.mulDivHalfUp(1, 1, 0);
    }

    function test_FIX_006_highOperandsWithoutOverflow() public view {
        uint256 big = type(uint256).max;
        assertEq(m.mulDivDown(big, big, big), big);
        assertEq(m.mulDivUp(big, big - 1, big), big - 1);
        // ceilDiv never computes n + d - 1.
        assertEq(m.ceilDiv(big, 2), big / 2 + 1);
        assertEq(m.ceilDiv(big, big), 1);
    }

    function test_FIX_007_wadTo6Down() public view {
        assertEq(m.toNativeDown(1.2345678e18, 6), 1_234_567);
    }

    function test_FIX_008_wadTo6Up() public view {
        assertEq(m.toNativeUp(1.2345671e18, 6), 1_234_568);
        assertEq(m.toNativeUp(1.234567e18, 6), 1_234_567);
    }

    function test_FIX_009_wadTo18() public view {
        assertEq(m.toNativeDown(1.2345678e18, 18), 1.2345678e18);
        assertEq(m.toNativeUp(1.2345678e18, 18), 1.2345678e18);
    }

    function testFuzz_FIX_010_arbitraryDecimals(uint256 x, uint8 d) public {
        d = uint8(bound(d, 0, 18));
        x = bound(x, 0, type(uint128).max);
        uint256 lo = m.toNativeDown(x, d);
        uint256 hi = m.toNativeUp(x, d);
        assertLe(hi - lo, 1);
        assertEq(m.nativeDenominator(d), 10 ** (54 - uint256(d)));
        vm.expectRevert(abi.encodeWithSelector(FixedPointMath.UnsupportedDecimals.selector, uint8(19)));
        m.nativeDenominator(19);
    }

    function testFuzz_FIX_011_payoutDownNeverExceedsExact(uint256 n, uint8 d) public view {
        n = bound(n, 0, MAXN);
        d = uint8(bound(d, 0, 18));
        uint256 den = m.nativeDenominator(d);
        uint256 payout = m.floorDiv(n, den);
        assertLe(payout * den, n);
        assertGt(payout * den + den, n);
    }

    function testFuzz_FIX_012_debitUpNeverUnderstates(uint256 n, uint8 d) public view {
        n = bound(n, 0, MAXN);
        d = uint8(bound(d, 0, 18));
        uint256 den = m.nativeDenominator(d);
        uint256 debit = m.ceilDiv(n, den);
        assertGe(debit * den, n);
        assertLt(debit * den - n, den);
    }

    function testFuzz_FIX_013_marginUpNeverUnderstates(uint256 n) public view {
        n = bound(n, 1, MAXN);
        uint256 den = m.nativeDenominator(6);
        assertGe(m.ceilDiv(n, den) * den, n);
    }

    /// MATH.md section 84: floor(x) + floor(y) <= floor(x + y), so splitting redemption cannot extract more.
    function testFuzz_FIX_014_splitRoundingAttack(uint256 q, uint256 split, uint256 price) public view {
        q = bound(q, 2, 1e27);
        split = bound(split, 1, q - 1);
        price = bound(price, 0, 100 * W);
        uint256 den = m.nativeDenominator(6);
        uint256 whole = m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, price, q) / den;
        uint256 a = m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, price, split) / den;
        uint256 b = m.payoffNumerator(OptionType.CALL, 10 * W, 5 * W, W, price, q - split) / den;
        assertLe(a + b, whole);
    }

    function test_mulDivHalfUp() public view {
        assertEq(m.mulDivHalfUp(5, 1, 2), 3); // 2.5 -> 3
        assertEq(m.mulDivHalfUp(7, 1, 3), 2); // 2.33 -> 2
        assertEq(m.mulDivHalfUp(8, 1, 3), 3); // 2.67 -> 3
        assertEq(m.mulDivHalfUp(12e18, 1e18, 0.96e18), 12.5e18); // ORACLE_AND_SETTLEMENT.md section 13
    }

    function test_scaleByRho() public view {
        assertEq(m.scaleByRho(1000, 0.75e18), 750);
        assertEq(m.scaleByRho(3, 0.5e18), 1); // floor(1.5)
    }

    function test_boundedProductAndAdd() public {
        (bool ok, uint256 p) = m.boundedProduct(MAXN, 1, 1);
        assertTrue(ok);
        assertEq(p, MAXN);
        (ok,) = m.boundedProduct(MAXN, 2, 1);
        assertFalse(ok);
        (ok,) = m.boundedProduct(2 ** 128, 2 ** 127, 1);
        assertFalse(ok);
        (ok, p) = m.boundedProduct(0, type(uint256).max, type(uint256).max);
        assertTrue(ok);
        assertEq(p, 0);
        vm.expectRevert(PayoffMath.NumeratorBoundExceeded.selector);
        m.product(MAXN, 2, 1);
        assertEq(m.boundedAdd(MAXN - 1, 1), MAXN);
        vm.expectRevert(PayoffMath.NumeratorBoundExceeded.selector);
        m.boundedAdd(MAXN, 1);
    }
}
