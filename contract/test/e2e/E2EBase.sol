// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptaraDeploy} from "../../script/OptaraDeploy.sol";
import {MerkleHelper} from "../utils/MerkleHelper.sol";
import {MockERC20} from "../mocks/MockDependencies.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockKuruRouter, MockKuruOrderBook} from "../mocks/MockVenues.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {IVenueRouter} from "../../src/interfaces/IVenueRouter.sol";
import {IKuruRouter} from "../../src/venues/kuru/IKuru.sol";
import {OptionType, ProductConfig, SeriesParams} from "../../src/libraries/OptaraTypes.sol";

/// @notice End-to-end base (TESTING.md §0.1): the whole protocol deployed by the production deployment code
///         (script/OptaraDeploy.sol), then ETH/USDC listed the way operations do it (USER_FLOWS.md F18) through the
///         role holders only. External systems are mocks: Pyth, a Chainlink-style ETH/USDC feed, Kuru (with the
///         semantics verified on the mainnet fork) and the USDC token. Surfaces are signed by two of three publishers
///         (F19) and every risk-increasing call carries its own OracleUpdate.
abstract contract E2EBase is Test, OptaraDeploy {
    // ---- people ----
    address internal governance = makeAddr("governanceTimelock");
    address internal guardian = makeAddr("guardian");
    address internal council = makeAddr("emergencyCouncil");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal seriesCreator = makeAddr("seriesCreator");
    address internal venueAdmin = makeAddr("venueAdmin");
    address internal alice = makeAddr("alice"); // writer
    address internal bob = makeAddr("bob"); // writer
    address internal carol = makeAddr("carol"); // buyer
    address internal keeper = makeAddr("keeper"); // liquidator and settlement keeper
    address internal maker = makeAddr("kuruMaker");
    uint256 internal keyA;
    uint256 internal keyB;

    // ---- external systems ----
    MockERC20 internal usdc;
    address internal weth = makeAddr("WETH");
    MockPyth internal pyth;
    MockAggregator internal ethFeed;
    MockKuruRouter internal kuruRouter;

    // ---- the protocol ----
    Deployment internal d;
    bytes32 internal eth; // productId
    bytes32 internal cfgId; // settlement oracle config
    bytes32 internal c4500;
    bytes32 internal c5000;
    bytes32 internal p3500;
    bytes32 internal group30;
    mapping(bytes32 => MockKuruOrderBook) internal books;

    bytes32 internal constant RISK_SET = keccak256("ETH default");
    bytes32 internal constant ETH_FEED = keccak256("pyth ETH/USDC");
    bytes32 internal constant KURU = keccak256("KURU");
    uint64 internal constant T0 = 1_791_244_800; // 2026-10-06
    uint64 internal constant EXP30 = T0 + 30 days;
    uint64 internal constant EXP60 = T0 + 60 days;

    uint64 internal surfaceSeq;
    uint256 internal pythTime;
    uint256 internal price = 4000e18;
    uint256 internal iv = 0.6e18;

    function setUp() public virtual {
        vm.warp(T0);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pyth = new MockPyth();
        pyth.setFeePerUpdate(0);
        ethFeed = new MockAggregator(8);
        ethFeed.pushRound(3990e8, T0 - 1 hours);
        kuruRouter = new MockKuruRouter();
        address pubA;
        address pubB;
        (pubA, keyA) = makeAddrAndKey("publisherA");
        (pubB, keyB) = makeAddrAndKey("publisherB");

        d = _deploy(
            Config({
                deployer: address(this),
                governance: governance,
                guardian: guardian,
                council: council,
                riskAdmin: riskAdmin,
                oracleAdmin: oracleAdmin,
                seriesCreator: seriesCreator,
                venueAdmin: venueAdmin,
                upgradeDelay: 7 days,
                emergencyDelay: 24 hours,
                pyth: address(pyth),
                kuruRouter: address(kuruRouter),
                surfaceQuorum: 2,
                maxSeriesPerAccount: 16,
                maxBucketsPerAccount: 4,
                minPositionQty: 1e16
            })
        );
        _listEth(pubA, pubB);
    }

    // ------------------------------------------------------------------ F18: listing (ops)

    function _listEth(address pubA, address pubB) internal {
        vm.startPrank(governance);
        d.registry.setSettlementAssetApproved(address(usdc), true);
        eth = d.registry.approveProduct(weth, address(usdc), _productConfig());
        d.risk.createRiskSet(RISK_SET, _riskParams());
        d.risk.assignProductRiskSet(eth, RISK_SET);
        d.risk.setProductShortCap(eth, 1_000_000e18);
        d.spot
            .setSource(
                eth,
                ILiveSpotOracle.SpotSource({
                    kind: ILiveSpotOracle.SourceKind.PYTH_DIRECT,
                    baseFeedId: ETH_FEED,
                    quoteFeedId: 0,
                    maxSpotAge: 60,
                    maxConfidenceBps: 100
                })
            );
        d.surface.setSurfaceConfig(eth, _surfaceConfig());
        d.surface.addPublisher(pubA, true);
        d.surface.addPublisher(pubB, false);
        d.fees.setMinSellerFee(address(usdc), 0.1e6);
        d.fees.setRewards(address(usdc), 2e6, 0.5e6);
        d.liquidation.setMaxInsurancePerLiquidation(address(usdc), 500e6);
        d.venues.setAdapterEnabled(KURU, true);
        vm.stopPrank();

        vm.prank(oracleAdmin);
        cfgId = d.settlementOracle.registerConfig(_settlementConfig());
        vm.prank(governance);
        d.settlementOracle.setConfigApproved(cfgId, true);

        // reserves: the asset stays close-only until insurance and the keeper reserve are seeded (FEES.md §6)
        vm.prank(riskAdmin);
        d.fees.setMinimums(address(usdc), 1000e6, 100e6);
        _seedInsurance(1000e6);
        usdc.mint(address(this), 100e6);
        usdc.approve(address(d.fees), 100e6);
        d.fees.fundKeeperReserve(address(usdc), 100e6);

        c4500 = _createSeries(OptionType.CALL, 4500e18, EXP30);
        c5000 = _createSeries(OptionType.CALL, 5000e18, EXP30);
        p3500 = _createSeries(OptionType.PUT, 3500e18, EXP30);
        group30 = d.registry.groupOf(c4500);
        _listOnKuru(c4500);
        _listOnKuru(c5000);
    }

    function _createSeries(OptionType t, uint256 strike, uint64 expiry) internal returns (bytes32 id) {
        vm.prank(seriesCreator);
        id = d.registry
            .createSeries(
                SeriesParams({
                    underlying: weth,
                    settlementAsset: address(usdc),
                    optionType: t,
                    strikeWad: strike,
                    contractSizeWad: 1e18,
                    expiry: expiry,
                    settlementOracleConfigId: cfgId,
                    volSurfaceProductId: eth,
                    riskParameterSetId: RISK_SET
                })
            );
    }

    /// @dev Kuru creates the book (owner-gated on the real Kuru); the venue admin registers it.
    function _listOnKuru(bytes32 seriesId) internal {
        address w = _wrapper(seriesId);
        MockKuruOrderBook b = new MockKuruOrderBook(IERC20(w), IERC20(address(usdc)), 18, 6, 1e4, 1e16, 30);
        kuruRouter.setMarket(
            address(b),
            IKuruRouter.MarketParams({
                pricePrecision: 1e4,
                sizePrecision: 1e16,
                baseAssetAddress: w,
                baseAssetDecimals: 18,
                quoteAssetAddress: address(usdc),
                quoteAssetDecimals: 6,
                tickSize: 100,
                minSize: 1e14,
                maxSize: 1e20,
                takerFeeBps: 30,
                makerFeeBps: 10
            })
        );
        books[seriesId] = b;
        vm.prank(venueAdmin);
        d.venues.registerMarket(KURU, address(b), seriesId, "");
    }

    // ------------------------------------------------------------------ F19: market data

    /// @dev A fresh OracleUpdate at the current `price` and `iv`: a Pyth blob plus a report signed by two publishers
    ///      with proofs for every leaf (strikes 3,500 / 4,500 / 5,000 / 6,200 / 8,000; tenors 30 and 60 days or the
    ///      next two after expiry).
    function _update() internal returns (OracleUpdate memory u) {
        u.spotUpdates = new bytes[](1);
        pythTime = pythTime >= block.timestamp ? pythTime + 1 : block.timestamp;
        // forge-lint: disable-next-line(unsafe-typecast)
        u.spotUpdates[0] = pyth.encode(ETH_FEED, int64(int256(price / 1e10)), -8, pythTime);
        u.spotProductIds = new bytes32[](1);
        u.spotProductIds[0] = eth;
        u.reports = new IVolSurfaceOracle.SurfaceReport[](1);
        u.reportSignatures = new bytes[][](1);
        (u.reports[0], u.reportSignatures[0], u.nodes) = _report();
    }

    function _report()
        internal
        returns (IVolSurfaceOracle.SurfaceReport memory r, bytes[] memory sigs, IVolSurfaceOracle.NodeProof[] memory n)
    {
        uint256[5] memory strikes = [uint256(3500e18), 4500e18, 5000e18, 6200e18, 8000e18];
        r.chainId = block.chainid;
        r.verifyingContract = address(d.surface);
        r.productId = eth;
        r.underlying = weth;
        r.settlementAsset = address(usdc);
        r.surfaceSeq = ++surfaceSeq;
        r.validAfter = uint64(block.timestamp);
        r.expiresAt = r.validAfter + 900;
        r.kNodes = new int256[](5);
        for (uint256 j; j < 5; ++j) {
            r.kNodes[j] = OptionPricer.logMoneyness(strikes[j], price);
        }
        (r.tenorTimestamps[0], r.tenorTimestamps[1]) =
            block.timestamp < EXP30 ? (EXP30, EXP60) : (EXP60, EXP60 + 30 days);
        bytes32[] memory leaves = new bytes32[](10);
        uint256[] memory w = new uint256[](10);
        for (uint256 i; i < 2; ++i) {
            uint256 t = uint256(r.tenorTimestamps[i] - r.validAfter) * 1e18 / FixedPoint.YEAR;
            uint256 v = iv * iv / 1e18 * t / 1e18;
            r.atmTotalVarianceByTenor[i] = v;
            for (uint256 j; j < 5; ++j) {
                w[i * 5 + j] = v;
                // forge-lint: disable-next-line(unsafe-typecast)
                leaves[i * 5 + j] = keccak256(abi.encode(eth, r.surfaceSeq, uint8(i), uint8(j), v));
            }
        }
        r.surfaceMinIvBps = 1000;
        r.surfaceMaxIvBps = 50_000;
        r.confidenceBps = 100;
        r.sourceCount = 3;
        r.surfaceRoot = MerkleHelper.root(leaves);
        sigs = _sign(r);
        n = _proofs(r.surfaceSeq, w, leaves);
    }

    /// @dev Publisher A and publisher B sign the report's EIP-712 digest (quorum 2), in address order.
    function _sign(IVolSurfaceOracle.SurfaceReport memory r) internal view returns (bytes[] memory sigs) {
        bytes32 digest = d.surface.reportDigest(r);
        (uint8 va, bytes32 ra, bytes32 sa) = vm.sign(keyA, digest);
        (uint8 vb, bytes32 rb, bytes32 sb) = vm.sign(keyB, digest);
        sigs = new bytes[](2);
        (bytes memory a, bytes memory b) = (abi.encodePacked(ra, sa, va), abi.encodePacked(rb, sb, vb));
        (sigs[0], sigs[1]) = vm.addr(keyA) < vm.addr(keyB) ? (a, b) : (b, a);
    }

    function _proofs(uint64 seq, uint256[] memory w, bytes32[] memory leaves)
        internal
        view
        returns (IVolSurfaceOracle.NodeProof[] memory n)
    {
        n = new IVolSurfaceOracle.NodeProof[](w.length);
        for (uint256 i; i < w.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            n[i] =
                IVolSurfaceOracle.NodeProof(eth, seq, uint8(i / 5), uint8(i % 5), w[i], MerkleHelper.proof(leaves, i));
        }
    }

    /// @dev Moves the market and pushes it on-chain (anyone may call updateOracles).
    function _moveTo(uint256 newPrice, uint256 newIv) internal {
        (price, iv) = (newPrice, newIv);
        d.clearing.updateOracles(_update());
    }

    function _empty() internal pure returns (OracleUpdate memory u) {}

    // ------------------------------------------------------------------ actions

    function _account(address owner) internal returns (uint256 id) {
        vm.prank(owner);
        id = d.ledger.createSubAccount(address(usdc));
    }

    function _deposit(uint256 accountId, address from, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(d.clearing), amount);
        d.clearing.depositCollateral(accountId, amount);
        vm.stopPrank();
    }

    function _wrapper(bytes32 seriesId) internal view returns (address) {
        return d.registry.getSeries(seriesId).wrapper;
    }

    function _seedInsurance(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(d.insurance), amount);
        d.insurance.deposit(address(usdc), amount);
    }

    function _health(uint256 accountId) internal view returns (int256) {
        IPortfolioRiskManager.Risk memory r = d.risk.riskOf(accountId);
        return r.equity - int256(r.maintenanceMargin);
    }

    function _buyOrder(bytes32 seriesId, uint256 premiumIn, uint256 minQty, address recipient)
        internal
        view
        returns (IVenueRouter.BuyOrder memory)
    {
        return IVenueRouter.BuyOrder(
            KURU, seriesId, premiumIn, minQty, type(uint256).max, type(uint256).max, recipient, uint64(block.timestamp)
        );
    }

    function _sellOrder(bytes32 seriesId, uint256 qty, uint256 minProceeds, address recipient)
        internal
        view
        returns (IVenueRouter.SellOrder memory)
    {
        return IVenueRouter.SellOrder(
            KURU, seriesId, qty, minProceeds, type(uint256).max, recipient, uint64(block.timestamp)
        );
    }

    /// @dev Custody = Σ cash + pool (INV-7) over the listed accounts.
    function _assertCustody(uint256[] memory accts) internal view {
        uint256 cash;
        for (uint256 i; i < accts.length; ++i) {
            cash += d.ledger.cashOf(accts[i]);
        }
        assertEq(usdc.balanceOf(address(d.clearing)), cash + d.window.groupAccounting(group30).pool, "INV-7");
    }

    // ------------------------------------------------------------------ parameters

    function _productConfig() internal pure returns (ProductConfig memory) {
        return ProductConfig({
            minStrikeWad: 100e18,
            maxStrikeWad: 1_000_000e18,
            minContractSizeWad: 0.001e18,
            maxContractSizeWad: 100e18,
            minTimeToExpiry: 1 hours,
            maxTimeToExpiry: 400 days,
            maxSettlementPriceWad: 1e30,
            underlyingSymbol: "ETH",
            assetSymbol: "USDC"
        });
    }

    /// @dev PARAMETERS.md §2–§3 defaults.
    function _riskParams() internal pure returns (IPortfolioRiskManager.RiskParams memory p) {
        int32[8] memory imSpots = [int32(-5000), -3000, -1500, 0, 1500, 3000, 5000, 10_000];
        int32[6] memory mmSpots = [int32(-3000), -1500, 0, 1500, 3000, 5000];
        p.initialSet = new IPortfolioRiskManager.Scenario[](24);
        for (uint256 i; i < 8; ++i) {
            p.initialSet[i] = IPortfolioRiskManager.Scenario(imSpots[i], -3000, 0, 0);
            p.initialSet[8 + i] = IPortfolioRiskManager.Scenario(imSpots[i], 7500, 0, 0);
            p.initialSet[16 + i] = IPortfolioRiskManager.Scenario(imSpots[i], 0, 1, 0);
        }
        p.maintenanceSet = new IPortfolioRiskManager.Scenario[](12);
        for (uint256 i; i < 6; ++i) {
            p.maintenanceSet[i] = IPortfolioRiskManager.Scenario(mmSpots[i], -3000, 0, 0);
            p.maintenanceSet[6 + i] = IPortfolioRiskManager.Scenario(mmSpots[i], 3000, 0, 0);
        }
        p.imBufferBps = 500;
        p.minIv = 0.1e18;
        p.maxIv = 5e18;
        p.nearExpiryFloorSeconds = 3600;
        p.maxOpenInterestPerSeries = 1e24;
    }

    function _surfaceConfig() internal pure returns (IVolSurfaceOracle.SurfaceConfig memory) {
        return IVolSurfaceOracle.SurfaceConfig({
            maxReportLifetime: 900,
            maxIvMoveBps: 50_000,
            maxConfidenceBps: 1000,
            minIvBps: 1000,
            maxIvBps: 50_000,
            surfaceStaleAfter: 300,
            maxSurfaceStale: 21_600,
            staleIvPenaltyBpsPerHour: 1000,
            maxLongTimeValueStale: 1800
        });
    }

    function _settlementConfig() internal view returns (ISettlementOracle.SettlementOracleConfig memory) {
        return ISettlementOracle.SettlementOracleConfig({
            underlying: weth,
            settlementAsset: address(usdc),
            primary: ISettlementOracle.FeedSource({
                kind: ISettlementOracle.FeedKind.DIRECT,
                feed: address(ethFeed),
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
    }

    /// @dev The settlement data proving `inForce` (with its successor, or 0 if it is the latest round).
    function _proof(uint80 inForce, uint80 successor) internal pure returns (bytes memory) {
        ISettlementOracle.RoundProof[] memory p = new ISettlementOracle.RoundProof[](1);
        p[0] = ISettlementOracle.RoundProof(inForce, successor);
        return abi.encode(ISettlementOracle.SettlementData(0, p, new ISettlementOracle.RoundProof[](0)));
    }
}
