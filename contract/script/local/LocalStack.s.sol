// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Manifest} from "../Manifest.sol";
import {ListingCalls} from "../ListingCalls.sol";
import {LocalMarketData} from "./LocalMarketData.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {IKuruRouter} from "../../src/venues/kuru/IKuru.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionType, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../../test/mocks/MockDependencies.sol";
import {MockPyth} from "../../test/mocks/MockPyth.sol";
import {MockAggregator} from "../../test/mocks/MockAggregator.sol";
import {MockKuruRouter, MockKuruOrderBook} from "../../test/mocks/MockVenues.sol";
import {OptaraDirectAdapter, OptaraDirectMarket} from "../../src/venues/OptaraDirectAdapter.sol";

/// @title LocalStack
/// @notice A complete local environment on anvil (DEPLOYMENT.md §4.1) for the keepers, publisher, indexer and
///         frontend: mock USDC/USDT, WETH/WMON/WBTC, Pyth, Chainlink-style settlement feeds and Kuru; Optara deployed by the production
///         code; ETH, MON and BTC products listed through the same calls a real network proposes (ListingCalls), reserves seeded by
///         the treasury calls; one-hour and weekly call/put series with Kuru books; a first spot price and signed surface;
///         funded test users. Writes `deployments/local.json` (`deployments/<NETWORK>.json` if `NETWORK` is set, as
///         the service test suites do so each gets its own manifest). `pnpm dev` (frontend) adds quotes and services.
/// @dev `anvil` then `forge script script/local/LocalStack.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`.
///      Accounts come from anvil's default mnemonic: 0 deployer and treasury, 2 and 3 publishers, 4 keeper,
///      5 Alice, 6 Bob (governance and every admin role for UI testing), 7–9 funded users. Never use these keys anywhere else.
contract LocalStack is Manifest, ListingCalls, LocalMarketData {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    bytes32 internal constant ETH_USDC_RISK_SET = keccak256("ETH/USDC default");
    bytes32 internal constant ETH_USDT_RISK_SET = keccak256("ETH/USDT default");
    bytes32 internal constant MON_USDC_RISK_SET = keccak256("MON/USDC default");
    bytes32 internal constant BTC_USDC_RISK_SET = keccak256("BTC/USDC default");
    bytes32 internal constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant PYTH_MON_USD = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    bytes32 internal constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 internal constant PYTH_USDT_USD = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;

    struct Mocks {
        MockERC20 usdc;
        MockERC20 usdt;
        MockERC20 weth;
        MockERC20 wmon;
        MockERC20 wbtc;
        MockPyth pyth;
        MockAggregator ethFeed;
        MockAggregator ethUsdtFeed;
        MockAggregator monFeed;
        MockAggregator btcFeed;
        MockKuruRouter kuru;
    }

    struct ProductPlan {
        address underlying;
        address asset;
        MockAggregator settlementFeed;
        string underlyingSymbol;
        string assetSymbol;
        bytes32 riskSetId;
        bytes32 pythFeed;
        bytes32 pythQuoteFeed;
        uint256 pythBasePriceWad;
        uint256 pythQuotePriceWad;
        uint256 spotWad;
        uint256 ivWad;
        uint256 shortCapUnderlyingWad;
        uint32 maxReportLifetime;
        uint256[4] strikes;
    }

    struct ListedData {
        bytes32[] productIds;
        bytes32[] cfgIds;
        bytes32[] ids;
        address[] books;
        address directAdapter;
        address[] directBooks;
        uint256[] starts;
        uint64[] expiries;
    }

    uint256[10] internal keys;
    address[10] internal accts;

    function run() external {
        for (uint256 i; i < 10; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            keys[i] = vm.deriveKey(MNEMONIC, uint32(i)); // i < 10
            accts[i] = vm.addr(keys[i]);
        }
        vm.startBroadcast(keys[0]);
        Mocks memory m = _mocks();
        Config memory c = _localConfig(m);
        Deployment memory d = _deploy(c);
        vm.stopBroadcast();

        ProductPlan[] memory products = _products(m);
        for (uint256 i; i < products.length; ++i) {
            ListingParams memory p = _listing(products[i], i == 0);
            _send(keys[6], _listingCalls(d, p)); // governance + admins (Bob locally, so the UI admin page can be tested)
            vm.broadcast(keys[0]);
            MockERC20(p.asset).mint(accts[0], p.insuranceSeed + p.keeperReserveMin);
            _send(keys[0], _seedCalls(d, p)); // the treasury (account 0 locally)
        }

        _listPublishFundAndWrite(m, d, c, products);
    }

    // ------------------------------------------------------------------ steps

    function _mocks() internal returns (Mocks memory m) {
        m.usdc = new MockERC20("USD Coin", "USDC", 6);
        m.usdt = new MockERC20("Tether USD", "USDT", 6);
        m.weth = new MockERC20("Wrapped Ether", "WETH", 18);
        m.wmon = new MockERC20("Wrapped Monad", "WMON", 18);
        m.wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 18);
        m.pyth = new MockPyth();
        m.ethFeed = new MockAggregator(8);
        m.ethUsdtFeed = new MockAggregator(8);
        m.monFeed = new MockAggregator(8);
        m.btcFeed = new MockAggregator(8);
        m.ethFeed.pushRound(int256(_envPrice("LOCAL_ETH_PRICE_WAD", 4000e18) / 1e10), block.timestamp);
        m.ethUsdtFeed.pushRound(int256(_envPrice("LOCAL_ETH_PRICE_WAD", 4000e18) / 1e10), block.timestamp);
        m.monFeed.pushRound(int256(_envPrice("LOCAL_MON_PRICE_WAD", 30_000_000_000_000_000) / 1e10), block.timestamp);
        m.btcFeed.pushRound(int256(_envPrice("LOCAL_BTC_PRICE_WAD", 100_000e18) / 1e10), block.timestamp);
        m.kuru = new MockKuruRouter();
    }

    function _localConfig(Mocks memory m) internal view returns (Config memory c) {
        address gov = accts[6]; // Bob in the frontend's local test wallet list.
        c = Config({
            deployer: accts[0],
            governance: gov,
            guardian: gov,
            council: gov,
            riskAdmin: gov,
            oracleAdmin: gov,
            seriesCreator: gov,
            venueAdmin: gov,
            upgradeDelay: 7 days,
            emergencyDelay: 24 hours,
            pyth: address(m.pyth),
            kuruRouter: _realKuru() != address(0) ? _realKuru() : address(m.kuru),
            surfaceQuorum: 2,
            maxSeriesPerAccount: 16,
            maxBucketsPerAccount: 4,
            minPositionQty: 1e16
        });
    }

    /// @dev Non-zero on a mainnet fork with real Kuru: the adapter uses Kuru's own router, no mock Kuru books are made,
    ///      and the devnet (frontend/scripts/devnet.ts) creates genuine Kuru markets for each series afterwards.
    function _realKuru() internal view returns (address) {
        return vm.envOr("LOCAL_KURU_ROUTER", address(0));
    }

    function _envPrice(string memory key, uint256 fallbackPrice) internal view returns (uint256) {
        uint256 p = vm.envOr(key, fallbackPrice);
        return p == 0 ? fallbackPrice : p;
    }

    function _strikeGrid(uint256 spot) internal pure returns (uint256[4] memory strikes) {
        strikes = [spot * 8 / 10, spot * 9 / 10, spot, spot * 11 / 10];
    }

    function _products(Mocks memory m) internal view returns (ProductPlan[] memory ps) {
        ps = new ProductPlan[](4);
        uint256 ethUsd = _envPrice("LOCAL_ETH_PRICE_WAD", 4000e18);
        uint256 monUsd = _envPrice("LOCAL_MON_PRICE_WAD", 30_000_000_000_000_000);
        uint256 btcUsd = _envPrice("LOCAL_BTC_PRICE_WAD", 100_000e18);
        uint256 usdcUsd = _envPrice("LOCAL_USDC_PRICE_WAD", 1e18);
        uint256 usdtUsd = _envPrice("LOCAL_USDT_PRICE_WAD", 1e18);
        uint256 ethUsdc = ethUsd * 1e18 / usdcUsd;
        uint256 ethUsdt = ethUsd * 1e18 / usdtUsd;
        uint256 monUsdc = monUsd * 1e18 / usdcUsd;
        uint256 btcUsdc = btcUsd * 1e18 / usdcUsd;
        ps[0] = ProductPlan(
            address(m.weth),
            address(m.usdc),
            m.ethFeed,
            "ETH",
            "USDC",
            ETH_USDC_RISK_SET,
            PYTH_ETH_USD,
            PYTH_USDC_USD,
            ethUsd,
            usdcUsd,
            ethUsdc,
            0.6e18,
            10_000e18,
            900,
            _strikeGrid(ethUsdc)
        );
        ps[1] = ProductPlan(
            address(m.weth),
            address(m.usdt),
            m.ethUsdtFeed,
            "ETH",
            "USDT",
            ETH_USDT_RISK_SET,
            PYTH_ETH_USD,
            PYTH_USDT_USD,
            ethUsd,
            usdtUsd,
            ethUsdt,
            0.6e18,
            10_000e18,
            900,
            _strikeGrid(ethUsdt)
        );
        ps[2] = ProductPlan(
            address(m.wmon),
            address(m.usdc),
            m.monFeed,
            "MON",
            "USDC",
            MON_USDC_RISK_SET,
            PYTH_MON_USD,
            PYTH_USDC_USD,
            monUsd,
            usdcUsd,
            monUsdc,
            1.1e18,
            50_000_000e18,
            900,
            _strikeGrid(monUsdc)
        );
        ps[3] = ProductPlan(
            address(m.wbtc),
            address(m.usdc),
            m.btcFeed,
            "BTC",
            "USDC",
            BTC_USDC_RISK_SET,
            PYTH_BTC_USD,
            PYTH_USDC_USD,
            btcUsd,
            usdcUsd,
            btcUsdc,
            0.55e18,
            1_000e18,
            900,
            _strikeGrid(btcUsdc)
        );
    }

    function _listing(ProductPlan memory plan, bool includePublishers) internal view returns (ListingParams memory p) {
        p.underlying = plan.underlying;
        p.asset = plan.asset;
        p.underlyingSymbol = plan.underlyingSymbol;
        p.assetSymbol = plan.assetSymbol;
        p.minStrikeWad = plan.spotWad / 100;
        p.maxStrikeWad = plan.spotWad * 100;
        p.maxReportLifetime = plan.maxReportLifetime;
        p.riskSetId = plan.riskSetId;
        p.shortCapUnderlyingWad = plan.shortCapUnderlyingWad;
        p.pythBaseFeed = plan.pythFeed;
        p.pythQuoteFeed = plan.pythQuoteFeed;
        p.settlement = ISettlementOracle.SettlementOracleConfig({
            underlying: plan.underlying,
            settlementAsset: plan.asset,
            primary: ISettlementOracle.FeedSource({
                kind: ISettlementOracle.FeedKind.DIRECT,
                feed: address(plan.settlementFeed),
                feedDecimals: 8,
                quoteFeed: address(0),
                quoteFeedDecimals: 0
            }),
            fallbackSource: ISettlementOracle.FeedSource({
                kind: ISettlementOracle.FeedKind.NONE,
                feed: address(0),
                feedDecimals: 0,
                quoteFeed: address(0),
                quoteFeedDecimals: 0
            }),
            observationStartOffset: -3600,
            observationEndOffset: 0,
            minFinalizationDelay: 300,
            maxFinalizationDelay: 7 days,
            maxLegSkew: 0
        });
        p.publishers = new address[](includePublishers ? 2 : 0);
        p.independent = new bool[](includePublishers ? 2 : 0);
        if (includePublishers) {
            (p.publishers[0], p.publishers[1]) = (accts[2], accts[3]);
            (p.independent[0], p.independent[1]) = (true, false);
        }
        p.minSellerFee = 0.1e6;
        p.insuranceSeed = 10_000e6;
        p.keeperReserveMin = 1_000e6;
        p.finalizeReward = 2e6;
        p.settleReward = 0.5e6;
        p.maxInsurancePerLiquidation = 5_000e6;
        p.approveAsset = true;
        p.enableKuru = true;
    }

    function _send(uint256 key, Call[] memory calls) internal {
        vm.startBroadcast(key);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        vm.stopBroadcast();
    }

    function _listPublishFundAndWrite(
        Mocks memory m,
        Deployment memory d,
        Config memory c,
        ProductPlan[] memory products
    ) internal {
        ListedData memory listed;
        listed.expiries = _localExpiries();
        uint256 perProduct = listed.expiries.length * 8;
        listed.ids = new bytes32[](products.length * perProduct);
        listed.books = new address[](products.length * perProduct);
        listed.directBooks = new address[](products.length * perProduct);
        listed.starts = new uint256[](products.length + 1);
        listed.productIds = new bytes32[](products.length);
        listed.cfgIds = new bytes32[](products.length);
        listed.directAdapter = _deployDirectAdapter(d);
        for (uint256 i; i < products.length; ++i) {
            listed.starts[i] = i * perProduct;
            listed.productIds[i] = d.registry.computeProductId(products[i].underlying, products[i].asset);
            listed.cfgIds[i] = d.settlementOracle.computeConfigId(_listing(products[i], false).settlement);
            _listSeries(
                d,
                products[i],
                listed.expiries,
                listed.ids,
                listed.books,
                listed.directBooks,
                listed.starts[i],
                listed.directAdapter
            );
            _publish(m, d, products[i], listed.productIds[i], listed.expiries);
        }
        listed.starts[products.length] = listed.ids.length;
        _fundUsers(m);
        _writeManifest(vm.envOr("NETWORK", string("local")), d, c, _extra(m, products, listed));
    }

    /// @dev The venues every listed series gets a book on (read once: a view call after `vm.broadcast` would use it up).
    struct Venues {
        bytes32 kuru;
        bytes32 direct;
        address directAdapter;
    }

    function _listSeries(
        Deployment memory d,
        ProductPlan memory plan,
        uint64[] memory expiries,
        bytes32[] memory ids,
        address[] memory books,
        address[] memory directBooks,
        uint256 offset,
        address directAdapter
    ) internal {
        Venues memory v = Venues({
            kuru: d.kuruAdapter.VENUE_ID(),
            direct: OptaraDirectAdapter(directAdapter).VENUE_ID(),
            directAdapter: directAdapter
        });
        for (uint256 i; i < expiries.length * 8; ++i) {
            (ids[offset + i], books[offset + i], directBooks[offset + i]) = _createSeriesBooks(
                d, plan, v, expiries[i / 8], i % 2 == 0 ? OptionType.CALL : OptionType.PUT, plan.strikes[(i / 2) % 4]
            );
        }
    }

    function _deployDirectAdapter(Deployment memory d) internal returns (address adapter) {
        vm.broadcast(keys[0]);
        adapter = address(new OptaraDirectAdapter());
        bytes32 direct = OptaraDirectAdapter(adapter).VENUE_ID();
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            role: "governance",
            to: address(d.venues),
            data: abi.encodeCall(d.venues.registerAdapter, (direct, adapter)),
            label: "register Optara direct adapter"
        });
        calls[1] = Call({
            role: "governance",
            to: address(d.venues),
            data: abi.encodeCall(d.venues.setAdapterEnabled, (direct, true)),
            label: "enable Optara direct adapter"
        });
        _send(keys[6], calls);
    }

    function _createSeriesBooks(
        Deployment memory d,
        ProductPlan memory plan,
        Venues memory v,
        uint64 expiry,
        OptionType optionType,
        uint256 strike
    ) internal returns (bytes32 id, address book, address directBook) {
        SeriesParams memory sp = _seriesParams(d, plan, expiry, optionType, strike);
        vm.broadcast(keys[6]);
        id = d.registry.createSeries(sp);
        (book, directBook) = _deployBooks(d, plan, d.registry.getSeries(id).wrapper, v.directAdapter);
        if (book != address(0)) {
            vm.broadcast(keys[6]);
            d.venues.registerMarket(v.kuru, book, id, "");
        }
        vm.broadcast(keys[6]);
        d.venues.registerMarket(v.direct, directBook, id, "");
    }

    function _seriesParams(
        Deployment memory d,
        ProductPlan memory plan,
        uint64 expiry,
        OptionType optionType,
        uint256 strike
    ) internal view returns (SeriesParams memory) {
        return SeriesParams({
            underlying: plan.underlying,
            settlementAsset: plan.asset,
            optionType: optionType,
            strikeWad: strike,
            contractSizeWad: 1e18,
            expiry: expiry,
            settlementOracleConfigId: d.settlementOracle.computeConfigId(_listing(plan, false).settlement),
            volSurfaceProductId: d.registry.computeProductId(plan.underlying, plan.asset),
            riskParameterSetId: plan.riskSetId
        });
    }

    /// @dev Kuru deploys its book (owner-gated on the real Kuru); the direct book quotes through the Optara adapter.
    function _deployBooks(Deployment memory d, ProductPlan memory plan, address wrapper, address directAdapter)
        internal
        returns (address book, address directBook)
    {
        bool mockKuru = _realKuru() == address(0);
        vm.startBroadcast(keys[0]);
        if (mockKuru) {
            MockKuruOrderBook b = new MockKuruOrderBook(IERC20(wrapper), IERC20(plan.asset), 18, 6, 1e4, 1e16, 30);
            MockKuruRouter(address(d.kuruAdapter.kuruRouter())).setMarket(address(b), _kuruParams(wrapper, plan.asset));
            book = address(b);
        }
        directBook = address(
            new OptaraDirectMarket(IERC20(wrapper), IERC20(plan.asset), 18, 6, 1e4, 1e16, directAdapter, accts[0])
        );
        vm.stopBroadcast();
    }

    function _kuruParams(address base, address quote) internal pure returns (IKuruRouter.MarketParams memory) {
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

    /// @dev A first spot price and a signed flat-IV surface whose tenors are the listed expiries.
    function _publish(
        Mocks memory m,
        Deployment memory d,
        ProductPlan memory plan,
        bytes32 productId,
        uint64[] memory tenors
    ) internal {
        Market memory mk = Market({
            pyth: address(m.pyth),
            surface: IVolSurfaceOracle(address(d.surface)),
            productId: productId,
            underlying: plan.underlying,
            asset: plan.asset,
            pythFeed: plan.pythFeed,
            pythQuoteFeed: plan.pythQuoteFeed,
            pythBasePriceWad: plan.pythBasePriceWad,
            pythQuotePriceWad: plan.pythQuotePriceWad,
            keyA: keys[2],
            keyB: keys[3]
        });
        OracleUpdate memory u = _oracleUpdate(mk, plan.spotWad, plan.ivWad, tenors, 1);
        uint256 fee = m.pyth.getUpdateFee(u.spotUpdates);
        vm.broadcast(keys[4]); // the keeper submits it
        d.clearing.updateOracles{value: fee}(u);
    }

    function _fundUsers(Mocks memory m) internal {
        vm.startBroadcast(keys[0]);
        for (uint256 i = 5; i < 10; ++i) {
            m.usdc.mint(accts[i], 100_000e6);
            m.usdt.mint(accts[i], 100_000e6);
            m.weth.mint(accts[i], 100e18);
            m.wmon.mint(accts[i], 1_000_000e18);
            m.wbtc.mint(accts[i], 10e18);
        }
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ manifest extras

    function _extra(Mocks memory m, ProductPlan[] memory products, ListedData memory listed)
        internal
        returns (string memory)
    {
        string memory k = "extra";
        vm.serializeAddress(k, "usdc", address(m.usdc));
        vm.serializeAddress(k, "usdt", address(m.usdt));
        vm.serializeAddress(k, "weth", address(m.weth));
        vm.serializeAddress(k, "wmon", address(m.wmon));
        vm.serializeAddress(k, "wbtc", address(m.wbtc));
        vm.serializeAddress(k, "pyth", address(m.pyth));
        vm.serializeAddress(k, "ethUsdcSettlementFeed", address(m.ethFeed));
        vm.serializeAddress(k, "ethUsdtSettlementFeed", address(m.ethUsdtFeed));
        vm.serializeAddress(k, "monUsdcSettlementFeed", address(m.monFeed));
        vm.serializeAddress(k, "btcUsdcSettlementFeed", address(m.btcFeed));
        vm.serializeAddress(k, "kuruRouter", _realKuru() != address(0) ? _realKuru() : address(m.kuru));
        vm.serializeAddress(k, "optaraDirectAdapter", listed.directAdapter);
        vm.serializeBytes32(k, "ethUsdcProductId", listed.productIds[0]);
        vm.serializeBytes32(k, "ethUsdcPythFeedId", PYTH_ETH_USD);
        vm.serializeBytes32(k, "ethUsdcSettlementConfigId", listed.cfgIds[0]);
        vm.serializeBytes32(k, "ethUsdcRiskSetId", ETH_USDC_RISK_SET);
        vm.serializeAddress(k, "governance", accts[6]);
        vm.serializeAddress(k, "publisherA", accts[2]);
        vm.serializeAddress(k, "publisherB", accts[3]);
        vm.serializeAddress(k, "keeper", accts[4]);
        address[] memory users = new address[](5);
        for (uint256 i; i < 5; ++i) {
            users[i] = accts[5 + i];
        }
        vm.serializeAddress(k, "users", users);
        uint256[] memory exp = new uint256[](listed.expiries.length);
        for (uint256 i; i < listed.expiries.length; ++i) {
            exp[i] = listed.expiries[i];
        }
        _serializeProducts(k, products, listed);
        vm.serializeUint(k, "expiries", exp);
        vm.serializeBytes32(k, "seriesIds", listed.ids);
        vm.serializeAddress(k, "kuruBooks", listed.books);
        return vm.serializeAddress(k, "optaraDirectBooks", listed.directBooks);
    }

    function _serializeProducts(string memory k, ProductPlan[] memory products, ListedData memory listed) internal {
        string[] memory symbols = new string[](products.length);
        string[] memory assetSymbols = new string[](products.length);
        address[] memory underlyings = new address[](products.length);
        address[] memory assets = new address[](products.length);
        bytes32[] memory feeds = new bytes32[](products.length);
        bytes32[] memory quoteFeeds = new bytes32[](products.length);
        bytes32[] memory risks = new bytes32[](products.length);
        address[] memory settlementFeeds = new address[](products.length);
        uint256[] memory spots = new uint256[](products.length);
        for (uint256 i; i < products.length; ++i) {
            symbols[i] = products[i].underlyingSymbol;
            assetSymbols[i] = products[i].assetSymbol;
            underlyings[i] = products[i].underlying;
            assets[i] = products[i].asset;
            feeds[i] = products[i].pythFeed;
            quoteFeeds[i] = products[i].pythQuoteFeed;
            risks[i] = products[i].riskSetId;
            settlementFeeds[i] = address(products[i].settlementFeed);
            spots[i] = products[i].spotWad;
        }
        vm.serializeString(k, "productSymbols", symbols);
        vm.serializeString(k, "productAssetSymbols", assetSymbols);
        vm.serializeAddress(k, "productUnderlyings", underlyings);
        vm.serializeAddress(k, "productSettlementAssets", assets);
        vm.serializeBytes32(k, "productIds", listed.productIds);
        vm.serializeBytes32(k, "productPythFeedIds", feeds);
        vm.serializeBytes32(k, "productPythQuoteFeedIds", quoteFeeds);
        vm.serializeAddress(k, "productSettlementFeeds", settlementFeeds);
        vm.serializeBytes32(k, "productSettlementConfigIds", listed.cfgIds);
        vm.serializeBytes32(k, "productRiskSetIds", risks);
        vm.serializeUint(k, "productSpotWads", spots);
        vm.serializeUint(k, "productSeriesStarts", listed.starts);
    }
}
