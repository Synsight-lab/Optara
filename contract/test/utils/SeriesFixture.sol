// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceFixture} from "./GovernanceFixture.sol";
import {OptionSeriesRegistry} from "../../src/series/OptionSeriesRegistry.sol";
import {ExternalOptionFactory} from "../../src/series/ExternalOptionFactory.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IExternalOptionFactory} from "../../src/interfaces/IExternalOptionFactory.sol";
import {ISettlementConfigs, IRiskSets} from "../../src/interfaces/IExternalDependencies.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {OptionType, ProductConfig, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20, MockSettlementConfigs, MockRiskSets} from "../mocks/MockDependencies.sol";

/// @notice Governance + OptionSeriesRegistry + ExternalOptionFactory, deployed like production: proxy addresses
///         are predicted from UpgradeAdmin's nonce so each initializer receives final addresses. ETH/USDC is
///         approved with the PARAMETERS.md §9 example bounds.
abstract contract SeriesFixture is GovernanceFixture {
    OptionSeriesRegistry internal registry;
    ExternalOptionFactory internal factory;
    ExternalOptionWrapper internal wrapperImpl;
    MockSettlementConfigs internal settlementConfigs;
    MockRiskSets internal riskSets;
    MockERC20 internal usdc;
    address internal weth = makeAddr("WETH");

    // not yet built: stand-in addresses with the right permissions on wrappers
    address internal clearing = makeAddr("OptionClearing");
    address internal settlementWindow = makeAddr("SettlementWindow");
    address internal liquidationModule = makeAddr("LiquidationModule");

    address internal seriesCreator = makeAddr("seriesCreator");

    bytes32 internal constant CFG = keccak256("ETH/USDC chainlink");
    bytes32 internal constant RISK_SET = keccak256("ETH default");
    bytes32 internal ethUsdc; // productId

    /// @dev Governance + series modules, hand-over, ETH/USDC configured.
    function _deploySeries() internal {
        _deployGovernanceCore();
        _deploySeriesModules();
        _handOver();
        _configureSeries();
    }

    /// @dev Registry and factory proxies (deployer still holds GOVERNANCE).
    function _deploySeriesModules() internal {
        settlementConfigs = new MockSettlementConfigs();
        riskSets = new MockRiskSets();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wrapperImpl = new ExternalOptionWrapper();

        address registryAddr = _nextProxy(0);
        address factoryAddr = _nextProxy(1);
        registry = OptionSeriesRegistry(
            upgradeAdmin.deployProxy(
                address(new OptionSeriesRegistry()),
                abi.encodeCall(
                    OptionSeriesRegistry.initialize,
                    (
                        IProtocolControl(address(pc)),
                        IExternalOptionFactory(factoryAddr),
                        ISettlementConfigs(address(settlementConfigs)),
                        IRiskSets(address(riskSets))
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
                        IProtocolControl(address(pc)),
                        address(wrapperImpl),
                        address(registry),
                        clearing,
                        settlementWindow,
                        liquidationModule
                    )
                )
            )
        );
        assertEq(address(registry), registryAddr, "registry address prediction");
        assertEq(address(factory), factoryAddr, "factory address prediction");

        pc.grantRole(Roles.SERIES_CREATOR, seriesCreator);
    }

    /// @dev After hand-over: approve USDC and the ETH/USDC product through governance.
    function _configureSeries() internal {
        settlementConfigs.set(CFG, weth, address(usdc), true);
        riskSets.set(RISK_SET, true);
        vm.startPrank(governance);
        registry.setSettlementAssetApproved(address(usdc), true);
        ethUsdc = registry.approveProduct(weth, address(usdc), _ethConfig());
        vm.stopPrank();
    }

    /// @dev PARAMETERS.md §9: strikes 100 – 1,000,000; contract size 0.001 – 100; 1 hour – 400 days.
    function _ethConfig() internal pure returns (ProductConfig memory) {
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

    function _params(OptionType t, uint256 strike, uint64 expiry) internal view returns (SeriesParams memory) {
        return SeriesParams({
            underlying: weth,
            settlementAsset: address(usdc),
            optionType: t,
            strikeWad: strike,
            contractSizeWad: 1e18,
            expiry: expiry,
            settlementOracleConfigId: CFG,
            volSurfaceProductId: ethUsdc,
            riskParameterSetId: RISK_SET
        });
    }

    function _create(SeriesParams memory p) internal returns (bytes32) {
        vm.prank(seriesCreator);
        return registry.createSeries(p);
    }
}
