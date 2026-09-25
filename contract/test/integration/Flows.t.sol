// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {SeriesStatus} from "../../src/libraries/OptaraTypes.sol";
import {AtomicSwap} from "../mocks/AtomicSwap.sol";

/// @notice End-to-end user flows (TEST_CASES.md Part XXXIII, USER_FLOWS.md) and state-machine transitions
///         (Part XXIX, STATE_MACHINE.md). "Kuru" is modelled as an external address holding ERC-20 balances:
///         Optara never reads venue state, which is exactly the boundary under test.
contract FlowsTest is OptaraTestBase {
    address kuru = makeAddr("kuruMarket");
    bytes32 k10;
    IOptionToken t10;

    function setUp() public override {
        super.setUp();
        k10 = _monCall(10 * WAD, 5 * WAD);
        t10 = _token(k10);
    }

    /// Venue trade: seller's tokens go to buyer, buyer's stablecoin to seller, entirely outside Optara.
    function _kuruTrade(address seller, address buyer, uint256 qty, uint256 price) internal {
        vm.prank(seller);
        t10.transfer(kuru, qty);
        vm.prank(kuru);
        t10.transfer(buyer, qty);
        usdt.mint(buyer, price);
        vm.prank(buyer);
        usdt.transfer(seller, price);
    }

    /// FLW-001: deposit -> write -> hold -> expiry -> sync.
    function test_FLW_001_writeHoldSync() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _finalizeMon(k10, 8 * WAD);
        core.syncRiskGroup(alice, _groupOf(k10));
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
        assertEq(core.freeCollateral(alice, address(usdt)), 5e6);
    }

    /// FLW-002 / USER_FLOWS.md section 47: write -> Kuru sell -> resell -> final holder redeems.
    function test_FLW_002_006_kuruSellResellRedeem() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _kuruTrade(alice, bob, WAD, 0.7e6);
        assertEq(core.cashBalance(alice, address(usdt)), 5e6); // premium not Optara margin
        assertEq(core.positionOf(alice, k10).shortQty, WAD); // short stays with alice
        vm.prank(bob);
        t10.transfer(dave, WAD); // FLW-006 resale
        _finalizeMon(k10, 14 * WAD);
        vm.prank(dave);
        assertEq(core.redeem(k10, WAD, dave), 4e6);
        core.syncRiskGroup(alice, _groupOf(k10));
        assertEq(core.cashBalance(alice, address(usdt)), 1e6);
    }

    /// FLW-003: premium deposited back becomes free and withdrawable.
    function test_FLW_003_premiumDepositWithdraw() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _kuruTrade(alice, bob, WAD, 0.7e6);
        vm.startPrank(alice);
        usdt.approve(address(core), 0.7e6);
        core.deposit(address(usdt), 0.7e6);
        assertEq(core.freeCollateral(alice, address(usdt)), 0.7e6);
        core.withdraw(address(usdt), 0.7e6, alice);
        vm.stopPrank();
    }

    /// FLW-004: Kuru buyback then close releases margin.
    function test_FLW_004_buybackClose() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _kuruTrade(alice, bob, WAD, 0.7e6);
        vm.prank(bob);
        t10.transfer(alice, WAD);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        vm.prank(alice);
        core.withdraw(address(usdt), 5e6, alice);
    }

    /// FLW-005: acquire hedge -> lock -> margin release -> atomic expiry sync (USER_FLOWS.md sections 14-24).
    function test_FLW_005_hedgeLockReleaseAtomicSync() public {
        bytes32 k12 = _monCall(12 * WAD, 3 * WAD);
        _deposit(carol, usdt, 3e6);
        _write(carol, k12, WAD);
        IOptionToken t12 = _token(k12);
        vm.prank(carol);
        t12.transfer(alice, WAD);
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _lock(alice, k12, WAD);
        assertEq(core.freeCollateral(alice, address(usdt)), 3e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 3e6, alice);
        _finalizeMon(k10, 20 * WAD);
        core.syncRiskGroup(alice, _groupOf(k10));
        assertEq(core.cashBalance(alice, address(usdt)), 0);
    }

    /// FLW-007: long stays external until after finalization, then transfers and redeems.
    function test_FLW_007_transferAfterFinalization() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _finalizeMon(k10, 12 * WAD);
        vm.prank(alice);
        t10.transfer(bob, WAD);
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 2e6);
    }

    /// FLW-008 / INV-KURU-04: Kuru "outage" (no venue at all) does not affect settlement.
    function test_FLW_008_kuruOutageSettlementWorks() public {
        _deposit(alice, usdt, 5e6);
        vm.prank(alice);
        core.write(k10, WAD, bob);
        vm.etch(kuru, hex"fe"); // venue contract broken
        _finalizeMon(k10, 13 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        core.syncRiskGroup(alice, _groupOf(k10));
        assertEq(core.cashBalance(alice, address(usdt)), 2e6);
    }

    /// FLW-009: two stablecoins in one account stay isolated.
    function test_FLW_009_twoStablecoinsIsolated() public {
        bytes32 eth =
            _createSeries(ETH, address(usdc), OptionType.CALL, 3000 * WAD, 20 * WAD, WAD, expiry1, ethUsdcConfig);
        _deposit(alice, usdt, 1000e6);
        _deposit(alice, usdc, 20e6);
        _write(alice, k10, WAD);
        _write(alice, eth, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        assertEq(core.requiredMargin(alice, address(usdc)), 20e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 995e6, alice);
        assertEq(core.freeCollateral(alice, address(usdc)), 0);
    }

    /// FLW-010: multiple risk groups in the same stablecoin sum.
    function test_FLW_010_multipleGroupsSum() public {
        bytes32 later =
            _createSeries(MON, address(usdt), OptionType.PUT, 10 * WAD, 4 * WAD, WAD, expiry2, monUsdtConfig);
        _deposit(alice, usdt, 9e6);
        _write(alice, k10, WAD);
        _write(alice, later, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 9e6);
        assertEq(core.accountGroups(alice).length, 2);
    }

    /// SAL-001 / INV-SALE-01: already-minted inventory is sold with payment and delivery in one transaction; if
    /// either leg fails, neither happens.
    function test_SAL_001_atomicInventorySale() public {
        AtomicSwap venue = new AtomicSwap();
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        vm.prank(alice);
        t10.approve(address(venue), WAD);
        usdt.mint(bob, 0.7e6);
        vm.startPrank(bob);
        usdt.approve(address(venue), 0.5e6); // insufficient payment allowance -> whole swap reverts
        vm.expectRevert();
        venue.swap(t10, alice, WAD, usdt, 0.7e6);
        assertEq(t10.balanceOf(alice), WAD);
        usdt.approve(address(venue), 0.7e6);
        venue.swap(t10, alice, WAD, usdt, 0.7e6);
        vm.stopPrank();
        assertEq(t10.balanceOf(bob), WAD);
        assertEq(usdt.balanceOf(alice), 0.7e6);
        assertEq(core.positionOf(alice, k10).shortQty, WAD); // the short never moves with the long
    }

    // ------------------------------------------------------------------ STM
    /// STM-001..004: series and group lifecycle is one-way.
    function test_STM_001_to_004_seriesLifecycle() public {
        assertEq(uint8(core.seriesStatus(keccak256("none"))), uint8(SeriesStatus.NONE));
        assertEq(uint8(core.seriesStatus(k10)), uint8(SeriesStatus.ACTIVE)); // STM-001
        vm.warp(expiry1);
        assertEq(uint8(core.seriesStatus(k10)), uint8(SeriesStatus.EXPIRED_UNSETTLED)); // STM-002
        vm.warp(expiry1 - 1);
        _finalizeMon(k10, 11 * WAD);
        assertEq(uint8(core.seriesStatus(k10)), uint8(SeriesStatus.SETTLED)); // STM-003
        vm.warp(expiry1 - 100); // even if chain time were earlier, finalized stays finalized
        assertEq(uint8(core.seriesStatus(k10)), uint8(SeriesStatus.SETTLED)); // STM-004
    }

    /// STM-005..008: account position lifecycle.
    function test_STM_005_to_008_accountLifecycle() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, WAD);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL); // STM-005 active -> closed
        assertEq(core.accountGroups(alice).length, 0);
        _write(alice, k10, WAD);
        vm.warp(expiry1); // STM-006 active -> matured
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        vm.warp(expiry1 - 1);
        _finalizeMon(k10, 12 * WAD);
        assertTrue(core.syncRiskGroup(alice, _groupOf(k10))); // STM-007
        assertFalse(core.syncRiskGroup(alice, _groupOf(k10))); // STM-008 synced cannot reapply
        assertEq(core.cashBalance(alice, address(usdt)), 8e6);
    }

    /// STM-009..016: long-token lifecycle; terminal quantities never reappear.
    function test_STM_009_to_016_longLifecycle() public {
        _deposit(alice, usdt, 20e6);
        _write(alice, k10, 4 * WAD);
        _lock(alice, k10, 2 * WAD); // STM-009 external -> locked
        _deposit(alice, usdt, 5e6);
        vm.prank(alice);
        core.unlockLong(k10, WAD, alice); // STM-010 locked -> external
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL); // STM-012 external -> consumed by close
        vm.prank(alice);
        t10.transfer(bob, WAD);
        _finalizeMon(k10, 13 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob); // STM-013 external settled -> redeemed
        core.syncRiskGroup(alice, _groupOf(k10)); // STM-011 locked -> consumed at settlement
        SeriesState memory st = core.getSeriesState(k10);
        assertEq(st.minted, 4 * WAD);
        assertEq(st.closed, WAD); // STM-015
        assertEq(st.redeemed, WAD); // STM-014
        assertEq(st.hedgeConsumed, WAD); // STM-016
        assertEq(t10.totalSupply(), WAD); // the one wallet unit still redeemable
        assertEq(st.closed + st.redeemed + st.hedgeConsumed + t10.totalSupply(), st.minted);
        assertEq(st.closed + st.shortSynced + st.openShortQty, st.minted);
    }
}
