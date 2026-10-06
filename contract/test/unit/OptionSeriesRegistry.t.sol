// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SeriesFixture} from "../utils/SeriesFixture.sol";
import {OptionSeriesRegistry} from "../../src/series/OptionSeriesRegistry.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {IExternalOptionFactory} from "../../src/interfaces/IExternalOptionFactory.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {ISettlementConfigs, IRiskSets} from "../../src/interfaces/IExternalDependencies.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {
    OptionType,
    ProductStatus,
    ProductConfig,
    Product,
    SeriesParams,
    SeriesTerms,
    Group
} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../mocks/MockDependencies.sol";
import {
    NotAuthorized,
    ZeroAddress,
    NotAContract,
    UnknownSeries,
    AssetNotApproved,
    UnsupportedDecimals,
    InvalidProductConfig,
    ProductNotEnabled,
    InvalidSeriesParams,
    SeriesExists,
    GroupFull,
    ActionPaused
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for OptionSeriesRegistry: SER-001..SER-007, settlement assets, product bounds.
contract OptionSeriesRegistryTest is SeriesFixture {
    uint64 internal constant NOW = 1_791_244_800; // 2026-10-06 00:00 UTC
    uint64 internal constant XMAS = 1_798_185_600; // 2026-12-25 08:00 UTC

    function setUp() public {
        vm.warp(NOW);
        _deploySeries();
    }

    // ------------------------------------------------------------------ initialization

    function test_initializeChecks() public {
        OptionSeriesRegistry impl = new OptionSeriesRegistry();
        bytes memory bad = abi.encodeCall(
            OptionSeriesRegistry.initialize,
            (
                IProtocolControl(address(pc)),
                IExternalOptionFactory(address(0)),
                ISettlementConfigs(stranger),
                IRiskSets(stranger)
            )
        );
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(address(impl), bad);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(
            IProtocolControl(address(pc)),
            IExternalOptionFactory(stranger),
            ISettlementConfigs(stranger),
            IRiskSets(stranger)
        );
        assertEq(registry.factory(), address(factory));
        assertEq(registry.settlementConfigs(), address(settlementConfigs));
        assertEq(registry.riskSets(), address(riskSets));
    }

    // ------------------------------------------------------------------ settlement assets

    function test_assetApproval() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        registry.setSettlementAssetApproved(address(usdt), true);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IOptionSeriesRegistry.SettlementAssetApproved(address(usdt), true, 6);
        vm.prank(governance);
        registry.setSettlementAssetApproved(address(usdt), true);
        assertTrue(registry.isSettlementAssetApproved(address(usdt)));
        assertEq(registry.settlementAssetDecimals(address(usdt)), 6);

        // revoking is risk-reducing: the guardian may do it
        vm.prank(guardian);
        registry.setSettlementAssetApproved(address(usdt), false);
        assertFalse(registry.isSettlementAssetApproved(address(usdt)));
        assertEq(registry.settlementAssetDecimals(address(usdt)), 6, "decimals kept");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        registry.setSettlementAssetApproved(address(usdt), false);
    }

    function test_assetApproval_rejectsBadTokens() public {
        MockERC20 big = new MockERC20("Big", "BIG", 19);
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(UnsupportedDecimals.selector, 19));
        registry.setSettlementAssetApproved(address(big), true);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, stranger));
        registry.setSettlementAssetApproved(stranger, true);
        MockERC20 zeroDec = new MockERC20("Zero", "ZRO", 0);
        registry.setSettlementAssetApproved(address(zeroDec), true); // 0 decimals is allowed
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ products (SER-007)

    function test_SER007_approveProductIsGovernanceOnly() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        registry.approveProduct(makeAddr("WBTC"), address(usdc), _ethConfig());
    }

    function test_SER007_approveProductStoresAndEmits() public {
        address wbtc = makeAddr("WBTC");
        bytes32 id = registry.computeProductId(wbtc, address(usdc));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOptionSeriesRegistry.ProductApproved(id, wbtc, address(usdc), _ethConfig());
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOptionSeriesRegistry.ProductEnabled(id, true);
        vm.prank(governance);
        assertEq(registry.approveProduct(wbtc, address(usdc), _ethConfig()), id);
        Product memory p = registry.getProduct(id);
        assertEq(p.underlying, wbtc);
        assertEq(p.settlementAsset, address(usdc));
        assertEq(uint8(p.status), uint8(ProductStatus.ENABLED));
        assertEq(p.config.maxStrikeWad, 1_000_000e18);
        assertEq(p.config.underlyingSymbol, "ETH");
        assertTrue(registry.isProductEnabled(id));
    }

    function test_approveProduct_requiresApprovedAsset() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(AssetNotApproved.selector, address(dai)));
        registry.approveProduct(weth, address(dai), _ethConfig());
    }

    function test_approveProduct_validatesConfig() public {
        ProductConfig memory c;
        vm.startPrank(governance);

        vm.expectRevert(abi.encodeWithSelector(InvalidProductConfig.selector, 1));
        registry.approveProduct(address(0), address(usdc), _ethConfig());
        vm.expectRevert(abi.encodeWithSelector(InvalidProductConfig.selector, 1));
        registry.approveProduct(address(usdc), address(usdc), _ethConfig());

        c = _ethConfig();
        c.minStrikeWad = 0;
        _expectConfig(c, 2);
        c = _ethConfig();
        c.minStrikeWad = c.maxStrikeWad + 1;
        _expectConfig(c, 2);
        c = _ethConfig();
        c.maxStrikeWad = c.maxSettlementPriceWad + 1;
        _expectConfig(c, 2);

        c = _ethConfig();
        c.minContractSizeWad = 0;
        _expectConfig(c, 3);
        c = _ethConfig();
        c.minContractSizeWad = c.maxContractSizeWad + 1;
        _expectConfig(c, 3);

        c = _ethConfig();
        c.minTimeToExpiry = 0;
        _expectConfig(c, 4);
        c = _ethConfig();
        c.minTimeToExpiry = c.maxTimeToExpiry + 1;
        _expectConfig(c, 4);
        c = _ethConfig();
        c.maxTimeToExpiry = 730 days + 1;
        _expectConfig(c, 4);

        c = _ethConfig();
        c.maxSettlementPriceWad = 1e36 + 1;
        c.maxStrikeWad = 1e36;
        _expectConfig(c, 5);
        c = _ethConfig();
        c.maxContractSizeWad = 1e50 / c.maxSettlementPriceWad + 1; // notional above 1e50
        _expectConfig(c, 5);

        c = _ethConfig();
        c.underlyingSymbol = "";
        _expectConfig(c, 6);
        c = _ethConfig();
        c.assetSymbol = "ABCDEFGHIJKLMNOPQ"; // 17 characters
        _expectConfig(c, 6);
        vm.stopPrank();
    }

    function _expectConfig(ProductConfig memory c, uint8 reason) internal {
        vm.expectRevert(abi.encodeWithSelector(InvalidProductConfig.selector, reason));
        registry.approveProduct(weth, address(usdc), c);
    }

    function test_SER007_enableDisable() public {
        vm.prank(guardian);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOptionSeriesRegistry.ProductEnabled(ethUsdc, false);
        registry.setProductEnabled(ethUsdc, false);
        assertFalse(registry.isProductEnabled(ethUsdc));
        assertEq(uint8(registry.getProduct(ethUsdc).status), uint8(ProductStatus.DISABLED));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        registry.setProductEnabled(ethUsdc, true);

        vm.prank(governance);
        registry.setProductEnabled(ethUsdc, true);
        assertTrue(registry.isProductEnabled(ethUsdc));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ProductNotEnabled.selector, bytes32(uint256(1))));
        registry.setProductEnabled(bytes32(uint256(1)), false);
    }

    function test_SER007_disabledProductBlocksNewSeriesNotExisting() public {
        bytes32 id = _create(_params(OptionType.CALL, 4500e18, XMAS));
        vm.prank(guardian);
        registry.setProductEnabled(ethUsdc, false);
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(ProductNotEnabled.selector, ethUsdc));
        registry.createSeries(_params(OptionType.CALL, 5000e18, XMAS));
        assertEq(registry.getSeries(id).strikeWad, 4500e18, "existing series unaffected");
    }

    // ------------------------------------------------------------------ SER-001: create

    function test_SER001_createCallAndPut() public {
        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        bytes32 id = registry.computeSeriesId(p);
        bytes32 groupId = registry.computeGroupId(weth, address(usdc), XMAS, CFG);
        address predicted = factory.predictWrapper(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IOptionSeriesRegistry.GroupCreated(groupId, weth, address(usdc), XMAS, CFG);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IExternalOptionFactory.WrapperDeployed(
            id, predicted, "Optara ETH/USDC 4500C 2026-12-25", "oETH-USDC-4500C-261225"
        );
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOptionSeriesRegistry.SeriesCreated(
            id,
            groupId,
            predicted,
            SeriesTerms(weth, address(usdc), OptionType.CALL, 4500e18, 1e18, XMAS, CFG, ethUsdc, RISK_SET, predicted)
        );
        assertEq(_create(p), id);

        SeriesTerms memory t = registry.getSeries(id);
        assertEq(t.wrapper, predicted);
        assertEq(t.strikeWad, 4500e18);
        assertEq(uint8(t.optionType), uint8(OptionType.CALL));
        assertEq(t.riskParameterSetId, RISK_SET);
        assertTrue(registry.seriesExists(id));
        assertEq(registry.groupOf(id), groupId);
        assertEq(registry.productOf(id), ethUsdc);

        ExternalOptionWrapper w = ExternalOptionWrapper(t.wrapper);
        assertEq(w.name(), "Optara ETH/USDC 4500C 2026-12-25");
        assertEq(w.symbol(), "oETH-USDC-4500C-261225");
        assertEq(w.decimals(), 18);
        assertEq(w.seriesId(), id);
        assertEq(w.minter(), clearing);
        assertTrue(w.isBurner(settlementWindow) && w.isBurner(liquidationModule) && w.isBurner(clearing));

        bytes32 put = _create(_params(OptionType.PUT, 3500e18, XMAS));
        assertEq(ExternalOptionWrapper(registry.getSeries(put).wrapper).symbol(), "oETH-USDC-3500P-261225");
        assertEq(registry.groupOf(put), groupId, "same group");
        assertEq(registry.seriesInGroup(groupId).length, 2);
    }

    function test_SER001_fractionalStrikeName() public {
        SeriesParams memory p = _params(OptionType.CALL, 4500.25e18, XMAS);
        bytes32 id = _create(p);
        assertEq(ExternalOptionWrapper(registry.getSeries(id).wrapper).name(), "Optara ETH/USDC 4500.25C 2026-12-25");
    }

    // ------------------------------------------------------------------ SER-002: duplicates

    function test_SER002_duplicateReverts() public {
        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        bytes32 id = _create(p);
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(SeriesExists.selector, id));
        registry.createSeries(p);
    }

    function test_SER002_riskSetIsNotPartOfIdentity() public {
        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        bytes32 id = _create(p);
        riskSets.set(keccak256("other"), true);
        p.riskParameterSetId = keccak256("other");
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(SeriesExists.selector, id));
        registry.createSeries(p);
    }

    // ------------------------------------------------------------------ SER-003: bounds

    function test_SER003_eachBoundViolatedReverts() public {
        SeriesParams memory p;
        p = _params(OptionType.CALL, 100e18 - 1, XMAS);
        _expectSeries(p, 1);
        p = _params(OptionType.CALL, 1_000_000e18 + 1, XMAS);
        _expectSeries(p, 1);
        p = _params(OptionType.CALL, 4500e18, XMAS);
        p.contractSizeWad = 0.001e18 - 1;
        _expectSeries(p, 2);
        p.contractSizeWad = 100e18 + 1;
        _expectSeries(p, 2);
        p = _params(OptionType.CALL, 4500e18, NOW + 1 hours - 1);
        _expectSeries(p, 3);
        p = _params(OptionType.CALL, 4500e18, NOW + 400 days + 1);
        _expectSeries(p, 3);
        p = _params(OptionType.CALL, 4500e18, XMAS);
        p.settlementOracleConfigId = keccak256("unknown config");
        _expectSeries(p, 4);
        p = _params(OptionType.CALL, 4500e18, XMAS);
        p.volSurfaceProductId = keccak256("BTC/USDC");
        _expectSeries(p, 5);
        p = _params(OptionType.CALL, 4500e18, XMAS);
        p.riskParameterSetId = keccak256("disabled set");
        _expectSeries(p, 6);
    }

    function test_SER003_boundsAreInclusive() public {
        _create(_params(OptionType.CALL, 100e18, NOW + 1 hours));
        _create(_params(OptionType.CALL, 1_000_000e18, NOW + 400 days));
        SeriesParams memory p = _params(OptionType.PUT, 4500e18, XMAS);
        p.contractSizeWad = 0.001e18;
        _create(p);
        p.contractSizeWad = 100e18;
        _create(p);
    }

    function test_SER003_settlementConfigForOtherPairRejected() public {
        settlementConfigs.set(CFG, makeAddr("WBTC"), address(usdc), true);
        _expectSeries(_params(OptionType.CALL, 4500e18, XMAS), 4);
    }

    function _expectSeries(SeriesParams memory p, uint8 reason) internal {
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(InvalidSeriesParams.selector, reason));
        registry.createSeries(p);
    }

    function test_createSeries_requiresRoleAndApprovals() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        registry.createSeries(_params(OptionType.CALL, 4500e18, XMAS));

        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        p.underlying = makeAddr("WBTC");
        bytes32 btcUsdc = registry.computeProductId(p.underlying, address(usdc));
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(ProductNotEnabled.selector, btcUsdc));
        registry.createSeries(p);

        vm.prank(guardian);
        registry.setSettlementAssetApproved(address(usdc), false);
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(AssetNotApproved.selector, address(usdc)));
        registry.createSeries(_params(OptionType.CALL, 4500e18, XMAS));
    }

    function test_createSeries_pausable() public {
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.PRODUCT, ethUsdc, uint256(1) << PauseBits.SERIES_CREATE);
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.SERIES_CREATE));
        registry.createSeries(_params(OptionType.CALL, 4500e18, XMAS));
    }

    // ------------------------------------------------------------------ SER-004: tenor coverage is not checked here

    function test_SER004_creationDoesNotRequireSurfaceCoverage() public {
        // the registry has no surface dependency: priceability is checked at mint (SeriesNotPriceable)
        _create(_params(OptionType.CALL, 4500e18, NOW + 399 days));
    }

    // ------------------------------------------------------------------ SER-005: terms never change

    function test_SER005_termsUnchangedByAdminActions() public {
        bytes32 id = _create(_params(OptionType.CALL, 4500e18, XMAS));
        bytes32 before = keccak256(abi.encode(registry.getSeries(id)));

        ProductConfig memory c = _ethConfig();
        c.maxStrikeWad = 5000e18; // new bounds would forbid this series today
        c.underlyingSymbol = "WETH";
        vm.prank(governance);
        registry.approveProduct(weth, address(usdc), c);
        vm.prank(guardian);
        registry.setProductEnabled(ethUsdc, false);
        riskSets.set(RISK_SET, false);
        settlementConfigs.set(CFG, weth, address(usdc), false);

        assertEq(keccak256(abi.encode(registry.getSeries(id))), before);
        assertEq(ExternalOptionWrapper(registry.getSeries(id).wrapper).symbol(), "oETH-USDC-4500C-261225");
    }

    // ------------------------------------------------------------------ SER-006: identity

    function test_SER006_groupsAndIds() public {
        bytes32 a = _create(_params(OptionType.CALL, 4500e18, XMAS));
        bytes32 b = _create(_params(OptionType.PUT, 4500e18, XMAS));
        bytes32 c = _create(_params(OptionType.CALL, 4500e18, XMAS + 7 days));
        assertTrue(a != b && a != c && b != c);
        assertEq(registry.groupOf(a), registry.groupOf(b));
        assertTrue(registry.groupOf(a) != registry.groupOf(c), "different expiry, different group");

        // a different settlement oracle config is a different group
        settlementConfigs.set(keccak256("cfg2"), weth, address(usdc), true);
        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        p.settlementOracleConfigId = keccak256("cfg2");
        bytes32 d = _create(p);
        assertTrue(registry.groupOf(d) != registry.groupOf(a));

        Group memory g = registry.getGroup(registry.groupOf(a));
        assertEq(g.expiry, XMAS);
        assertEq(g.settlementOracleConfigId, CFG);
    }

    function test_SER006_seriesIdFormula() public view {
        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        bytes32 domain = keccak256(abi.encode(keccak256("Optara.PM.Series"), block.chainid, address(registry), 1));
        assertEq(registry.seriesDomain(), domain);
        bytes32 expected =
            keccak256(abi.encode(domain, weth, address(usdc), OptionType.CALL, 4500e18, 1e18, XMAS, CFG, ethUsdc));
        assertEq(registry.computeSeriesId(p), expected);
        assertEq(
            registry.computeGroupId(weth, address(usdc), XMAS, CFG),
            keccak256(abi.encode(keccak256("Optara.PM.Group"), weth, address(usdc), XMAS, CFG))
        );
        assertEq(ethUsdc, keccak256(abi.encode(keccak256("Optara.PM.Product"), weth, address(usdc))));
    }

    function test_SER006_seriesIdDependsOnChain() public {
        SeriesParams memory p = _params(OptionType.CALL, 4500e18, XMAS);
        bytes32 here = registry.computeSeriesId(p);
        vm.chainId(10_143);
        assertTrue(registry.computeSeriesId(p) != here);
    }

    // ------------------------------------------------------------------ group limit

    function test_groupFullAt256Series() public {
        for (uint256 i; i < 256; ++i) {
            _create(_params(OptionType.CALL, 100e18 + i * 1e18, XMAS));
        }
        bytes32 groupId = registry.computeGroupId(weth, address(usdc), XMAS, CFG);
        assertEq(registry.seriesInGroup(groupId).length, 256);
        vm.prank(seriesCreator);
        vm.expectRevert(abi.encodeWithSelector(GroupFull.selector, groupId));
        registry.createSeries(_params(OptionType.CALL, 999e18, XMAS));
    }

    // ------------------------------------------------------------------ views on unknown ids

    function test_unknownSeriesViewsRevert() public {
        bytes32 x = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, x));
        registry.getSeries(x);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, x));
        registry.groupOf(x);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, x));
        registry.productOf(x);
        assertFalse(registry.seriesExists(x));
        assertEq(registry.seriesInGroup(x).length, 0);
    }
}
