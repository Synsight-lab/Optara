// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {MathHarness} from "../utils/MathHarness.sol";
import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";
import {PairStatus} from "../../src/libraries/OptaraTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Every remaining revert branch and view (TEST_CASES.md Appendices B-C: each custom error and each
///         public function needs a direct test).
contract EdgeCoverageTest is OptaraTestBase {
    bytes32 k10;

    function setUp() public override {
        super.setUp();
        k10 = _monCall(10 * WAD, 5 * WAD);
    }

    function test_fixedPointDecimalsGuards() public {
        MathHarness m = new MathHarness();
        vm.expectRevert(abi.encodeWithSelector(FixedPointMath.UnsupportedDecimals.selector, uint8(19)));
        m.toNativeDown(1, 19);
        vm.expectRevert(abi.encodeWithSelector(FixedPointMath.UnsupportedDecimals.selector, uint8(19)));
        m.toNativeUp(1, 19);
    }

    function test_metadataPaddingAndJanuary() public {
        // January expiry exercises the m <= 2 calendar branch; 10.05 exercises fraction zero-padding.
        uint64 jan = 1_798_761_600 + 5 days; // 2027-01-06
        vm.warp(jan - 30 days);
        monUsdtFeed.pushRound(8e8, block.timestamp);
        bytes32 id = _createSeries(MON, address(usdt), OptionType.CALL, 10.05e18, 5 * WAD, WAD, jan, monUsdtConfig);
        IERC20Metadata t = IERC20Metadata(core.getSeries(id).optionToken);
        assertEq(t.symbol(), "oMON-USDT-10.05C-C5-270106");
        assertEq(t.name(), "Optara MON/USDT 10.05C Cap5 2027-01-06");
    }

    function test_configRemainingBranches() public {
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setAssetBufferDefaults(address(usdt), 1, 1); // onlyGovernance
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, attacker));
        config.setPairStatus(pid, PairStatus.NEW_RISK_DISABLED);
        SeriesBounds memory b = _defaultBounds();
        b.minContractSizeWad = b.maxContractSizeWad + 1;
        vm.prank(configAdmin);
        vm.expectRevert(OptaraConfig.InvalidBounds.selector);
        config.setSeriesBounds(pid, b);
        b = _defaultBounds();
        b.maxStrikeWad = config.MAX_PRICE_WAD() + 1;
        vm.prank(configAdmin);
        vm.expectRevert(OptaraConfig.InvalidBounds.selector);
        config.setSeriesBounds(pid, b);
        b = _defaultBounds();
        b.maxCapWad = config.MAX_PRICE_WAD() + 1;
        vm.prank(configAdmin);
        vm.expectRevert(OptaraConfig.InvalidBounds.selector);
        config.setSeriesBounds(pid, b);
        vm.startPrank(gov);
        vm.expectRevert(OptaraConfig.InvalidPauseBits.selector);
        config.unpause(bytes32(0), 0);
        vm.expectRevert(OptaraConfig.InvalidPauseBits.selector);
        config.unpause(bytes32(0), 1 << 12);
        vm.stopPrank();
        assertEq(config.assetSymbol(address(usdt)), "USDT");
        (PairStatus st, address u, address a) = config.pairInfo(pid);
        assertEq(uint8(st), uint8(PairStatus.ENABLED));
        assertEq(u, MON);
        assertEq(a, address(usdt));
    }

    function test_registryRemainingBranches() public {
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.InvalidConfig.selector, "config"));
        new OracleRegistry(OptaraConfig(address(0)));
        bytes32 unknown = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.UnknownConfig.selector, unknown));
        registry.getConfig(unknown);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.UnknownConfig.selector, unknown));
        registry.adapterOf(unknown);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.UnknownConfig.selector, unknown));
        registry.finalizationDelays(unknown);
        (uint64 mn, uint64 mx) = registry.finalizationDelays(monUsdtConfig);
        assertEq(mn, MIN_FINAL_DELAY);
        assertEq(mx, MAX_FINAL_DELAY);
        assertEq(registry.adapterOf(monUsdtConfig), address(adapter));
    }

    function test_adapterLatestRevertAndZeroRound() public {
        uint64 exp = expiry1;
        vm.warp(exp - 5);
        uint80 r = monUsdtFeed.pushRound(10e8, block.timestamp);
        vm.warp(exp + MIN_FINAL_DELAY);
        monUsdtFeed.setLatestBroken(true);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkSettlementAdapter.NotLatestRound.selector, address(monUsdtFeed), r)
        );
        adapter.quoteSettlementPrice(monUsdtConfig, exp, _data(0, _proof1(r, 0), _empty()));
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkSettlementAdapter.RoundUnavailable.selector, address(monUsdtFeed), uint80(0)
            )
        );
        adapter.quoteSettlementPrice(monUsdtConfig, exp, _data(0, _proof1(0, 0), _empty()));
    }

    function test_coreRemainingBranchesAndViews() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, WAD);
        bytes32 grp = _groupOf(k10);
        // views
        assertEq(core.groupIdAt(0), grp);
        Leg[] memory legs = core.accountGroupLegs(alice, grp);
        assertEq(legs.length, 1);
        assertEq(legs[0].shortQty, WAD);
        assertEq(core.worstCaseLossNumerator(alice, grp), 5 * WAD * WAD * WAD);
        assertEq(core.groupRequiredMargin(alice, keccak256("none")), 0);
        assertEq(core.requiredMarginAfter(alice, k10, int256(WAD), 0), 10e6);
        // previews before finalization revert
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupNotFinalized.selector, grp));
        core.seriesPayoffPerUnderlying(k10);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupNotFinalized.selector, grp));
        core.previewRedeem(k10, WAD);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupNotFinalized.selector, grp));
        core.previewSync(alice, grp);
        assertFalse(core.isOracleStalled(keccak256("none")));
        // execute on an unrestricted asset
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetNotRestricted.selector, address(usdt)));
        core.executeShortfallResolution(address(usdt));
        // maxWithdrawable while restricted is zero
        assertEq(core.maxWithdrawable(alice, address(usdt)), 5e6);
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "X");
        assertEq(core.maxWithdrawable(alice, address(usdt)), 0);
        // finalized group reports zero worst-case margin (replaced by its settlement delta)
        _finalizeMon(k10, 12 * WAD);
        assertEq(core.groupRequiredMargin(alice, grp), 0);
        assertEq(core.requiredMargin(alice, address(usdt)), 0);
        assertEq(core.effectiveCash(alice, address(usdt)), 8e6);
    }

    function test_recapitalizeRejectedInWindDown() public {
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "LOSS");
        vm.prank(gov);
        core.proposeShortfallResolution(address(usdt), 0.9e18, "R");
        vm.warp(block.timestamp + SHORTFALL_DELAY);
        vm.prank(gov);
        core.executeShortfallResolution(address(usdt));
        _fund(carol, usdt, 1e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetInWindDown.selector, address(usdt)));
        core.recapitalize(address(usdt), 1e6);
        // new risk is disabled in wind-down
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetInWindDown.selector, address(usdt)));
        core.write(k10, WAD, alice);
    }

    function test_requiredMarginAfterNewGroupAndClamp() public {
        // hypothetical write into a group the account does not yet have
        assertEq(core.requiredMarginAfter(alice, k10, int256(WAD), 0), 5e6);
        // negative deltas clamp at zero
        assertEq(core.requiredMarginAfter(alice, k10, -int256(WAD), -int256(WAD)), 0);
        assertEq(core.additionalCollateralForWrite(alice, k10, 2 * WAD), 10e6);
    }
}
