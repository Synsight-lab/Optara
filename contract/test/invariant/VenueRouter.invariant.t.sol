// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockKuruFixture} from "../utils/MockKuruFixture.sol";

/// @notice Random buys, sells, restocks, bid refills, buyer-fee changes and donations through the router and the
///         Kuru adapter. After every call: the router and adapter hold only what was donated to them (INV-50), the
///         buyer's cash equals start − Σ spent − Σ buyer fees + Σ proceeds, the fee controller's split equals every
///         fee charged (INV-9), and Optara's internal totals move only through mints (INV-52).
contract VenueRouterInvariantTest is MockKuruFixture {
    uint256 public spentSum;
    uint256 public buyerFees;
    uint256 public proceedsSum;
    uint256 public sellerFees;
    uint256 public mintedShorts;
    uint256 public donatedRouter;
    uint256 public donatedAdapter;
    uint256 public trades;
    uint256 internal buyerStart;

    function setUp() public {
        _deployVenueMarket();
        _deposit(writerAcct, writer, 2_000_000e6);
        usdc.mint(buyer, 1_000_000e6);
        buyerStart = usdc.balanceOf(buyer);
        sellerFees = fees.previewSellerFee(c4500, 5e18);
        mintedShorts = 5e18;
        IERC20 w = IERC20(_wrapper(c4500)); // read before the prank
        vm.prank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = this.h_buy.selector;
        sel[1] = this.h_sell.selector;
        sel[2] = this.h_restock.selector;
        sel[3] = this.h_bid.selector;
        sel[4] = this.h_feeRate.selector;
        sel[5] = this.h_donate.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    function h_buy(uint64 raw) external {
        uint256 premium = bound(raw, 1, 20_000e6);
        vm.prank(buyer);
        (uint256 qty, uint256 spent, uint256 fee,) =
            venueRouter.buyThroughVenue(_buyOrder(c4500, premium, 0, buyer), "");
        (spentSum, buyerFees) = (spentSum + spent, buyerFees + fee);
        if (qty != 0) trades++;
    }

    function h_sell(uint64 raw) external {
        uint256 held = IERC20(_wrapper(c4500)).balanceOf(buyer);
        if (held == 0) return;
        vm.prank(buyer);
        (uint256 sold, uint256 proceeds,) =
            venueRouter.sellThroughVenue(_sellOrder(c4500, bound(raw, 1, held), 0, buyer), "");
        proceedsSum += proceeds;
        if (sold != 0) trades++;
    }

    /// @dev The writer mints 0.1–5 wrappers onto the book and re-quotes the ask at 50–300.
    function h_restock(uint16 rawQty, uint16 rawPrice) external {
        uint256 qty = bound(rawQty, 10, 500) * 1e16;
        sellerFees += fees.previewSellerFee(c4500, qty);
        vm.prank(writer);
        clearingModule.mintExternalLong(writerAcct, c4500, qty, address(book), type(uint256).max, _empty());
        mintedShorts += qty;
        book.setAsk(bound(rawPrice, 50, 300) * 10_000, book.askSize() + qty * 1e16 / 1e18);
    }

    function h_bid(uint16 rawPrice, uint16 rawSize) external {
        uint256 size = bound(rawSize, 1, 500) * 1e14;
        uint256 price = bound(rawPrice, 50, 300) * 10_000;
        usdc.mint(address(book), size * price / 1e16 * 1e6 / 1e4 + 1);
        book.setBid(price, size);
    }

    function h_feeRate(uint16 bps) external {
        vm.prank(governance);
        fees.setFeeRates(300, uint16(bound(bps, 0, 1000)));
    }

    function h_donate(bool toRouter, uint32 amount) external {
        usdc.mint(toRouter ? address(venueRouter) : address(adapter), amount);
        if (toRouter) donatedRouter += amount;
        else donatedAdapter += amount;
    }

    // ------------------------------------------------------------------ invariants

    function invariant_INV50_nothingLeftBehind() public view {
        IERC20 w = IERC20(_wrapper(c4500));
        assertEq(w.balanceOf(address(venueRouter)) + w.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(venueRouter)), donatedRouter);
        assertEq(usdc.balanceOf(address(adapter)), donatedAdapter);
    }

    function invariant_buyerCashExact() public view {
        assertEq(usdc.balanceOf(buyer), buyerStart - spentSum - buyerFees + proceedsSum);
    }

    function invariant_INV9_feesSplit() public view {
        assertEq(
            fees.treasury(address(usdc)) + fees.keeperReserve(address(usdc)) + insurance.balanceOf(address(usdc)),
            sellerFees + buyerFees
        );
    }

    function invariant_INV52_optaraBalancesOnlyMoveByMints() public view {
        (uint256 longs, uint256 shorts) = ledger.totals(c4500);
        assertEq(longs, 0);
        assertEq(shorts, mintedShorts);
    }

    function test_handlerPathsReachable() public {
        this.h_buy(330e6);
        this.h_sell(1e18);
        this.h_restock(100, 120);
        this.h_bid(90, 200);
        this.h_feeRate(50);
        this.h_donate(true, 3);
        this.h_donate(false, 4);
        this.h_buy(100e6);
        assertEq(trades, 3);
        invariant_INV50_nothingLeftBehind();
        invariant_buyerCashExact();
        invariant_INV9_feesSplit();
        invariant_INV52_optaraBalancesOnlyMoveByMints();
    }
}
