// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptaraConfig} from "../../src/config/OptaraConfig.sol";
import {OracleRegistry} from "../../src/oracle/OracleRegistry.sol";
import {ChainlinkSettlementAdapter} from "../../src/oracle/ChainlinkSettlementAdapter.sol";
import {OptaraCore} from "../../src/core/OptaraCore.sol";
import {SeriesFactory} from "../../src/factory/SeriesFactory.sol";
import {IOptionToken} from "../../src/interfaces/IOptionToken.sol";
import {OptionType, SeriesBounds, OracleConfig, ExposureScope, Series} from "../../src/libraries/OptaraTypes.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {
    KuruTestnet,
    NativeOrder,
    SwapResult,
    IKuruProtocolAuthority,
    IKuruAccountCore,
    IKuruSpotRouter,
    IKuruOrderBook
} from "./KuruInterfaces.sol";

/// @notice Fork fixture: the real Kuru Spot V2 deployment on Monad testnet plus a fresh Optara V2 deployment on the
///         same fork, settled in Kuru's test USDC, and one Kuru OPTION/USDC market listed by Kuru governance
///         (impersonated: listing is permissioned on the live testnet).
///
/// Run: FOUNDRY_PROFILE=fork forge test          (MONAD_TESTNET_RPC overrides the public RPC; KURU_FORK_BLOCK pins)
abstract contract KuruForkBase is Test {
    uint256 internal constant WAD = 1e18;
    // Market units chosen for an 18-decimal option token quoted in 6-decimal USDC. Fees, notional bounds and passive
    // spread mirror Kuru's canonical testnet markets (deployments/testnet: 0.07% taker, 0.04% maker, 10 USDC min).
    uint96 internal constant SIZE_PRECISION = 1e4; // 0.0001 option per size unit
    uint32 internal constant PRICE_PRECISION = 1e4; // 0.0001 USDC per price unit
    uint32 internal constant TICK = 1;
    uint32 internal constant PASSIVE_SPREAD_TICKS = 400;
    uint96 internal constant MIN_QUOTE = 10e6;
    uint96 internal constant MAX_QUOTE = 5_000_000e6;
    uint256 internal constant TAKER_FEE_PPS = 7000;
    uint256 internal constant MAKER_FEE_PPS = 4000;
    uint256 internal constant PPS = 10_000_000;

    IERC20 internal usdc = IERC20(KuruTestnet.USDC);
    IKuruAccountCore internal kuru = IKuruAccountCore(KuruTestnet.ACCOUNT_CORE);
    IKuruSpotRouter internal router = IKuruSpotRouter(KuruTestnet.SPOT_ROUTER);
    IKuruOrderBook internal book;
    address internal kuruGov;

    OptaraConfig internal config;
    OracleRegistry internal registry;
    ChainlinkSettlementAdapter internal adapter;
    OptaraCore internal core;
    SeriesFactory internal factory;
    MockAggregator internal feed; // MON/USDC settlement feed (local mock on the fork)
    bytes32 internal oracleConfigId;
    bytes32 internal seriesId; // MON/USDC call K=10 C=5 CS=1
    bytes32 internal groupId;
    IOptionToken internal opt;
    uint64 internal expiry;

    address internal gov = makeAddr("optaraGov");
    address internal creator = makeAddr("seriesCreator");
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal alice = makeAddr("alice"); // writer / seller
    address internal bob = makeAddr("bob"); // buyer
    address internal carol = makeAddr("carol"); // second writer
    address internal keeper = makeAddr("keeper");
    address internal MON = makeAddr("MON");

    function setUp() public virtual {
        string memory rpc = vm.envOr("MONAD_TESTNET_RPC", string("https://testnet-rpc.monad.xyz"));
        uint256 pin = vm.envOr("KURU_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        assertEq(block.chainid, KuruTestnet.CHAIN_ID, "not Monad testnet");
        assertFalse(kuru.protocolPaused(), "Kuru paused on testnet");

        _deployOptara();
        _listOnKuru();

        deal(address(usdc), alice, 10_000e6);
        deal(address(usdc), bob, 10_000e6);
        deal(address(usdc), carol, 10_000e6);
    }

    // ------------------------------------------------------------------------------------------ Optara

    function _deployOptara() internal {
        config = new OptaraConfig(gov);
        registry = new OracleRegistry(config);
        adapter = new ChainlinkSettlementAdapter(registry);
        core = new OptaraCore(config, registry, 2 days);
        factory = new SeriesFactory(core, config, registry);
        core.bindSeriesFactory(address(factory));

        SeriesBounds memory b = SeriesBounds({
            minStrikeWad: 1e12,
            maxStrikeWad: 1e30,
            minCapWad: 1e12,
            maxCapWad: 1e30,
            minContractSizeWad: 1e12,
            maxContractSizeWad: 1e24,
            minTimeToExpiry: 1 hours,
            maxTimeToExpiry: 400 days,
            quantityIncrement: 1
        });
        uint256 big = uint256(type(int256).max);
        vm.startPrank(gov);
        config.grantRole(config.SERIES_CREATOR_ROLE(), creator);
        config.grantRole(config.ORACLE_CONFIG_ROLE(), oracleAdmin);
        config.setPositionLimits(8, 8, 32);
        config.approveAsset(address(usdc), "USDC", 0, 0);
        config.approveUnderlying(MON, "MON");
        config.approvePair(MON, address(usdc), b, big, big);
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(usdc)))), big);
        vm.stopPrank();

        feed = new MockAggregator(8);
        feed.pushRound(8e8, block.timestamp);
        ChainlinkSettlementAdapter.Params memory p;
        p.primary.kind = 1;
        p.primary.feed = address(feed);
        p.primary.feedDecimals = 8;
        OracleConfig memory oc;
        oc.underlying = MON;
        oc.settlementAsset = address(usdc);
        oc.adapter = address(adapter);
        oc.observationStartOffset = -1 hours;
        oc.observationEndOffset = 0;
        oc.minFinalizationDelay = 5 minutes;
        oc.maxFinalizationDelay = 7 days;
        oc.ruleVersion = keccak256("chainlink-round-in-force/v1");
        oc.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        oracleConfigId = registry.registerConfig(oc);
        vm.prank(gov);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, oracleConfigId, big);

        expiry = uint64(block.timestamp + 7 days);
        vm.prank(creator);
        (seriesId,) = factory.createSeries(
            SeriesFactory.SeriesParams(
                MON, address(usdc), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry, oracleConfigId
            )
        );
        Series memory s = core.getSeries(seriesId);
        opt = IOptionToken(s.optionToken);
        groupId = s.groupId;
    }

    // ------------------------------------------------------------------------------------------ Kuru listing

    /// Kuru governance whitelists the option token, enables it in AccountCore and deploys OPTION/USDC.
    function _listOnKuru() internal {
        kuruGov = IKuruProtocolAuthority(KuruTestnet.PROTOCOL_AUTHORITY).governance();
        book = IKuruOrderBook(_deployMarket(address(opt), address(usdc)));
    }

    function _deployMarket(address base, address quote) internal returns (address market) {
        vm.startPrank(kuruGov);
        router.whitelistSpotToken(base, true);
        kuru.configureSpotToken(base, true);
        market = router.deploySpotMarket(
            base,
            quote,
            SIZE_PRECISION,
            PRICE_PRECISION,
            TICK,
            PASSIVE_SPREAD_TICKS,
            MIN_QUOTE,
            MAX_QUOTE,
            TAKER_FEE_PPS,
            MAKER_FEE_PPS
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------ helpers

    /// Optara: deposit USDC margin and write `qty` options to the writer's own wallet.
    function _writeOnOptara(address writer, uint256 qty, uint256 margin) internal {
        vm.startPrank(writer);
        usdc.approve(address(core), margin);
        core.deposit(address(usdc), margin);
        core.write(seriesId, qty, writer);
        vm.stopPrank();
    }

    function _kuruDeposit(address who, address token, uint256 amount) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(kuru), amount);
        kuru.deposit(token, amount);
        vm.stopPrank();
    }

    function _kuruWithdraw(address who, address token, uint256 amount) internal {
        vm.prank(who);
        kuru.withdraw(token, amount);
    }

    /// Order-book quantity for `optionsWad` options, and raw price for `usdc6` (6-decimal USDC per option).
    function _size(uint256 optionsWad) internal view returns (uint96) {
        return uint96(optionsWad / book.baseSizeMultiplier());
    }

    function _price(uint256 usdc6) internal pure returns (uint32) {
        return uint32(usdc6 * PRICE_PRECISION / 1e6);
    }

    function _order(uint8 side, uint256 optionsWad, uint256 usdc6, uint8 tif)
        internal
        view
        returns (NativeOrder[] memory o)
    {
        o = new NativeOrder[](1);
        o[0] = NativeOrder(side, _size(optionsWad), _price(usdc6), tif, 0, 0);
    }

    function _place(address who, uint8 side, uint256 optionsWad, uint256 usdc6, uint8 tif) internal {
        NativeOrder[] memory o = _order(side, optionsWad, usdc6, tif);
        vm.prank(who);
        book.batch(0, o, new uint8[](0));
    }

    /// Finalizes the Optara group at `priceWad` with a proven round in force at expiry (mock MON/USDC feed).
    function _finalize(uint256 priceWad) internal {
        vm.warp(expiry - 10);
        uint80 r = feed.pushRound(int256(priceWad / 1e10), block.timestamp);
        vm.warp(uint256(expiry) + 30);
        uint80 n = feed.pushRound(int256(priceWad / 1e10), block.timestamp);
        vm.warp(uint256(expiry) + 5 minutes);
        ChainlinkSettlementAdapter.RoundProof[] memory proofs = new ChainlinkSettlementAdapter.RoundProof[](1);
        proofs[0] = ChainlinkSettlementAdapter.RoundProof(r, n);
        bytes memory data = abi.encode(
            ChainlinkSettlementAdapter.SettlementData(0, proofs, new ChainlinkSettlementAdapter.RoundProof[](0))
        );
        vm.prank(keeper);
        core.finalizeRiskGroup(groupId, data);
    }
}
