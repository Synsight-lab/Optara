// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockKuruFixture} from "../utils/MockKuruFixture.sol";

/// @notice Router and Kuru adapter accounting over random budgets, prices, depths and buyer-fee rates: the buyer
///         pays exactly premium spent + ceil(spent × bps) and gets the rest back (INV-50), the fee goes through the
///         split, wrappers received match Kuru's fill rule, sells return unsold wrappers, nothing stays in the router
///         or the adapter, and Optara balances never move (INV-52).
contract VenueRouterFuzzTest is MockKuruFixture {
    function setUp() public {
        _deployVenueMarket();
        _deposit(writerAcct, writer, 1_000_000e6); // margin for up to 100 more contracts
        usdc.mint(buyer, 40_000e6); // budgets up to 30,000 plus fees
        vm.prank(writer);
        clearingModule.mintExternalLong(writerAcct, c4500, 45e18, address(book), type(uint256).max, _empty());
    }

    function testFuzz_buy(uint256 premiumIn, uint256 price, uint256 depth, uint16 bps) public {
        price = bound(price, 1, 500) * 10_000 + 100 * bound(price >> 16, 0, 99); // 1.00–500.99 USDC, tick 100
        depth = bound(depth, 1, 5000) * 1e14; // 0.01–50 wrappers of asks
        premiumIn = bound(premiumIn, 1, 30_000e6);
        bps = uint16(bound(bps, 0, 1000));
        vm.prank(governance);
        fees.setFeeRates(300, bps);
        book.setAsk(price, depth);
        (uint256 l0, uint256 s0) = ledger.totals(c4500);
        uint256 cash0 = usdc.balanceOf(buyer);

        vm.prank(buyer);
        (uint256 qty, uint256 spent, uint256 fee,) =
            venueRouter.buyThroughVenue(_buyOrder(c4500, premiumIn, 0, buyer), "");

        (uint256 credit, uint256 refundRaw) = _expectedBuy(premiumIn, price, depth);
        assertEq(qty, credit, "wrappers per Kuru's rule");
        assertEq(IERC20(_wrapper(c4500)).balanceOf(buyer), qty);
        assertEq(spent, premiumIn - refundRaw, "premium spent");
        assertEq(fee, (spent * bps + 9999) / 10_000, "buyer fee on the actual spend, rounded up");
        assertEq(cash0 - usdc.balanceOf(buyer), spent + fee, "INV-50: exact refund");
        _nothingLeft();
        (uint256 l1, uint256 s1) = ledger.totals(c4500);
        assertEq(l1, l0, "INV-52");
        assertEq(s1, s0, "INV-52");
    }

    /// @dev Kuru's fill rule (budget in price-precision units, size in size-precision units), then its fee in base.
    function _expectedBuy(uint256 premiumIn, uint256 price, uint256 depth)
        internal
        pure
        returns (uint256 credit, uint256 refundRaw)
    {
        uint256 quoteSize = premiumIn * 1e4 / 1e6;
        uint256 fill = quoteSize * 1e16 / price;
        if (fill > depth) fill = depth;
        uint256 used = (fill * price + 1e16 - 1) / 1e16;
        credit = fill * 1e18 / 1e16;
        credit -= (credit * 30 + 9999) / 10_000;
        refundRaw = (quoteSize - used) * 1e6 / 1e4 + (premiumIn - quoteSize * 1e6 / 1e4);
    }

    function testFuzz_sell(uint256 qty, uint256 price, uint256 depth) public {
        price = bound(price, 1, 500) * 10_000;
        depth = bound(depth, 0, 5000) * 1e14;
        qty = bound(qty, 1, 50e18);
        book.setBid(price, depth);
        usdc.mint(address(book), 30_000e6);
        vm.prank(writer);
        clearingModule.mintExternalLong(
            writerAcct, c4500, (qty + 1e16 - 1) / 1e16 * 1e16, buyer, type(uint256).max, _empty()
        );
        IERC20 w = IERC20(_wrapper(c4500));
        uint256 held = w.balanceOf(buyer);
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        (uint256 sold, uint256 proceeds,) = venueRouter.sellThroughVenue(_sellOrder(c4500, qty, 0, buyer), "");
        vm.stopPrank();

        uint256 size = qty * 1e16 / 1e18;
        uint256 fillSize = size > depth ? depth : size;
        assertEq(sold, fillSize * 1e18 / 1e16, "sold per Kuru's fill");
        uint256 gross = fillSize * price / 1e16 * 1e6 / 1e4;
        assertEq(proceeds, gross - (gross * 30 + 9999) / 10_000, "net of Kuru's fee in quote");
        assertEq(w.balanceOf(buyer), held - sold, "unsold wrappers came back");
        assertEq(usdc.balanceOf(buyer), 50_000e6 + proceeds);
        _nothingLeft();
    }

    function _nothingLeft() internal view {
        IERC20 w = IERC20(_wrapper(c4500));
        assertEq(w.balanceOf(address(venueRouter)) + w.balanceOf(address(adapter)), 0, "INV-50");
        assertEq(usdc.balanceOf(address(venueRouter)) + usdc.balanceOf(address(adapter)), 0, "INV-50");
    }
}
