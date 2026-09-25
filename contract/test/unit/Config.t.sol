// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PairStatus} from "../../src/libraries/OptaraTypes.sol";

/// @notice OptaraConfig: approvals, prospective limits, scoped pauses and the role graph (ACCESS_CONTROL.md).
contract ConfigTest is OptaraTestBase {
    function test_constructorRejectsZeroGovernance() public {
        vm.expectRevert(OptaraConfig.ZeroAddress.selector);
        new OptaraConfig(address(0));
    }

    function test_roleAdminIsGovernance() public view {
        bytes32 g = config.GOVERNANCE_ROLE();
        assertEq(config.getRoleAdmin(config.PAUSER_ROLE()), g);
        assertEq(config.getRoleAdmin(config.CONFIG_ROLE()), g);
        assertEq(config.getRoleAdmin(config.SERIES_CREATOR_ROLE()), g);
        assertEq(config.getRoleAdmin(config.ORACLE_CONFIG_ROLE()), g);
        assertEq(config.getRoleAdmin(config.UNPAUSER_ROLE()), g);
        assertEq(config.getRoleAdmin(g), g);
        assertEq(config.getRoleAdmin(config.DEFAULT_ADMIN_ROLE()), g);
        assertEq(config.getRoleMemberCount(g), 1);
    }

    /// ACL-015: operational roles cannot grant themselves or anyone a stronger role.
    function test_ACL_015_noSelfEscalation() public {
        address[5] memory ops = [pauser, creator, oracleAdmin, configAdmin, unpauser];
        bytes32 g = config.GOVERNANCE_ROLE();
        bytes32 pauserRole = config.PAUSER_ROLE();
        for (uint256 i = 0; i < ops.length; ++i) {
            vm.prank(ops[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops[i], g));
            config.grantRole(g, ops[i]);
            vm.prank(ops[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops[i], g));
            config.grantRole(pauserRole, attacker);
        }
    }

    /// ACL-016: revocation is effective for the next transaction.
    function test_ACL_016_revokeEffectiveImmediately() public {
        bytes32 pauserRole = config.PAUSER_ROLE();
        vm.prank(gov);
        config.revokeRole(pauserRole, pauser);
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.pause(bytes32(0), Actions.WRITE);
    }

    /// ACL-017: pauser pauses; only governance or UNPAUSER unpauses.
    function test_ACL_017_unpauseAuthorization() public {
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.WRITE);
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.unpause(bytes32(0), Actions.WRITE);
        vm.prank(unpauser);
        config.unpause(bytes32(0), Actions.WRITE);
        assertFalse(config.isPaused(Actions.WRITE, address(0), bytes32(0)));
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.WRITE);
        vm.prank(gov);
        config.unpause(bytes32(0), Actions.WRITE);
        assertEq(config.pausedBits(bytes32(0)), 0);
    }

    function test_lastGovernanceCannotLeave() public {
        bytes32 g = config.GOVERNANCE_ROLE();
        vm.prank(gov);
        vm.expectRevert(OptaraConfig.LastGovernanceMember.selector);
        config.renounceRole(g, gov);
        vm.prank(gov);
        vm.expectRevert(OptaraConfig.LastGovernanceMember.selector);
        config.revokeRole(g, gov);
        // Handover works: add the new holder, then the old one may leave.
        address timelock = makeAddr("timelock");
        vm.startPrank(gov);
        config.grantRole(g, timelock);
        config.renounceRole(g, gov);
        vm.stopPrank();
        assertTrue(config.hasRole(g, timelock));
        assertFalse(config.hasRole(g, gov));
    }

    function test_pauseScopesAndBits() public {
        vm.startPrank(pauser);
        config.pause(config.assetScope(address(usdt)), Actions.WITHDRAW);
        config.pause(monUsdtConfig, Actions.FINALIZE);
        vm.expectRevert(OptaraConfig.InvalidPauseBits.selector);
        config.pause(bytes32(0), 0);
        vm.expectRevert(OptaraConfig.InvalidPauseBits.selector);
        config.pause(bytes32(0), 1 << 10);
        vm.stopPrank();
        assertTrue(config.isPaused(Actions.WITHDRAW, address(usdt), bytes32(0)));
        assertFalse(config.isPaused(Actions.WITHDRAW, address(usdc), bytes32(0)));
        assertTrue(config.isPaused(Actions.FINALIZE, address(usdc), monUsdtConfig));
        assertFalse(config.isPaused(Actions.FINALIZE, address(usdc), ethUsdcConfig));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, attacker));
        config.pause(bytes32(0), Actions.WRITE);
    }

    function test_approveAssetValidation() public {
        MockERC20 t = new MockERC20("X", "X", 6);
        vm.startPrank(gov);
        vm.expectRevert(OptaraConfig.ZeroAddress.selector);
        config.approveAsset(address(0), "X", 0, 0);
        vm.expectRevert(OptaraConfig.ZeroAddress.selector);
        config.approveAsset(makeAddr("eoa"), "X", 0, 0);
        vm.expectRevert(OptaraConfig.EmptySymbol.selector);
        config.approveAsset(address(t), "", 0, 0);
        vm.expectRevert(OptaraConfig.InvalidBuffer.selector);
        config.approveAsset(address(t), "X", 10_001, 0);
        MockERC20 bad = new MockERC20("B", "B", 19);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnsupportedDecimals.selector, uint8(19)));
        config.approveAsset(address(bad), "B", 0, 0);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.AssetAlreadyKnown.selector, address(usdt)));
        config.approveAsset(address(usdt), "USDT", 0, 0);
        vm.stopPrank();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.approveAsset(address(t), "X", 0, 0);
        (bool known, bool enabled, uint8 dec) = config.assetInfo(address(usde));
        assertTrue(known && enabled);
        assertEq(dec, 18);
    }

    function test_assetDisableAndReenable() public {
        vm.prank(pauser);
        config.setAssetNewRiskEnabled(address(usdt), false);
        (, bool enabled,) = config.assetInfo(address(usdt));
        assertFalse(enabled);
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setAssetNewRiskEnabled(address(usdt), true);
        vm.prank(gov);
        config.setAssetNewRiskEnabled(address(usdt), true);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownAsset.selector, address(1)));
        config.setAssetNewRiskEnabled(address(1), false);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, attacker));
        config.setAssetNewRiskEnabled(address(usdt), false);
    }

    function test_bufferDefaults() public {
        vm.prank(gov);
        config.setAssetBufferDefaults(address(usdt), 100, 5);
        (uint16 bps, uint256 fixedBuffer) = config.bufferDefaults(address(usdt));
        assertEq(bps, 100);
        assertEq(fixedBuffer, 5);
        vm.startPrank(gov);
        vm.expectRevert(OptaraConfig.InvalidBuffer.selector);
        config.setAssetBufferDefaults(address(usdt), 10_001, 0);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownAsset.selector, address(1)));
        config.setAssetBufferDefaults(address(1), 0, 0);
        vm.stopPrank();
    }

    function test_underlyingApproval() public {
        address x = makeAddr("X");
        vm.startPrank(gov);
        vm.expectRevert(OptaraConfig.ZeroAddress.selector);
        config.approveUnderlying(address(0), "X");
        vm.expectRevert(OptaraConfig.EmptySymbol.selector);
        config.approveUnderlying(x, "");
        config.approveUnderlying(x, "X");
        vm.stopPrank();
        vm.prank(pauser);
        config.setUnderlyingApproved(x, false);
        (bool ok, string memory sym) = config.underlyingInfo(x);
        assertFalse(ok);
        assertEq(sym, "X");
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setUnderlyingApproved(x, true);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, attacker));
        config.setUnderlyingApproved(x, false);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnderlyingNotApproved.selector, address(7)));
        config.setUnderlyingApproved(address(7), false);
    }

    function test_pairApprovalValidation() public {
        address x = makeAddr("X");
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnderlyingNotApproved.selector, x));
        config.approvePair(x, address(usdt), _defaultBounds(), 1, 1);
        config.approveUnderlying(x, "X");
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownAsset.selector, address(9)));
        config.approvePair(x, address(9), _defaultBounds(), 1, 1);
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.PairAlreadyApproved.selector, pid));
        config.approvePair(MON, address(usdt), _defaultBounds(), 1, 1);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.approvePair(x, address(usdt), _defaultBounds(), BIG_LIMIT + 1, 1);
        SeriesBounds memory b = _defaultBounds();
        b.quantityIncrement = 0;
        vm.expectRevert(OptaraConfig.InvalidBounds.selector);
        config.approvePair(x, address(usdt), b, 1, 1);
        vm.stopPrank();
    }

    function test_pairApprovalRejectsUnderlyingEqualsAsset() public {
        vm.startPrank(gov);
        config.approveUnderlying(address(usdt), "USDT");
        vm.expectRevert(OptaraConfig.UnderlyingEqualsAsset.selector);
        config.approvePair(address(usdt), address(usdt), _defaultBounds(), 1, 1);
        vm.stopPrank();
    }

    function test_boundsValidation() public {
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        SeriesBounds memory b = _defaultBounds();
        uint256 maxPrice = config.MAX_PRICE_WAD();
        SeriesBounds[9] memory bad;
        for (uint256 i = 0; i < 9; ++i) {
            bad[i] = _defaultBounds(); // fresh copy; memory struct assignment would alias
        }
        bad[0].minStrikeWad = 0;
        bad[1].minCapWad = 0;
        bad[2].minContractSizeWad = 0;
        bad[3].minStrikeWad = b.maxStrikeWad + 1;
        bad[4].maxStrikeWad = maxPrice;
        bad[4].maxCapWad = 1e20;
        bad[5].maxContractSizeWad = maxPrice + 1;
        bad[6].maxTimeToExpiry = 0;
        bad[7].minTimeToExpiry = b.maxTimeToExpiry + 1;
        bad[8].minCapWad = b.maxCapWad + 1;
        vm.startPrank(configAdmin);
        for (uint256 i = 0; i < 9; ++i) {
            vm.expectRevert(OptaraConfig.InvalidBounds.selector);
            config.setSeriesBounds(pid, bad[i]);
        }
        config.setSeriesBounds(pid, b);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownPair.selector, bytes32(uint256(1))));
        config.setSeriesBounds(bytes32(uint256(1)), b);
        vm.stopPrank();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setSeriesBounds(pid, b);
    }

    function test_pairStatusTransitions() public {
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        vm.prank(pauser);
        config.setPairStatus(pid, PairStatus.NEW_RISK_DISABLED);
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setPairStatus(pid, PairStatus.ENABLED);
        vm.prank(configAdmin);
        config.setPairStatus(pid, PairStatus.ENABLED);
        vm.prank(configAdmin);
        config.setPairStatus(pid, PairStatus.NEW_RISK_DISABLED);
        vm.prank(configAdmin);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, configAdmin));
        config.setPairStatus(pid, PairStatus.RETIRED);
        vm.startPrank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptaraConfig.InvalidPairTransition.selector, PairStatus.NEW_RISK_DISABLED, PairStatus.UNAPPROVED
            )
        );
        config.setPairStatus(pid, PairStatus.UNAPPROVED);
        config.setPairStatus(pid, PairStatus.RETIRED);
        vm.expectRevert(
            abi.encodeWithSelector(OptaraConfig.InvalidPairTransition.selector, PairStatus.RETIRED, PairStatus.ENABLED)
        );
        config.setPairStatus(pid, PairStatus.ENABLED);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownPair.selector, bytes32(uint256(5))));
        config.setPairStatus(bytes32(uint256(5)), PairStatus.ENABLED);
        vm.stopPrank();
    }

    /// CAP-003 (config side): raising a cap is governance-only; lowering is allowed to the guardian.
    function test_exposureLimitAuthorization() public {
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        vm.prank(pauser);
        config.setExposureLimit(ExposureScope.PAIR, pid, 100);
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setExposureLimit(ExposureScope.PAIR, pid, 101);
        vm.prank(gov);
        config.setExposureLimit(ExposureScope.PAIR, pid, 101);
        vm.prank(pauser);
        config.setExposureLimit(ExposureScope.SERIES, pid, 5);
        vm.prank(pauser);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, monUsdtConfig, 7);
        vm.prank(pauser);
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(usdt)))), 9);
        (uint256 sL, uint256 pL, uint256 oL, uint256 aL) = config.exposureLimits(pid, monUsdtConfig, address(usdt));
        assertEq(sL, 5);
        assertEq(pL, 101);
        assertEq(oL, 7);
        assertEq(aL, 9);
        vm.startPrank(gov);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setExposureLimit(ExposureScope.PAIR, pid, BIG_LIMIT + 1);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownPair.selector, bytes32(uint256(3))));
        config.setExposureLimit(ExposureScope.PAIR, bytes32(uint256(3)), 1);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownAsset.selector, address(3)));
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(3)), 1);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.UnknownAsset.selector, address(usdt)));
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(usdt))) | (1 << 200)), 1);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, attacker));
        config.setExposureLimit(ExposureScope.PAIR, pid, 1);
    }

    function test_positionLimits() public {
        vm.startPrank(gov);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setPositionLimits(0, 1, 1);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setPositionLimits(17, 1, 1);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setPositionLimits(1, 17, 1);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setPositionLimits(1, 1, 65);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setPositionLimits(1, 0, 1);
        vm.expectRevert(OptaraConfig.InvalidLimit.selector);
        config.setPositionLimits(1, 1, 0);
        config.setPositionLimits(16, 16, 64);
        vm.stopPrank();
        (uint32 a, uint32 b, uint32 c) = config.positionLimits();
        assertEq(a, 16);
        assertEq(b, 16);
        assertEq(c, 64);
        vm.prank(configAdmin);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, configAdmin));
        config.setPositionLimits(1, 1, 1);
    }
}
