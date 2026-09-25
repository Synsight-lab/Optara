// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {OptionToken} from "../../src/token/OptionToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PairStatus, OracleConfigStatus, SeriesStatus} from "../../src/libraries/OptaraTypes.sol";

/// @notice SeriesFactory, risk-group identity and OptionToken (TEST_CASES.md Parts III-V).
contract SeriesAndTokenTest is OptaraTestBase {
    function _p() internal view returns (SeriesFactory.SeriesParams memory) {
        return _params(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdtConfig);
    }

    function _create(SeriesFactory.SeriesParams memory p) internal returns (bytes32 id) {
        vm.prank(creator);
        (id,) = factory.createSeries(p);
    }

    function _expectCreateRevert(SeriesFactory.SeriesParams memory p, bytes memory err) internal {
        vm.prank(creator);
        vm.expectRevert(err);
        factory.createSeries(p);
    }

    // ------------------------------------------------------------------ SER

    function test_SER_001_createValidCallMonUsdt() public {
        bytes32 id = _create(_p());
        Series memory s = core.getSeries(id);
        assertEq(s.underlying, MON);
        assertEq(s.settlementAsset, address(usdt));
        assertEq(uint8(s.optionType), uint8(OptionType.CALL));
        assertEq(s.strikeWad, 10 * WAD);
        assertEq(s.capWad, 5 * WAD);
        assertEq(s.contractSizeWad, WAD);
        assertEq(s.expiry, expiry1);
        assertEq(s.oracleConfigId, monUsdtConfig);
        assertEq(s.assetDecimals, 6);
        assertEq(uint8(core.seriesStatus(id)), uint8(SeriesStatus.ACTIVE));
        assertEq(core.seriesCount(), 1);
        assertEq(core.seriesIdAt(0), id);
    }

    function test_SER_002_createValidPut() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.optionType = OptionType.PUT;
        p.capWad = 10 * WAD; // cap == strike allowed
        bytes32 id = _create(p);
        assertEq(uint8(core.getSeries(id).optionType), uint8(OptionType.PUT));
    }

    function test_SER_003_createEthUsdc() public {
        bytes32 id = _create(
            _params(ETH, address(usdc), OptionType.CALL, 4000 * WAD, 500 * WAD, WAD / 10, expiry1, ethUsdcConfig)
        );
        assertEq(core.getSeries(id).settlementAsset, address(usdc));
    }

    /// SER-004 uses MON/USDe as the 18-decimal "BTC/USDe"-style pair.
    function test_SER_004_createUsde() public {
        bytes32 id =
            _create(_params(MON, address(usde), OptionType.PUT, 10 * WAD, 4 * WAD, WAD, expiry1, monUsdeConfig));
        assertEq(core.getSeries(id).assetDecimals, 18);
    }

    function test_SER_005_rejectZeroUnderlying() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.underlying = address(0);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.ZeroAddress.selector));
    }

    function test_SER_006_rejectZeroSettlementAsset() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.settlementAsset = address(0);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.ZeroAddress.selector));
    }

    function test_SER_007_rejectUnapprovedPair() public {
        SeriesFactory.SeriesParams memory p =
            _params(ETH, address(usde), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdeConfig);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.PairNotEnabled.selector));
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        vm.prank(pauser);
        config.setPairStatus(pid, PairStatus.NEW_RISK_DISABLED);
        _expectCreateRevert(_p(), abi.encodeWithSelector(SeriesFactory.PairNotEnabled.selector));
    }

    function test_SER_008_rejectZeroStrike() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.strikeWad = 0;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.ZeroStrike.selector));
    }

    function test_SER_009_rejectZeroCap() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.capWad = 0;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.ZeroCap.selector));
    }

    function test_SER_010_rejectZeroContractSize() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.contractSizeWad = 0;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.ZeroContractSize.selector));
    }

    function test_SER_011_rejectInvalidExpiry() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.expiry = uint64(block.timestamp);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.InvalidExpiry.selector));
        p.expiry = uint64(block.timestamp + 30 minutes); // below minTimeToExpiry
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.InvalidExpiry.selector));
        p.expiry = uint64(block.timestamp + 401 days); // above maxTimeToExpiry
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.InvalidExpiry.selector));
    }

    function test_SER_012_rejectPutCapAboveStrike() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.optionType = OptionType.PUT;
        p.capWad = 12 * WAD;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.PutCapAboveStrike.selector));
    }

    function test_SER_013_rejectUnknownOracleConfig() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.oracleConfigId = keccak256("unknown");
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.OracleConfigNotApproved.selector));
        vm.prank(pauser);
        registry.setStatus(monUsdtConfig, OracleConfigStatus.SUSPENDED_FOR_NEW_SERIES);
        _expectCreateRevert(_p(), abi.encodeWithSelector(SeriesFactory.OracleConfigNotApproved.selector));
    }

    function test_SER_014_rejectIncompatibleOraclePair() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.oracleConfigId = monUsdeConfig; // MON/USDe config for a MON/USDT series
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.OracleConfigMismatch.selector));
        p = _params(ETH, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdtConfig);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.OracleConfigMismatch.selector));
    }

    function test_SER_015_duplicateRejected() public {
        bytes32 id = _create(_p());
        _expectCreateRevert(_p(), abi.encodeWithSelector(SeriesFactory.SeriesAlreadyExists.selector, id));
    }

    function test_SER_016_to_020_distinctFieldsDistinctIds() public {
        bytes32 base = _create(_p());
        SeriesFactory.SeriesParams memory p = _p();
        p.strikeWad = 11 * WAD;
        bytes32 a = _create(p); // SER-016
        p = _p();
        p.capWad = 4 * WAD;
        bytes32 b = _create(p); // SER-017
        p = _p();
        p.expiry = expiry2;
        bytes32 c = _create(p); // SER-018
        p = _params(MON, address(usde), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdeConfig);
        bytes32 d = _create(p); // SER-019
        bytes32 otherConfig = _registerDirect(MON, address(usdt), address(monUsdtBackupFeed), 8, address(0), 0);
        vm.prank(gov);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, otherConfig, BIG_LIMIT);
        p = _p();
        p.oracleConfigId = otherConfig;
        bytes32 e = _create(p); // SER-020
        p = _p();
        p.contractSizeWad = WAD / 10;
        bytes32 f = _create(p);
        p = _p();
        p.optionType = OptionType.PUT;
        bytes32 g = _create(p);
        bytes32[8] memory ids = [base, a, b, c, d, e, f, g];
        for (uint256 i = 0; i < 8; ++i) {
            for (uint256 j = i + 1; j < 8; ++j) {
                assertTrue(ids[i] != ids[j]);
                assertTrue(core.getSeries(ids[i]).optionToken != core.getSeries(ids[j]).optionToken);
            }
        }
        // identity is the documented hash
        assertEq(
            base,
            keccak256(
                abi.encode(
                    core.protocolSeriesDomain(),
                    MON,
                    address(usdt),
                    OptionType.CALL,
                    10 * WAD,
                    5 * WAD,
                    WAD,
                    expiry1,
                    monUsdtConfig
                )
            )
        );
    }

    /// SER-021 / ACL-010: no exposed function mutates series terms; registerSeries is factory-only and one-shot.
    function test_SER_021_termsImmutable() public {
        bytes32 id = _create(_p());
        Series memory s = core.getSeries(id);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.OnlySeriesFactory.selector, gov));
        core.registerSeries(id, s);
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesAlreadyExists.selector, id));
        core.registerSeries(id, s);
        // governance changes to bounds/limits do not touch existing terms
        vm.startPrank(gov);
        config.setSeriesBounds(s.pairId, _defaultBounds());
        config.setExposureLimit(ExposureScope.PAIR, s.pairId, 1);
        vm.stopPrank();
        assertEq(keccak256(abi.encode(core.getSeries(id))), keccak256(abi.encode(s)));
    }

    function test_factoryAuthorizationAndPause() public {
        SeriesFactory.SeriesParams memory p = _p();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.NotAuthorized.selector, attacker));
        factory.createSeries(p);
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.SERIES_CREATION);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.SeriesCreationPaused.selector));
        vm.prank(gov);
        config.unpause(bytes32(0), Actions.SERIES_CREATION);
        vm.prank(gov); // governance may also create
        factory.createSeries(p);
    }

    function test_factoryRejectsOutOfBoundsAndDisabled() public {
        SeriesFactory.SeriesParams memory p = _p();
        p.strikeWad = 1;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.OutOfBounds.selector, "strike"));
        p = _p();
        p.capWad = 1e31;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.OutOfBounds.selector, "cap"));
        p = _p();
        p.contractSizeWad = 1e25;
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.OutOfBounds.selector, "contractSize"));
        p = _p();
        p.underlying = address(usdt);
        _expectCreateRevert(p, abi.encodeWithSelector(SeriesFactory.UnderlyingEqualsAsset.selector));
        vm.prank(pauser);
        config.setUnderlyingApproved(MON, false);
        _expectCreateRevert(_p(), abi.encodeWithSelector(SeriesFactory.UnderlyingNotApproved.selector));
        vm.prank(gov);
        config.setUnderlyingApproved(MON, true);
        vm.prank(pauser);
        config.setAssetNewRiskEnabled(address(usdt), false);
        _expectCreateRevert(_p(), abi.encodeWithSelector(SeriesFactory.AssetNotApproved.selector));
    }

    function test_factoryConstructorAndCoreWiring() public {
        vm.expectRevert(SeriesFactory.ZeroAddress.selector);
        new SeriesFactory(IOptaraCore(address(0)), config, registry);
        OptaraCore fresh = new OptaraCore(config, registry, SHORTFALL_DELAY);
        Series memory s;
        vm.expectRevert(IOptaraCoreErrors.NotSealed.selector);
        fresh.registerSeries(bytes32(0), s);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, attacker));
        fresh.bindSeriesFactory(address(factory));
        vm.expectRevert(IOptaraCoreErrors.ZeroAddress.selector);
        fresh.bindSeriesFactory(address(0));
        fresh.bindSeriesFactory(address(factory));
        vm.expectRevert(IOptaraCoreErrors.AlreadySealed.selector);
        fresh.bindSeriesFactory(address(this));
        vm.expectRevert(IOptaraCoreErrors.InvalidDelay.selector);
        new OptaraCore(config, registry, 1 hours);
        vm.expectRevert(IOptaraCoreErrors.ZeroAddress.selector);
        new OptaraCore(config, OracleRegistry(address(0)), SHORTFALL_DELAY);
    }

    function test_registerSeriesRejectsInconsistentIdentity() public {
        bytes32 id = _create(_p());
        Series memory s = core.getSeries(id);
        s.strikeWad = 11 * WAD; // id no longer matches terms
        vm.prank(address(factory));
        vm.expectRevert(IOptaraCoreErrors.InvalidSeriesRegistration.selector);
        core.registerSeries(keccak256("other"), s);
    }

    // ------------------------------------------------------------------ RGI

    function test_RGI_001_to_008_groupIdentity() public {
        bytes32 a = _create(_p());
        SeriesFactory.SeriesParams memory p = _p();
        p.strikeWad = 12 * WAD;
        bytes32 b = _create(p); // RGI-006 different strike, same group
        p = _p();
        p.capWad = 3 * WAD;
        bytes32 c = _create(p); // RGI-007 different cap, same group
        p = _p();
        p.optionType = OptionType.PUT;
        bytes32 d = _create(p); // RGI-008 call and put share a group
        assertEq(_groupOf(a), _groupOf(b));
        assertEq(_groupOf(a), _groupOf(c));
        assertEq(_groupOf(a), _groupOf(d)); // RGI-001
        assertEq(_groupOf(a), core.computeGroupId(MON, expiry1, address(usdt), monUsdtConfig));
        p = _params(ETH, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdtConfig);
        // RGI-002: different underlying -> different group (identity check without needing an ETH/USDT config)
        assertTrue(core.computeGroupId(ETH, expiry1, address(usdt), monUsdtConfig) != _groupOf(a));
        p = _p();
        p.expiry = expiry2;
        assertTrue(_groupOf(_create(p)) != _groupOf(a)); // RGI-003
        assertTrue(
            _groupOf(
                    _create(
                        _params(MON, address(usde), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdeConfig)
                    )
                ) != _groupOf(a)
        ); // RGI-004
        assertTrue(core.computeGroupId(MON, expiry1, address(usdt), monUsdeConfig) != _groupOf(a)); // RGI-005
        assertEq(core.groupCount(), 3);
    }

    // ------------------------------------------------------------------ TOK

    function test_TOK_001_metadataBinding() public {
        bytes32 id = _create(_p());
        OptionToken t = OptionToken(core.getSeries(id).optionToken);
        assertEq(t.seriesId(), id);
        assertEq(t.core(), address(core));
        assertEq(t.decimals(), 18);
        (uint256 y, uint256 m, uint256 d) = _date(expiry1);
        string memory dateLong = string.concat(vm.toString(y), "-", _pad(m), "-", _pad(d));
        string memory dateShort = string.concat(_pad(y % 100), _pad(m), _pad(d));
        assertEq(t.name(), string.concat("Optara MON/USDT 10C Cap5 ", dateLong));
        assertEq(t.symbol(), string.concat("oMON-USDT-10C-C5-", dateShort));
        SeriesFactory.SeriesParams memory p = _p();
        p.optionType = OptionType.PUT;
        p.strikeWad = 12.5e18;
        p.capWad = 0.25e18;
        OptionToken t2 = OptionToken(core.getSeries(_create(p)).optionToken);
        assertEq(t2.symbol(), string.concat("oMON-USDT-12.5P-C0.25-", dateShort));
    }

    function test_TOK_002_003_mintAuthorization() public {
        bytes32 id = _create(_p());
        IOptionToken t = _token(id);
        address[4] memory callers = [attacker, gov, pauser, keeper];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(OptionToken.OnlyCore.selector, callers[i]));
            t.mint(callers[i], 1);
        }
        vm.prank(address(core));
        t.mint(alice, 5);
        assertEq(t.balanceOf(alice), 5);
    }

    function test_TOK_004_005_006_burnAuthorization() public {
        bytes32 id = _create(_p());
        IOptionToken t = _token(id);
        vm.prank(address(core));
        t.mint(alice, 5);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.OnlyCore.selector, attacker));
        t.burn(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.OnlyCore.selector, alice));
        t.burn(alice, 1);
        vm.prank(address(core));
        t.burn(alice, 2);
        assertEq(t.balanceOf(alice), 3);
        vm.expectRevert(OptionToken.ZeroCore.selector);
        new OptionToken("n", "s", bytes32(0), address(0));
    }

    function test_TOK_007_008_009_erc20Behaviour() public {
        bytes32 id = _create(_p());
        _deposit(alice, usdt, _usdt(10));
        _write(alice, id, 2 * WAD);
        IOptionToken t = _token(id);
        vm.prank(alice);
        t.transfer(bob, WAD); // TOK-007
        assertEq(t.balanceOf(bob), WAD);
        vm.prank(alice);
        t.approve(carol, WAD);
        vm.prank(carol);
        t.transferFrom(alice, dave, WAD / 2); // TOK-008
        assertEq(t.balanceOf(dave), WAD / 2);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, WAD / 2, WAD));
        t.transferFrom(alice, dave, WAD); // TOK-009
        assertEq(t.totalSupply(), 2 * WAD); // transfers never change supply
    }

    function _date(uint256 ts) internal pure returns (uint256 y, uint256 m, uint256 d) {
        // independent re-derivation for the test: days from civil via iteration
        uint256 days_ = ts / 86400;
        y = 1970;
        while (true) {
            uint256 yd = (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 366 : 365;
            if (days_ < yd) break;
            days_ -= yd;
            ++y;
        }
        uint8[12] memory ml = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ml[1] = 29;
        m = 1;
        while (days_ >= ml[m - 1]) {
            days_ -= ml[m - 1];
            ++m;
        }
        d = days_ + 1;
    }

    function _pad(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }
}
