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

/// @title LocalStack
/// @notice A complete local environment on anvil (DEPLOYMENT.md §4.1) for the keepers, publisher, indexer and
///         frontend: mock USDC/WETH, Pyth, a Chainlink-style ETH/USDC feed and Kuru; Optara deployed by the production
///         code; ETH/USDC listed through the same calls a real network proposes (ListingCalls), reserves seeded by
///         the treasury calls; weekly call and put series with Kuru books; a first spot price and signed surface;
///         funded test users. Writes `deployments/local.json`.
/// @dev `anvil` then `forge script script/local/LocalStack.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`.
///      Accounts come from anvil's default mnemonic: 0 deployer and treasury, 1 governance and every admin role,
///      2 and 3 publishers (2 independent), 4 keeper, 5–9 users. Never use these keys anywhere else.
contract LocalStack is Manifest, ListingCalls, LocalMarketData {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    bytes32 internal constant RISK_SET = keccak256("ETH/USDC default");
    bytes32 internal constant ETH_FEED = keccak256("local pyth ETH/USDC");

    struct Mocks {
        MockERC20 usdc;
        MockERC20 weth;
        MockPyth pyth;
        MockAggregator ethFeed;
        MockKuruRouter kuru;
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

        ListingParams memory p = _ethListing(m);
        _send(keys[1], _listingCalls(d, p)); // governance + admins (all account 1 locally)
        vm.broadcast(keys[0]);
        m.usdc.mint(accts[0], p.insuranceSeed + p.keeperReserveMin);
        _send(keys[0], _seedCalls(d, p)); // the treasury (account 0 locally)

        uint64[] memory expiries = _weeklyExpiries();
        (bytes32[] memory ids, address[] memory books) = _listSeries(m, d, expiries);
        bytes32 productId = d.registry.computeProductId(address(m.weth), address(m.usdc));
        _publish(m, d, productId, expiries);
        _fundUsers(m);

        bytes32 cfgId = d.settlementOracle.computeConfigId(p.settlement);
        _writeManifest("local", d, c, _extra(m, productId, cfgId, ids, books, expiries));
    }

    // ------------------------------------------------------------------ steps

    function _mocks() internal returns (Mocks memory m) {
        m.usdc = new MockERC20("USD Coin", "USDC", 6);
        m.weth = new MockERC20("Wrapped Ether", "WETH", 18);
        m.pyth = new MockPyth();
        m.ethFeed = new MockAggregator(8);
        m.ethFeed.pushRound(4000e8, block.timestamp);
        m.kuru = new MockKuruRouter();
    }

    function _localConfig(Mocks memory m) internal view returns (Config memory c) {
        address gov = accts[1];
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
            kuruRouter: address(m.kuru),
            surfaceQuorum: 2,
            maxSeriesPerAccount: 16,
            maxBucketsPerAccount: 4,
            minPositionQty: 1e16
        });
    }

    function _ethListing(Mocks memory m) internal view returns (ListingParams memory p) {
        p.underlying = address(m.weth);
        p.asset = address(m.usdc);
        p.underlyingSymbol = "ETH";
        p.assetSymbol = "USDC";
        p.minStrikeWad = 100e18;
        p.maxStrikeWad = 1_000_000e18;
        p.maxReportLifetime = 900;
        p.riskSetId = RISK_SET;
        p.shortCapUnderlyingWad = 10_000e18;
        p.pythBaseFeed = ETH_FEED;
        p.settlement = ISettlementOracle.SettlementOracleConfig({
            underlying: address(m.weth),
            settlementAsset: address(m.usdc),
            primary: ISettlementOracle.FeedSource({
                kind: ISettlementOracle.FeedKind.DIRECT,
                feed: address(m.ethFeed),
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
        p.publishers = new address[](2);
        p.independent = new bool[](2);
        (p.publishers[0], p.publishers[1]) = (accts[2], accts[3]);
        (p.independent[0], p.independent[1]) = (true, false);
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

    function _listSeries(Mocks memory m, Deployment memory d, uint64[] memory expiries)
        internal
        returns (bytes32[] memory ids, address[] memory books)
    {
        uint256[4] memory strikes = [uint256(3500e18), 4000e18, 4500e18, 5000e18];
        ids = new bytes32[](16);
        books = new address[](16);
        bytes32 kuru = d.kuruAdapter.VENUE_ID();
        for (uint256 i; i < 16; ++i) {
            SeriesParams memory sp = SeriesParams({
                underlying: address(m.weth),
                settlementAsset: address(m.usdc),
                optionType: i % 2 == 0 ? OptionType.CALL : OptionType.PUT,
                strikeWad: strikes[(i / 2) % 4],
                contractSizeWad: 1e18,
                expiry: expiries[i / 8],
                settlementOracleConfigId: d.settlementOracle.computeConfigId(_ethListing(m).settlement),
                volSurfaceProductId: d.registry.computeProductId(address(m.weth), address(m.usdc)),
                riskParameterSetId: RISK_SET
            });
            vm.broadcast(keys[1]);
            ids[i] = d.registry.createSeries(sp);
            address w = d.registry.getSeries(ids[i]).wrapper;
            vm.startBroadcast(keys[0]); // Kuru deploys the book (owner-gated on the real Kuru)
            MockKuruOrderBook b = new MockKuruOrderBook(IERC20(w), IERC20(address(m.usdc)), 18, 6, 1e4, 1e16, 30);
            m.kuru.setMarket(address(b), _kuruParams(w, address(m.usdc)));
            vm.stopBroadcast();
            books[i] = address(b);
            vm.broadcast(keys[1]);
            d.venues.registerMarket(kuru, address(b), ids[i], "");
        }
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

    /// @dev A first spot price (4,000) and a signed 60%-IV surface whose tenors are the two expiries.
    function _publish(Mocks memory m, Deployment memory d, bytes32 productId, uint64[] memory tenors) internal {
        Market memory mk = Market({
            pyth: address(m.pyth),
            surface: IVolSurfaceOracle(address(d.surface)),
            productId: productId,
            underlying: address(m.weth),
            asset: address(m.usdc),
            pythFeed: ETH_FEED,
            keyA: keys[2],
            keyB: keys[3]
        });
        OracleUpdate memory u = _oracleUpdate(mk, 4000e18, 0.6e18, tenors, 1);
        uint256 fee = m.pyth.getUpdateFee(u.spotUpdates);
        vm.broadcast(keys[4]); // the keeper submits it
        d.clearing.updateOracles{value: fee}(u);
    }

    function _fundUsers(Mocks memory m) internal {
        vm.startBroadcast(keys[0]);
        for (uint256 i = 5; i < 10; ++i) {
            m.usdc.mint(accts[i], 100_000e6);
        }
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ manifest extras

    function _extra(
        Mocks memory m,
        bytes32 productId,
        bytes32 cfgId,
        bytes32[] memory ids,
        address[] memory books,
        uint64[] memory expiries
    ) internal returns (string memory) {
        string memory k = "extra";
        vm.serializeAddress(k, "usdc", address(m.usdc));
        vm.serializeAddress(k, "weth", address(m.weth));
        vm.serializeAddress(k, "pyth", address(m.pyth));
        vm.serializeAddress(k, "ethUsdcSettlementFeed", address(m.ethFeed));
        vm.serializeAddress(k, "kuruRouter", address(m.kuru));
        vm.serializeBytes32(k, "ethUsdcProductId", productId);
        vm.serializeBytes32(k, "ethUsdcPythFeedId", ETH_FEED);
        vm.serializeBytes32(k, "ethUsdcSettlementConfigId", cfgId);
        vm.serializeBytes32(k, "ethUsdcRiskSetId", RISK_SET);
        vm.serializeAddress(k, "governance", accts[1]);
        vm.serializeAddress(k, "publisherA", accts[2]);
        vm.serializeAddress(k, "publisherB", accts[3]);
        vm.serializeAddress(k, "keeper", accts[4]);
        address[] memory users = new address[](5);
        for (uint256 i; i < 5; ++i) {
            users[i] = accts[5 + i];
        }
        vm.serializeAddress(k, "users", users);
        uint256[] memory exp = new uint256[](expiries.length);
        for (uint256 i; i < expiries.length; ++i) {
            exp[i] = expiries[i];
        }
        vm.serializeUint(k, "expiries", exp);
        vm.serializeBytes32(k, "seriesIds", ids);
        return vm.serializeAddress(k, "kuruBooks", books);
    }
}
