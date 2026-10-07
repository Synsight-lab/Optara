// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The parts of Kuru's (Monad mainnet) Router and OrderBook that KuruAdapter uses. Checked against Kuru's
///         public source (Kuru-Labs/Kuru-contracts-dex-public: contracts/Router.sol, OrderBook.sol, MarginAccount.sol)
///         and, for the selectors and the `verifiedMarket` layout, against the live contracts on a mainnet fork
///         (repository commit c94e6aa). Kuru's published docs give `_minAmountOut` as uint96; the source and the live
///         selector use uint256.
interface IKuruRouter {
    struct MarketParams {
        uint32 pricePrecision;
        uint96 sizePrecision;
        address baseAssetAddress;
        uint256 baseAssetDecimals;
        address quoteAssetAddress;
        uint256 quoteAssetDecimals;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    /// @notice Zero for a market Kuru's router did not deploy.
    function verifiedMarket(address orderBook) external view returns (MarketParams memory);
}

interface IKuruOrderBook {
    /// @notice Non-margin path (`_isMargin = false`): pulls `_quoteSize × 10^quoteDecimals / pricePrecision` of the
    ///         quote token from the caller, sends the bought base (net of the taker fee, which is taken in base)
    ///         and any unfilled quote straight back to the caller. `_minAmountOut` is in base token units.
    function placeAndExecuteMarketBuy(uint96 _quoteSize, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        external
        payable
        returns (uint256 baseCredited);

    /// @notice Non-margin path: pulls `_size × 10^baseDecimals / sizePrecision` of the base token from the caller
    ///         and sends the proceeds (net of the taker fee, taken in quote) straight back. `_minAmountOut` is in
    ///         quote token units.
    function placeAndExecuteMarketSell(uint96 _size, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        external
        payable
        returns (uint256 quoteCredited);
}
