// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementFixture} from "../utils/SettlementFixture.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";

/// @notice The 30-day ETH group from mints to dust. `h_progress` walks the lifecycle one step per call (expiry and
///         finalization, one settlement, the ratio); mints, unwraps, wrapper transfers, redemptions, claims and the
///         sweep run at random around it. After every call: custody = Σ cash + pool (INV-7), pool = collected +
///         insurance − payouts (INV-31), the price and ratio never change once set (INV-26, INV-29), the ratio is
///         ≤ 1 and set only with no participants left (INV-28), participants match the accounts holding the group
///         (INV-27), and wrapper supply never exceeds its snapshot nor grows after finalization (INV-33).
contract SettlementWindowInvariantTest is SettlementFixture {
    uint256[3] internal accts;
    address[3] internal owners;
    address[2] internal holders;
    bytes32[3] internal ids;

    uint256 public payouts;
    uint256 public swept;
    uint256 public firstPrice;
    uint256 public firstRatio;
    uint256 public redemptions;

    function setUp() public {
        _deployClearingMarket();
        (owners[0], owners[1], owners[2]) = (alice, bob, makeAddr("carol"));
        (holders[0], holders[1]) = (makeAddr("h0"), makeAddr("h1"));
        (ids[0], ids[1], ids[2]) = (c4500, c5000, p3500);
        for (uint256 i; i < 3; ++i) {
            accts[i] = _account(owners[i]);
            _deposit(accts[i], owners[i], 30_000e6);
        }
        usdc.mint(address(this), 500e6);
        usdc.approve(address(insurance), 500e6);
        insurance.deposit(address(usdc), 500e6);
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = this.h_mint.selector;
        sel[1] = this.h_unwrap.selector;
        sel[2] = this.h_transfer.selector;
        sel[3] = this.h_progress.selector;
        sel[4] = this.h_redeem.selector;
        sel[5] = this.h_claim.selector;
        sel[6] = this.h_sweep.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    // ------------------------------------------------------------------ handlers

    function h_mint(uint8 i, uint8 j, uint16 raw) external {
        if (block.timestamp >= EXP30) return;
        uint256 q = bound(raw, 1, 200) * 1e16;
        vm.prank(owners[i % 3]);
        try clearingModule.mintExternalLong(
            accts[i % 3], ids[j % 3], q, holders[raw % 2], type(uint256).max, _empty()
        ) {}
            catch {}
    }

    function h_unwrap(uint8 k, uint8 i, uint8 j, uint16 raw) external {
        if (block.timestamp >= EXP30) return;
        address h = holders[k % 2];
        IERC20 w = IERC20(_wrapper(ids[j % 3]));
        uint256 units = w.balanceOf(h) / 1e16;
        if (units == 0) return;
        uint256 q = bound(raw, 1, units) * 1e16;
        vm.prank(h);
        assertTrue(w.transfer(owners[i % 3], q));
        vm.prank(owners[i % 3]);
        clearingModule.unwrapLong(accts[i % 3], ids[j % 3], q);
    }

    function h_transfer(uint8 k, uint8 j, uint16 raw) external {
        IERC20 w = IERC20(_wrapper(ids[j % 3]));
        uint256 bal = w.balanceOf(holders[k % 2]);
        if (bal == 0) return;
        vm.prank(holders[k % 2]);
        assertTrue(w.transfer(holders[(uint256(k) + 1) % 2], bound(raw, 1, bal)));
    }

    /// @dev One lifecycle step: 6 days pass (until a week before expiry), expire and finalize (price 2,000–8,000), settle the next participant, or set the
    ///      ratio. Accounts are drained to 0–2,000 at expiry with probability 1/2 to create shortfalls.
    function h_progress(uint64 entropy) external {
        ISettlementWindow.GroupAccounting memory g = window.groupAccounting(group30);
        if (block.timestamp + 6 days < EXP30) {
            vm.warp(block.timestamp + 6 days); // let mints happen over the series' life
            clearingModule.updateOracles(_marketUpdate(4000e18));
            return;
        }
        if (!g.finalized) {
            vm.warp(EXP30 + 1);
            for (uint256 i; i < 3; ++i) {
                if ((entropy >> i) & 1 == 1) _drainTo(accts[i], (uint256(entropy) >> 8) % 2000e6);
            }
            _finalize30(2000e18 + uint256(entropy) % 6000e18);
            firstPrice = window.settlementPrice(group30);
            return;
        }
        for (uint256 i; i < 3; ++i) {
            if (ledger.seriesCountInGroup(accts[i], group30) != 0) {
                window.settleAccountGroup(accts[i], group30);
                return;
            }
        }
        if (!g.ratioSet) {
            window.computeRecoveryRatio(group30);
            (, firstRatio) = window.recoveryRatio(group30);
        }
    }

    function h_redeem(uint8 k, uint8 j, uint16 raw) external {
        if (!window.groupAccounting(group30).ratioSet) return;
        IERC20 w = IERC20(_wrapper(ids[j % 3]));
        uint256 bal = w.balanceOf(holders[k % 2]);
        if (bal == 0) return;
        uint256 q = bound(raw, 1, bal);
        uint256 before = usdc.balanceOf(holders[k % 2]);
        uint256 supply = w.totalSupply();
        vm.prank(holders[k % 2]);
        window.redeemWrapper(ids[j % 3], q, holders[k % 2]);
        payouts += usdc.balanceOf(holders[k % 2]) - before;
        assertEq(w.totalSupply(), supply - q, "INV-33: redemption burns exactly qty");
        redemptions++;
    }

    function h_claim(uint8 i) external {
        uint256 a = accts[i % 3];
        if (!window.groupAccounting(group30).ratioSet || window.creditOf(a, group30) == 0) return;
        uint256 before = ledger.cashOf(a);
        window.claimSettlement(a, group30);
        payouts += ledger.cashOf(a) - before;
    }

    function h_sweep() external {
        uint256 pool = window.groupAccounting(group30).pool;
        try window.sweepDust(group30) {
            swept += pool;
        } catch {}
    }

    function _drainTo(uint256 accountId, uint256 cash) internal {
        uint256 have = ledger.cashOf(accountId);
        if (have <= cash) return;
        vm.prank(clearing);
        ledger.subCash(accountId, have - cash);
        vm.prank(clearing);
        assertTrue(usdc.transfer(stranger, have - cash));
    }

    // ------------------------------------------------------------------ invariants

    function invariant_INV7_INV31_custodyAndPool() public view {
        ISettlementWindow.GroupAccounting memory g = window.groupAccounting(group30);
        uint256 cash;
        for (uint256 i; i < 3; ++i) {
            cash += ledger.cashOf(accts[i]);
        }
        assertEq(usdc.balanceOf(address(clearingModule)), cash + g.pool, "INV-7");
        assertEq(g.pool + payouts + swept, g.collected + g.insurance, "INV-31: exact pool accounting");
    }

    function invariant_INV26_INV28_INV29_writtenOnce() public view {
        ISettlementWindow.GroupAccounting memory g = window.groupAccounting(group30);
        if (g.finalized) assertEq(g.priceWad, firstPrice, "INV-26");
        if (g.ratioSet) {
            assertEq(g.ratioWad, firstRatio, "INV-29: fixed");
            assertLe(g.ratioWad, 1e18, "INV-29: at most 1");
            assertEq(ledger.participants(group30), 0, "INV-28");
        }
    }

    function invariant_INV27_participants() public view {
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                if (ledger.balanceOf(accts[i], ids[j]) != 0) {
                    ++n;
                    break;
                }
            }
        }
        assertEq(ledger.participants(group30), n);
    }

    /// @dev After finalization supply only falls, and only through redemption (checked exactly in `h_redeem`).
    function invariant_INV33_supplyBoundedBySnapshot() public view {
        if (!window.groupAccounting(group30).finalized) return;
        for (uint256 j; j < 3; ++j) {
            assertLe(IERC20(_wrapper(ids[j])).totalSupply(), window.wrapperSupplyAtFinalization(ids[j]), "INV-33");
        }
    }

    function test_handlerPathsReachable() public {
        this.h_mint(0, 0, 150);
        this.h_mint(1, 1, 120);
        this.h_unwrap(0, 2, 0, 50);
        this.h_transfer(0, 0, 1000);
        for (uint256 k; k < 4; ++k) {
            this.h_progress(0); // 6-day steps to a week before expiry
        }
        this.h_progress(0x2a5f_0000_0000_0003); // finalize, draining accounts 0 and 1
        for (uint256 k; k < 4; ++k) {
            this.h_progress(0);
        }
        assertTrue(window.groupAccounting(group30).ratioSet);
        for (uint8 k; k < 2; ++k) {
            for (uint8 j; j < 3; ++j) {
                this.h_redeem(k, j, type(uint16).max);
            }
        }
        for (uint8 i; i < 3; ++i) {
            this.h_claim(i);
        }
        this.h_sweep();
        assertGt(redemptions, 0);
        invariant_INV7_INV31_custodyAndPool();
        invariant_INV26_INV28_INV29_writtenOnce();
        invariant_INV27_participants();
        invariant_INV33_supplyBoundedBySnapshot();
    }
}
