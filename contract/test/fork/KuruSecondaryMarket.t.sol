// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./KuruForkBase.sol";
import {CloseSource} from "../../src/libraries/OptaraTypes.sol";
import {IOptaraCoreErrors} from "../../src/interfaces/IOptaraCore.sol";

interface IKuruEmergency {
    function emergency() external view returns (address);
}

/// @notice Optara long tokens traded on the REAL Kuru Spot V2 contracts (Monad testnet fork). Proves the venue
///         boundary of PROTOCOL_SPEC.md sections 12-13/25 and KURU_INTEGRATION.md against Kuru's actual matching,
///         custody (AccountCore), fees, notional limits, slippage checks and pause controls:
///         - Kuru balances are never Optara margin, hedges or closes;
///         - premium becomes margin only after an actual Optara deposit;
///         - a buyer redeems only tokens withdrawn from Kuru custody;
///         - buy-to-close needs the Optara close/cancel after the fill;
///         - Optara never depends on Kuru being live.
/// Numbers: 1 option = 1 MON, call K=10 C=5, so 5 USDC margin per option; fees 0.07% taker / 0.04% maker in USDC.
contract KuruSecondaryMarketTest is KuruForkBase {
    uint256 constant Q = 20 * WAD; // 20 options
    uint256 constant ASK = 1_250_000; // 1.25 USDC per option -> 25 USDC notional

    function _fee(uint256 notional, uint256 pps) internal pure returns (uint256) {
        return notional * pps / PPS;
    }

    /// alice writes `Q` on Optara (100 USDC margin), lists them on Kuru at 1.25; bob takes them.
    function _writeListAndSell() internal {
        _writeOnOptara(alice, Q, 100e6);
        _kuruDeposit(alice, address(opt), Q);
        _place(alice, KuruTestnet.SELL, Q, ASK, KuruTestnet.GTC);
        _kuruDeposit(bob, address(usdc), 100e6);
        _place(bob, KuruTestnet.BUY, Q, ASK, KuruTestnet.IOC);
    }

    /// The official market for a series: verified by Kuru's Router and AccountCore, settled in the same AccountCore,
    /// base = the series' option token, quote = the series' settlement asset (KI-INV-08/09).
    function _isOfficialMarket(address market, bytes32 id) internal view returns (bool) {
        Series memory s = core.getSeries(id);
        IKuruOrderBook m = IKuruOrderBook(market);
        return router.verifiedSpotMarket(market) && kuru.verifiedSpotOrderBook(market)
            && m.spotBalanceAccountAddress() == address(kuru) && m.baseToken() == s.optionToken
            && m.quoteToken() == s.settlementAsset && kuru.spotOrderBookToBaseToken(market) == s.optionToken
            && kuru.spotOrderBookToQuoteToken(market) == s.settlementAsset;
    }

    // =============================================================================================

    /// KUR-001/002/004: the listed market binds exactly OPTION/settlement-asset; an OPTION/WETH market can be listed on
    /// Kuru, so the integration must check the quote itself.
    function test_KUR_001_002_004_forkMarketBindsSeries() public {
        assertTrue(_isOfficialMarket(address(book), seriesId));
        (uint32 pp, uint96 sp,, uint96 minQ,, uint256 tf, uint256 mf) = book.getMarketParams();
        assertEq(pp, PRICE_PRECISION);
        assertEq(sp, SIZE_PRECISION);
        assertEq(book.baseSizeMultiplier(), 1e14, "1 size unit = 0.0001 option");
        assertEq(minQ, MIN_QUOTE);
        assertEq(tf, TAKER_FEE_PPS);
        assertEq(mf, MAKER_FEE_PPS);
        address wethMarket = _deployMarket(address(opt), KuruTestnet.WETH);
        assertTrue(router.verifiedSpotMarket(wethMarket), "Kuru accepts the listing");
        assertFalse(_isOfficialMarket(wethMarket, seriesId), "but it is not the series' official market");
    }

    /// KUR-007: sell flow. Premium lands in Kuru custody, not Optara; it becomes margin only after a real deposit.
    function test_KUR_007_forkWriteListSellPremiumOutsideOptara() public {
        _writeListAndSell();
        uint256 notional = 25e6;
        assertEq(kuru.getBalance(bob, address(opt)), Q, "buyer holds the longs inside Kuru");
        assertEq(kuru.getBalance(bob, address(usdc)), 100e6 - notional - _fee(notional, TAKER_FEE_PPS));
        assertEq(kuru.getBalance(alice, address(usdc)), notional - _fee(notional, MAKER_FEE_PPS), "premium on Kuru");
        assertEq(opt.balanceOf(address(kuru)), Q, "Kuru AccountCore custodies the tokens");
        // Optara is untouched by the trade
        assertEq(core.positionOf(alice, seriesId).shortQty, Q);
        assertEq(core.cashBalance(alice, address(usdc)), 100e6);
        assertEq(core.requiredMargin(alice, address(usdc)), 100e6);
        assertEq(core.freeCollateral(alice, address(usdc)), 0, "premium is not free collateral");
        assertEq(core.positionOf(bob, seriesId).lockedQty, 0, "a Kuru balance is not an Optara hedge");
        assertEq(opt.totalSupply(), Q);
        assertEq(usdc.balanceOf(address(core)), 100e6);
        // premium becomes margin only via withdraw from Kuru + deposit into Optara
        uint256 premium = kuru.getBalance(alice, address(usdc));
        _kuruWithdraw(alice, address(usdc), premium);
        vm.startPrank(alice);
        usdc.approve(address(core), premium);
        core.deposit(address(usdc), premium);
        vm.stopPrank();
        assertEq(core.freeCollateral(alice, address(usdc)), premium);
    }

    /// KUR-006: buy flow. A long still inside Kuru cannot be redeemed; withdrawn, it redeems the exact payoff.
    function test_KUR_006_forkBuyerWithdrawsAndRedeems() public {
        _writeListAndSell();
        _finalize(13 * WAD); // payoff 3 per option
        vm.prank(bob);
        vm.expectRevert(); // tokens are in Kuru custody, not in bob's wallet
        core.redeem(seriesId, Q, bob);
        _kuruWithdraw(bob, address(opt), Q);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        assertEq(core.redeem(seriesId, Q, bob), 60e6);
        assertEq(usdc.balanceOf(bob) - before, 60e6, "venue fees never reduce the Optara payout");
        core.syncRiskGroup(alice, groupId);
        assertEq(core.cashBalance(alice, address(usdc)), 40e6);
        vm.prank(alice);
        core.withdraw(address(usdc), 40e6, alice);
        assertEq(usdc.balanceOf(address(core)), 0, "Optara vault fully settled");
        assertEq(opt.totalSupply(), 0);
    }

    /// KUR-008/010: buy-to-close. The Kuru fill closes nothing; the short closes only when Optara burns the long.
    function test_KUR_008_010_forkBuyToCloseNeedsOptaraClose() public {
        _writeListAndSell();
        _place(bob, KuruTestnet.SELL, Q, 1_100_000, KuruTestnet.GTC); // bob relists at 1.10
        _place(alice, KuruTestnet.BUY, Q, 1_100_000, KuruTestnet.IOC); // alice buys back with her premium
        assertEq(kuru.getBalance(alice, address(opt)), Q);
        // KUR-010: after the fill, Optara still holds the full obligation
        assertEq(core.positionOf(alice, seriesId).shortQty, Q, "a fill is not a close");
        assertEq(core.requiredMargin(alice, address(usdc)), 100e6);
        vm.prank(alice);
        vm.expectRevert(); // the long is still in Kuru custody
        core.closeShort(seriesId, Q, CloseSource.EXTERNAL);
        // KUR-008: withdraw from Kuru, close in Optara
        _kuruWithdraw(alice, address(opt), Q);
        vm.prank(alice);
        core.closeShort(seriesId, Q, CloseSource.EXTERNAL);
        assertEq(core.positionOf(alice, seriesId).shortQty, 0);
        assertEq(core.requiredMargin(alice, address(usdc)), 0);
        assertEq(core.freeCollateral(alice, address(usdc)), 100e6, "all margin released");
        assertEq(opt.totalSupply(), 0);
        // premium 25 - 0.01 maker fee - buyback 22 - 0.0154 taker fee stays on Kuru as alice's profit
        assertEq(kuru.getBalance(alice, address(usdc)), 25e6 - 10_000 - 22e6 - 15_400);
    }

    /// KUR-009: Kuru enforces the taker's limits: slippage floor on swaps, fill-or-kill, and swap deadlines.
    function test_KUR_009_forkSlippageAndFillLimitsEnforced() public {
        _writeOnOptara(alice, Q, 100e6);
        _kuruDeposit(alice, address(opt), Q);
        _place(alice, KuruTestnet.SELL, Q, ASK, KuruTestnet.GTC);
        _kuruDeposit(bob, address(usdc), 100e6);
        uint128 budget = 12_508_750; // 12.5 USDC + 0.07%: about 10 options
        SwapResult memory est = book.estimateSwap(true, budget);
        assertGt(est.amountOut, 0);
        vm.startPrank(bob);
        vm.expectRevert();
        book.swap(0, true, budget, est.amountOut + 1, uint64(block.timestamp + 60)); // slippage floor violated
        vm.expectRevert();
        book.swap(0, true, budget, est.amountOut, uint64(block.timestamp - 1)); // expired deadline
        SwapResult memory got = book.swap(0, true, budget, est.amountOut, uint64(block.timestamp + 60));
        vm.stopPrank();
        assertEq(got.amountOut, est.amountOut);
        assertEq(kuru.getBalance(bob, address(opt)), est.amountOut);
        // fill-or-kill for more than the book holds reverts as a whole
        NativeOrder[] memory fok = _order(KuruTestnet.BUY, 30 * WAD, ASK, KuruTestnet.FOK);
        vm.prank(bob);
        vm.expectRevert();
        book.batch(0, fok, new uint8[](0));
    }

    /// KUR-011: Kuru frozen by its emergency role. Every Optara path keeps working; only longs parked in Kuru wait.
    function test_KUR_011_forkKuruOutageOptaraUnaffected() public {
        _writeOnOptara(alice, 30 * WAD, 150e6); // 20 go to Kuru, 10 stay in her wallet
        _kuruDeposit(alice, address(opt), Q);
        _place(alice, KuruTestnet.SELL, Q, ASK, KuruTestnet.GTC);
        _kuruDeposit(bob, address(usdc), 100e6);
        _place(bob, KuruTestnet.BUY, Q, ASK, KuruTestnet.IOC);

        address emergency = IKuruEmergency(KuruTestnet.PROTOCOL_AUTHORITY).emergency();
        address[] memory markets = new address[](1);
        markets[0] = address(book);
        vm.startPrank(emergency);
        kuru.toggleProtocolState(true);
        router.toggleSpotMarkets(markets, 2); // HARD_PAUSED
        vm.stopPrank();
        assertTrue(kuru.protocolPaused());
        vm.prank(bob);
        vm.expectRevert();
        kuru.withdraw(address(opt), Q); // venue custody frozen

        // Optara: close, lock, withdraw, finalize and sync all work during the outage
        vm.startPrank(alice);
        core.closeShort(seriesId, 5 * WAD, CloseSource.EXTERNAL);
        opt.approve(address(core), 5 * WAD);
        core.lockLong(seriesId, 5 * WAD);
        core.withdraw(address(usdc), 25e6, alice); // 25 short - 5 locked identical longs = 20 net * 5 = 100 required
        vm.stopPrank();
        _finalize(13 * WAD);
        core.syncRiskGroup(alice, groupId); // short 25 * 3 = 75 debit, locked 5 * 3 = 15 credit
        assertEq(core.cashBalance(alice, address(usdc)), 125e6 - 60e6);
        assertEq(opt.balanceOf(address(kuru)), Q, "bob's longs are the only thing waiting on Kuru");

        vm.prank(emergency);
        vm.expectRevert(); // Kuru's emergency role can pause but not unpause (same split as Optara's pauser)
        kuru.toggleProtocolState(false);
        vm.prank(kuruGov);
        kuru.toggleProtocolState(false);
        _kuruWithdraw(bob, address(opt), Q);
        vm.prank(bob);
        assertEq(core.redeem(seriesId, Q, bob), 60e6, "claim fully backed after the outage");
        assertEq(usdc.balanceOf(address(core)), core.cashBalance(alice, address(usdc)), "vault == remaining claims");
    }

    /// KUR-015: a buy-back that lands after expiry but before finalization maps to cancelUnfinalizedShort.
    function test_KUR_015_forkBuyToCloseAcrossExpiry() public {
        _writeListAndSell();
        vm.warp(expiry + 1 hours); // expired, not finalized; Kuru keeps trading the token
        _place(bob, KuruTestnet.SELL, Q, 500_000, KuruTestnet.GTC); // 0.50 * 20 = 10 USDC, the minimum notional
        _place(alice, KuruTestnet.BUY, Q, 500_000, KuruTestnet.IOC);
        _kuruWithdraw(alice, address(opt), Q);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, seriesId));
        core.closeShort(seriesId, Q, CloseSource.EXTERNAL);
        core.cancelUnfinalizedShort(seriesId, Q, CloseSource.EXTERNAL);
        core.withdraw(address(usdc), 100e6, alice); // no price needed to release the reservation
        vm.stopPrank();
        assertEq(core.positionOf(alice, seriesId).shortQty, 0);
        assertEq(opt.totalSupply(), 0);
    }

    /// Settled longs keep trading on Kuru; whoever withdraws them redeems the fixed payoff.
    function test_KUR_006_forkSettledLongTradesAndRedeems() public {
        _writeListAndSell();
        _finalize(13 * WAD);
        _place(bob, KuruTestnet.SELL, Q, 2_950_000, KuruTestnet.GTC); // bob sells his 3-USDC claims at 2.95
        _kuruDeposit(carol, address(usdc), 100e6);
        _place(carol, KuruTestnet.BUY, Q, 2_950_000, KuruTestnet.IOC);
        _kuruWithdraw(carol, address(opt), Q);
        vm.prank(carol);
        assertEq(core.redeem(seriesId, Q, carol), 60e6);
    }

    /// Kuru's minimum quote notional (10 USDC on the canonical config) bounds the smallest ticket.
    function test_KUR_007_forkMinimumNotionalBoundsTicketSize() public {
        _writeOnOptara(alice, Q, 100e6);
        _kuruDeposit(alice, address(opt), Q);
        NativeOrder[] memory small = _order(KuruTestnet.SELL, 5 * WAD, ASK, KuruTestnet.GTC); // 6.25 USDC
        vm.prank(alice);
        vm.expectRevert();
        book.batch(0, small, new uint8[](0));
        _place(alice, KuruTestnet.SELL, 8 * WAD, ASK, KuruTestnet.GTC); // exactly 10 USDC
        (, uint32 ask) = book.bestBidAsk();
        assertEq(ask, _price(ASK));
    }

    /// P-5 / INV-HEDGE: a long locked as an Optara hedge cannot also be listed on Kuru.
    function test_KUR_012_forkLockedHedgeCannotBeListed() public {
        _writeOnOptara(alice, Q, 100e6);
        vm.startPrank(alice);
        opt.approve(address(core), Q);
        core.lockLong(seriesId, Q); // identical long hedges the short: requirement 0
        assertEq(core.requiredMargin(alice, address(usdc)), 0);
        opt.approve(address(kuru), 1);
        vm.expectRevert();
        kuru.deposit(address(opt), 1); // nothing left in the wallet
        core.unlockLong(seriesId, Q, alice); // back to 100 USDC requirement, fully covered
        vm.stopPrank();
        _kuruDeposit(alice, address(opt), Q);
        assertEq(kuru.getBalance(alice, address(opt)), Q);
        assertEq(core.requiredMargin(alice, address(usdc)), 100e6);
    }
}
