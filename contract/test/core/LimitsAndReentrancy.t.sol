// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {ReentrantERC20} from "../mocks/HostileTokens.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Bounded computation at the hard caps (DOS-*, RSK-023, INV-GAS-*) and reentrancy (REE-*).
contract LimitsAndReentrancyTest is OptaraTestBase {
    /// Gas budget per call at the hard caps. Monad's block gas limit is far higher; this keeps operations
    /// comfortably executable (TESTING.md section 116).
    uint256 constant GAS_BUDGET = 30_000_000;

    // ------------------------------------------------------------------ DOS
    function _maxLimits() internal {
        vm.prank(gov);
        config.setPositionLimits(16, 16, 64);
    }

    /// DOS-001/002/007/008/009 + RSK-023: 16 series in one group (max), each short and locked; margin, withdraw,
    /// unlock and sync stay within budget; the 17th series is rejected.
    function test_DOS_001_002_007_008_009_maxSeriesPerGroup() public {
        _maxLimits();
        bytes32[] memory ids = new bytes32[](17);
        for (uint256 i = 0; i < 17; ++i) {
            ids[i] = _createSeries(
                MON,
                address(usdt),
                i % 2 == 0 ? OptionType.CALL : OptionType.PUT,
                (5 + i) * WAD,
                (1 + i % 4) * WAD,
                WAD,
                expiry1,
                monUsdtConfig
            );
        }
        _deposit(alice, usdt, 1_000e6);
        _deposit(carol, usdt, 1_000e6);
        for (uint256 i = 0; i < 16; ++i) {
            _write(alice, ids[i], WAD);
            // hedges come from carol so alice's group has both legs
            _write(carol, ids[i], WAD / 2);
            IOptionToken t = _token(ids[i]);
            vm.prank(carol);
            t.transfer(alice, WAD / 2);
            _lock(alice, ids[i], WAD / 4);
        }
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.PositionLimitReached.selector); // DOS-002
        core.write(ids[16], WAD, alice);

        uint256 g0 = gasleft();
        core.requiredMargin(alice, address(usdt));
        uint256 marginGas = g0 - gasleft();
        g0 = gasleft();
        vm.prank(alice);
        core.withdraw(address(usdt), 1e6, alice);
        uint256 withdrawGas = g0 - gasleft();
        g0 = gasleft();
        vm.prank(alice);
        core.unlockLong(ids[3], 1, alice);
        uint256 unlockGas = g0 - gasleft();
        console2.log("16-series group: requiredMargin gas", marginGas);
        console2.log("16-series group: withdraw gas", withdrawGas);
        console2.log("16-series group: unlock gas", unlockGas);
        assertLt(marginGas, GAS_BUDGET); // DOS-007
        assertLt(withdrawGas, GAS_BUDGET); // DOS-009
        assertLt(unlockGas, GAS_BUDGET);

        _finalizeMon(ids[0], 12 * WAD);
        g0 = gasleft();
        core.syncRiskGroup(alice, _groupOf(ids[0]));
        uint256 syncGas = g0 - gasleft();
        console2.log("16-series group: sync gas", syncGas);
        assertLt(syncGas, GAS_BUDGET); // DOS-008
        assertEq(core.accountSeriesCount(alice), 0);
    }

    /// DOS-003/004/005/006: 16 groups (max) and 64 series (max) per account; withdraw across all within budget.
    function test_DOS_003_to_006_maxGroupsAndSeries() public {
        _maxLimits();
        bytes32[] memory ids = new bytes32[](64);
        uint256 n;
        for (uint256 gIdx = 0; gIdx < 16; ++gIdx) {
            uint64 exp = uint64(block.timestamp + 2 days + gIdx * 1 days);
            for (uint256 j = 0; j < 4; ++j) {
                ids[n++] = _createSeries(
                    MON, address(usdt), OptionType.CALL, (10 + j) * WAD, 2 * WAD, WAD, exp, monUsdtConfig
                );
            }
        }
        _deposit(alice, usdt, 10_000e6);
        for (uint256 i = 0; i < 64; ++i) {
            _write(alice, ids[i], WAD);
        }
        assertEq(core.accountGroups(alice).length, 16); // DOS-003
        assertEq(core.accountSeriesCount(alice), 64); // DOS-005
        bytes32 extra =
            _createSeries(MON, address(usdt), OptionType.CALL, 30 * WAD, 2 * WAD, WAD, expiry2, monUsdtConfig);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.PositionLimitReached.selector); // DOS-004 / DOS-006
        core.write(extra, WAD, alice);
        uint256 g0 = gasleft();
        vm.prank(alice);
        core.withdraw(address(usdt), 1e6, alice);
        uint256 withdrawGas = g0 - gasleft();
        console2.log("16 groups x 4 series: withdraw gas", withdrawGas);
        assertLt(withdrawGas, GAS_BUDGET);
        assertEq(core.requiredMargin(alice, address(usdt)), 128e6);
    }

    // ------------------------------------------------------------------ REE
    ReentrantERC20 rtk;
    bytes32 rseries;

    function _setupReentrantAsset() internal {
        rtk = new ReentrantERC20("Reentrant USD", "rUSD", 6);
        vm.startPrank(gov);
        config.approveAsset(address(rtk), "rUSD", 0, 0);
        _approvePair(MON, address(rtk));
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(rtk)))), BIG_LIMIT);
        vm.stopPrank();
        bytes32 cfg = _registerDirect(MON, address(rtk), address(monUsdtFeed), 8, address(0), 0);
        vm.prank(gov);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, cfg, BIG_LIMIT);
        rseries = _createSeries(MON, address(rtk), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, cfg);
        rtk.mint(alice, 100e6);
        vm.prank(alice);
        rtk.approve(address(core), type(uint256).max);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(rtk.reentered());
        assertFalse(rtk.reenterSucceeded());
        assertEq(bytes4(rtk.reenterReturn()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    /// REE-001: reentering withdraw from inside the deposit transfer is blocked; accounting stays exact.
    function test_REE_001_depositReentrancy() public {
        _setupReentrantAsset();
        rtk.arm(address(core), abi.encodeCall(core.withdraw, (address(rtk), 1, alice)));
        vm.prank(alice);
        core.deposit(address(rtk), 10e6);
        _assertReentryBlocked();
        assertEq(core.cashBalance(alice, address(rtk)), 10e6);
        assertEq(rtk.balanceOf(address(core)), 10e6);
    }

    /// REE-002: reentering during the withdrawal payout is blocked.
    function test_REE_002_withdrawalReentrancy() public {
        _setupReentrantAsset();
        vm.prank(alice);
        core.deposit(address(rtk), 10e6);
        rtk.arm(address(core), abi.encodeCall(core.withdraw, (address(rtk), 5e6, alice)));
        vm.prank(alice);
        core.withdraw(address(rtk), 5e6, alice);
        _assertReentryBlocked();
        assertEq(core.cashBalance(alice, address(rtk)), 5e6);
        assertEq(rtk.balanceOf(address(core)), 5e6);
    }

    /// REE-003/004/005: lock, unlock and close reentry through the settlement token path (the option token itself
    /// has no hooks). A write triggered during a deposit hook is blocked as well.
    function test_REE_003_004_005_positionPathsReentrancy() public {
        _setupReentrantAsset();
        rtk.arm(address(core), abi.encodeCall(core.write, (rseries, WAD, alice)));
        vm.prank(alice);
        core.deposit(address(rtk), 10e6);
        _assertReentryBlocked();
        rtk.arm(address(core), abi.encodeCall(core.lockLong, (rseries, WAD)));
        vm.prank(alice);
        core.deposit(address(rtk), 1e6);
        _assertReentryBlocked();
        rtk.arm(address(core), abi.encodeCall(core.closeShort, (rseries, WAD, CloseSource.EXTERNAL)));
        vm.prank(alice);
        core.deposit(address(rtk), 1e6);
        _assertReentryBlocked();
        rtk.arm(address(core), abi.encodeCall(core.unlockLong, (rseries, WAD, alice)));
        vm.prank(alice);
        core.deposit(address(rtk), 1e6);
        _assertReentryBlocked();
    }

    /// REE-006: reentering redeem during the redemption payout cannot double-pay.
    function test_REE_006_redeemReentrancy() public {
        _setupReentrantAsset();
        vm.prank(alice);
        core.deposit(address(rtk), 10e6);
        vm.prank(alice);
        core.write(rseries, 2 * WAD, alice);
        bytes memory data = _directProofData(monUsdtFeed, 13e8, expiry1);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY);
        core.finalizeRiskGroup(core.getSeries(rseries).groupId, data);
        rtk.arm(address(core), abi.encodeCall(core.redeem, (rseries, WAD, alice)));
        uint256 before = rtk.balanceOf(alice);
        vm.prank(alice);
        core.redeem(rseries, WAD, alice);
        _assertReentryBlocked();
        assertEq(rtk.balanceOf(alice) - before, 3e6);
        assertEq(_token(rseries).balanceOf(alice), WAD);
    }

    /// REE-007 N/A: canonical V2 ships no router.
}
