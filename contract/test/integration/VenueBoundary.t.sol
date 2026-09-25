// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {MockVenue} from "../mocks/MockVenue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The Optara/venue accounting boundary at contract level (PROTOCOL_SPEC.md sections 12-13, 25;
///         KURU_INTEGRATION.md). TEST_CASES.md KUR-006/007/008/010/011/012 and INV-013 test what the CORE must
///         guarantee for these workflows; the optara-kuru package tests its own orchestration (slippage UX,
///         order routing) in the SDK repo. Also FEE-002, INV-014 and RSK-023.
contract VenueBoundaryTest is OptaraTestBase {
    MockVenue venue;
    bytes32 k10;
    bytes32 grp;
    IOptionToken t10;

    function setUp() public override {
        super.setUp();
        venue = new MockVenue();
        venue.setFeeBps(100); // 1% taker fee, charged by the venue in the quote stablecoin
        k10 = _monCall(10 * WAD, 5 * WAD);
        grp = _groupOf(k10);
        t10 = _token(k10);
    }

    function _toVenue(address who, IERC20 token, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(venue), amount);
        venue.depositMargin(token, amount);
        vm.stopPrank();
    }

    function _fromVenue(address who, IERC20 token, uint256 amount) internal {
        vm.prank(who);
        venue.withdrawMargin(token, amount);
    }

    /// alice writes 1 k10 and lists it on the venue; bob buys it at `price` (plus the venue fee).
    function _writeAndSell(uint256 price) internal {
        _deposit(alice, usdt, 5e6);
        vm.prank(alice);
        core.write(k10, WAD, alice);
        _toVenue(alice, IERC20(address(t10)), WAD);
        usdt.mint(bob, 10e6);
        _toVenue(bob, IERC20(address(usdt)), 10e6);
        vm.prank(bob);
        venue.fill(alice, IERC20(address(t10)), IERC20(address(usdt)), WAD, price, type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------

    /// KUR-006: buying on the venue moves only venue balances; Optara's claim and the writer's obligation are unchanged.
    function test_KUR_006_buyOptionWorkflow() public {
        _writeAndSell(1e6);
        assertEq(venue.marginBalance(bob, address(t10)), WAD, "buyer holds the long inside the venue");
        assertEq(t10.balanceOf(address(venue)), WAD);
        assertEq(core.positionOf(alice, k10).shortQty, WAD, "the short is untouched");
        assertEq(core.positionOf(bob, k10).shortQty, 0);
        assertEq(core.cashBalance(bob, address(usdt)), 0, "premium paid on the venue is not Optara cash");
        // the buyer withdraws the long and holds a standard redeemable claim
        _fromVenue(bob, IERC20(address(t10)), WAD);
        _finalizeMon(k10, 13 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 3e6);
    }

    /// KUR-007: premium stays a venue balance and becomes margin only after an actual Optara deposit.
    function test_KUR_007_sellOptionWorkflow() public {
        _writeAndSell(12e5);
        assertEq(venue.marginBalance(alice, address(usdt)), 12e5, "premium credited inside the venue");
        assertEq(core.cashBalance(alice, address(usdt)), 5e6, "Optara cash unchanged by the sale");
        assertEq(core.freeCollateral(alice, address(usdt)), 0, "premium is not free collateral");
        _fromVenue(alice, IERC20(address(usdt)), 12e5);
        vm.startPrank(alice);
        usdt.approve(address(core), 12e5);
        core.deposit(address(usdt), 12e5);
        vm.stopPrank();
        assertEq(core.cashBalance(alice, address(usdt)), 62e5);
        assertEq(core.freeCollateral(alice, address(usdt)), 12e5, "margin only after the Optara deposit");
    }

    /// KUR-008 / KUR-010: a buy-back fill does not close anything; the short closes only when Optara consumes the long.
    function test_KUR_008_010_buyToCloseNeedsOptaraClose() public {
        _writeAndSell(1e6);
        // alice buys the option back on the venue
        usdt.mint(alice, 2e6);
        _toVenue(alice, IERC20(address(usdt)), 2e6);
        _toVenue(bob, IERC20(address(t10)), 0); // no-op deposit keeps bob's venue balance as is
        vm.prank(alice);
        venue.fill(bob, IERC20(address(t10)), IERC20(address(usdt)), WAD, 11e5, 2e6);
        assertEq(venue.marginBalance(alice, address(t10)), WAD);
        // KUR-010: the fill alone changed nothing in Optara
        assertEq(core.positionOf(alice, k10).shortQty, WAD, "fill is not a close");
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        vm.prank(alice);
        vm.expectRevert(); // the long is still in the venue: EXTERNAL close cannot burn it from alice's wallet
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        // KUR-008: withdraw from the venue, then close in Optara
        _fromVenue(alice, IERC20(address(t10)), WAD);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(core.positionOf(alice, k10).shortQty, 0);
        assertEq(core.requiredMargin(alice, address(usdt)), 0);
        assertEq(core.freeCollateral(alice, address(usdt)), 5e6);
        assertEq(t10.totalSupply(), 0);
    }

    /// KUR-011: a venue outage never blocks Optara close, lock, withdrawal, finalization, sync or redemption.
    function test_KUR_011_venueOutageHandledCleanly() public {
        _deposit(alice, usdt, 10e6);
        vm.prank(alice);
        core.write(k10, 2 * WAD, alice);
        vm.prank(alice);
        t10.transfer(bob, WAD);
        venue.setHalted(true);
        vm.expectRevert(MockVenue.VenueHalted.selector);
        venue.depositMargin(IERC20(address(usdt)), 1);
        vm.startPrank(alice);
        core.closeShort(k10, 5e17, CloseSource.EXTERNAL);
        t10.approve(address(core), 5e17);
        core.lockLong(k10, 5e17);
        core.withdraw(address(usdt), 1e6, alice);
        vm.stopPrank();
        _finalizeMon(k10, 13 * WAD);
        core.syncRiskGroup(alice, grp);
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 3e6);
        assertTrue(venue.halted(), "all of the above ran during the outage");
    }

    /// KUR-012 / INV-013: venue balances (stablecoins or longs) never appear as Optara cash, margin or hedge credit.
    function test_KUR_012_INV_013_venueBalanceExcludedFromMargin() public {
        usdt.mint(alice, 50e6);
        _toVenue(alice, IERC20(address(usdt)), 50e6);
        assertEq(core.cashBalance(alice, address(usdt)), 0);
        assertEq(core.freeCollateral(alice, address(usdt)), 0);
        assertEq(core.additionalCollateralForWrite(alice, k10, WAD), 5e6, "preview ignores the venue balance");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 0));
        core.write(k10, WAD, alice);
        // a long parked in the venue is not a locked hedge either
        _deposit(carol, usdt, 5e6);
        vm.prank(carol);
        core.write(k10, WAD, carol);
        _toVenue(carol, IERC20(address(t10)), WAD);
        assertEq(core.requiredMargin(carol, address(usdt)), 5e6, "venue-held long gives no margin relief");
        assertEq(core.positionOf(carol, k10).lockedQty, 0);
        assertEq(core.accountRiskState(carol, address(usdt)).cash, 5e6);
    }

    /// FEE-002: the venue's trading fee never changes the Optara payout of the long.
    function test_FEE_002_venueFeeDoesNotChangePayout() public {
        venue.setFeeBps(500); // 5%
        _writeAndSell(1e6);
        assertEq(venue.feesCollected(), 5e4, "the venue kept its fee");
        _fromVenue(bob, IERC20(address(t10)), WAD);
        // dave receives an identical long directly (no venue)
        _deposit(carol, usdt, 5e6);
        vm.prank(carol);
        core.write(k10, WAD, dave);
        _finalizeMon(k10, 14 * WAD);
        vm.prank(bob);
        uint256 viaVenue = core.redeem(k10, WAD, bob);
        vm.prank(dave);
        uint256 direct = core.redeem(k10, WAD, dave);
        assertEq(viaVenue, 4e6);
        assertEq(viaVenue, direct, "same contractual payout regardless of venue fees");
    }

    /// INV-014: client/SDK previews are pure reads (no storage write), and a stale preview cannot bypass execution.
    function test_INV_014_clientStateCannotAlterContracts() public {
        _deposit(alice, usdt, 5e6);
        vm.record();
        core.requiredMargin(alice, address(usdt));
        core.effectiveCash(alice, address(usdt));
        core.freeCollateral(alice, address(usdt));
        core.maxWithdrawable(alice, address(usdt));
        core.deficit(alice, address(usdt));
        core.accountRiskState(alice, address(usdt));
        core.requiredMarginAfter(alice, k10, int256(WAD), 0);
        uint256 extra = core.additionalCollateralForWrite(alice, k10, WAD);
        core.seriesStatus(k10);
        core.isOracleStalled(grp);
        core.worstCaseLossNumerator(alice, grp);
        (, bytes32[] memory writes) = vm.accesses(address(core));
        assertEq(writes.length, 0, "previews never write state");
        assertEq(extra, 0, "preview says the write fits");
        // state changes after the preview: the stale preview is not honoured
        vm.prank(alice);
        core.withdraw(address(usdt), 1, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 5e6 - 1));
        core.write(k10, WAD, alice);
    }

    /// RSK-023: a group at the configured maximum (16 series, every leg short and hedged) stays executable end to
    /// end: margin, lock, LOCKED close, post-expiry cancellation, finalization, sync, redemption and withdrawal.
    function test_RSK_023_maxConfiguredSeriesPerGroupRemainsExecutable() public {
        vm.prank(gov);
        config.setPositionLimits(16, 16, 64);
        bytes32[] memory ids = new bytes32[](16);
        ids[0] = k10;
        for (uint256 i = 1; i < 16; ++i) {
            ids[i] = _createSeries(
                MON,
                address(usdt),
                i % 2 == 0 ? OptionType.CALL : OptionType.PUT,
                (6 + i) * WAD + WAD / 2, // half-integer strikes never collide with k10 (duplicates are rejected)
                (1 + i % 5) * WAD,
                i % 3 == 0 ? WAD / 2 : WAD,
                expiry1,
                monUsdtConfig
            );
        }
        _deposit(alice, usdt, 1_000e6);
        _deposit(carol, usdt, 1_000e6);
        for (uint256 i = 0; i < 16; ++i) {
            _write(alice, ids[i], WAD);
            _write(carol, ids[i], WAD);
            IOptionToken t = _token(ids[i]);
            vm.prank(carol);
            t.transfer(alice, WAD);
            _lock(alice, ids[i], WAD / 2);
        }
        assertEq(core.accountGroupSeries(alice, grp).length, 16);
        uint256 budget = 30_000_000;
        uint256 g0 = gasleft();
        vm.prank(alice);
        core.closeShort(ids[1], WAD / 4, CloseSource.LOCKED);
        assertLt(g0 - gasleft(), budget, "LOCKED close at max");
        vm.warp(expiry1 + 1);
        g0 = gasleft();
        vm.prank(alice);
        core.cancelUnfinalizedShort(ids[2], WAD / 4, CloseSource.EXTERNAL);
        assertLt(g0 - gasleft(), budget, "cancellation at max");
        g0 = gasleft();
        vm.prank(alice);
        core.unlockLong(ids[3], 1, alice);
        assertLt(g0 - gasleft(), budget, "unlock at max");
        _finalizeMon(k10, 13 * WAD);
        g0 = gasleft();
        assertTrue(core.syncRiskGroup(alice, grp));
        assertLt(g0 - gasleft(), budget, "sync at max");
        core.syncRiskGroup(carol, grp);
        assertEq(core.accountSeriesCount(alice), 0);
        for (uint256 i = 0; i < 16; ++i) {
            uint256 bal = _token(ids[i]).balanceOf(alice);
            if (bal > 0) {
                vm.prank(alice);
                core.redeem(ids[i], bal, alice);
            }
        }
        uint256 free = core.freeCollateral(alice, address(usdt));
        vm.prank(alice);
        core.withdraw(address(usdt), free, alice);
        assertEq(core.cashBalance(alice, address(usdt)), 0);
    }
}
