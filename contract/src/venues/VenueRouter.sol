// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {PauseBits} from "../governance/PauseBits.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IVenueRouter} from "../interfaces/IVenueRouter.sol";
import {IVenueRegistry} from "../interfaces/IVenueRegistry.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {SeriesTerms} from "../libraries/OptaraTypes.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    DeadlineExpired,
    SlippageExceeded,
    FeeTooHigh,
    NonExactTransfer,
    VenueBalanceLeft
} from "../libraries/Errors.sol";

/// @title VenueRouter
/// @notice Official buys and sells through registered venue markets (docs/VENUES_AND_KURU.md §5, FEES.md §4).
/// @dev The router measures every amount by balance differences instead of trusting the adapter: wrappers
///      received on a buy, quote spent, proceeds on a sell. The buyer fee is charged on the premium actually
///      spent, after the trade. Every call ends with the router and the adapter holding none of the quote token or
///      the wrapper (INV-50); a venue fill never touches Optara balances (INV-52).
contract VenueRouter is OptaraModule, IVenueRouter {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:optara.storage.VenueRouter
    struct RouterStorage {
        IOptionSeriesRegistry registry;
        IVenueRegistry venues;
        IFeeController fees;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.VenueRouter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x95fb967aced19b1612cc315e78ad5b928ae9b89cbf9b3f8f551fcf8e4a031b00;

    /// @dev The tokens and parties of one trade, and the balances at its start (a donation can't block trading:
    ///      INV-50 is checked against these, not against zero).
    struct Trade {
        IERC20 wrapper;
        IERC20 quote;
        address adapter;
        address market;
        uint256 routerQuote;
        uint256 routerWrapper;
        uint256 adapterQuote;
        uint256 adapterWrapper;
    }

    function initialize(
        IProtocolControl control_,
        IOptionSeriesRegistry registry_,
        IVenueRegistry venues_,
        IFeeController fees_
    ) external initializer {
        __OptaraModule_init(control_);
        if (address(registry_) == address(0) || address(venues_) == address(0) || address(fees_) == address(0)) {
            revert ZeroAddress();
        }
        RouterStorage storage $ = _s();
        ($.registry, $.venues, $.fees) = (registry_, venues_, fees_);
    }

    /// @dev Both order kinds in one shape (sells have no buyer fee).
    struct Order {
        bytes32 venueId;
        bytes32 seriesId;
        uint256 amount; // buy: premiumIn; sell: qty
        uint256 limit; // buy: minQty; sell: minProceeds
        uint256 maxBuyerFee;
        uint256 maxVenueFee;
        address recipient;
        uint64 deadline;
    }

    /// @inheritdoc IVenueRouter
    function buyThroughVenue(BuyOrder calldata b, bytes calldata adapterData)
        external
        nonReentrant
        returns (uint256, uint256, uint256, uint256)
    {
        return _buy(
            Order(
                b.venueId,
                b.seriesId,
                b.premiumIn,
                b.minQty,
                b.maxBuyerFeeNative,
                b.maxVenueFeeNative,
                b.recipient,
                b.deadline
            ),
            adapterData
        );
    }

    /// @inheritdoc IVenueRouter
    function sellThroughVenue(SellOrder calldata o, bytes calldata adapterData)
        external
        nonReentrant
        returns (uint256, uint256, uint256)
    {
        return _sell(
            Order(o.venueId, o.seriesId, o.qty, o.minProceeds, 0, o.maxVenueFeeNative, o.recipient, o.deadline),
            adapterData
        );
    }

    function _buy(Order memory o, bytes calldata adapterData)
        private
        returns (uint256 qtyOut, uint256 premiumSpent, uint256 buyerFee, uint256 venueFee)
    {
        RouterStorage storage $ = _s();
        if (o.amount == 0) revert ZeroAmount();
        Trade memory t = _open(o);
        // the fee is bounded up front on the full budget and charged on what is actually spent
        uint256 feeBound = $.fees.previewBuyerFee(o.amount);
        if (feeBound > o.maxBuyerFee) revert FeeTooHigh(feeBound, o.maxBuyerFee);
        _pullExact(t.quote, o.amount);
        (qtyOut, premiumSpent, venueFee) = _fillBuy(o, t, adapterData);
        if (qtyOut < o.limit) revert SlippageExceeded();
        if (venueFee > o.maxVenueFee) revert FeeTooHigh(venueFee, o.maxVenueFee);

        buyerFee = $.fees.previewBuyerFee(premiumSpent); // ≤ the bound checked above
        _pullExact(t.quote, buyerFee);
        if (buyerFee != 0) {
            t.quote.safeTransfer(address($.fees), buyerFee);
            $.fees.notifyBuyerFee(msg.sender, o.seriesId, address(t.quote), buyerFee);
        }
        t.wrapper.safeTransfer(o.recipient, qtyOut);
        uint256 refund = o.amount - premiumSpent;
        if (refund != 0) t.quote.safeTransfer(msg.sender, refund);
        _requireEmpty(t);
        emit VenueTrade(o.venueId, o.seriesId, msg.sender, o.recipient, true, qtyOut, premiumSpent, buyerFee, venueFee);
    }

    function _sell(Order memory o, bytes calldata adapterData)
        private
        returns (uint256 qtySold, uint256 proceeds, uint256 venueFee)
    {
        if (o.amount == 0) revert ZeroAmount();
        Trade memory t = _open(o);
        _pullExact(t.wrapper, o.amount);
        (qtySold, proceeds, venueFee) = _fillSell(o, t, adapterData);
        if (proceeds < o.limit) revert SlippageExceeded();
        if (venueFee > o.maxVenueFee) revert FeeTooHigh(venueFee, o.maxVenueFee);

        // no Optara fee on sells: the seller already paid at mint (FEES.md §4)
        t.quote.safeTransfer(o.recipient, proceeds);
        uint256 unsold = o.amount - qtySold;
        if (unsold != 0) t.wrapper.safeTransfer(msg.sender, unsold);
        _requireEmpty(t);
        emit VenueTrade(o.venueId, o.seriesId, msg.sender, o.recipient, false, qtySold, proceeds, 0, venueFee);
    }

    /// @dev Hands the budget to the adapter and measures what came back: wrappers bought and quote spent.
    function _fillBuy(Order memory o, Trade memory t, bytes calldata adapterData)
        private
        returns (uint256 qtyOut, uint256 premiumSpent, uint256 venueFee)
    {
        uint256 quoteBefore = t.quote.balanceOf(address(this));
        uint256 wrappersBefore = t.wrapper.balanceOf(address(this));
        t.quote.safeTransfer(t.adapter, o.amount);
        (, venueFee) = IVenueAdapter(t.adapter).buy(t.market, o.amount, o.maxVenueFee, address(this), adapterData);
        premiumSpent = quoteBefore - t.quote.balanceOf(address(this));
        qtyOut = t.wrapper.balanceOf(address(this)) - wrappersBefore;
    }

    /// @dev Hands the wrappers to the adapter and measures what came back: wrappers sold and proceeds.
    function _fillSell(Order memory o, Trade memory t, bytes calldata adapterData)
        private
        returns (uint256 qtySold, uint256 proceeds, uint256 venueFee)
    {
        uint256 quoteBefore = t.quote.balanceOf(address(this));
        uint256 wrappersBefore = t.wrapper.balanceOf(address(this));
        t.wrapper.safeTransfer(t.adapter, o.amount);
        (, venueFee) = IVenueAdapter(t.adapter).sell(t.market, o.amount, o.maxVenueFee, address(this), adapterData);
        proceeds = t.quote.balanceOf(address(this)) - quoteBefore;
        qtySold = wrappersBefore - t.wrapper.balanceOf(address(this));
    }

    function modules() external view returns (address registry, address venues, address fees) {
        RouterStorage storage $ = _s();
        return (address($.registry), address($.venues), address($.fees));
    }

    // ================================================================================================== internal

    /// @dev Checks shared by buys and sells: pause, deadline, recipient, series active, market and adapter usable.
    function _open(Order memory o) private view returns (Trade memory t) {
        RouterStorage storage $ = _s();
        SeriesTerms memory terms = $.registry.getSeries(o.seriesId); // reverts UnknownSeries
        _requireNotPaused(PauseBits.ROUTER, terms.settlementAsset, terms.volSurfaceProductId);
        if (block.timestamp > o.deadline) revert DeadlineExpired();
        if (o.recipient == address(0)) revert InvalidRecipient();
        (t.adapter, t.market) = $.venues.tradableMarket(o.venueId, o.seriesId); // active, unexpired, adapter enabled
        (t.wrapper, t.quote) = (IERC20(terms.wrapper), IERC20(terms.settlementAsset));
        (t.routerQuote, t.routerWrapper) = (t.quote.balanceOf(address(this)), t.wrapper.balanceOf(address(this)));
        (t.adapterQuote, t.adapterWrapper) = (t.quote.balanceOf(t.adapter), t.wrapper.balanceOf(t.adapter));
    }

    function _pullExact(IERC20 token, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert NonExactTransfer(amount, received);
    }

    /// @dev INV-50: neither the router nor the adapter keeps any of the call's quote token or wrappers.
    function _requireEmpty(Trade memory t) private view {
        if (t.quote.balanceOf(address(this)) != t.routerQuote || t.quote.balanceOf(t.adapter) != t.adapterQuote) {
            revert VenueBalanceLeft(address(t.quote));
        }
        if (t.wrapper.balanceOf(address(this)) != t.routerWrapper || t.wrapper.balanceOf(t.adapter) != t.adapterWrapper)
        {
            revert VenueBalanceLeft(address(t.wrapper));
        }
    }

    function _s() private pure returns (RouterStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
