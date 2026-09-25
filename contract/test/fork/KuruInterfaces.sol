// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Kuru Spot V2 interfaces (Monad testnet deployment of 2026-09-01), taken from the ABIs shipped in
///         the npm package toxicflow-labs/ts-sdk 0.0.1 and https://kuru-testnet-docs.mintlify.site. TEST-ONLY: Optara's contracts
///         never import or call Kuru (PROTOCOL_SPEC.md section 13, P-10).
library KuruTestnet {
    uint256 internal constant CHAIN_ID = 10143;
    address internal constant ACCOUNT_CORE = 0x6384e9b2Bf3b65e1535403a0A543b5FDA905eE22;
    address internal constant SPOT_ROUTER = 0xba24a1042701f06e8F7edCF04389260D1Fa4c697;
    address internal constant USDC = 0xEe0722ead54f1B4fe97bE399Be43BC0226a6f97E; // 6 decimals, Kuru quote token
    address internal constant WETH = 0x8B6C5fafeF85B030bB1e71ae7ac085cC2380aAf8;
    address internal constant PROTOCOL_AUTHORITY = 0xd90C08F27742BB11dDaE4d8B8F6eD4C944D0F1c2;

    uint8 internal constant BUY = 0;
    uint8 internal constant SELL = 1;
    uint8 internal constant GTC = 0;
    uint8 internal constant IOC = 1;
    uint8 internal constant FOK = 2;
    uint8 internal constant EXEC_NONE = 0;
    uint8 internal constant POST_ONLY = 1;
}

struct NativeOrder {
    uint8 side;
    uint96 quantity;
    uint32 price;
    uint8 tif;
    uint8 executionInstruction;
    uint32 minSizeAfterBlock;
}

struct SwapResult {
    uint128 amountInUsed;
    uint128 amountOut;
}

interface IKuruProtocolAuthority {
    function governance() external view returns (address);
}

interface IKuruAccountCore {
    function deposit(address token, uint256 amount) external payable;
    function withdraw(address token, uint256 amount) external;
    function getBalance(address user, address token) external view returns (uint256);
    function getSpotReservedBalance(address user, address token) external view returns (uint256);
    function userRegistry(address user) external view returns (uint40);
    function configureSpotToken(address token, bool enabled) external;
    function spotTokenConfigs(address token) external view returns (uint8 decimals, bool enabled);
    function verifiedSpotOrderBook(address market) external view returns (bool);
    function spotOrderBookToBaseToken(address market) external view returns (address);
    function spotOrderBookToQuoteToken(address market) external view returns (address);
    function toggleProtocolState(bool paused) external;
    function protocolPaused() external view returns (bool);
}

interface IKuruSpotRouter {
    function whitelistSpotToken(address token, bool status) external;
    function deploySpotMarket(
        address baseToken,
        address quoteToken,
        uint96 sizePrecision,
        uint32 pricePrecision,
        uint32 tickSize,
        uint32 passiveSpreadTicks,
        uint96 minQuoteNotional,
        uint96 maxQuoteNotional,
        uint256 takerFeePps,
        uint256 makerFeePps
    ) external returns (address proxy);
    function verifiedSpotMarket(address market) external view returns (bool);
    function toggleSpotMarkets(address[] calldata orderBooks, uint8 state) external;
}

interface IKuruOrderBook {
    function batch(uint40 userId, NativeOrder[] calldata orders, uint8[] calldata cancelSlotIdxs) external;
    function swap(uint40 userId, bool isBuy, uint128 amountIn, uint128 minAmountOut, uint64 deadline)
        external
        returns (SwapResult memory);
    function estimateSwap(bool isBuy, uint128 amountIn) external view returns (SwapResult memory);
    function cancelAllOrders(uint40 userId) external;
    function bestBidAsk() external view returns (uint32 bid, uint32 ask);
    function marketState() external view returns (uint8);
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function spotBalanceAccountAddress() external view returns (address);
    function baseSizeMultiplier() external view returns (uint256);
    function getMarketParams() external view returns (uint32, uint96, uint32, uint96, uint96, uint256, uint256);
    function makerLockedReserves(uint40 userId) external view returns (uint256 baseReserved, uint256 quoteReserved);
}
