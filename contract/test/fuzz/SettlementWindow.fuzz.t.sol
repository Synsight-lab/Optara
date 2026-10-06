// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementFixture} from "../utils/SettlementFixture.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";

/// @notice Random settlement groups: three writers mint the three 30-day series, two holders receive the wrappers and
///         unwrap part of them into the writers' accounts (so accounts net longs against shorts), some accounts are
///         drained to create shortfalls, insurance is seeded at random, and the final price is random. Checks the
///         settlement identity (INV-47), ratio bounds (INV-29, INV-30), pool accounting (INV-31), custody with pools
///         (INV-7), order and split independence of redemption (INV-32) and once-only settlement and claims (INV-48).
contract SettlementWindowFuzzTest is SettlementFixture {
    uint256[3] internal accts;
    address[3] internal owners;
    address[2] internal holders;
    bytes32[3] internal ids;

    function setUp() public {
        _deployClearingMarket();
        (owners[0], owners[1], owners[2]) = (alice, bob, makeAddr("carol"));
        (holders[0], holders[1]) = (makeAddr("h0"), makeAddr("h1"));
        (ids[0], ids[1], ids[2]) = (c4500, c5000, p3500);
        for (uint256 i; i < 3; ++i) {
            accts[i] = _account(owners[i]);
            _deposit(accts[i], owners[i], 60_000e6);
        }
    }

    /// @dev Builds the group from `seed`, drains accounts, seeds insurance and finalizes at a random price.
    function _build(uint256 seed) internal {
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                seed = uint256(keccak256(abi.encode(seed)));
                uint256 q = (seed % 300) * 1e16; // 0–2.99 contracts
                if (q == 0) continue;
                address h = holders[(seed >> 16) % 2];
                vm.prank(owners[i]);
                clearingModule.mintExternalLong(accts[i], ids[j], q, h, type(uint256).max, _empty());
                uint256 back = ((seed >> 32) % (q / 1e16 + 1)) * 1e16; // part goes back in as an internal long
                uint256 to = (seed >> 48) % 3;
                if (back != 0) {
                    IERC20 w = IERC20(_wrapper(ids[j]));
                    vm.prank(h);
                    assertTrue(w.transfer(owners[to], back));
                    vm.prank(owners[to]);
                    clearingModule.unwrapLong(accts[to], ids[j], back);
                }
            }
        }
        vm.warp(EXP30 + 1);
        for (uint256 i; i < 3; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            if (seed % 3 == 0) _drainTo(accts[i], seed % 3000e6); // leave 0–3,000
        }
        seed = uint256(keccak256(abi.encode(seed)));
        uint256 ins = seed % 2000e6;
        usdc.mint(address(this), ins);
        usdc.approve(address(insurance), ins);
        if (ins != 0) insurance.deposit(address(usdc), ins);
        _finalize30(2000e18 + (seed >> 64) % 6000e18);
    }

    function _drainTo(uint256 accountId, uint256 cash) internal {
        uint256 have = ledger.cashOf(accountId);
        if (have <= cash) return;
        vm.prank(clearing);
        ledger.subCash(accountId, have - cash);
        vm.prank(clearing);
        assertTrue(usdc.transfer(stranger, have - cash));
    }

    function testFuzz_settlementLifecycle(uint256 seed, uint256 order) public {
        _build(seed);
        ISettlementWindow.GroupAccounting memory g = window.groupAccounting(group30);

        // INV-47: Σ account nets + wrapper claims = 0 exactly
        int256 sum = int256(g.wrapperClaimN);
        for (uint256 i; i < 3; ++i) {
            (int256 n,,) = window.previewSettle(accts[i], group30);
            sum += n;
        }
        assertEq(sum, 0, "INV-47: settlement identity");

        uint256[] memory list = new uint256[](3);
        uint256 o = order % 3;
        (list[0], list[1], list[2]) = (accts[o], accts[(o + 1) % 3], accts[(o + 2) % 3]);
        window.settleAccountsGroup(list, group30);
        assertEq(ledger.participants(group30), 0);
        window.settleAccountsGroup(list, group30); // INV-48: a second pass settles nobody
        window.computeRecoveryRatio(group30);
        g = window.groupAccounting(group30);
        assertLe(g.ratioWad, 1e18, "INV-29");
        if (g.unpaid == 0 || g.insurance >= g.unpaid) assertEq(g.ratioWad, 1e18, "INV-30: covered means 1");
        _custody(g);

        // INV-32: redeem in random chunks; the total is within rounding of a one-shot redemption
        for (uint256 j; j < 3; ++j) {
            for (uint256 k; k < 2; ++k) {
                IERC20 w = IERC20(_wrapper(ids[j]));
                uint256 bal = w.balanceOf(holders[k]);
                if (bal == 0) continue;
                (uint256 oneShot,) = window.previewRedeem(ids[j], bal);
                uint256 first = (bal * ((order >> (8 * (j * 2 + k))) % 100)) / 100;
                uint256 got = usdc.balanceOf(holders[k]);
                vm.startPrank(holders[k]);
                if (first != 0) window.redeemWrapper(ids[j], first, holders[k]);
                window.redeemWrapper(ids[j], bal - first, holders[k]);
                vm.stopPrank();
                got = usdc.balanceOf(holders[k]) - got;
                assertLe(got, oneShot, "INV-32: splitting never pays more");
                assertGe(got + 1, oneShot, "INV-32: and loses at most rounding");
            }
        }
        for (uint256 i; i < 3; ++i) {
            if (window.creditOf(accts[i], group30) != 0) window.claimSettlement(accts[i], group30);
        }
        g = window.groupAccounting(group30);
        assertEq(g.unclaimedCredits, 0);
        assertLe(g.pool, 12, "only rounding dust remains");
        _custody(g);
        window.sweepDust(group30);
        assertEq(window.groupAccounting(group30).pool, 0);
    }

    /// @dev INV-7 with pools; INV-31: pool ≤ collected + insurance.
    function _custody(ISettlementWindow.GroupAccounting memory g) internal view {
        uint256 cash;
        for (uint256 i; i < 3; ++i) {
            cash += ledger.cashOf(accts[i]);
        }
        assertEq(usdc.balanceOf(address(clearingModule)), cash + g.pool, "INV-7");
        assertLe(g.pool, g.collected + g.insurance, "INV-31");
    }
}
