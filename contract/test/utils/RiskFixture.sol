// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceFixture} from "./GovernanceFixture.sol";
import {MerkleHelper} from "./MerkleHelper.sol";
import {OptionSeriesRegistry} from "../../src/series/OptionSeriesRegistry.sol";
import {ExternalOptionFactory} from "../../src/series/ExternalOptionFactory.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {SubAccounts} from "../../src/accounts/SubAccounts.sol";
import {LiveSpotOracle} from "../../src/oracle/LiveSpotOracle.sol";
import {VolSurfaceOracle} from "../../src/oracle/VolSurfaceOracle.sol";
import {PortfolioRiskManager} from "../../src/risk/PortfolioRiskManager.sol";
import {FeeController} from "../../src/fees/FeeController.sol";
import {InsuranceFund} from "../../src/insurance/InsuranceFund.sol";
import {OptionClearing} from "../../src/clearing/OptionClearing.sol";
import {IOptionClearing} from "../../src/interfaces/IOptionClearing.sol";
import {LiquidationModule} from "../../src/liquidation/LiquidationModule.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IInsuranceFund} from "../../src/interfaces/IInsuranceFund.sol";
import {IPortfolioRiskManager as IPRM} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IExternalOptionFactory} from "../../src/interfaces/IExternalOptionFactory.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {
    ISettlementConfigs,
    IRiskSets,
    ISettlementState,
    IReserveStatus
} from "../../src/interfaces/IExternalDependencies.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {OptionType, ProductConfig, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {
    MockERC20,
    MockSettlementConfigs,
    MockSettlementState,
    MockReserveStatus,
    MockSettlementOracle
} from "../mocks/MockDependencies.sol";
import {SettlementWindow} from "../../src/settlement/SettlementWindow.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";
import {MockPyth} from "../mocks/MockPyth.sol";

