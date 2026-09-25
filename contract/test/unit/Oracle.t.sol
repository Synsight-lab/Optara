// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {OracleConfigStatus} from "../../src/libraries/OptaraTypes.sol";

/// @notice OracleRegistry and ChainlinkSettlementAdapter (TEST_CASES.md Parts XIV-XV, FIN-010/011/013, ORN-013).
contract OracleTest is OptaraTestBase {
    uint64 exp;

    function setUp() public override {
        super.setUp();
        exp = expiry1;
    }

    // ------------------------------------------------------------------ Registry (ORC)

    function test_ORC_001_registerDirect() public view {
        OracleConfig memory c = registry.getConfig(monUsdtConfig);
        assertEq(c.underlying, MON);
        assertEq(c.settlementAsset, address(usdt));
        assertEq(c.adapter, address(adapter));
        assertTrue(registry.isApprovedForNewRisk(monUsdtConfig));
        assertEq(uint8(registry.statusOf(monUsdtConfig)), uint8(OracleConfigStatus.APPROVED_FOR_NEW_SERIES));
    }

    function test_ORC_002_registerDerived() public view {
        OracleConfig memory c = registry.getConfig(ethUsdcConfig);
        ChainlinkSettlementAdapter.Params memory p = abi.decode(c.sourceParams, (ChainlinkSettlementAdapter.Params));
        assertEq(p.primary.kind, 2);
        assertEq(p.primary.quoteFeed, address(usdcUsdFeed));
    }

    function test_ORC_003_rejectInvalidSource() public {
        ChainlinkSettlementAdapter.Params memory p;
        p.primary = _directSource(address(0), 8);
        OracleConfig memory c = _oracleConfig(MON, address(usdt), abi.encode(p));
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "feed"));
        registry.registerConfig(c);
        // decimals mismatch
        p.primary = _directSource(address(monUsdtFeed), 18);
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "decimals mismatch"));
        registry.registerConfig(c);
        // dead feed
        MockAggregator dead = new MockAggregator(8);
        dead.pushRound(0, block.timestamp);
        p.primary = _directSource(address(dead), 8);
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "feed not live"));
        registry.registerConfig(c);
        // primary missing
        p.primary.kind = 0;
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "primary missing"));
        registry.registerConfig(c);
        // bad kind
        p.primary.kind = 3;
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "kind"));
        registry.registerConfig(c);
        // direct with quote fields
        p.primary = _directSource(address(monUsdtFeed), 8);
        p.primary.maxLegSkew = 1;
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "direct has quote fields")
        );
        registry.registerConfig(c);
        // secondary none but fields set
        p.primary = _directSource(address(monUsdtFeed), 8);
        p.secondary.feed = address(monUsdtFeed);
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "secondary fields set")
        );
        registry.registerConfig(c);
        // derived with zero skew / same feed
        p.secondary = p.secondary;
        p.secondary.feed = address(0);
        p.primary.kind = 2;
        p.primary.maxLegSkew = 0;
        p.primary.quoteFeed = address(usdcUsdFeed);
        p.primary.quoteFeedDecimals = 8;
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "maxLegSkew"));
        registry.registerConfig(c);
        p.primary.maxLegSkew = 60;
        p.primary.quoteFeed = address(monUsdtFeed);
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "same leg feeds"));
        registry.registerConfig(c);
        // feed decimals above 18
        MockAggregator d19 = new MockAggregator(19);
        d19.pushRound(1, block.timestamp);
        p.primary = _directSource(address(d19), 19);
        c.sourceParams = abi.encode(p);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSource.selector, "decimals > 18"));
        registry.registerConfig(c);
    }

    /// ORC-004/005: a config binds the exact pair; series creation rejects a config for another pair (see SER-014).
    function test_ORC_004_005_registryRejectsMalformedIdentity() public {
        ChainlinkSettlementAdapter.Params memory p;
        p.primary = _directSource(address(monUsdtFeed), 8);
        OracleConfig memory c = _oracleConfig(MON, MON, abi.encode(p));
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "underlying == asset"));
        registry.registerConfig(c);
        c = _oracleConfig(address(0), address(usdt), abi.encode(p));
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "zero asset"));
        registry.registerConfig(c);
    }

    function test_ORC_006_suspendForNewSeries() public {
        vm.prank(pauser);
        registry.setStatus(monUsdtConfig, OracleConfigStatus.SUSPENDED_FOR_NEW_SERIES);
        assertFalse(registry.isApprovedForNewRisk(monUsdtConfig));
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.NotAuthorized.selector, pauser));
        registry.setStatus(monUsdtConfig, OracleConfigStatus.APPROVED_FOR_NEW_SERIES);
        vm.prank(oracleAdmin);
        registry.setStatus(monUsdtConfig, OracleConfigStatus.APPROVED_FOR_NEW_SERIES);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.NotAuthorized.selector, oracleAdmin));
        registry.setStatus(monUsdtConfig, OracleConfigStatus.RETIRED);
        vm.startPrank(gov);
        registry.setStatus(monUsdtConfig, OracleConfigStatus.RETIRED);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleRegistry.InvalidStatusTransition.selector,
                OracleConfigStatus.RETIRED,
                OracleConfigStatus.APPROVED_FOR_NEW_SERIES
            )
        );
        registry.setStatus(monUsdtConfig, OracleConfigStatus.APPROVED_FOR_NEW_SERIES);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.UnknownConfig.selector, bytes32(uint256(1))));
        registry.setStatus(bytes32(uint256(1)), OracleConfigStatus.RETIRED);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.NotAuthorized.selector, attacker));
        registry.setStatus(ethUsdcConfig, OracleConfigStatus.SUSPENDED_FOR_NEW_SERIES);
    }

    /// ORC-007/008: an existing series stays bound; a suspended/retired config still finalizes its groups.
    function test_ORC_007_008_existingSeriesRemainsBound() public {
        bytes32 id = _monCall(10 * WAD, 5 * WAD);
        vm.prank(gov);
        registry.setStatus(monUsdtConfig, OracleConfigStatus.RETIRED);
        assertEq(core.getSeries(id).oracleConfigId, monUsdtConfig);
        _finalizeMon(id, 12 * WAD);
        assertEq(core.getGroup(_groupOf(id)).settlementPriceWad, 12 * WAD);
    }

    function test_registryWindowValidation() public {
        ChainlinkSettlementAdapter.Params memory p;
        p.primary = _directSource(address(monUsdtFeed), 8);
        OracleConfig memory c = _oracleConfig(MON, address(usdt), abi.encode(p));
        OracleConfig memory b;
        bytes memory params = abi.encode(p);
        vm.startPrank(oracleAdmin);
        b = _oracleConfig(MON, address(usdt), params);
        b.observationStartOffset = 10;
        b.observationEndOffset = 0;
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "inverted window"));
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.maxFinalizationDelay = 0;
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "maxFinalizationDelay"));
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.maxFinalizationDelay = 366 days;
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "maxFinalizationDelay"));
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.minFinalizationDelay = 8 days;
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "min > max delay"));
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.observationEndOffset = 5 minutes; // == minFinalizationDelay: finalization not strictly after observation end
        vm.expectRevert(
            abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "finalization before observation end")
        );
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.observationStartOffset = -int64(366 days);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "offset bound"));
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.ruleVersion = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "ruleVersion"));
        registry.registerConfig(b);
        b = _oracleConfig(MON, address(usdt), params);
        b.adapter = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "adapter"));
        registry.registerConfig(b);
        // duplicate
        b = _oracleConfig(MON, address(usdt), params);
        b.ruleVersion = keccak256("dup");
        registry.registerConfig(b);
        vm.expectRevert();
        registry.registerConfig(b);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.NotAuthorized.selector, attacker));
        registry.registerConfig(c);
    }

    /// ORN-013: negative/zero/positive offsets; negative resulting time and uint64 overflow rejected.
    function test_ORN_013_signedOffsetArithmetic() public {
        (uint64 s, uint64 e) = registry.observationWindow(monUsdtConfig, exp);
        assertEq(s, exp - 1 hours);
        assertEq(e, exp);
        vm.expectRevert(OracleRegistry.InvalidObservationTime.selector);
        registry.observationWindow(monUsdtConfig, 30 minutes); // expiry - 1h < 0
        vm.expectRevert(OracleRegistry.InvalidObservationTime.selector);
        registry.validateSeriesExpiry(monUsdtConfig, type(uint64).max - 1 days);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.UnknownConfig.selector, bytes32(0)));
        registry.observationWindow(bytes32(0), exp);
        // positive offsets: observe 10 minutes after expiry, finalize 20 minutes after
        ChainlinkSettlementAdapter.Params memory p;
        p.primary = _directSource(address(monUsdtFeed), 8);
        OracleConfig memory c = _oracleConfig(MON, address(usdt), abi.encode(p));
        c.observationStartOffset = 0;
        c.observationEndOffset = 10 minutes;
        c.minFinalizationDelay = 20 minutes;
        vm.prank(oracleAdmin);
        bytes32 id = registry.registerConfig(c);
        (s, e) = registry.observationWindow(id, exp);
        assertEq(s, exp);
        assertEq(e, exp + 10 minutes);
    }

    // ------------------------------------------------------------------ Adapter (ORN, FIN)

    function _quote(bytes32 cfg, bytes memory data) internal view returns (uint256 price, uint64 ts) {
        return adapter.quoteSettlementPrice(cfg, exp, data);
    }

    /// ORN-001: 8-decimal direct feed normalizes to WAD.
    function test_ORN_001_direct8Decimals() public {
        bytes memory data = _directProofData(monUsdtFeed, 12.5e8, exp);
        (uint256 price, uint64 ts) = _quote(monUsdtConfig, data);
        assertEq(price, 12.5e18);
        assertEq(ts, exp - 10);
    }

    /// ORN-002: 18-decimal direct feed normalizes to WAD unchanged.
    function test_ORN_002_direct18Decimals() public {
        bytes memory data = _directProofData(monUsdeFeed, 12.5e18, exp);
        (uint256 price,) = _quote(monUsdeConfig, data);
        assertEq(price, 12.5e18);
    }

    function _derivedData(int256 ethUsd, int256 usdcUsd, uint256 tsEth, uint256 tsUsdc)
        internal
        returns (bytes memory)
    {
        vm.warp(exp - 3600);
        uint80 r1 = ethUsdFeed.pushRound(ethUsd, tsEth);
        uint80 r2 = usdcUsdFeed.pushRound(usdcUsd, tsUsdc);
        vm.warp(exp + MIN_FINAL_DELAY);
        return _data(0, _proof2(r1, 0, r2, 0), _empty());
    }

    function test_ORN_003_derivedAtParity() public {
        bytes memory data = _derivedData(4800e8, 1e8, exp - 60, exp - 30);
        (uint256 price, uint64 ts) = _quote(ethUsdcConfig, data);
        assertEq(price, 4800e18);
        assertEq(ts, exp - 30);
    }

    /// ORN-004 / ORACLE_AND_SETTLEMENT.md section 13: 12 / 0.96 = 12.5 stablecoin units.
    function test_ORN_004_derivedDepeg() public {
        bytes memory data = _derivedData(12e8, 0.96e8, exp - 60, exp - 60);
        (uint256 price,) = _quote(ethUsdcConfig, data);
        assertEq(price, 12.5e18);
    }

    function test_ORN_005_derivedAboveOne() public {
        bytes memory data = _derivedData(3000e8, 1.2e8, exp - 60, exp - 60);
        (uint256 price,) = _quote(ethUsdcConfig, data);
        assertEq(price, 2500e18);
        // half-up rounding: 10 / 3 = 3.333.. -> ...333; 20/3 -> ...667
        data = _derivedData(20e8, 3e8, exp - 50, exp - 50);
        (price,) = _quote(ethUsdcConfig, data);
        assertEq(price, 6666666666666666667);
    }

    /// ORN-006: zero stablecoin price is an invalid observation (never a division by zero).
    function test_ORN_006_zeroStablecoinPriceRejected() public {
        bytes memory data = _derivedData(3000e8, 0, exp - 60, exp - 60);
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationInvalid.selector);
        _quote(ethUsdcConfig, data);
    }

    function test_ORN_007_negativePriceRejected() public {
        bytes memory data = _directProofData(monUsdtFeed, -1, exp);
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationInvalid.selector);
        _quote(monUsdtConfig, data);
    }

    /// ORN-008: staleness is measured against the observation start (expiry - 1h), not block.timestamp.
    function test_ORN_008_staleSourceRejected() public {
        vm.warp(exp - 2 hours);
        uint80 r = monUsdtFeed.pushRound(10e8, block.timestamp);
        vm.warp(exp + 1 hours);
        uint80 n = monUsdtFeed.pushRound(11e8, block.timestamp);
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationInvalid.selector);
        _quote(monUsdtConfig, _data(0, _proof1(r, n), _empty()));
    }

    /// ORN-009: a round that is not the round in force at the observation end is rejected.
    function test_ORN_009_wrongObservationTimeRejected() public {
        vm.warp(exp - 100);
        uint80 r1 = monUsdtFeed.pushRound(10e8, block.timestamp);
        vm.warp(exp - 50);
        uint80 r2 = monUsdtFeed.pushRound(11e8, block.timestamp);
        vm.warp(exp + 50);
        uint80 r3 = monUsdtFeed.pushRound(12e8, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        // r1 is not in force at expiry: its successor r2 is also <= expiry
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkSettlementAdapter.SuccessorNotAfterObservation.selector, address(monUsdtFeed), r2
            )
        );
        _quote(monUsdtConfig, _data(0, _proof1(r1, r2), _empty()));
        // r3 is after expiry
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.RoundAfterObservation.selector, address(monUsdtFeed), r3)
        );
        _quote(monUsdtConfig, _data(0, _proof1(r3, 0), _empty()));
        // r1 with a non-immediate successor
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkSettlementAdapter.NotImmediateSuccessor.selector, address(monUsdtFeed), r1, r3
            )
        );
        _quote(monUsdtConfig, _data(0, _proof1(r1, r3), _empty()));
        // r2 is not the latest round
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.NotLatestRound.selector, address(monUsdtFeed), r2)
        );
        _quote(monUsdtConfig, _data(0, _proof1(r2, 0), _empty()));
        // correct proof
        (uint256 price,) = _quote(monUsdtConfig, _data(0, _proof1(r2, r3), _empty()));
        assertEq(price, 11e18);
    }

    /// ORN-010 N/A: Chainlink feeds publish no confidence interval (ORACLE_AND_SETTLEMENT.md section 22 "if used").
    /// ORN-011: compatible derived timestamps accepted (within maxLegSkew).
    function test_ORN_011_compatibleTimestampsAccepted() public {
        bytes memory data = _derivedData(3000e8, 1e8, exp - 3600, exp);
        (uint256 price,) = _quote(ethUsdcConfig, data);
        assertEq(price, 3000e18);
    }

    function test_ORN_012_incompatibleDerivedTimestampsRejected() public {
        vm.warp(exp - 3600);
        uint80 r1 = ethUsdFeed.pushRound(3000e8, block.timestamp); // 1h before expiry
        vm.warp(exp);
        uint80 r2 = usdcUsdFeed.pushRound(1e8, block.timestamp - 3601 + 3600); // at expiry
        // make skew 1h + 1s by moving the ETH leg one second earlier inside the window
        ethUsdFeed.set(r1, 3000e8, exp - 3600);
        usdcUsdFeed.set(r2, 1e8, exp);
        vm.warp(exp + MIN_FINAL_DELAY);
        (uint256 price,) = _quote(ethUsdcConfig, _data(0, _proof2(r1, 0, r2, 0), _empty()));
        assertEq(price, 3000e18); // exactly 1h skew is allowed
        ethUsdFeed.set(r1, 3000e8, exp - 3600);
        usdcUsdFeed.set(r2, 1e8, exp);
        // A derived config with a tighter skew rejects the same data.
        ChainlinkSettlementAdapter.Params memory p;
        p.primary.kind = 2;
        p.primary.feed = address(ethUsdFeed);
        p.primary.feedDecimals = 8;
        p.primary.quoteFeed = address(usdcUsdFeed);
        p.primary.quoteFeedDecimals = 8;
        p.primary.maxLegSkew = 3599;
        vm.prank(oracleAdmin);
        bytes32 tight = registry.registerConfig(_oracleConfig(ETH, address(usdc), abi.encode(p)));
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationInvalid.selector);
        adapter.quoteSettlementPrice(tight, exp, _data(0, _proof2(r1, 0, r2, 0), _empty()));
    }

    /// FIN-010: primary proven invalid (stale) -> precommitted secondary settles.
    function test_FIN_010_fallbackPrimaryFailSecondaryValid() public {
        vm.warp(exp - 3 hours);
        uint80 p = monUsdtFeed.pushRound(10e8, block.timestamp); // stale at expiry
        vm.warp(exp - 5);
        uint80 s = monUsdtBackupFeed.pushRound(9e8, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        bytes memory data = _data(1, _proof1(p, 0), _proof1(s, 0));
        (uint256 price, uint64 ts) = _quote(monUsdtConfig, data);
        assertEq(price, 9e18);
        assertEq(ts, exp - 5);
    }

    /// FIN-011: both sources invalid -> no price; the group stays unsettled.
    function test_FIN_011_bothInvalidStaysUnsettled() public {
        vm.warp(exp - 3 hours);
        uint80 p = monUsdtFeed.pushRound(10e8, block.timestamp);
        uint80 s = monUsdtBackupFeed.pushRound(9e8, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationInvalid.selector);
        _quote(monUsdtConfig, _data(0, _proof1(p, 0), _empty()));
        vm.expectRevert(ChainlinkSettlementAdapter.SecondaryObservationInvalid.selector);
        _quote(monUsdtConfig, _data(1, _proof1(p, 0), _proof1(s, 0)));
    }

    /// FIN-013: omitting or lying about primary data does not make the secondary eligible; a caller can never
    /// choose between two valid prices.
    function test_FIN_013_uniqueSourceSelection() public {
        vm.warp(exp - 5);
        uint80 p = monUsdtFeed.pushRound(10e8, block.timestamp);
        uint80 s = monUsdtBackupFeed.pushRound(9e8, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        // secondary requested while the primary is valid
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationValid.selector);
        _quote(monUsdtConfig, _data(1, _proof1(p, 0), _proof1(s, 0)));
        // omitted primary proof
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.WrongProofCount.selector, 1, 0));
        _quote(monUsdtConfig, _data(1, _empty(), _proof1(s, 0)));
        // bogus primary round id
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkSettlementAdapter.RoundUnavailable.selector, address(monUsdtFeed), uint80(7)
            )
        );
        _quote(monUsdtConfig, _data(1, _proof1(7, 0), _proof1(s, 0)));
        // no secondary configured
        bytes memory derived = _derivedData(3000e8, 1e8, exp - 60, exp - 60);
        derived;
        vm.expectRevert(ChainlinkSettlementAdapter.NoSecondarySource.selector);
        adapter.quoteSettlementPrice(ethUsdcConfig, exp, _data(1, _proof2(1, 0, 1, 0), _empty()));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.InvalidSourceIndex.selector, uint8(2)));
        _quote(monUsdtConfig, _data(2, _proof1(p, 0), _empty()));
    }

    function test_observationMustBeFinal() public {
        vm.warp(exp - 5);
        uint80 p = monUsdtFeed.pushRound(10e8, block.timestamp);
        vm.warp(exp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.ObservationNotFinal.selector, exp));
        _quote(monUsdtConfig, _data(0, _proof1(p, 0), _empty()));
    }

    function test_verifyRejectsValueAndWrongAdapter() public {
        bytes memory data = _directProofData(monUsdtFeed, 10e8, exp);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ChainlinkSettlementAdapter.NoFeeRequired.selector);
        adapter.verifySettlementPrice{value: 1}(monUsdtConfig, exp, data);
        ChainlinkSettlementAdapter other = new ChainlinkSettlementAdapter(registry);
        vm.expectRevert(ChainlinkSettlementAdapter.WrongAdapter.selector);
        other.quoteSettlementPrice(monUsdtConfig, exp, data);
        OracleConfig memory existing = registry.getConfig(monUsdtConfig);
        vm.expectRevert(ChainlinkSettlementAdapter.WrongAdapter.selector);
        other.validateConfig(existing);
        vm.expectRevert(ChainlinkSettlementAdapter.ZeroAddress.selector);
        new ChainlinkSettlementAdapter(OracleRegistry(address(0)));
        (uint256 price,) = adapter.verifySettlementPrice(monUsdtConfig, exp, data);
        assertEq(price, 10e18);
    }

    function test_wrongProofCountDerived() public {
        vm.warp(exp + MIN_FINAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSettlementAdapter.WrongProofCount.selector, 2, 1));
        _quote(ethUsdcConfig, _data(0, _proof1(1, 0), _empty()));
    }

    function test_successorUnavailableAndBrokenFeed() public {
        vm.warp(exp - 5);
        uint80 p = monUsdtFeed.pushRound(10e8, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkSettlementAdapter.SuccessorUnavailable.selector, address(monUsdtFeed), p + 1
            )
        );
        _quote(monUsdtConfig, _data(0, _proof1(p, p + 1), _empty()));
        monUsdtFeed.setBroken(true);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.RoundUnavailable.selector, address(monUsdtFeed), p)
        );
        _quote(monUsdtConfig, _data(0, _proof1(p, 0), _empty()));
        monUsdtFeed.setBroken(false);
        monUsdtFeed.setReturnWrongId(true);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.RoundUnavailable.selector, address(monUsdtFeed), p)
        );
        _quote(monUsdtConfig, _data(0, _proof1(p, 0), _empty()));
    }

    /// Phase boundary: last round of phase 1 is followed by round 1 of phase 2.
    function test_phaseBoundarySuccessor() public {
        vm.warp(exp - 5);
        uint80 p = monUsdtFeed.pushRound(10e8, block.timestamp);
        monUsdtFeed.startNewPhase();
        vm.warp(exp + 60);
        uint80 n = monUsdtFeed.pushRound(11e8, block.timestamp);
        assertEq(n, monUsdtFeed.id(2, 1));
        assertTrue(adapter.isImmediateSuccessor(address(monUsdtFeed), p, n));
        vm.warp(exp + MIN_FINAL_DELAY);
        (uint256 price,) = _quote(monUsdtConfig, _data(0, _proof1(p, n), _empty()));
        assertEq(price, 10e18);
        // not the last round of phase 1 -> not an immediate successor
        assertFalse(adapter.isImmediateSuccessor(address(monUsdtFeed), p - 1, n));
        // phase jump by 2 or aggregator round != 1
        assertFalse(adapter.isImmediateSuccessor(address(monUsdtFeed), p, monUsdtFeed.id(3, 1)));
        assertFalse(adapter.isImmediateSuccessor(address(monUsdtFeed), p, monUsdtFeed.id(2, 2)));
        // zerosForMissing aggregators: missing round + 1 reports updatedAt 0
        monUsdtFeed.setZerosForMissing(true);
        assertTrue(adapter.isImmediateSuccessor(address(monUsdtFeed), p, n));
        assertFalse(adapter.isImmediateSuccessor(address(monUsdtFeed), type(uint80).max, n));
    }

    function test_normalizationOverflowIsInvalid() public {
        MockAggregator huge = new MockAggregator(0);
        huge.pushRound(type(int256).max, block.timestamp);
        ChainlinkSettlementAdapter.Params memory p;
        p.primary = _directSource(address(huge), 0);
        vm.prank(oracleAdmin);
        bytes32 cfg = registry.registerConfig(_oracleConfig(MON, address(usdt), abi.encode(p)));
        vm.warp(exp - 5);
        uint80 r = huge.pushRound(type(int256).max, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        vm.expectRevert(ChainlinkSettlementAdapter.PrimaryObservationInvalid.selector);
        adapter.quoteSettlementPrice(cfg, exp, _data(0, _proof1(r, 0), _empty()));
    }
}
