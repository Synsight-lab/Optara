// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OptaraConfig} from "../../src/config/OptaraConfig.sol";
import {OracleRegistry} from "../../src/oracle/OracleRegistry.sol";
import {ChainlinkSettlementAdapter} from "../../src/oracle/ChainlinkSettlementAdapter.sol";
import {OptaraCore} from "../../src/core/OptaraCore.sol";
import {SeriesFactory} from "../../src/factory/SeriesFactory.sol";
import {IOptaraCore, IOptaraCoreErrors, IOptaraCoreEvents} from "../../src/interfaces/IOptaraCore.sol";
import {IOptionToken} from "../../src/interfaces/IOptionToken.sol";
import {
    OptionType,
    CloseSource,
    SeriesBounds,
    OracleConfig,
    Series,
    Group,
    Position,
    SeriesState,
    Leg,
    AssetStatus,
    ExposureScope,
    Actions
} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PayoffMath} from "../../src/libraries/PayoffMath.sol";
import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice Deploys a complete Optara V2 system with TEST-ONLY parameters. None of these values are production
///         configuration (DEPLOYMENT.md section 84).
abstract contract OptaraTestBase is Test {
    uint256 internal constant WAD = 1e18;
    uint64 internal constant SHORTFALL_DELAY = 2 days;
    int64 internal constant OBS_START = -1 hours; // observation must be at most 1h old at expiry
    int64 internal constant OBS_END = 0;
    uint64 internal constant MIN_FINAL_DELAY = 5 minutes;
    uint64 internal constant MAX_FINAL_DELAY = 7 days;
    uint256 internal constant BIG_LIMIT = uint256(type(int256).max);

    OptaraConfig internal config;
    OracleRegistry internal registry;
    ChainlinkSettlementAdapter internal adapter;
    OptaraCore internal core;
    SeriesFactory internal factory;

    address internal gov = makeAddr("governance");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal creator = makeAddr("seriesCreator");
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal configAdmin = makeAddr("configAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    // Underlyings are price identifiers, not tokens.
    address internal MON = makeAddr("MON");
    address internal ETH = makeAddr("ETH");

    MockERC20 internal usdt; // 6 decimals
    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal usde; // 18 decimals

    MockAggregator internal monUsdtFeed; // direct MON/USDT, 8 decimals
    MockAggregator internal ethUsdFeed; // ETH/USD, 8 decimals
    MockAggregator internal usdcUsdFeed; // USDC/USD, 8 decimals
    MockAggregator internal monUsdeFeed; // direct MON/USDe, 18 decimals
    MockAggregator internal monUsdtBackupFeed; // secondary MON/USDT, 8 decimals

    bytes32 internal monUsdtConfig;
    bytes32 internal ethUsdcConfig;
    bytes32 internal monUsdeConfig;

    uint64 internal expiry1;
    uint64 internal expiry2;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        expiry1 = uint64(block.timestamp + 30 days);
        expiry2 = uint64(block.timestamp + 60 days);

        config = new OptaraConfig(gov);
        registry = new OracleRegistry(config);
        adapter = new ChainlinkSettlementAdapter(registry);
        core = new OptaraCore(config, registry, SHORTFALL_DELAY);
        factory = new SeriesFactory(core, config, registry);
        core.bindSeriesFactory(address(factory));

        vm.startPrank(gov);
        config.grantRole(config.PAUSER_ROLE(), pauser);
        config.grantRole(config.UNPAUSER_ROLE(), unpauser);
        config.grantRole(config.SERIES_CREATOR_ROLE(), creator);
        config.grantRole(config.ORACLE_CONFIG_ROLE(), oracleAdmin);
        config.grantRole(config.CONFIG_ROLE(), configAdmin);
        config.setPositionLimits(8, 8, 32);
        vm.stopPrank();

        usdt = new MockERC20("Tether USD", "USDT", 6);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usde = new MockERC20("Ethena USDe", "USDe", 18);

        monUsdtFeed = new MockAggregator(8);
        ethUsdFeed = new MockAggregator(8);
        usdcUsdFeed = new MockAggregator(8);
        monUsdeFeed = new MockAggregator(18);
        monUsdtBackupFeed = new MockAggregator(8);
        monUsdtFeed.pushRound(8e8, block.timestamp);
        ethUsdFeed.pushRound(3000e8, block.timestamp);
        usdcUsdFeed.pushRound(1e8, block.timestamp);
        monUsdeFeed.pushRound(8e18, block.timestamp);
        monUsdtBackupFeed.pushRound(8e8, block.timestamp);

        vm.startPrank(gov);
        config.approveAsset(address(usdt), "USDT", 0, 0);
        config.approveAsset(address(usdc), "USDC", 0, 0);
        config.approveAsset(address(usde), "USDe", 0, 0);
        config.approveUnderlying(MON, "MON");
        config.approveUnderlying(ETH, "ETH");
        _approvePair(MON, address(usdt));
        _approvePair(ETH, address(usdc));
        _approvePair(MON, address(usde));
        _approvePair(ETH, address(usdt));
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(usdt)))), BIG_LIMIT);
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(usdc)))), BIG_LIMIT);
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(usde)))), BIG_LIMIT);
        vm.stopPrank();

        monUsdtConfig = _registerDirect(MON, address(usdt), address(monUsdtFeed), 8, address(monUsdtBackupFeed), 8);
        ethUsdcConfig = _registerDerived(ETH, address(usdc), address(ethUsdFeed), address(usdcUsdFeed));
        monUsdeConfig = _registerDirect(MON, address(usde), address(monUsdeFeed), 18, address(0), 0);
        vm.startPrank(gov);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, monUsdtConfig, BIG_LIMIT);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, ethUsdcConfig, BIG_LIMIT);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, monUsdeConfig, BIG_LIMIT);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Configuration helpers
    // ------------------------------------------------------------------------------------------

    function _defaultBounds() internal pure returns (SeriesBounds memory b) {
        b.minStrikeWad = 1e12;
        b.maxStrikeWad = 1e30;
        b.minCapWad = 1e12;
        b.maxCapWad = 1e30;
        b.minContractSizeWad = 1e12;
        b.maxContractSizeWad = 1e24;
        b.minTimeToExpiry = 1 hours;
        b.maxTimeToExpiry = 400 days;
        b.quantityIncrement = 1;
    }

    function _approvePair(address underlying, address asset) internal returns (bytes32) {
        return config.approvePair(underlying, asset, _defaultBounds(), BIG_LIMIT, BIG_LIMIT);
    }

    function _oracleConfig(address underlying, address asset, bytes memory params)
        internal
        view
        returns (OracleConfig memory c)
    {
        c.underlying = underlying;
        c.settlementAsset = asset;
        c.adapter = address(adapter);
        c.observationStartOffset = OBS_START;
        c.observationEndOffset = OBS_END;
        c.minFinalizationDelay = MIN_FINAL_DELAY;
        c.maxFinalizationDelay = MAX_FINAL_DELAY;
        c.ruleVersion = keccak256("chainlink-round-in-force/v1");
        c.sourceParams = params;
    }

    function _directSource(address feed, uint8 dec) internal pure returns (ChainlinkSettlementAdapter.Source memory s) {
        s.kind = 1;
        s.feed = feed;
        s.feedDecimals = dec;
    }

    function _registerDirect(
        address underlying,
        address asset,
        address feed,
        uint8 dec,
        address backupFeed,
        uint8 backupDec
    ) internal returns (bytes32) {
        ChainlinkSettlementAdapter.Params memory p;
        p.primary = _directSource(feed, dec);
        if (backupFeed != address(0)) p.secondary = _directSource(backupFeed, backupDec);
        vm.prank(oracleAdmin);
        return registry.registerConfig(_oracleConfig(underlying, asset, abi.encode(p)));
    }

    function _registerDerived(address underlying, address asset, address feedU, address feedS)
        internal
        returns (bytes32)
    {
        ChainlinkSettlementAdapter.Params memory p;
        p.primary.kind = 2;
        p.primary.feed = feedU;
        p.primary.feedDecimals = 8;
        p.primary.quoteFeed = feedS;
        p.primary.quoteFeedDecimals = 8;
        p.primary.maxLegSkew = 1 hours;
        vm.prank(oracleAdmin);
        return registry.registerConfig(_oracleConfig(underlying, asset, abi.encode(p)));
    }

    // ------------------------------------------------------------------------------------------
    // Series helpers
    // ------------------------------------------------------------------------------------------

    function _params(
        address underlying,
        address asset,
        OptionType t,
        uint256 strikeWad,
        uint256 capWad,
        uint256 sizeWad,
        uint64 expiry,
        bytes32 configId
    ) internal pure returns (SeriesFactory.SeriesParams memory p) {
        p = SeriesFactory.SeriesParams(underlying, asset, t, strikeWad, capWad, sizeWad, expiry, configId);
    }

    function _createSeries(
        address underlying,
        address asset,
        OptionType t,
        uint256 strikeWad,
        uint256 capWad,
        uint256 sizeWad,
        uint64 expiry,
        bytes32 configId
    ) internal returns (bytes32 id) {
        vm.prank(creator);
        (id,) = factory.createSeries(_params(underlying, asset, t, strikeWad, capWad, sizeWad, expiry, configId));
    }

    /// MON/USDT call or put, contract size 1, expiry1.
    function _monCall(uint256 k, uint256 c) internal returns (bytes32) {
        return _createSeries(MON, address(usdt), OptionType.CALL, k, c, WAD, expiry1, monUsdtConfig);
    }

    function _monPut(uint256 k, uint256 c) internal returns (bytes32) {
        return _createSeries(MON, address(usdt), OptionType.PUT, k, c, WAD, expiry1, monUsdtConfig);
    }

    function _token(bytes32 seriesId) internal view returns (IOptionToken) {
        return IOptionToken(core.getSeries(seriesId).optionToken);
    }

    function _groupOf(bytes32 seriesId) internal view returns (bytes32) {
        return core.getSeries(seriesId).groupId;
    }

    // ------------------------------------------------------------------------------------------
    // Account helpers
    // ------------------------------------------------------------------------------------------

    function _fund(address who, MockERC20 token, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(core), type(uint256).max);
    }

    function _deposit(address who, MockERC20 token, uint256 amount) internal {
        _fund(who, token, amount);
        vm.prank(who);
        core.deposit(address(token), amount);
    }

    function _write(address who, bytes32 seriesId, uint256 qty) internal {
        vm.prank(who);
        core.write(seriesId, qty, who);
    }

    function _lock(address who, bytes32 seriesId, uint256 qty) internal {
        vm.startPrank(who);
        _token(seriesId).approve(address(core), qty);
        core.lockLong(seriesId, qty);
        vm.stopPrank();
    }

    function _usdt(uint256 whole) internal pure returns (uint256) {
        return whole * 1e6;
    }

    // ------------------------------------------------------------------------------------------
    // Oracle helpers
    // ------------------------------------------------------------------------------------------

    /// @dev Pushes an in-force round shortly before expiry, then a successor after, and returns proof data.
    function _directProofData(MockAggregator feed, int256 answer, uint64 expiry) internal returns (bytes memory) {
        vm.warp(expiry - 10);
        uint80 r = feed.pushRound(answer, block.timestamp);
        vm.warp(expiry + 30);
        uint80 n = feed.pushRound(answer + 1, block.timestamp);
        ChainlinkSettlementAdapter.RoundProof[] memory proofs = new ChainlinkSettlementAdapter.RoundProof[](1);
        proofs[0] = ChainlinkSettlementAdapter.RoundProof(r, n);
        return abi.encode(
            ChainlinkSettlementAdapter.SettlementData(0, proofs, new ChainlinkSettlementAdapter.RoundProof[](0))
        );
    }

    /// @dev Finalizes the MON/USDT group at `priceWad` (8-decimal feed), warping past the finalization delay.
    function _finalizeMon(bytes32 seriesId, uint256 priceWad) internal {
        Series memory s = core.getSeries(seriesId);
        bytes memory data = _directProofData(monUsdtFeed, int256(priceWad / 1e10), s.expiry);
        vm.warp(uint256(s.expiry) + MIN_FINAL_DELAY);
        vm.prank(keeper);
        core.finalizeRiskGroup(s.groupId, data);
    }

    function _proof1(uint80 r, uint80 n) internal pure returns (ChainlinkSettlementAdapter.RoundProof[] memory p) {
        p = new ChainlinkSettlementAdapter.RoundProof[](1);
        p[0] = ChainlinkSettlementAdapter.RoundProof(r, n);
    }

    function _proof2(uint80 r1, uint80 n1, uint80 r2, uint80 n2)
        internal
        pure
        returns (ChainlinkSettlementAdapter.RoundProof[] memory p)
    {
        p = new ChainlinkSettlementAdapter.RoundProof[](2);
        p[0] = ChainlinkSettlementAdapter.RoundProof(r1, n1);
        p[1] = ChainlinkSettlementAdapter.RoundProof(r2, n2);
    }

    function _data(
        uint8 idx,
        ChainlinkSettlementAdapter.RoundProof[] memory primary,
        ChainlinkSettlementAdapter.RoundProof[] memory secondary
    ) internal pure returns (bytes memory) {
        return abi.encode(ChainlinkSettlementAdapter.SettlementData(idx, primary, secondary));
    }

    function _empty() internal pure returns (ChainlinkSettlementAdapter.RoundProof[] memory) {
        return new ChainlinkSettlementAdapter.RoundProof[](0);
    }

    // ------------------------------------------------------------------------------------------
    // Pooled-custody identity (MATH.md sections 64, 118)
    // ------------------------------------------------------------------------------------------

    /// @dev Protocol-owned balance of `asset` as an exact numerator over D_A:
    ///      VB*D - (sum effective cash * D + outstanding external claims N + realized residual N
    ///              + residual embedded in pending finalized deltas N + recapitalized surplus * D).
    ///      The fee-free MVP requires this to be exactly zero (never negative). `accounts` and `seriesIds` must
    ///      list every account with a balance/position and every series of `asset`.
    function _protocolOwnedN(address asset, address[] memory accounts, bytes32[] memory seriesIds)
        internal
        view
        returns (int256)
    {
        uint256 d = FixedPointMath.nativeDenominator(MockERC20(asset).decimals());
        int256 effective;
        uint256 pendingN;
        for (uint256 a = 0; a < accounts.length; ++a) {
            effective += core.effectiveCash(accounts[a], asset);
            bytes32[] memory gs = core.accountGroups(accounts[a]);
            for (uint256 g = 0; g < gs.length; ++g) {
                Group memory grp_ = core.getGroup(gs[g]);
                if (grp_.settlementAsset != asset || !grp_.finalized) continue;
                (int256 delta, uint256 sN, uint256 lN) = core.previewSync(accounts[a], gs[g]);
                if (delta < 0) pendingN += uint256(-delta) * d - (sN - lN);
                else if (lN > sN) pendingN += (lN - sN) - uint256(delta) * d;
            }
        }
        uint256 externalN;
        for (uint256 i = 0; i < seriesIds.length; ++i) {
            Series memory s = core.getSeries(seriesIds[i]);
            if (s.settlementAsset != asset) continue;
            Group memory g = core.getGroup(s.groupId);
            if (!g.finalized) continue;
            uint256 locked;
            for (uint256 a = 0; a < accounts.length; ++a) {
                locked += core.positionOf(accounts[a], seriesIds[i]).lockedQty;
            }
            uint256 ext = IOptionToken(s.optionToken).totalSupply() - locked;
            externalN += PayoffMath.payoffNumerator(
                s.optionType, s.strikeWad, s.capWad, s.contractSizeWad, g.settlementPriceWad, ext
            );
        }
        uint256 vaultN = MockERC20(asset).balanceOf(address(core)) * d;
        int256 claimsN = effective * int256(d) + int256(externalN + core.roundingResidualN(asset) + pendingN)
            + int256(core.totalRecapitalized(asset) * d);
        return int256(vaultN) - claimsN;
    }
}
