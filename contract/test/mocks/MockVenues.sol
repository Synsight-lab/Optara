// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {IKuruRouter} from "../../src/venues/kuru/IKuru.sol";
import {IVenueAdapter} from "../../src/interfaces/IVenueAdapter.sol";

/// @notice Kuru's router as far as KuruAdapter sees it: a verified-market registry.
contract MockKuruRouter {
    mapping(address => IKuruRouter.MarketParams) internal markets;

    function setMarket(address book, IKuruRouter.MarketParams memory p) external {
        markets[book] = p;
    }

    function verifiedMarket(address book) external view returns (IKuruRouter.MarketParams memory) {
        return markets[book];
    }
}

/// @notice One-level Kuru order book with the non-margin market-order semantics of Kuru's OrderBook.sol (verified
///         against the live contracts in test/fork/KuruAdapter.fork.t.sol): sizes in size-precision units, the buy
///         budget in price-precision units, the buy fee taken in base, the sell fee in quote, unfilled amounts
///         returned straight to the caller.
contract MockKuruOrderBook {
    IERC20 public immutable base;
    IERC20 public immutable quote;
    uint256 public immutable baseUnit; // 10^baseDecimals
    uint256 public immutable quoteUnit;
    uint256 public immutable pricePrecision;
    uint256 public immutable sizePrecision;
    uint256 public immutable takerFeeBps;
    uint256 public askPrice; // price-precision units per whole base token
    uint256 public askSize; // size-precision units
    uint256 public bidPrice;
    uint256 public bidSize;

    constructor(
        IERC20 base_,
        IERC20 quote_,
        uint256 baseDecimals,
        uint256 quoteDecimals,
        uint256 pricePrecision_,
        uint256 sizePrecision_,
        uint256 takerFeeBps_
    ) {
        (base, quote, baseUnit, quoteUnit) = (base_, quote_, 10 ** baseDecimals, 10 ** quoteDecimals);
        (pricePrecision, sizePrecision, takerFeeBps) = (pricePrecision_, sizePrecision_, takerFeeBps_);
    }

    /// @notice As Kuru's OrderBook.bestBidAsk(): prices in 1e18 per whole base token (quote units); no bid → 0, no
    ///         ask → type(uint256).max. Frontends read quotes through this view.
    function bestBidAsk() external view returns (uint256 bid, uint256 ask) {
        bid = bidSize == 0 ? 0 : bidPrice * 1e18 / pricePrecision;
        ask = askSize == 0 ? type(uint256).max : askPrice * 1e18 / pricePrecision;
    }

    /// @dev The book must hold the base it offers (and the quote it bids) itself.
    function setAsk(uint256 price, uint256 size) external {
        (askPrice, askSize) = (price, size);
    }

    function setBid(uint256 price, uint256 size) external {
        (bidPrice, bidSize) = (price, size);
    }

    function placeAndExecuteMarketBuy(uint96 quoteSize, uint256 minOut, bool isMargin, bool)
        external
        returns (uint256)
    {
        require(!isMargin, "margin path not modeled");
        quote.transferFrom(msg.sender, address(this), uint256(quoteSize) * quoteUnit / pricePrecision);
        uint256 fill = askPrice == 0 ? 0 : uint256(quoteSize) * sizePrecision / askPrice;
        if (fill > askSize) fill = askSize;
        askSize -= fill;
        uint256 used = M.divUp(fill * askPrice, sizePrecision); // price-precision units
        uint256 left = quoteSize - used;
        uint256 credit = fill * baseUnit / sizePrecision;
        credit -= M.fullMulDivUp(credit, takerFeeBps, 10_000);
        if (credit != 0) base.transfer(msg.sender, credit);
        if (left != 0) quote.transfer(msg.sender, left * quoteUnit / pricePrecision);
        require(credit >= minOut, "slippage");
        return credit;
    }

    function placeAndExecuteMarketSell(uint96 size, uint256 minOut, bool isMargin, bool) external returns (uint256) {
        require(!isMargin, "margin path not modeled");
        base.transferFrom(msg.sender, address(this), uint256(size) * baseUnit / sizePrecision);
        uint256 fill = size > bidSize ? bidSize : size;
        bidSize -= fill;
        uint256 gross = fill * bidPrice / sizePrecision * quoteUnit / pricePrecision;
        uint256 net = gross - M.fullMulDivUp(gross, takerFeeBps, 10_000);
        if (net != 0) quote.transfer(msg.sender, net);
        uint256 unsold = (size - fill) * baseUnit / sizePrecision;
        if (unsold != 0) base.transfer(msg.sender, unsold);
        require(net >= minOut, "slippage");
        return net;
    }
}

/// @notice A venue adapter whose behavior tests choose, to exercise VenueRouter's defenses. The "venue" is an
///         address holding inventory that approved this adapter; fills are at a fixed price. It can spend or sell only
///         part, keep tokens it should return (misbehavior), or report any venue fee.
contract MockVenueAdapter is IVenueAdapter {
    bytes32 public immutable id;
    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable venue;
    uint256 public price = 100e6; // quote per whole base
    uint256 public fillBps = 10_000; // share of the order filled
    uint256 public feeReported;
    uint256 public keep; // tokens kept back from what should be returned

    constructor(bytes32 id_, IERC20 base_, IERC20 quote_, address venue_) {
        (id, base, quote, venue) = (id_, base_, quote_, venue_);
    }

    function configure(uint256 price_, uint256 fillBps_, uint256 feeReported_, uint256 keep_) external {
        (price, fillBps, feeReported, keep) = (price_, fillBps_, feeReported_, keep_);
    }

    function venueId() external view returns (bytes32) {
        return id;
    }

    function marketTokens(address) external view returns (address, address) {
        return (address(base), address(quote));
    }

    function quoteBuy(address, uint256) external view returns (uint256) {
        return feeReported;
    }

    function quoteSell(address, uint256) external view returns (uint256) {
        return feeReported;
    }

    function buy(address, uint256 premiumIn, uint256, address recipient, bytes calldata)
        external
        returns (uint256 spent, uint256 venueFee)
    {
        spent = premiumIn * fillBps / 10_000;
        quote.transfer(venue, spent);
        base.transferFrom(venue, recipient, spent * 1e18 / price);
        quote.transfer(recipient, premiumIn - spent - keep);
        venueFee = feeReported;
    }

    function sell(address, uint256 qty, uint256, address recipient, bytes calldata)
        external
        returns (uint256 sold, uint256 venueFee)
    {
        sold = qty * fillBps / 10_000;
        base.transfer(venue, sold);
        quote.transferFrom(venue, recipient, sold * price / 1e18);
        base.transfer(recipient, qty - sold - keep);
        venueFee = feeReported;
    }
}