/// @notice Full stack for margin tests: registry (with the real risk manager as its risk-set checker), factory,
///         ledger, spot oracle (mock Pyth), surface oracle and PortfolioRiskManager, deployed with predicted
///         addresses. Settlement state is a mock until step 11; the reserve check is a mock unless
///         `_useRealReserves()`. Ledger writes come from a stand-in `clearing` address unless `_deployRealClearing()`.
abstract contract RiskFixture is GovernanceFixture {
    OptionSeriesRegistry internal registry;
    ExternalOptionFactory internal factory;
    SubAccounts internal ledger;
    LiveSpotOracle internal spot;
    VolSurfaceOracle internal surface;
    PortfolioRiskManager internal risk;
    InsuranceFund internal insurance;
    FeeController internal fees;
    OptionClearing internal clearingModule; // set only when `_deployRealClearing()` is true
    LiquidationModule internal liquidation; // set only when `_deployRealLiquidation()` is true
    SettlementWindow internal window; // set only when `_deployRealSettlement()` is true
    address internal settlementOracle; // the window's oracle: a MockSettlementOracle unless overridden
    address internal router = makeAddr("VenueRouter");
    MockPyth internal pyth;
    MockSettlementConfigs internal settlementConfigs;
    MockSettlementState internal settlementState;
    MockReserveStatus internal reserves;
    MockERC20 internal usdc;

    address internal weth = makeAddr("WETH");
    address internal wbtc = makeAddr("WBTC");
    address internal clearing = makeAddr("OptionClearing");
    address internal liquidationModule = makeAddr("LiquidationModule");
    address internal settlementWindow = makeAddr("SettlementWindow");
    address internal seriesCreator = makeAddr("seriesCreator");
    address internal alice = makeAddr("alice");

    bytes32 internal constant RISK_SET = keccak256("default risk set");
    bytes32 internal constant ETH_CFG = keccak256("ETH/USDC settlement");
    bytes32 internal constant BTC_CFG = keccak256("BTC/USDC settlement");
    bytes32 internal constant ETH_FEED = keccak256("pyth ETH/USDC");
    bytes32 internal constant BTC_FEED = keccak256("pyth BTC/USDC");
    uint64 internal constant T0 = 1_791_244_800; // 2026-10-06
    uint64 internal constant EXP30 = T0 + 30 days;

    bytes32 internal ethUsdc;
    bytes32 internal btcUsdc;
    uint256 internal keyA;
    uint256 internal keyB;
    mapping(bytes32 => uint64) internal seq;
    uint256 internal pythTime;

    function _deployRisk() internal {
        vm.warp(T0);
        pyth = new MockPyth();
        pyth.setFeePerUpdate(0);
        settlementConfigs = new MockSettlementConfigs();
        settlementState = new MockSettlementState();
        reserves = new MockReserveStatus();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        _deployGovernanceCore();
        _deployModules();
        pc.grantRole(Roles.SERIES_CREATOR, seriesCreator);
        _handOver();
        _configure();
    }

    function _deployModules() internal {
        address registryAddr = _nextProxy(0);
        address factoryAddr = _nextProxy(1);
        address ledgerAddr = _nextProxy(2);
        address spotAddr = _nextProxy(3);
        address surfaceAddr = _nextProxy(4);
        address riskAddr = _nextProxy(5);
        address insuranceAddr = _nextProxy(6);
        address feesAddr = _nextProxy(7);
        if (_deployRealClearing()) clearing = _nextProxy(8);
        if (_deployRealLiquidation()) liquidationModule = _nextProxy(9);
        if (_deployRealSettlement()) settlementWindow = _nextProxy(10);
        address settlementStateAddr = _deployRealSettlement() ? settlementWindow : address(settlementState);
        IProtocolControl c = IProtocolControl(address(pc));
        registry = OptionSeriesRegistry(
            upgradeAdmin.deployProxy(
                address(new OptionSeriesRegistry()),
                abi.encodeCall(
                    OptionSeriesRegistry.initialize,
                    (
                        c,
                        IExternalOptionFactory(factoryAddr),
                        ISettlementConfigs(address(settlementConfigs)),
                        IRiskSets(riskAddr)
                    )
                )
            )
        );
        factory = ExternalOptionFactory(
            upgradeAdmin.deployProxy(
                address(new ExternalOptionFactory()),
                abi.encodeCall(
                    ExternalOptionFactory.initialize,
                    (
                        c,
                        address(new ExternalOptionWrapper()),
                        registryAddr,
                        clearing,
                        settlementWindow,
                        liquidationModule
                    )
                )
            )
        );
        ledger = SubAccounts(
            upgradeAdmin.deployProxy(
                address(new SubAccounts()),
                abi.encodeCall(
                    SubAccounts.initialize,
                    (c, IOptionSeriesRegistry(registryAddr), clearing, liquidationModule, settlementWindow, 16, 4, 1e16)
                )
            )
        );
        spot = LiveSpotOracle(
            upgradeAdmin.deployProxy(
                address(new LiveSpotOracle()),
                abi.encodeCall(
                    LiveSpotOracle.initialize, (c, IPyth(address(pyth)), IOptionSeriesRegistry(registryAddr))
                )
            )
        );
        surface = VolSurfaceOracle(
            upgradeAdmin.deployProxy(
                address(new VolSurfaceOracle()),
                abi.encodeCall(VolSurfaceOracle.initialize, (c, IOptionSeriesRegistry(registryAddr), 2))
            )
        );
        risk = PortfolioRiskManager(
            upgradeAdmin.deployProxy(
                address(new PortfolioRiskManager()),
                abi.encodeCall(
                    PortfolioRiskManager.initialize,
                    (
                        c,
                        ISubAccounts(ledgerAddr),
                        IOptionSeriesRegistry(registryAddr),
                        ILiveSpotOracle(spotAddr),
                        IVolSurfaceOracle(surfaceAddr),
                        ISettlementState(settlementStateAddr),
                        IReserveStatus(_useRealReserves() ? feesAddr : address(reserves))
                    )
                )
            )
        );
        insurance = InsuranceFund(
            upgradeAdmin.deployProxy(
                address(new InsuranceFund()),
                abi.encodeCall(InsuranceFund.initialize, (c, feesAddr, clearing, liquidationModule, settlementWindow))
            )
        );
        fees = FeeController(
            upgradeAdmin.deployProxy(
                address(new FeeController()),
                abi.encodeCall(
                    FeeController.initialize,
                    (
                        c,
                        IInsuranceFund(insuranceAddr),
                        IPRM(riskAddr),
                        IOptionSeriesRegistry(registryAddr),
                        clearing,
                        router,
                        settlementWindow
                    )
                )
            )
        );
        assertEq(address(risk), riskAddr, "address prediction");
        assertEq(address(fees), feesAddr, "address prediction");
        if (_deployRealClearing()) _deployClearing(c);
        if (_deployRealLiquidation()) _deployLiquidation(c);
        if (_deployRealSettlement()) _deploySettlement(c);
    }

    function _deploySettlement(IProtocolControl c) private {
        settlementOracle = _settlementOracleFor(c);
        ISettlementWindow.Modules memory m = ISettlementWindow.Modules({
            ledger: address(ledger),
            registry: address(registry),
            settlementOracle: settlementOracle,
            fees: address(fees),
            insurance: address(insurance),
            clearing: address(clearingModule)
        });
        window = SettlementWindow(
            upgradeAdmin.deployProxy(
                address(new SettlementWindow()), abi.encodeCall(SettlementWindow.initialize, (c, m))
            )
        );
        assertEq(address(window), settlementWindow, "address prediction");
    }

    /// @dev The SettlementWindow's oracle; override to use the real SettlementOracle.
    function _settlementOracleFor(IProtocolControl) internal virtual returns (address) {
        return address(new MockSettlementOracle());
    }

    /// @dev Override (together with real clearing and liquidation) to deploy the real SettlementWindow.
    function _deployRealSettlement() internal pure virtual returns (bool) {
        return false;
    }

    function _deployLiquidation(IProtocolControl c) private {
        ILiquidationModule.Modules memory m = ILiquidationModule.Modules({
            ledger: address(ledger),
            registry: address(registry),
            risk: address(risk),
            insurance: address(insurance),
            clearing: address(clearingModule),
            spot: address(spot),
            surface: address(surface)
        });
        liquidation = LiquidationModule(
            upgradeAdmin.deployProxy(
                address(new LiquidationModule()), abi.encodeCall(LiquidationModule.initialize, (c, m))
            )
        );
        assertEq(address(liquidation), liquidationModule, "address prediction");
    }

    /// @dev Override (together with `_deployRealClearing`) to deploy the real LiquidationModule.
    function _deployRealLiquidation() internal pure virtual returns (bool) {
        return false;
    }

    function _deployClearing(IProtocolControl c) private {
        IOptionClearing.Modules memory m = IOptionClearing.Modules({
            ledger: address(ledger),
            registry: address(registry),
            risk: address(risk),
            fees: address(fees),
            insurance: address(insurance),
            spot: address(spot),
            surface: address(surface),
            settlementState: _deployRealSettlement() ? settlementWindow : address(settlementState),
            liquidationModule: liquidationModule,
            settlementWindow: settlementWindow
        });
        clearingModule = OptionClearing(
            upgradeAdmin.deployProxy(address(new OptionClearing()), abi.encodeCall(OptionClearing.initialize, (c, m)))
        );
        assertEq(address(clearingModule), clearing, "address prediction");
    }

    /// @dev Override to deploy the real OptionClearing at the `clearing` address instead of a stand-in.
    function _deployRealClearing() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Override to wire the risk manager's reserve check to the real FeeController instead of the mock.
    function _useRealReserves() internal pure virtual returns (bool) {
        return false;
    }

    function _configure() internal {
        settlementConfigs.set(ETH_CFG, weth, address(usdc), true);
        settlementConfigs.set(BTC_CFG, wbtc, address(usdc), true);
        address pubA;
        address pubB;
        (pubA, keyA) = makeAddrAndKey("publisherA");
        (pubB, keyB) = makeAddrAndKey("publisherB");
        vm.startPrank(governance);
        registry.setSettlementAssetApproved(address(usdc), true);
        ethUsdc = registry.approveProduct(weth, address(usdc), _productConfig("ETH"));
        btcUsdc = registry.approveProduct(wbtc, address(usdc), _productConfig("BTC"));
        risk.createRiskSet(RISK_SET, _defaultRiskParams());
        risk.assignProductRiskSet(ethUsdc, RISK_SET);
        risk.assignProductRiskSet(btcUsdc, RISK_SET);
        risk.setProductShortCap(ethUsdc, 1e9 * 1e18);
        risk.setProductShortCap(btcUsdc, 1e9 * 1e18);
        spot.setSource(ethUsdc, _direct(ETH_FEED));
        spot.setSource(btcUsdc, _direct(BTC_FEED));
        surface.setSurfaceConfig(ethUsdc, _surfaceConfig());
        surface.setSurfaceConfig(btcUsdc, _surfaceConfig());
        surface.addPublisher(pubA, true);
        surface.addPublisher(pubB, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ parameters

    function _productConfig(string memory sym) internal pure returns (ProductConfig memory) {
        return ProductConfig({
            minStrikeWad: 100e18,
            maxStrikeWad: 1_000_000e18,
            minContractSizeWad: 0.001e18,
            maxContractSizeWad: 100e18,
            minTimeToExpiry: 1 hours,
            maxTimeToExpiry: 400 days,
            maxSettlementPriceWad: 1e30,
            underlyingSymbol: sym,
            assetSymbol: "USDC"
        });
    }

    /// @dev PARAMETERS.md §2–§3 defaults.
    function _defaultRiskParams() internal pure returns (IPortfolioRiskManager.RiskParams memory p) {
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
            maxIvMoveBps: 50_000, // permissive: tests move IV freely
            maxConfidenceBps: 1000,
            minIvBps: 1000,
            maxIvBps: 50_000,
            surfaceStaleAfter: 300,
            maxSurfaceStale: 21_600,
            staleIvPenaltyBpsPerHour: 1000,
            maxLongTimeValueStale: 1800
        });
    }

    function _direct(bytes32 feed) internal pure returns (ILiveSpotOracle.SpotSource memory) {
        return ILiveSpotOracle.SpotSource({
            kind: ILiveSpotOracle.SourceKind.PYTH_DIRECT, baseFeedId: feed, quoteFeedId: 0, maxSpotAge: 60
        });
    }

    // ------------------------------------------------------------------ market data

    /// @dev Pushes a spot price published now (expo −8).
    function _setSpot(bytes32 productId, uint256 priceWad) internal {
        bytes[] memory u = new bytes[](1);
        u[0] = _spotBlob(productId, priceWad);
        bytes32[] memory ps = new bytes32[](1);
        ps[0] = productId;
        spot.update(u, ps);
    }

    /// @dev A Pyth update blob for `productId` published now (or 1 s after the previous one), expo −8.
    function _spotBlob(bytes32 productId, uint256 priceWad) internal returns (bytes memory) {
        bytes32 feed = productId == ethUsdc ? ETH_FEED : BTC_FEED;
        pythTime = pythTime >= block.timestamp ? pythTime + 1 : block.timestamp;
        // forge-lint: disable-next-line(unsafe-typecast)
        return pyth.encode(feed, int64(int256(priceWad / 1e10)), -8, pythTime);
    }

    /// @dev Publishes a surface whose nodes sit exactly at the given strikes (log-moneyness at `spotWad`) with the
    ///         given IVs, flat across `tenors` (total variance = σ² × T from now), and proves every leaf.
    function _setSurface(
        bytes32 productId,
        uint256 spotWad,
        uint256[] memory strikes,
        uint256[] memory ivs,
        uint64[] memory tenors
    ) internal {
        (IVolSurfaceOracle.SurfaceReport memory r, bytes[] memory sigs, IVolSurfaceOracle.NodeProof[] memory n) =
            _buildSurface(productId, spotWad, strikes, ivs, tenors);
        surface.submitReport(r, sigs);
        surface.proveNodes(n);
    }

    /// @dev Builds (without submitting) the next signed report for `productId` and proofs for all its leaves.
    function _buildSurface(
        bytes32 productId,
        uint256 spotWad,
        uint256[] memory strikes,
        uint256[] memory ivs,
        uint64[] memory tenors
    )
        internal
        returns (IVolSurfaceOracle.SurfaceReport memory r, bytes[] memory sigs, IVolSurfaceOracle.NodeProof[] memory n)
    {
        r.chainId = block.chainid;
        r.verifyingContract = address(surface);
        r.productId = productId;
        r.underlying = productId == ethUsdc ? weth : wbtc;
        r.settlementAsset = address(usdc);
        r.surfaceSeq = ++seq[productId];
        r.validAfter = uint64(block.timestamp);
        r.expiresAt = r.validAfter + 900;
        r.kNodes = new int256[](strikes.length);
        for (uint256 j; j < strikes.length; ++j) {
            r.kNodes[j] = OptionPricer.logMoneyness(strikes[j], spotWad);
        }
        uint256[] memory w = new uint256[](tenors.length * strikes.length);
        for (uint256 i; i < tenors.length; ++i) {
            r.tenorTimestamps[i] = tenors[i];
            uint256 t = uint256(tenors[i] - r.validAfter) * 1e18 / FixedPoint.YEAR;
            for (uint256 j; j < strikes.length; ++j) {
                w[i * strikes.length + j] = ivs[j] * ivs[j] / 1e18 * t / 1e18;
            }
            r.atmTotalVarianceByTenor[i] = w[i * strikes.length + _atm(r.kNodes)];
        }
        r.surfaceMinIvBps = 1000;
        r.surfaceMaxIvBps = 50_000;
        r.confidenceBps = 100;
        r.sourceCount = 3;
        bytes32[] memory leaves = new bytes32[](w.length);
        for (uint256 i; i < tenors.length; ++i) {
            for (uint256 j; j < strikes.length; ++j) {
                // forge-lint: disable-next-line(unsafe-typecast)
                leaves[i * strikes.length + j] =
                    keccak256(abi.encode(productId, r.surfaceSeq, uint8(i), uint8(j), w[i * strikes.length + j]));
            }
        }
        r.surfaceRoot = MerkleHelper.root(leaves);
        sigs = _signAB(r);
        n = new IVolSurfaceOracle.NodeProof[](w.length);
        for (uint256 i; i < w.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            n[i] = IVolSurfaceOracle.NodeProof(
                productId,
                r.surfaceSeq,
                uint8(i / strikes.length),
                uint8(i % strikes.length),
                w[i],
                MerkleHelper.proof(leaves, i)
            );
        }
    }

    /// @dev Index of the node closest to k = 0 (for the header's ATM variance).
    function _atm(int256[] memory k) internal pure returns (uint256 best) {
        uint256 bestAbs = type(uint256).max;
        for (uint256 j; j < k.length; ++j) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 a = k[j] < 0 ? uint256(-k[j]) : uint256(k[j]);
            if (a < bestAbs) (best, bestAbs) = (j, a);
        }
    }

    function _signAB(IVolSurfaceOracle.SurfaceReport memory r) internal view returns (bytes[] memory sigs) {
        bytes32 digest = surface.reportDigest(r);
        (uint8 va, bytes32 ra, bytes32 sa) = vm.sign(keyA, digest);
        (uint8 vb, bytes32 rb, bytes32 sb) = vm.sign(keyB, digest);
        sigs = new bytes[](2);
        bytes memory a = abi.encodePacked(ra, sa, va);
        bytes memory b = abi.encodePacked(rb, sb, vb);
        (sigs[0], sigs[1]) = vm.addr(keyA) < vm.addr(keyB) ? (a, b) : (b, a);
    }

    /// @dev The MATH.md §10 market: ETH 4,000; IV 65% at 3,500, 60% at 4,500, 62% at 5,000; tenors 30 and 60 days.
    function _workedExampleMarket() internal {
        _setSpot(ethUsdc, 4000e18);
        uint256[] memory k = new uint256[](3);
        uint256[] memory iv = new uint256[](3);
        (k[0], k[1], k[2]) = (3500e18, 4500e18, 5000e18);
        (iv[0], iv[1], iv[2]) = (0.65e18, 0.6e18, 0.62e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        _setSurface(ethUsdc, 4000e18, k, iv, tenors);
    }

    // ------------------------------------------------------------------ positions

    function _series(bytes32 productId, OptionType t, uint256 strike, uint64 expiry) internal returns (bytes32) {
        SeriesParams memory p = SeriesParams({
            underlying: productId == ethUsdc ? weth : wbtc,
            settlementAsset: address(usdc),
            optionType: t,
            strikeWad: strike,
            contractSizeWad: 1e18,
            expiry: expiry,
            settlementOracleConfigId: productId == ethUsdc ? ETH_CFG : BTC_CFG,
            volSurfaceProductId: productId,
            riskParameterSetId: RISK_SET
        });
        bytes32 id = registry.computeSeriesId(p);
        if (registry.seriesExists(id)) return id;
        vm.prank(seriesCreator);
        return registry.createSeries(p);
    }

    function _account(address owner) internal returns (uint256 id) {
        vm.prank(owner);
        id = ledger.createSubAccount(address(usdc));
    }

    function _hold(uint256 account, bytes32 seriesId, int256 qty) internal {
        vm.prank(clearing);
        ledger.applyDelta(account, seriesId, qty);
    }

    function _fund(uint256 account, uint256 native) internal {
        vm.prank(clearing);
        ledger.addCash(account, native);
    }
}
