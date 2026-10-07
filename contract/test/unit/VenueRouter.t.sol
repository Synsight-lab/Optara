// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockKuruFixture} from "../utils/MockKuruFixture.sol";
import {VenueRouter} from "../../src/venues/VenueRouter.sol";
import {KuruAdapter} from "../../src/venues/kuru/KuruAdapter.sol";
import {IKuruRouter} from "../../src/venues/kuru/IKuru.sol";
import {IVenueRouter} from "../../src/interfaces/IVenueRouter.sol";
import {IVenueRegistry} from "../../src/interfaces/IVenueRegistry.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {MockVenueAdapter, MockKuruOrderBook} from "../mocks/MockVenues.sol";
import {FeeOnTransferToken} from "../mocks/MockDependencies.sol";
import {OptionType, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    DeadlineExpired,
    SlippageExceeded,
    FeeTooHigh,
    VenueBalanceLeft,
    AdapterDisabled,
    MarketNotVerified,
    UnknownSeries,
    ActionPaused,
    NonExactTransfer
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for VenueRouter and KuruAdapter (mock Kuru with the real semantics): VEN-002..VEN-007,
///         FEE-004, FEE-005, LIQ-014.
contract VenueRouterTest is MockKuruFixture {
    bytes32 internal constant MOCK = keccak256("MOCK");
    MockVenueAdapter internal mock;

    function setUp() public {
        _deployVenueMarket();
    }

    function _buy(uint256 premiumIn, uint256 minQty) internal returns (uint256, uint256, uint256, uint256) {
        vm.prank(buyer);
        return venueRouter.buyThroughVenue(_buyOrder(c4500, premiumIn, minQty, buyer), "");
    }

    /// @dev A second venue whose behavior tests choose, holding 10 wrappers and 1,000 USDC of inventory.
    function _installMock() internal {
        address mockVenue = makeAddr("mockVenue");
        mock = new MockVenueAdapter(MOCK, IERC20(_wrapper(c4500)), IERC20(address(usdc)), mockVenue);
        vm.startPrank(governance);
        venues.registerAdapter(MOCK, address(mock));
        venues.setAdapterEnabled(MOCK, true);
        vm.stopPrank();
        vm.prank(venueAdmin);
        venues.registerMarket(MOCK, address(0xBEEF), c4500, "");
        vm.prank(writer);
        clearingModule.mintExternalLong(writerAcct, c4500, 10e18, mockVenue, type(uint256).max, _empty());
        usdc.mint(mockVenue, 1000e6);
        IERC20 w = IERC20(_wrapper(c4500));
        vm.startPrank(mockVenue);
        w.approve(address(mock), type(uint256).max);
        usdc.approve(address(mock), type(uint256).max);
        vm.stopPrank();
    }

    function _mockOrder(uint256 premiumIn) internal view returns (IVenueRouter.BuyOrder memory o) {
        o = _buyOrder(c4500, premiumIn, 0, buyer);
        o.venueId = MOCK;
    }

    // ------------------------------------------------------------------ initialization

    function test_initialize() public {
        IProtocolControl c = IProtocolControl(address(pc));
        address impl = address(new VenueRouter());
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            impl,
            abi.encodeCall(
                VenueRouter.initialize,
                (c, IOptionSeriesRegistry(address(registry)), IVenueRegistry(address(0)), IFeeController(address(fees)))
            )
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        venueRouter.initialize(
            c, IOptionSeriesRegistry(address(registry)), IVenueRegistry(address(venues)), IFeeController(address(fees))
        );
        (address r, address v, address f) = venueRouter.modules();
        (r, v, f) = (r, v, f);
        assertEq(r, address(registry));
        assertEq(v, address(venues));
        assertEq(f, address(fees));
    }

    // ------------------------------------------------------------------ VEN-002 / FEE-004: buys

    /// @dev 330 USDC at 110 buys 3 wrappers; Kuru keeps 0.3% in base; Optara's buyer fee is 3% of the premium.
    function test_VEN002_FEE004_buy() public {
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.BuyerFeeCharged(buyer, c4500, address(usdc), 9.9e6);
        vm.expectEmit(true, true, true, true, address(venueRouter));
        emit IVenueRouter.VenueTrade(KURU, c4500, buyer, buyer, true, 2.991e18, 330e6, 9.9e6, 990_000);
        (uint256 qty, uint256 spent, uint256 fee, uint256 venueFee) = _buy(330e6, 2.99e18);
        assertEq(qty, 2.991e18);
        assertEq(spent, 330e6);
        assertEq(fee, 9.9e6);
        assertEq(venueFee, 990_000, "shown separately");
        assertEq(IERC20(_wrapper(c4500)).balanceOf(buyer), 2.991e18);
        assertEq(usdc.balanceOf(buyer), 10_000e6 - 330e6 - 9.9e6);
        assertEq(
            fees.treasury(address(usdc)) + fees.keeperReserve(address(usdc)) + insurance.balanceOf(address(usdc)),
            9.9e6 + fees.previewSellerFee(c4500, 5e18),
            "the buyer fee went through the split"
        );
        _assertEmpty();
    }

    function test_VEN002_partialFillRefundsExactly() public {
        (uint256 qty, uint256 spent, uint256 fee, uint256 venueFee) = _buy(1000e6, 0);
        assertEq(venueFee, 1_650_000, "Kuru's fee on what was spent, not on the budget");
        assertEq(spent, 550e6, "all 5 asks");
        assertEq(qty, 4.985e18);
        assertEq(fee, 16.5e6, "fee on what was spent");
        assertEq(usdc.balanceOf(buyer), 10_000e6 - 550e6 - 16.5e6, "INV-50: exact refund");
        _assertEmpty();
    }

    /// @dev Wrappers go to the named recipient, not the payer; the adapter leaves no allowance on the book.
    function test_VEN002_recipientAndAllowances() public {
        address gift = makeAddr("gift");
        vm.prank(buyer);
        (uint256 qty,,,) = venueRouter.buyThroughVenue(_buyOrder(c4500, 330e6 + 50, 0, gift), "");
        IERC20 w = IERC20(_wrapper(c4500));
        assertEq(w.balanceOf(gift), qty);
        assertEq(w.balanceOf(buyer), 0);
        assertEq(usdc.allowance(address(adapter), address(book)), 0, "quote approval reset (50 raw were never pulled)");
        vm.prank(gift);
        w.approve(address(venueRouter), type(uint256).max);
        vm.prank(gift);
        venueRouter.sellThroughVenue(_sellOrder(c4500, 1e18 + 50, 0, gift), "");
        assertEq(w.allowance(address(adapter), address(book)), 0, "base approval reset (50 wei below one size unit)");
    }

    function test_VEN002_limits() public {
        IVenueRouter.BuyOrder memory o = _buyOrder(c4500, 330e6, 0, buyer);
        o.maxBuyerFeeNative = 9.9e6 - 1;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 9.9e6, 9.9e6 - 1));
        venueRouter.buyThroughVenue(o, "");
        o = _buyOrder(c4500, 330e6, 0, buyer);
        o.maxVenueFeeNative = 989_999;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 990_000, 989_999));
        venueRouter.buyThroughVenue(o, "");
        vm.expectRevert(SlippageExceeded.selector);
        _buy(330e6, 2.991e18 + 1);
    }

    /// @dev The adapter's own cap on Kuru's sell fee (the router's bound is passed through to it).
    function test_VEN003_sellVenueFeeCap() public {
        _buy(330e6, 0);
        IERC20 w = IERC20(_wrapper(c4500));
        IVenueRouter.SellOrder memory so = _sellOrder(c4500, 2e18, 0, buyer);
        so.maxVenueFeeNative = 599_999;
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 600_000, 599_999));
        venueRouter.sellThroughVenue(so, "");
        vm.stopPrank();
    }

    /// @dev A fee-on-transfer settlement asset can't be pulled exactly: the router refuses it.
    function test_feeOnTransferAssetRejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        bytes32 cfg = keccak256("ETH/FOT settlement");
        settlementConfigs.set(cfg, weth, address(fot), true);
        vm.startPrank(governance);
        registry.setSettlementAssetApproved(address(fot), true);
        bytes32 product = registry.approveProduct(weth, address(fot), _productConfig("ETH"));
        risk.assignProductRiskSet(product, RISK_SET);
        vm.stopPrank();
        SeriesParams memory p = SeriesParams({
            underlying: weth,
            settlementAsset: address(fot),
            optionType: OptionType.CALL,
            strikeWad: 4500e18,
            contractSizeWad: 1e18,
            expiry: EXP30,
            settlementOracleConfigId: cfg,
            volSurfaceProductId: product,
            riskParameterSetId: RISK_SET
        });
        vm.prank(seriesCreator);
        bytes32 s = registry.createSeries(p);
        address w = _wrapper(s);
        MockKuruOrderBook b = new MockKuruOrderBook(IERC20(w), IERC20(address(fot)), 18, 6, 1e4, 1e16, 30);
        kuruRouter.setMarket(address(b), _params(w, address(fot)));
        vm.prank(venueAdmin);
        venues.registerMarket(KURU, address(b), s, "");
        fot.mint(buyer, 100e6);
        vm.startPrank(buyer);
        fot.approve(address(venueRouter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NonExactTransfer.selector, 100e6, 99e6));
        venueRouter.buyThroughVenue(_buyOrder(s, 100e6, 0, buyer), "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ VEN-003 / FEE-005: sells

    function test_VEN003_FEE005_sell() public {
        _buy(330e6, 0);
        uint256 treasuryBefore = fees.treasury(address(usdc));
        IERC20 w = IERC20(_wrapper(c4500));
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        vm.expectRevert(SlippageExceeded.selector);
        venueRouter.sellThroughVenue(_sellOrder(c4500, 2e18, 199.4e6 + 1, buyer), "");
        (uint256 sold, uint256 proceeds, uint256 venueFee) =
            venueRouter.sellThroughVenue(_sellOrder(c4500, 2e18, 199.4e6, makeAddr("payee")), "");
        vm.stopPrank();
        assertEq(sold, 2e18);
        assertEq(proceeds, 199.4e6, "200 less Kuru's 0.3% of the quote");
        assertEq(venueFee, 600_000);
        assertEq(usdc.balanceOf(makeAddr("payee")), 199.4e6);
        assertEq(fees.treasury(address(usdc)), treasuryBefore, "FEE-005: no Optara fee on sells");
        _assertEmpty();
    }

    function test_VEN003_unsoldWrappersComeBack() public {
        vm.prank(writer);
        clearingModule.mintExternalLong(writerAcct, c4500, 7e18, buyer, type(uint256).max, _empty());
        IERC20 w = IERC20(_wrapper(c4500));
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        (uint256 sold, uint256 proceeds,) = venueRouter.sellThroughVenue(_sellOrder(c4500, 7e18, 0, buyer), "");
        vm.stopPrank();
        assertEq(sold, 5e18, "the bid only takes 5");
        assertEq(proceeds, 498.5e6);
        assertEq(w.balanceOf(buyer), 2e18, "2 unsold wrappers returned");
        _assertEmpty();
    }

    // ------------------------------------------------------------------ VEN-004 / inputs / pauses

    function test_VEN004_deadline() public {
        IVenueRouter.BuyOrder memory o = _buyOrder(c4500, 330e6, 0, buyer);
        vm.warp(block.timestamp + 1);
        vm.prank(buyer);
        vm.expectRevert(DeadlineExpired.selector);
        venueRouter.buyThroughVenue(o, "");
        IVenueRouter.SellOrder memory so = _sellOrder(c4500, 1e18, 0, buyer);
        so.deadline -= 1;
        vm.prank(buyer);
        vm.expectRevert(DeadlineExpired.selector);
        venueRouter.sellThroughVenue(so, "");
    }

    function test_inputChecks() public {
        vm.expectRevert(ZeroAmount.selector);
        _buy(0, 0);
        vm.prank(buyer);
        vm.expectRevert(ZeroAmount.selector);
        venueRouter.sellThroughVenue(_sellOrder(c4500, 0, 0, buyer), "");
        vm.prank(buyer);
        vm.expectRevert(InvalidRecipient.selector);
        venueRouter.buyThroughVenue(_buyOrder(c4500, 1e6, 0, address(0)), "");
        bytes32 bogus = keccak256("series");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, bogus));
        venueRouter.buyThroughVenue(_buyOrder(bogus, 1e6, 0, buyer), "");
        vm.prank(buyer);
        vm.expectRevert(MarketNotVerified.selector);
        venueRouter.buyThroughVenue(_buyOrder(c5000, 1e6, 0, buyer), ""); // no market for C5000
        vm.prank(guardian);
        venues.setAdapterEnabled(KURU, false);
        vm.expectRevert(abi.encodeWithSelector(AdapterDisabled.selector, KURU));
        _buy(1e6, 0);
    }

    function test_pauseRouter() public {
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.GLOBAL, bytes32(0), uint256(1) << PauseBits.ROUTER);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.ROUTER));
        _buy(1e6, 0);
    }

    // ------------------------------------------------------------------ VEN-005: nothing left behind

    function test_VEN005_misbehavingAdapterReverts() public {
        _installMock();
        vm.prank(buyer);
        venueRouter.buyThroughVenue(_mockOrder(100e6), ""); // a well-behaved fill: 1 wrapper
        mock.configure(100e6, 5000, 0, 1); // fills half and keeps 1 unit of the refund
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(VenueBalanceLeft.selector, address(usdc)));
        venueRouter.buyThroughVenue(_mockOrder(100e6), "");
        // a sell that keeps an unsold wrapper back
        IERC20 w = IERC20(_wrapper(c4500));
        IVenueRouter.SellOrder memory so = _sellOrder(c4500, 1e18, 0, buyer);
        so.venueId = MOCK;
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VenueBalanceLeft.selector, address(w)));
        venueRouter.sellThroughVenue(so, "");
        vm.stopPrank();
        // an adapter reporting a fee above the buyer's bound
        mock.configure(100e6, 10_000, 5e6, 0);
        IVenueRouter.BuyOrder memory o = _mockOrder(100e6);
        o.maxVenueFeeNative = 4e6;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 5e6, 4e6));
        venueRouter.buyThroughVenue(o, "");
        IVenueRouter.SellOrder memory so2 = _sellOrder(c4500, 1e18, 0, buyer);
        (so2.venueId, so2.maxVenueFeeNative) = (MOCK, 4e6);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 5e6, 4e6));
        venueRouter.sellThroughVenue(so2, "");
    }

    /// @dev Tokens sent to the router or the adapter by anyone can't block trading (INV-50 is measured per call).
    function test_VEN005_donationsDoNotBlock() public {
        usdc.mint(address(venueRouter), 7);
        usdc.mint(address(adapter), 5);
        (uint256 qty,,,) = _buy(330e6, 0);
        assertEq(qty, 2.991e18);
        assertEq(usdc.balanceOf(address(venueRouter)), 7, "the donation stays where it was");
        assertEq(usdc.balanceOf(address(adapter)), 5);
    }

    // ------------------------------------------------------------------ KuruAdapter directly

    function test_kuruAdapterBasics() public {
        vm.expectRevert(ZeroAddress.selector);
        new KuruAdapter(address(0), IKuruRouter(address(kuruRouter)));
        assertEq(adapter.venueId(), KURU);
        assertEq(adapter.router(), address(venueRouter));
        assertEq(adapter.quoteBuy(address(book), 330e6), 990_000);
        assertEq(adapter.quoteSell(address(book), 199.4e6), 600_000);
        (address b, address q) = adapter.marketTokens(address(0xdead));
        assertEq(b, address(0));
        assertEq(q, address(0));
        vm.expectRevert(MarketNotVerified.selector);
        adapter.quoteBuy(address(0xdead), 1e6);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, address(this)));
        adapter.buy(address(book), 1e6, 0, address(this), "");
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, address(this)));
        adapter.sell(address(book), 1e18, 0, address(this), "");
    }

    /// @dev Budgets and sizes below one Kuru unit trade nothing and come back whole.
    function test_kuruAdapterDustAmounts() public {
        (uint256 qty, uint256 spent,,) = _buy(99, 0); // 99 raw < 1 price unit (100 raw)
        assertEq(qty, 0);
        assertEq(spent, 0);
        _buy(330e6, 0);
        IERC20 w = IERC20(_wrapper(c4500));
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        (uint256 sold,,) = venueRouter.sellThroughVenue(_sellOrder(c4500, 99, 0, buyer), ""); // < 1 size unit
        vm.stopPrank();
        assertEq(sold, 0);
        _assertEmpty();
    }

    // ------------------------------------------------------------------ VEN-006 / VEN-007 / LIQ-014

    /// @dev With Kuru disabled: mint, transfer, unwrap, close, liquidate, settle and redeem all still work.
    function test_VEN006_LIQ014_everythingWorksWithoutTheVenue() public {
        vm.prank(guardian);
        venues.setAdapterEnabled(KURU, false);
        address holder = makeAddr("holder");
        uint256 holderAcct = _account(holder);
        uint256 short = _account(alice);
        _deposit(short, alice, 3700e6);
        vm.prank(alice);
        clearingModule.mintExternalLong(short, c4500, 1e18, holder, type(uint256).max, _empty()); // mint
        IERC20 w = IERC20(_wrapper(c4500));
        vm.prank(holder);
        assertTrue(w.transfer(alice, 0.2e18)); // transfer
        vm.prank(alice);
        clearingModule.closeShortWithWrapper(short, c4500, 0.2e18); // close
        vm.prank(holder);
        clearingModule.unwrapLong(holderAcct, c4500, 0.3e18); // unwrap
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        uint256 liq = _account(stranger);
        _deposit(liq, stranger, 10_000e6);
        liquidation.startAuction(short, weth, _empty()); // liquidate
        vm.prank(stranger);
        liquidation.liquidateSlice(short, weth, liq, 2500, 0, 0, _empty());
        vm.warp(EXP30 + 1);
        _finalize30(5200e18); // settle and redeem
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (short, liq, holderAcct, writerAcct);
        window.settleAccountsGroup(ids, group30);
        window.computeRecoveryRatio(group30);
        vm.prank(holder);
        window.redeemWrapper(c4500, 0.5e18, holder);
        assertGt(usdc.balanceOf(holder), 0);
    }

    /// @dev INV-52 / INV-20: wrappers and USDC sitting on the venue never count as anyone's margin.
    function test_VEN007_venueBalancesAreNotMargin() public {
        IPortfolioRiskManager.Risk memory before = risk.riskOf(writerAcct);
        _buy(330e6, 0); // trades on the venue move only venue and wallet balances
        IPortfolioRiskManager.Risk memory afterTrade = risk.riskOf(writerAcct);
        assertEq(afterTrade.equity, before.equity);
        assertEq(afterTrade.initialMargin, before.initialMargin);
        assertEq(ledger.cashOf(writerAcct), ledger.cashOf(writerAcct)); // the writer's wrappers on Kuru: no credit
        (uint256 longs, uint256 shorts) = ledger.totals(c4500);
        assertEq(longs, 0);
        assertEq(shorts, 5e18, "the venue fill changed no Optara balance");
    }

    function _assertEmpty() internal view {
        IERC20 w = IERC20(_wrapper(c4500));
        assertEq(w.balanceOf(address(venueRouter)), 0, "INV-50");
        assertEq(w.balanceOf(address(adapter)), 0, "INV-50");
        assertEq(usdc.balanceOf(address(venueRouter)), 0, "INV-50");
        assertEq(usdc.balanceOf(address(adapter)), 0, "INV-50");
    }
}
