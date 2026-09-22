// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interfaces for the REAL Kuru Router and OrderBook contracts, assembled from
/// https://docs.kuru.io/contracts/Router and https://docs.kuru.io/contracts/OrderBook (fetched 2026-09-22)
/// and confirmed empirically against the live Monad mainnet Router at deployment time (verifiedMarket,
/// orderBookImplementation, kuruAmmVaultImplementation, owner all respond as documented). Fork-test only:
/// never imported by src/.
interface IKuruRouter {
    /// @dev Reverse-engineered from GROUND TRUTH on a Monad mainnet fork, not from documentation: Kuru's
    /// docs never published this struct's layout. A guessed 11-field struct (market first, then base/quote,
    /// then sizePrecision before pricePrecision, plus a trailing kuruAmmSpread) decoded to GARBAGE when read
    /// back after a real deployment - it was wrong in three ways at once (wrong order, a swapped pair, and
    /// wrong field count). This version was confirmed by:
    ///   1. deploying a real throwaway market on a persistent forked node (impersonating the Router's real
    ///      owner, since deployProxy is access-restricted - see the finding on deployProxy above),
    ///   2. reading Router.verifiedMarket(market) and OrderBook.getMarketParams() as RAW, undecoded bytes,
    ///   3. matching each 32-byte word against values whose origin was already known (our own deployProxy
    ///      inputs), rather than trusting any assumed field order.
    /// Router.verifiedMarket() and OrderBook.getMarketParams() were confirmed to return byte-identical data.
    /// Notably: there is NO kuruAmmSpread field here, and NO self-referencing market/ammVault address fields
    /// either - both were part of my original wrong guess. kuruAmmSpread and the ammVault address exist (the
    /// Router's own MarketCreated-style event includes them - see MainnetForkKuru.t.sol) but are not part of
    /// what these two getters return; where kuruAmmSpread can be read back post-deployment, if at all, was
    /// not determined here.
    struct MarketParams {
        uint256 pricePrecision;
        uint256 sizePrecision;
        address baseAssetAddress;
        uint256 baseAssetDecimals;
        address quoteAssetAddress;
        uint256 quoteAssetDecimals;
        uint256 tickSize;
        uint256 minSize;
        uint256 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    /// @dev `_type` is IOrderBook.OrderBookType. The exact enum ordinal for NO_NATIVE is not published in
    /// the docs; it is confirmed empirically on the fork (see MainnetForkKuru.t.sol) before being trusted.
    function deployProxy(
        uint8 _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) external returns (address proxy);

    function verifiedMarket(address orderBook) external view returns (MarketParams memory);

    function orderBookImplementation() external view returns (address);

    function kuruAmmVaultImplementation() external view returns (address);

    function owner() external view returns (address);
}

interface IKuruOrderBook {
    /// @dev Ground-truth confirmed on the fork: the input signature (price, size, postOnly) is correct - a
    /// raw low-level call with these exact argument types succeeded and emitted a real OrderCreated event
    /// with the new order's id. But it returns ZERO bytes, not a uint40 - the ORIGINAL declaration here
    /// (`returns (uint40 orderId)`) made the high-level call site's automatic ABI-decode revert with no
    /// message right after a successful, state-changing call, which is a nasty failure mode: the order was
    /// actually created and its id emitted in OrderCreated, but the calling transaction still reverted and
    /// rolled everything back. Declared void here to match reality; get the order id from the event.
    function addBuyOrder(uint32 _price, uint96 _size, bool _postOnly) external;

    function addSellOrder(uint32 _price, uint96 _size, bool _postOnly) external;

    /// @dev `_minAmountOut` is uint256, not uint96 - confirmed against Kuru's own public source
    /// (Kuru-Labs/Kuru-contracts-dex-public, contracts/interfaces/IOrderBook.sol). An earlier uint96 guess
    /// changed the function selector entirely, so every call landed on no matching function in the real
    /// implementation and reverted with 0 bytes of data at ~927 gas - cheap enough that it was mistakable
    /// for a rejected parameter, not a routing miss, until ground truth (this repo) settled it.
    function placeAndExecuteMarketBuy(uint96 _quoteAmount, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        external
        payable
        returns (uint256);

    function placeAndExecuteMarketSell(uint96 _size, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        external
        payable
        returns (uint256);

    function batchCancelOrders(uint40[] calldata _orderIds) external;

    /// @dev Ground-truth confirmed on the fork: a guessed `(uint32, uint32)` return decoded the real "no
    /// bid" sentinel (type(uint256).max) into a uint32, which Solidity's ABI decoder rejects (the upper
    /// bits are non-zero), reverting with no message right after a successful staticcall - the same nasty
    /// failure mode as addBuyOrder/addSellOrder above. The real return is `(uint256, uint256)`.
    function bestBidAsk() external view returns (uint256 bestBid, uint256 bestAsk);

    function getL2Book() external view returns (bytes memory);

    function getMarketParams() external view returns (IKuruRouter.MarketParams memory);
}

/// @notice Real finding, confirmed empirically on the fork: `addBuyOrder`/`addSellOrder` (resting limit
/// orders) debit the trader's MarginAccount balance, NOT their wallet directly - a bare `approve()` on the
/// order book is not enough, and omitting a prior `deposit()` reverts with MarginAccount's own
/// `InsufficientBalance()` (selector 0xf4d678b8). `placeAndExecuteMarketBuy`/`Sell` with `_isMargin: false`
/// take the opposite path (pulled straight from the wallet via transferFrom), which is why the buy side of
/// this test needed no such deposit. The MarginAccount address itself is not exposed by any Router or
/// OrderBook getter this interface calls; it was read off the real `initialize()` calldata captured in a
/// recorded trace (see MainnetForkKuru.t.sol) and then confirmed live: it is a real, already-deployed
/// proxy on Monad mainnet, owned by the same address that owns the Router.
interface IKuruMarginAccount {
    function deposit(address _user, address _token, uint256 _amount) external payable;
    function withdraw(uint256 _amount, address _token) external;
    function getBalance(address _user, address _token) external view returns (uint256);
}
