// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VenueFixture} from "./VenueFixture.sol";
import {KuruAdapter} from "../../src/venues/kuru/KuruAdapter.sol";
import {IKuruRouter} from "../../src/venues/kuru/IKuru.sol";
import {MockKuruRouter, MockKuruOrderBook} from "../mocks/MockVenues.sol";

/// @notice VenueFixture with a mock Kuru (same non-margin semantics as the real one, see KuruAdapter.fork.t.sol):
///         one book for C4500 with pricePrecision 1e4 and sizePrecision 1e16, 0.3% taker fee, an ask of 5 wrappers
///         at 110 (real wrappers minted by a writer) and a bid of 5 wrappers at 100.
abstract contract MockKuruFixture is VenueFixture {
    MockKuruRouter internal kuruRouter;
    MockKuruOrderBook internal book;
    KuruAdapter internal adapter;
    address internal buyer = makeAddr("buyer");
    address internal writer = makeAddr("writer");
    uint256 internal writerAcct;

    function _deployVenueMarket() internal {
        _deployClearingMarket();
        _grantVenueAdmin();
        kuruRouter = new MockKuruRouter();
        adapter = _installKuru(address(kuruRouter));
        book = _book(c4500);
        vm.prank(venueAdmin);
        venues.registerMarket(KURU, address(book), c4500, "tick=100");

        writerAcct = _account(writer);
        _deposit(writerAcct, writer, 200_000e6);
        vm.prank(writer);
        clearingModule.mintExternalLong(writerAcct, c4500, 5e18, address(book), type(uint256).max, _empty());
        book.setAsk(1_100_000, 5e16);
        usdc.mint(address(book), 500e6);
        book.setBid(1_000_000, 5e16);

        usdc.mint(buyer, 10_000e6);
        vm.prank(buyer);
        usdc.approve(address(venueRouter), type(uint256).max);
    }

    /// @dev A mock Kuru book for `seriesId` (base = its wrapper, quote = USDC), verified in the mock Kuru router.
    function _book(bytes32 seriesId) internal returns (MockKuruOrderBook b) {
        address w = _wrapper(seriesId);
        b = new MockKuruOrderBook(IERC20(w), IERC20(address(usdc)), 18, 6, 1e4, 1e16, 30);
        kuruRouter.setMarket(address(b), _params(w, address(usdc)));
    }

    function _params(address base, address quote) internal pure returns (IKuruRouter.MarketParams memory) {
        return IKuruRouter.MarketParams({
            pricePrecision: 1e4,
            sizePrecision: 1e16,
            baseAssetAddress: base,
            baseAssetDecimals: 18,
            quoteAssetAddress: quote,
            quoteAssetDecimals: 6,
            tickSize: 100,
            minSize: 1e14,
            maxSize: 1e20,
            takerFeeBps: 30,
            makerFeeBps: 10
        });
    }
}
