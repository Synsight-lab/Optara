// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OptionSeriesFactory} from "../src/OptionSeriesFactory.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {VaultDeployer} from "../src/VaultDeployer.sol";
import {PremiumExecutionGuard} from "../src/PremiumExecutionGuard.sol";
import {IVaultDeployer} from "../src/interfaces/IVaultDeployer.sol";
import {IOptionSeriesFactory} from "../src/interfaces/IOptionSeriesFactory.sol";
import {
    OptionType,
    CreateSeriesParams,
    PairConfig,
    FeeConfig,
    EXPIRY_SLOT_OFFSET,
    ADMIN_ROLE,
    PAUSER_ROLE,
    BPS_SCALE
} from "../src/Types.sol";
import "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// The premium guard. Every premium figure is a TOTAL in quote raw units. Expected numbers are worked out by
/// hand in the comments so a change to any rounding direction shows up as a failing exact-integer assertion.
contract GuardTest is Test {
    OptionSeriesFactory internal factory;
    PremiumExecutionGuard internal guard;
    MockERC20 internal mon;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockAggregator internal monFeed;
    MockAggregator internal btcFeed;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal market = makeAddr("kuruMarket");

    OptionSeriesVault internal call; // MON call, strike 10, C = 1e18, exercise fee 25 bps
    OptionSeriesVault internal put; // MON put, strike 10
    bytes32 internal callId;
    bytes32 internal putId;

    uint64 internal expiry;
    uint64 internal feedRound = 1;

    function setUp() public {
        vm.warp(1_700_000_000);
        mon = new MockERC20("Wrapped MON", "WMON", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        monFeed = new MockAggregator(8);
        btcFeed = new MockAggregator(8);
        _price(monFeed, 12e8); // MON at 12.00 USDC
        _price(btcFeed, 55000e8);

        VaultDeployer d = new VaultDeployer();
        factory = new OptionSeriesFactory(admin, IVaultDeployer(address(d)));
        guard = new PremiumExecutionGuard(IOptionSeriesFactory(address(factory)), 100, 3600, 30);

        vm.startPrank(admin);
        factory.setAllowedAsset(address(mon), true);
        factory.setAllowedAsset(address(usdc), true);
        factory.setAllowedAsset(address(wbtc), true);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(monFeed), 3600, 0.5e18));
        factory.setPairConfig(address(wbtc), address(usdc), PairConfig(address(btcFeed), 3600, 100e18));
        factory.setDefaultFeeConfig(FeeConfig(10, 25));
        vm.stopPrank();

        expiry = uint64(((block.timestamp / 1 days) + 3) * 1 days + EXPIRY_SLOT_OFFSET);
        (call, callId) = _create(OptionType.CALL, address(mon), address(monFeed), 10e18);
        (put, putId) = _create(OptionType.PUT, address(mon), address(monFeed), 10e18);
        vm.startPrank(admin);
        factory.setKuruMarket(callId, market);
        factory.setKuruMarket(putId, market);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _price(MockAggregator f, int256 answer8) internal {
        feedRound++;
        f.push((uint80(1) << 64) | uint80(feedRound), answer8, block.timestamp);
    }

    function _create(OptionType t, address underlying, address feed_, uint256 strike)
        internal
        returns (OptionSeriesVault v, bytes32 id)
    {
        (bytes32 seriesId, address vault) = factory.createSeries(
            CreateSeriesParams({
                optionType: t,
                underlying: underlying,
                quote: address(usdc),
                strikePrice: strike,
                expiry: expiry,
                chainlinkFeed: feed_
            })
        );
        return (OptionSeriesVault(vault), seriesId);
    }

    function _buy(bytes32 id, uint256 amount, uint256 gross, uint16 takerBps, uint256 maxTotal)
        internal
        view
        returns (PremiumExecutionGuard.CheckResult memory)
    {
        return guard.checkBuy(
            PremiumExecutionGuard.BuyCheck({
                seriesId: id,
                market: market,
                optionAmount: amount,
                grossPremium: gross,
                takerFeeBps: takerBps,
                buyerMaxTotalPremium: maxTotal,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _sell(bytes32 id, uint256 amount, uint256 gross, uint16 makerBps, bool rebate)
        internal
        view
        returns (PremiumExecutionGuard.CheckResult memory)
    {
        return guard.checkSell(
            PremiumExecutionGuard.SellCheck({
                seriesId: id,
                market: market,
                optionAmount: amount,
                grossPremium: gross,
                makerFeeBps: makerBps,
                makerFeeIsRebate: rebate,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    // ================================================================== exact bounds

    /// CALL, K = 10, R = 12, 5 options, C = 1e18, UQ = 1e30, exercise fee 25 bps, seller tolerance 100 bps.
    ///   intrinsic     = 5 * (12 - 10)         = 10 USDC     = 10_000_000
    ///   hardMaxGross  = 5 * 12                = 60 USDC     = 60_000_000
    ///   hardMax       = 60_000_000 * 9975/10000             = 59_850_000
    ///   acceptableMin = 10_000_000 * 9900/10000             =  9_900_000
    function test_bounds_call_exactIntegers() public view {
        PremiumExecutionGuard.CheckResult memory r = _buy(callId, 5e18, 11e6, 20, 12e6);
        assertEq(r.referencePrice, 12e18);
        assertEq(r.acceptableMinPremium, 9_900_000);
        assertEq(r.hardMaxPremium, 59_850_000);
    }

    /// PUT, K = 10, R = 12: the put is out of the money, so intrinsic is zero.
    ///   hardMaxGross = 5 * K = 50 USDC, hardMax = 50_000_000 * 9975/10000 = 49_875_000
    function test_bounds_put_outOfTheMoney() public view {
        PremiumExecutionGuard.CheckResult memory r = _buy(putId, 5e18, 1e6, 0, 2e6);
        assertEq(r.acceptableMinPremium, 0);
        assertEq(r.hardMaxPremium, 49_875_000);
    }

    /// PUT, K = 10, R = 8, 5 options: intrinsic = 5 * 2 = 10 USDC, min = 9_900_000, hardMax = 49_875_000.
    function test_bounds_put_inTheMoney() public {
        _price(monFeed, 8e8);
        PremiumExecutionGuard.CheckResult memory r = _buy(putId, 5e18, 11e6, 0, 12e6);
        assertEq(r.acceptableMinPremium, 9_900_000);
        assertEq(r.hardMaxPremium, 49_875_000);
    }

    /// PUT, K = 10, R = 8, a = 1e16 + 1 (a non-terminating division), UQ = 1e30, C = 1e18, os = 1e18:
    ///   E = a (exact), intrinsic = ceil((1e16+1) * 2e18 / 1e30) = ceil(20000.000000000002) = 20001
    ///   hardGross = floor((1e16+1) * 10e18 / 1e30) = floor(100000.00000000001) = 100000
    ///   hardMax = floor(100000 * 9975/10000) = 99750
    ///   min = ceil(20001 * 9900/10000) = ceil(19800.99) = 19801
    /// Rounding UP on the minimum and DOWN on the maximum are both visible: 20001 not 20000, 100000 not 100001.
    function test_bounds_nonTerminatingDivisionRoundsTowardRejection() public {
        _price(monFeed, 8e8);
        PremiumExecutionGuard.CheckResult memory r = _buy(putId, 1e16 + 1, 1, 0, 1e6);
        assertEq(r.acceptableMinPremium, 19_801);
        assertEq(r.hardMaxPremium, 99_750);
    }

    /// The two bounds must NOT share one rounded exposure term. WBTC put, 8 dp underlying:
    ///   C = 1e8, os = 1e18, UQ = 1e20, K = 60000, R = 55000, a = 1e16 + 1
    ///   E(a) = (1e16+1) * 1e8 / 1e18 = 1e6 + 1e-10:  E_up = 1_000_001,  E_down = 1_000_000
    ///   intrinsic = ceil(E_up * 5000e18 / 1e20)   = 1_000_001 * 50 = 50_000_050   (uses E_UP)
    ///   min       = ceil(50_000_050 * 9900/10000) = ceil(49_500_049.5) = 49_500_050
    ///   hardGross = floor(E_down * 60000e18 / 1e20) = 1_000_000 * 600 = 600_000_000  (uses E_DOWN)
    ///   hardMax   = floor(600_000_000 * 9975/10000) = 598_500_000
    /// Sharing E_up would give hardGross 600_000_600 and hardMax 598_500_598: a looser ceiling.
    function test_bounds_theTwoBoundsDoNotShareOneRoundedExposure() public {
        (OptionSeriesVault v, bytes32 id) = _create(OptionType.PUT, address(wbtc), address(btcFeed), 60000e18);
        vm.prank(admin);
        factory.setKuruMarket(id, market);
        assertEq(v.contractSize(), 1e8);

        PremiumExecutionGuard.CheckResult memory r = _buy(id, 1e16 + 1, 1, 0, 1e9);
        assertEq(r.acceptableMinPremium, 49_500_050);
        assertEq(r.hardMaxPremium, 598_500_000);
    }

    /// The ceiling is net of the exercise fee; the floor is not.
    function test_bounds_ceilingIsNetOfExerciseFeeAndFloorIsNot() public {
        // a series with a 100 bps exercise fee, otherwise identical
        vm.prank(admin);
        factory.setDefaultFeeConfig(FeeConfig(0, 100));
        (OptionSeriesVault v, bytes32 id) = _create(OptionType.CALL, address(mon), address(monFeed), 10.5e18);
        vm.prank(admin);
        factory.setKuruMarket(id, market);
        assertEq(v.exerciseFeeBps(), 100);

        // K = 10.5, R = 12, 5 options: intrinsic = 7.5 USDC, min = 7_425_000
        //   hardGross = 60 USDC, hardMax = 60_000_000 * 9900/10000 = 59_400_000 (vs 59_850_000 at 25 bps)
        PremiumExecutionGuard.CheckResult memory r = _buy(id, 5e18, 8e6, 0, 9e6);
        assertEq(r.acceptableMinPremium, 7_425_000);
        assertEq(r.hardMaxPremium, 59_400_000);
        // and the 25 bps series has a higher ceiling for the same size
        assertLt(r.hardMaxPremium, _buy(callId, 5e18, 8e6, 0, 9e6).hardMaxPremium);
    }

    /// An ask between the net and the gross ceiling is rejected.
    function test_bounds_askBetweenNetAndGrossCeilingIsRejected() public view {
        // gross ceiling 60_000_000, net ceiling 59_850_000
        PremiumExecutionGuard.CheckResult memory r = _buy(callId, 5e18, 59_900_000, 0, 100e6);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.ABOVE_HARD_MAX));
        r = _buy(callId, 5e18, 59_850_000, 0, 100e6);
        assertTrue(r.valid); // exactly at the net ceiling is allowed
    }

    // ================================================================== buys

    function test_buy_insideTheRangeIsValid() public view {
        // gross 11 USDC, taker fee 20 bps = ceil(22_000) = 22_000, all-in 11_022_000, cap 11.1 USDC
        PremiumExecutionGuard.CheckResult memory r = _buy(callId, 5e18, 11e6, 20, 11_100_000);
        assertTrue(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.OK));
        assertEq(r.allInCost, 11_022_000);
    }

    /// The buyer's limit binds on ALL-IN cost, not on the gross premium.
    function test_buy_limitBindsOnAllInNotGross() public view {
        // gross 11_000_000 is under the 11_010_000 limit, but with the 22_000 fee all-in is 11_022_000, over it
        PremiumExecutionGuard.CheckResult memory r = _buy(callId, 5e18, 11e6, 20, 11_010_000);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.ABOVE_BUYER_LIMIT));
        assertEq(r.allInCost, 11_022_000);
        // and exactly at the limit is allowed
        assertTrue(_buy(callId, 5e18, 11e6, 20, 11_022_000).valid);
    }

    /// A high taker fee cannot make an over-limit trade pass.
    function test_buy_highTakerFeeCannotHideAnOverLimitCost() public view {
        // gross 10 USDC, 30 bps fee -> 30_000, all-in 10_030_000 > limit 10_020_000
        assertFalse(_buy(callId, 5e18, 10e6, 30, 10_020_000).valid);
        assertTrue(_buy(callId, 5e18, 10e6, 30, 10_030_000).valid);
    }

    /// The taker fee estimate rounds UP: a cost bound must never be underestimated.
    function test_buy_takerFeeRoundsUp() public view {
        // gross 10_001, 30 bps: 10_001 * 30 / 10_000 = 30.003 -> ceil = 31 (floor would be 30)
        PremiumExecutionGuard.CheckResult memory r = _buy(callId, 5e18, 10_001, 30, 1e9);
        assertEq(r.allInCost, 10_001 + 31);
    }

    /// Totals, not per-option: the regression test for the unit bug. With 5 options and a 100 USDC total, the
    /// per-option cost is 20 USDC = 20_000_000 raw, which is BELOW the total ceiling of 59_850_000 raw. A check
    /// that compared per-option to a total would pass. The real check compares the total and fails.
    function test_buy_boundsAreComparedAsTotalsNotPerOption() public view {
        uint256 total = 100e6;
        uint256 perOption = total / 5;
        assertLt(perOption, 59_850_000); // the buggy comparison would let this through
        PremiumExecutionGuard.CheckResult memory r = _buy(callId, 5e18, total, 0, 1_000e6);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.ABOVE_HARD_MAX));
    }

    function test_buy_bothBoundsScaleWithSize() public view {
        // 50 options: every total is exactly 10x larger
        PremiumExecutionGuard.CheckResult memory small = _buy(callId, 5e18, 1e6, 0, 1e9);
        PremiumExecutionGuard.CheckResult memory big = _buy(callId, 50e18, 1e6, 0, 1e9);
        assertEq(big.hardMaxPremium, small.hardMaxPremium * 10);
        assertEq(big.acceptableMinPremium, small.acceptableMinPremium * 10);
    }

    // ================================================================== sells

    function test_sell_insideTheRangeIsValid() public view {
        // gross 11 USDC, maker fee 10 bps = ceil(11_000) = 11_000, net 10_989_000 >= min 9_900_000
        PremiumExecutionGuard.CheckResult memory r = _sell(callId, 5e18, 11e6, 10, false);
        assertTrue(r.valid);
        assertEq(r.netProceeds, 10_989_000);
    }

    /// The seller check uses what the seller actually receives, not the headline ask.
    function test_sell_usesNetProceedsNotTheHeadlineAsk() public view {
        // gross 9_900_000 equals the minimum, but a 10 bps fee (9_900) leaves 9_890_100, below it
        PremiumExecutionGuard.CheckResult memory r = _sell(callId, 5e18, 9_900_000, 10, false);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.BELOW_ACCEPTABLE_MIN));
        assertEq(r.netProceeds, 9_890_100);
        // with a zero fee the same ask is exactly at the minimum and passes
        assertTrue(_sell(callId, 5e18, 9_900_000, 0, false).valid);
    }

    /// A maker fee rounds UP (less for the seller); a rebate rounds DOWN (less for the seller). Both lower net.
    function test_sell_makerFeeRoundsUpAndRebateRoundsDown() public view {
        // gross 10_001 at 10 bps: 10.001 -> fee ceil 11, rebate floor 10
        assertEq(_sell(callId, 5e18, 10_001, 10, false).netProceeds, 10_001 - 11);
        assertEq(_sell(callId, 5e18, 10_001, 10, true).netProceeds, 10_001 + 10);
    }

    function test_sell_aRebateCanRescueAnAskThatAFeeWouldSink() public view {
        assertFalse(_sell(callId, 5e18, 9_900_000, 10, false).valid); // fee: 9_890_100 < 9_900_000
        assertTrue(_sell(callId, 5e18, 9_900_000, 10, true).valid); // rebate: 9_909_900 >= 9_900_000
    }

    function test_sell_belowIntrinsicWithToleranceIsFlagged() public view {
        // intrinsic 10 USDC, tolerance 1% -> min 9.9; an ask of 8 USDC is well below
        PremiumExecutionGuard.CheckResult memory r = _sell(callId, 5e18, 8e6, 0, false);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.BELOW_ACCEPTABLE_MIN));
    }

    function test_sell_outOfTheMoneyHasNoFloor() public view {
        // the put is out of the money (R = 12 > K = 10): intrinsic 0, any ask passes the floor
        PremiumExecutionGuard.CheckResult memory r = _sell(putId, 5e18, 1, 0, false);
        assertTrue(r.valid);
        assertEq(r.acceptableMinPremium, 0);
    }

    // ================================================================== common checks, in order

    function test_common_unknownSeries() public view {
        PremiumExecutionGuard.CheckResult memory r = _buy(bytes32(uint256(123)), 5e18, 1e6, 0, 1e9);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.NOT_OFFICIAL_SERIES));
    }

    function test_common_expiredSeries() public {
        vm.warp(expiry);
        assertEq(uint8(_buy(callId, 5e18, 1e6, 0, 1e9).reason), uint8(PremiumExecutionGuard.Reason.EXPIRED));
        assertEq(uint8(_sell(callId, 5e18, 1e6, 0, false).reason), uint8(PremiumExecutionGuard.Reason.EXPIRED));
    }

    function test_common_zeroAmount() public view {
        assertEq(uint8(_buy(callId, 0, 0, 0, 0).reason), uint8(PremiumExecutionGuard.Reason.ZERO_AMOUNT));
    }

    function test_common_wrongOrUnsetMarket() public {
        // a market that is not the registered one
        PremiumExecutionGuard.CheckResult memory r = guard.checkBuy(
            PremiumExecutionGuard.BuyCheck(callId, makeAddr("otherMarket"), 5e18, 11e6, 0, 12e6, block.timestamp + 1)
        );
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.WRONG_MARKET));

        // the zero address
        r = guard.checkBuy(PremiumExecutionGuard.BuyCheck(callId, address(0), 5e18, 11e6, 0, 12e6, block.timestamp + 1));
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.WRONG_MARKET));

        // a series with no market pointer at all cannot be routed
        (, bytes32 id) = _create(OptionType.CALL, address(mon), address(monFeed), 11e18);
        r = guard.checkBuy(PremiumExecutionGuard.BuyCheck(id, market, 5e18, 11e6, 0, 12e6, block.timestamp + 1));
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.WRONG_MARKET));
    }

    function test_common_deadline() public view {
        PremiumExecutionGuard.CheckResult memory r = guard.checkBuy(
            PremiumExecutionGuard.BuyCheck(callId, market, 5e18, 11e6, 0, 12e6, block.timestamp - 1)
        );
        assertEq(uint8(r.reason), uint8(PremiumExecutionGuard.Reason.DEADLINE_PASSED));
        // exactly at the deadline is still allowed
        r = guard.checkBuy(PremiumExecutionGuard.BuyCheck(callId, market, 5e18, 11e6, 0, 12e6, block.timestamp));
        assertTrue(r.valid);
    }

    function test_common_venueFeeTooHigh() public view {
        assertEq(uint8(_buy(callId, 5e18, 11e6, 31, 1e9).reason), uint8(PremiumExecutionGuard.Reason.VENUE_FEE_TOO_HIGH));
        assertTrue(_buy(callId, 5e18, 11e6, 30, 1e9).valid); // exactly the cap is allowed
        assertEq(
            uint8(_sell(callId, 5e18, 11e6, 31, false).reason), uint8(PremiumExecutionGuard.Reason.VENUE_FEE_TOO_HIGH)
        );
    }

    function test_common_oracleUnavailable() public {
        // stale
        vm.warp(block.timestamp + 3601);
        assertEq(uint8(_buy(callId, 5e18, 11e6, 0, 1e9).reason), uint8(PremiumExecutionGuard.Reason.ORACLE_UNAVAILABLE));
        // exactly at the max age is fine
        vm.warp(block.timestamp - 1);
        assertTrue(_buy(callId, 5e18, 11e6, 0, 1e9).valid);
    }

    function test_common_oracleBrokenOrNonPositive() public {
        monFeed.setBroken(true);
        assertEq(uint8(_buy(callId, 5e18, 11e6, 0, 1e9).reason), uint8(PremiumExecutionGuard.Reason.ORACLE_UNAVAILABLE));
        monFeed.setBroken(false);

        _price(monFeed, 0);
        assertEq(uint8(_buy(callId, 5e18, 11e6, 0, 1e9).reason), uint8(PremiumExecutionGuard.Reason.ORACLE_UNAVAILABLE));
        _price(monFeed, -5);
        assertEq(uint8(_sell(callId, 5e18, 11e6, 0, false).reason), uint8(PremiumExecutionGuard.Reason.ORACLE_UNAVAILABLE));
    }

    /// Never reverts: even when everything is wrong the guard returns a reason.
    function test_common_neverReverts() public view {
        _buy(bytes32(0), 0, 0, type(uint16).max, 0);
        guard.checkSell(
            PremiumExecutionGuard.SellCheck(bytes32(uint256(7)), address(0), type(uint256).max, 0, 0, true, 0)
        );
    }

    // ================================================================== empty range

    /// Deep in the money with a low seller tolerance: the seller floor is taken from gross intrinsic value, the
    /// buyer ceiling is net of the exercise fee, so the floor can sit above the ceiling. No price is acceptable.
    function test_emptyRange_failsClosedAndPrefersNeitherBound() public {
        vm.prank(admin);
        factory.setDefaultFeeConfig(FeeConfig(0, 100)); // 1% exercise fee
        // the put at strike 10 already exists from setUp, so use a different strike
        (, bytes32 id) = _create(OptionType.PUT, address(mon), address(monFeed), 10.5e18);
        vm.prank(admin);
        factory.setKuruMarket(id, market);
        vm.prank(admin);
        guard.setSellerDiscountToleranceBps(0); // no discount allowed
        _price(monFeed, 1e6); // MON collapses to 0.01 USDC: the put is deep in the money

        // intrinsic ~ (10.5 - 0.01) * 5 = 52.45; hardMax = 52.5 * 0.99 = 51.975 < min 52.45
        PremiumExecutionGuard.CheckResult memory b = _buy(id, 5e18, 1e6, 0, 1e9);
        assertFalse(b.valid);
        assertEq(uint8(b.reason), uint8(PremiumExecutionGuard.Reason.EMPTY_RANGE));
        assertGt(b.acceptableMinPremium, b.hardMaxPremium);

        PremiumExecutionGuard.CheckResult memory s = _sell(id, 5e18, 60e6, 0, false);
        assertFalse(s.valid);
        assertEq(uint8(s.reason), uint8(PremiumExecutionGuard.Reason.EMPTY_RANGE));
    }

    /// With a tolerance at least as large as the exercise fee the range is never empty.
    function test_emptyRange_toleranceAtLeastTheFeeKeepsTheRangeNonEmpty() public {
        vm.prank(admin);
        factory.setDefaultFeeConfig(FeeConfig(0, 100));
        (, bytes32 id) = _create(OptionType.PUT, address(mon), address(monFeed), 10.5e18);
        vm.prank(admin);
        factory.setKuruMarket(id, market);
        // tolerance 100 bps == exercise fee 100 bps
        _price(monFeed, 1e6);
        PremiumExecutionGuard.CheckResult memory b = _buy(id, 5e18, 1e6, 0, 1e9);
        assertLe(b.acceptableMinPremium, b.hardMaxPremium);
    }

    // ================================================================== parameters

    function test_params_onlyAdminCanChangeThem() public {
        vm.startPrank(stranger);
        vm.expectRevert(Unauthorized.selector);
        guard.setSellerDiscountToleranceBps(1);
        vm.expectRevert(Unauthorized.selector);
        guard.setMaxReferenceAge(1);
        vm.expectRevert(Unauthorized.selector);
        guard.setMaxVenueFeeBps(1);
        vm.stopPrank();

        vm.startPrank(admin);
        guard.setSellerDiscountToleranceBps(250);
        guard.setMaxReferenceAge(7200);
        guard.setMaxVenueFeeBps(50);
        vm.stopPrank();
        assertEq(guard.sellerDiscountToleranceBps(), 250);
        assertEq(guard.maxReferenceAge(), 7200);
        assertEq(guard.maxVenueFeeBps(), 50);
    }

    function test_params_boundedByOneHundredPercent() public {
        vm.startPrank(admin);
        vm.expectRevert(InvalidGuardParam.selector);
        guard.setSellerDiscountToleranceBps(10_001);
        vm.expectRevert(InvalidGuardParam.selector);
        guard.setMaxVenueFeeBps(10_001);
        guard.setSellerDiscountToleranceBps(10_000); // exactly 100% is allowed
        guard.setMaxVenueFeeBps(10_000);
        vm.stopPrank();
    }

    function test_params_constructorValidation() public {
        vm.expectRevert(ZeroAddress.selector);
        new PremiumExecutionGuard(IOptionSeriesFactory(address(0)), 100, 3600, 30);
        vm.expectRevert(InvalidGuardParam.selector);
        new PremiumExecutionGuard(IOptionSeriesFactory(address(factory)), 10_001, 3600, 30);
        vm.expectRevert(InvalidGuardParam.selector);
        new PremiumExecutionGuard(IOptionSeriesFactory(address(factory)), 100, 3600, 10_001);
    }

    function test_params_changingThemNeverChangesAnyVault() public {
        uint256 lockedBefore = call.collateralLocked();
        bytes32 idBefore = call.seriesId();
        vm.startPrank(admin);
        guard.setSellerDiscountToleranceBps(5000);
        guard.setMaxReferenceAge(1);
        guard.setMaxVenueFeeBps(1);
        vm.stopPrank();
        assertEq(call.collateralLocked(), lockedBefore);
        assertEq(call.seriesId(), idBefore);
        assertEq(call.mintFeeBps(), 10);
    }

    function test_guardHoldsNoFundsAndIsPurelyView() public view {
        assertEq(address(guard).balance, 0);
        assertEq(address(guard).code.length > 0, true);
    }

    // ================================================================== fuzz

    struct Ref {
        bool isCall;
        uint256 a; // option amount
        uint256 c; // contract size
        uint256 k; // strike
        uint256 r; // reference price
        uint256 uq;
        uint256 exFee;
        uint256 tol;
    }

    /// Reference implementation of the two bounds, written independently with explicit roundings.
    function _expectedBounds(Ref memory x) internal pure returns (uint256 minP, uint256 maxP) {
        uint256 eUp = Math.mulDiv(x.a, x.c, 1e18, Math.Rounding.Ceil);
        uint256 eDown = Math.mulDiv(x.a, x.c, 1e18);
        uint256 diff = x.isCall ? (x.r > x.k ? x.r - x.k : 0) : (x.k > x.r ? x.k - x.r : 0);
        uint256 intrinsic = Math.mulDiv(eUp, diff, x.uq, Math.Rounding.Ceil);
        minP = Math.mulDiv(intrinsic, BPS_SCALE - x.tol, BPS_SCALE, Math.Rounding.Ceil);
        uint256 gross = Math.mulDiv(eDown, x.isCall ? x.r : x.k, x.uq);
        maxP = Math.mulDiv(gross, BPS_SCALE - x.exFee, BPS_SCALE);
    }

    function testFuzz_bounds_matchTheReferenceAndNeverOverflow(uint96 amountRaw, uint64 priceRaw8, bool isPut) public {
        uint256 amount = bound(amountRaw, 1e16, 1e27);
        int256 price8 = int256(bound(priceRaw8, 1, 1e14)); // up to 1,000,000 USDC at 8 decimals
        _price(monFeed, price8);

        bytes32 id = isPut ? putId : callId;
        PremiumExecutionGuard.CheckResult memory r = _buy(id, amount, 0, 0, type(uint256).max);
        (uint256 expMin, uint256 expMax) = _expectedBounds(
            Ref({
                isCall: !isPut,
                a: amount,
                c: 1e18,
                k: 10e18,
                r: uint256(price8) * 1e10,
                uq: 1e30,
                exFee: 25,
                tol: 100
            })
        );

        assertEq(r.acceptableMinPremium, expMin);
        assertEq(r.hardMaxPremium, expMax);
    }

    /// Rounding only ever moves toward rejection: the floor is never below, and the ceiling never above, the
    /// exact rational value. Checked by cross-multiplying with bounded inputs so nothing overflows.
    function testFuzz_bounds_roundingOnlyTightensTheRails(uint32 amountUnits, uint32 priceUnits) public {
        uint256 amount = uint256(bound(amountUnits, 1, 1e9)) * 1e10 + 1; // deliberately not a round number
        uint256 price6 = bound(priceUnits, 1, 1e9); // price in 1e-6 USDC units
        _price(monFeed, int256(price6 * 100)); // 8-decimal answer
        uint256 R = price6 * 1e12; // PRICE_SCALE units

        PremiumExecutionGuard.CheckResult memory r = _buy(putId, amount, 0, 0, type(uint256).max);
        // exact ceiling (put): amount * 1e18/1e18 * K(10e18) / 1e30 * 9975/10000, all as one fraction
        // hardMax * 1e18 * 1e30 * 10000 <= amount * 1e18 * 10e18 * 9975
        assertLe(r.hardMaxPremium * 1e30 * 10_000, amount * 10e18 * 9975);
        // exact floor (put intrinsic): amount * 1e18 * (K-R) / (1e18 * 1e30) * 9900/10000; min must be >= exact
        uint256 diff = 10e18 > R ? 10e18 - R : 0;
        assertGe(r.acceptableMinPremium * 1e30 * 10_000, amount * diff * 9900);
    }
}
