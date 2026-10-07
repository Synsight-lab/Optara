// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IVenueAdapter} from "../../interfaces/IVenueAdapter.sol";
import {IKuruRouter, IKuruOrderBook} from "./IKuru.sol";
import {NotAuthorized, ZeroAddress, MarketNotVerified, FeeTooHigh} from "../../libraries/Errors.sol";

/// @title KuruAdapter
/// @notice Kuru order books behind VenueRouter (docs/VENUES_AND_KURU.md §6). Immediate-or-cancel market orders on
///         Kuru's non-margin path: nothing is left in Kuru's margin account, and fills arrive straight back here.
/// @dev Not upgradeable; replaced by registering a new adapter (the registry keys adapters by venue id).
///      Market tokens and fees come from Kuru's own router (`verifiedMarket`), so a contract that merely claims the
///      right tokens can't be registered or traded. The adapter forwards only what the current call produced:
///      tokens sent to it by anyone else stay put and can't block trading (VenueRouter checks INV-50 against the
///      balances at the start of the call).
contract KuruAdapter is IVenueAdapter {
    using SafeERC20 for IERC20;
    using SafeCastLib for uint256;

    bytes32 public constant VENUE_ID = keccak256("KURU");
    uint256 internal constant BPS = 10_000;

    address public immutable router;
    IKuruRouter public immutable kuruRouter;

    constructor(address router_, IKuruRouter kuruRouter_) {
        if (router_ == address(0) || address(kuruRouter_) == address(0)) revert ZeroAddress();
        (router, kuruRouter) = (router_, kuruRouter_);
    }

    modifier onlyRouter() {
        if (msg.sender != router) revert NotAuthorized(msg.sender);
        _;
    }

    function venueId() external pure returns (bytes32) {
        return VENUE_ID;
    }

    /// @inheritdoc IVenueAdapter
    function marketTokens(address market) external view returns (address base, address quote) {
        IKuruRouter.MarketParams memory p = kuruRouter.verifiedMarket(market);
        return (p.baseAssetAddress, p.quoteAssetAddress);
    }

    /// @inheritdoc IVenueAdapter
    /// @dev Kuru takes the buy fee in base; this is its value in quote: premium × takerFeeBps, rounded up.
    function quoteBuy(address market, uint256 premiumIn) external view returns (uint256) {
        return M.fullMulDivUp(premiumIn, _params(market).takerFeeBps, BPS);
    }

    /// @inheritdoc IVenueAdapter
    /// @dev Kuru takes the sell fee from the gross proceeds: fee = net × bps / (10,000 − bps), rounded up.
    function quoteSell(address market, uint256 proceeds) external view returns (uint256) {
        uint256 bps = _params(market).takerFeeBps;
        return M.fullMulDivUp(proceeds, bps, BPS - bps);
    }

    /// @inheritdoc IVenueAdapter
    function buy(address market, uint256 premiumIn, uint256 maxVenueFee, address recipient, bytes calldata)
        external
        onlyRouter
        returns (uint256 premiumSpent, uint256 venueFee)
    {
        IKuruRouter.MarketParams memory p = _params(market);
        (IERC20 base, IERC20 quote) = (IERC20(p.baseAssetAddress), IERC20(p.quoteAssetAddress));
        uint256 quoteBefore = quote.balanceOf(address(this)) - premiumIn; // what was here before this call
        uint256 baseBefore = base.balanceOf(address(this));

        // the quote budget in Kuru's price-precision units, rounded down (any remainder comes back unspent)
        uint256 quoteSize = premiumIn * p.pricePrecision / (10 ** p.quoteAssetDecimals);
        if (quoteSize != 0) {
            quote.forceApprove(market, premiumIn);
            IKuruOrderBook(market).placeAndExecuteMarketBuy(quoteSize.toUint96(), 0, false, false);
            quote.forceApprove(market, 0);
        }
        uint256 bought = base.balanceOf(address(this)) - baseBefore;
        uint256 unspent = quote.balanceOf(address(this)) - quoteBefore;
        premiumSpent = premiumIn - unspent;
        venueFee = M.fullMulDivUp(premiumSpent, p.takerFeeBps, BPS);
        if (venueFee > maxVenueFee) revert FeeTooHigh(venueFee, maxVenueFee);
        if (bought != 0) base.safeTransfer(recipient, bought);
        if (unspent != 0) quote.safeTransfer(recipient, unspent);
    }

    /// @inheritdoc IVenueAdapter
    function sell(address market, uint256 qty, uint256 maxVenueFee, address recipient, bytes calldata)
        external
        onlyRouter
        returns (uint256 qtySold, uint256 venueFee)
    {
        IKuruRouter.MarketParams memory p = _params(market);
        (IERC20 base, IERC20 quote) = (IERC20(p.baseAssetAddress), IERC20(p.quoteAssetAddress));
        uint256 baseBefore = base.balanceOf(address(this)) - qty;
        uint256 quoteBefore = quote.balanceOf(address(this));

        // the size in Kuru's size-precision units, rounded down (any remainder comes back unsold)
        uint256 size = qty * p.sizePrecision / (10 ** p.baseAssetDecimals);
        if (size != 0) {
            base.forceApprove(market, qty);
            IKuruOrderBook(market).placeAndExecuteMarketSell(size.toUint96(), 0, false, false);
            base.forceApprove(market, 0);
        }
        uint256 unsold = base.balanceOf(address(this)) - baseBefore;
        uint256 proceeds = quote.balanceOf(address(this)) - quoteBefore;
        qtySold = qty - unsold;
        venueFee = M.fullMulDivUp(proceeds, p.takerFeeBps, BPS - p.takerFeeBps);
        if (venueFee > maxVenueFee) revert FeeTooHigh(venueFee, maxVenueFee);
        if (proceeds != 0) quote.safeTransfer(recipient, proceeds);
        if (unsold != 0) base.safeTransfer(recipient, unsold);
    }

    function _params(address market) private view returns (IKuruRouter.MarketParams memory p) {
        p = kuruRouter.verifiedMarket(market);
        if (p.baseAssetAddress == address(0)) revert MarketNotVerified();
    }
}
