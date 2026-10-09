// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {ZeroAddress, FeeTooHigh} from "../libraries/Errors.sol";

/// @title OptaraDirectMarket
/// @notice Simple protocol-owned spot book for option wrappers. It is intentionally isolated from clearing: fills
///         move ERC-20 wrapper/quote balances only, and never affect margin until the user unwraps or closes.
contract OptaraDirectMarket {
    using SafeERC20 for IERC20;

    /// @notice The owner took inventory (options) or bid funding (quote) back out of the book.
    event Withdrawn(address indexed token, uint256 amount, address indexed to);

    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable adapter;
    address public immutable owner;
    uint256 public immutable baseUnit;
    uint256 public immutable quoteUnit;
    uint256 public immutable pricePrecision;
    uint256 public immutable sizePrecision;
    uint256 public askPrice;
    uint256 public askSize;
    uint256 public bidPrice;
    uint256 public bidSize;

    modifier onlyAdapter() {
        if (msg.sender != adapter) revert ZeroAddress();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ZeroAddress();
        _;
    }

    constructor(
        IERC20 base_,
        IERC20 quote_,
        uint256 baseDecimals,
        uint256 quoteDecimals,
        uint256 pricePrecision_,
        uint256 sizePrecision_,
        address adapter_,
        address owner_
    ) {
        if (
            address(base_) == address(0) || address(quote_) == address(0) || adapter_ == address(0)
                || owner_ == address(0)
        ) {
            revert ZeroAddress();
        }
        (base, quote, adapter, owner) = (base_, quote_, adapter_, owner_);
        (baseUnit, quoteUnit) = (10 ** baseDecimals, 10 ** quoteDecimals);
        (pricePrecision, sizePrecision) = (pricePrecision_, sizePrecision_);
    }

    function bestBidAsk() external view returns (uint256 bid, uint256 ask) {
        bid = bidSize == 0 ? 0 : bidPrice * 1e18 / pricePrecision;
        ask = askSize == 0 ? type(uint256).max : askPrice * 1e18 / pricePrecision;
    }

    function setAsk(uint256 price, uint256 size) external onlyOwner {
        (askPrice, askSize) = (price, size);
    }

    function setBid(uint256 price, uint256 size) external onlyOwner {
        (bidPrice, bidSize) = (price, size);
    }

    /// @notice Lets the owner take back what the book holds: unsold options (base) or unused bid funding (quote).
    ///         Without it, anything put into the book could only leave through trades. Withdrawing inventory doesn't
    ///         lower the ask size by itself; a buy above what the book holds reverts, so lower the ask too.
    function withdraw(IERC20 token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), amount, to);
    }

    function buy(uint256 premiumIn, address recipient) external onlyAdapter returns (uint256 premiumSpent) {
        quote.transferFrom(msg.sender, address(this), premiumIn);
        uint256 quoteSize = premiumIn * pricePrecision / quoteUnit;
        uint256 fill = askPrice == 0 ? 0 : quoteSize * sizePrecision / askPrice;
        if (fill > askSize) fill = askSize;
        askSize -= fill;
        uint256 used = M.divUp(fill * askPrice, sizePrecision);
        premiumSpent = used * quoteUnit / pricePrecision;
        uint256 credit = fill * baseUnit / sizePrecision;
        if (credit != 0) base.transfer(recipient, credit);
        uint256 refund = premiumIn - premiumSpent;
        if (refund != 0) quote.transfer(recipient, refund);
    }

    function sell(uint256 qty, address recipient) external onlyAdapter returns (uint256 qtySold) {
        base.transferFrom(msg.sender, address(this), qty);
        uint256 size = qty * sizePrecision / baseUnit;
        uint256 fill = size > bidSize ? bidSize : size;
        bidSize -= fill;
        uint256 proceeds = fill * bidPrice / sizePrecision * quoteUnit / pricePrecision;
        if (proceeds != 0) quote.transfer(recipient, proceeds);
        uint256 unsold = (size - fill) * baseUnit / sizePrecision;
        if (unsold != 0) base.transfer(recipient, unsold);
        qtySold = fill * baseUnit / sizePrecision;
    }
}

/// @title OptaraDirectAdapter
/// @notice In-house venue adapter used by the official VenueRouter. It is optional, has no venue fee, and can coexist
///         with Kuru or replace it in environments where no Kuru market exists.
contract OptaraDirectAdapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant VENUE_ID = keccak256("OPTARA_DIRECT");
    uint256 internal constant BPS = 10_000;

    function venueId() external pure returns (bytes32) {
        return VENUE_ID;
    }

    function marketTokens(address market) external view returns (address base, address quote) {
        base = address(OptaraDirectMarket(market).base());
        quote = address(OptaraDirectMarket(market).quote());
    }

    function quoteBuy(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function quoteSell(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function buy(address market, uint256 premiumIn, uint256 maxVenueFee, address recipient, bytes calldata)
        external
        returns (uint256 premiumSpent, uint256 venueFee)
    {
        if (maxVenueFee < venueFee) revert FeeTooHigh(venueFee, maxVenueFee);
        IERC20 quote = OptaraDirectMarket(market).quote();
        quote.forceApprove(market, premiumIn);
        premiumSpent = OptaraDirectMarket(market).buy(premiumIn, recipient);
    }

    function sell(address market, uint256 qty, uint256 maxVenueFee, address recipient, bytes calldata)
        external
        returns (uint256 qtySold, uint256 venueFee)
    {
        if (maxVenueFee < venueFee) revert FeeTooHigh(venueFee, maxVenueFee);
        IERC20 base = OptaraDirectMarket(market).base();
        base.forceApprove(market, qty);
        qtySold = OptaraDirectMarket(market).sell(qty, recipient);
    }
}
