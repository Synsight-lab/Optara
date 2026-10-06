// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LedgerFixture} from "../utils/LedgerFixture.sol";
import {PositionBelowMinimum, InsufficientCash} from "../../src/libraries/Errors.sol";

/// @notice Fuzz tests for SubAccounts: INV-6 minimum position decides success, totals follow any delta (INV-2),
///         cash never goes negative (INV-8).
contract SubAccountsFuzzTest is LedgerFixture {
    uint256 internal a;
    uint256 internal b;

    function setUp() public {
        _deployLedger();
        a = _newAccount(alice, address(usdc));
        b = _newAccount(bob, address(usdc));
    }

    function testFuzz_INV6_minimumDecidesSuccess(int256 first, int256 second) public {
        first = bound(first, -1000e18, 1000e18);
        second = bound(second, -1000e18, 1000e18);
        _tryDelta(a, first, 0);
        int256 before = ledger.balanceOf(a, ethC4500);
        _tryDelta(a, second, before);
    }

    function _tryDelta(uint256 id, int256 d, int256 before) internal {
        int256 next = before + d;
        bool ok = next == 0 || (_abs(next) >= MIN_QTY && _abs(next) % MIN_QTY == 0);
        vm.prank(clearing);
        if (!ok) vm.expectRevert(abi.encodeWithSelector(PositionBelowMinimum.selector, next));
        ledger.applyDelta(id, ethC4500, d);
        if (ok && d != 0) assertEq(ledger.balanceOf(id, ethC4500), next);
    }

    function testFuzz_INV2_totalsFollowBalances(uint64 qa, uint64 qb, uint64 qc, bool sa, bool sb, bool sc) public {
        int256 da = _signed(qa, sa);
        int256 db = _signed(qb, sb);
        int256 dc = _signed(qc, sc);
        _delta(a, ethC4500, da);
        _delta(b, ethC4500, db);
        _delta(a, ethC4500, dc);
        int256 balA = da + dc;
        int256 balB = db;
        (uint256 l, uint256 s) = ledger.totals(ethC4500);
        assertEq(l, _pos(balA) + _pos(balB));
        assertEq(s, _pos(-balA) + _pos(-balB));
        uint256 expectedParticipants = (balA != 0 ? 1 : 0) + (balB != 0 ? 1 : 0);
        assertEq(ledger.participants(groupA), expectedParticipants);
        assertEq(ledger.seriesOf(a).length, balA != 0 ? 1 : 0);
    }

    function testFuzz_INV8_cashNeverNegative(uint128 add, uint128 sub) public {
        vm.prank(clearing);
        ledger.addCash(a, add);
        vm.prank(liquidationModule);
        if (sub > add) vm.expectRevert(abi.encodeWithSelector(InsufficientCash.selector, uint256(sub), uint256(add)));
        ledger.subCash(a, sub);
        assertEq(ledger.cashOf(a), sub > add ? add : add - sub);
    }

    // ---- helpers

    /// @dev Multiples of the minimum (or zero) so the delta itself is always valid.
    function _signed(uint64 q, bool neg) internal pure returns (int256) {
        int256 v = int256(uint256(q % 1000)) * MIN_QTY_I;
        return neg ? -v : v;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _pos(int256 x) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x > 0 ? uint256(x) : 0;
    }
}
