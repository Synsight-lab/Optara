// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    FeeOnTransferERC20,
    FalseReturnERC20,
    NoReturnERC20,
    RebasingERC20,
    BlacklistERC20
} from "../mocks/HostileTokens.sol";

/// @notice Deposit, withdrawal, per-asset margin and stablecoin behaviour (TEST_CASES.md Parts VII, VIII, XIII,
///         XXXII; DON-002).
contract CashTest is OptaraTestBase {
    bytes32 callId;

    function setUp() public override {
        super.setUp();
        callId = _monCall(10 * WAD, 5 * WAD);
    }

    function _approveNewAsset(address token, string memory sym) internal {
        vm.prank(gov);
        config.approveAsset(token, sym, 0, 0);
    }

    // ------------------------------------------------------------------ DEP
    function test_DEP_001_002_003_depositApprovedAssets() public {
        _deposit(alice, usdt, 7e6);
        _deposit(alice, usdc, 9e6);
        _deposit(alice, usde, 11e18);
        assertEq(core.cashBalance(alice, address(usdt)), 7e6);
        assertEq(core.cashBalance(alice, address(usdc)), 9e6);
        assertEq(core.cashBalance(alice, address(usde)), 11e18);
    }

    function test_DEP_004_rejectZero() public {
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.deposit(address(usdt), 0);
    }

    function test_DEP_005_rejectUnsupportedAsset() public {
        MockERC20 x = new MockERC20("X", "X", 6);
        _fund(alice, x, 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownAsset.selector, address(x)));
        core.deposit(address(x), 1e6);
    }

    function test_DEP_006_007_exactLedgerAndVaultIncrease() public {
        _fund(alice, usdt, 3e6);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.CollateralDeposited(alice, address(usdt), 3e6, false);
        vm.prank(alice);
        core.deposit(address(usdt), 3e6);
        assertEq(core.cashBalance(alice, address(usdt)), 3e6);
        assertEq(usdt.balanceOf(address(core)), 3e6);
        assertEq(core.totalCash(address(usdt)), 3e6);
        assertEq(core.vaultBalance(address(usdt)), 3e6);
    }

    function test_DEP_008_depositOneAssetDoesNotAffectAnother() public {
        _deposit(alice, usdt, 3e6);
        assertEq(core.cashBalance(alice, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    /// DEP-010 / STB-008: a fee-on-transfer token cannot be credited more than received; deposits revert.
    function test_DEP_010_feeOnTransferRejected() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("F", "F", 6);
        _approveNewAsset(address(fot), "F");
        fot.mint(alice, 100e6);
        vm.startPrank(alice);
        fot.approve(address(core), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NonExactTransfer.selector, 100e6, 99e6));
        core.deposit(address(fot), 100e6);
        vm.stopPrank();
        assertEq(core.cashBalance(alice, address(fot)), 0);
    }

    function test_DEP_011_falseReturnTokenFailsSafely() public {
        FalseReturnERC20 f = new FalseReturnERC20(6);
        _approveNewAsset(address(f), "FALSE");
        f.mint(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(f)));
        core.deposit(address(f), 1e6); // no allowance -> returns false
        assertEq(core.cashBalance(alice, address(f)), 0);
    }

    /// USDT-style tokens without return values work through SafeERC20.
    function test_noReturnTokenSupported() public {
        NoReturnERC20 t = new NoReturnERC20(6);
        _approveNewAsset(address(t), "NORET");
        t.mint(alice, 5e6);
        vm.startPrank(alice);
        t.approve(address(core), 5e6);
        core.deposit(address(t), 5e6);
        core.withdraw(address(t), 2e6, bob);
        vm.stopPrank();
        assertEq(t.balanceOf(bob), 2e6);
        assertEq(core.cashBalance(alice, address(t)), 3e6);
    }

    function test_DEP_012_transferRevertLeavesLedgerUnchanged() public {
        BlacklistERC20 b = new BlacklistERC20("B", "B", 6);
        _approveNewAsset(address(b), "B");
        b.mint(alice, 5e6);
        vm.prank(alice);
        b.approve(address(core), 5e6);
        b.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        core.deposit(address(b), 5e6);
        assertEq(core.cashBalance(alice, address(b)), 0);
        assertEq(core.totalCash(address(b)), 0);
    }

    function test_depositPausedScopes() public {
        _fund(alice, usdt, 1e6);
        bytes32 scope = config.assetScope(address(usdt));
        vm.prank(pauser);
        config.pause(scope, Actions.DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.DEPOSIT));
        core.deposit(address(usdt), 1e6);
        _deposit(alice, usdc, 1e6); // unaffected asset
    }

    // ------------------------------------------------------------------ WDW
    function test_WDW_001_withdrawFreeCollateral() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, callId, WAD); // requires 5
        vm.prank(alice);
        core.withdraw(address(usdt), 3e6, alice);
        assertEq(core.cashBalance(alice, address(usdt)), 7e6);
        assertEq(usdt.balanceOf(alice), 3e6);
    }

    function test_WDW_002_withdrawExactMax() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, callId, WAD);
        assertEq(core.maxWithdrawable(alice, address(usdt)), 5e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 5e6, alice);
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
    }

    function test_WDW_003_oneUnitAboveFreeReverts() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, callId, WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 5e6 - 1));
        core.withdraw(address(usdt), 5e6 + 1, alice);
    }

    function test_WDW_004_rejectZeroAndBadRecipient() public {
        _deposit(alice, usdt, 1e6);
        vm.startPrank(alice);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.withdraw(address(usdt), 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRecipient.selector, address(0)));
        core.withdraw(address(usdt), 1, address(0));
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientCash.selector, 2e6, 1e6));
        core.withdraw(address(usdt), 2e6, alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownAsset.selector, address(9)));
        core.withdraw(address(9), 1, alice);
        vm.stopPrank();
    }

    /// WDW-005 / MAR-004 / WRT-010: a huge USDC balance cannot cover a USDT requirement.
    function test_WDW_005_wrongAssetCannotHelp() public {
        _deposit(alice, usdt, 5e6);
        _deposit(alice, usdc, 1_000_000e6);
        _write(alice, callId, WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 4e6));
        core.withdraw(address(usdt), 1e6, alice);
        vm.prank(alice);
        core.withdraw(address(usdc), 1_000_000e6, alice); // USDC fully free
    }

    function test_WDW_006_007_recipientGetsExactAmountLedgerReduces() public {
        _deposit(alice, usdt, 10e6);
        vm.expectEmit(true, true, true, true, address(core));
        emit IOptaraCoreEvents.CollateralWithdrawn(alice, address(usdt), bob, 4e6, 4e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 4e6, bob);
        assertEq(usdt.balanceOf(bob), 4e6);
        assertEq(core.cashBalance(alice, address(usdt)), 6e6);
        assertEq(core.totalCash(address(usdt)), 6e6);
    }

    function test_WDW_009_tokenTransferRevertRestoresState() public {
        BlacklistERC20 b = new BlacklistERC20("B", "B", 6);
        _approveNewAsset(address(b), "B");
        b.mint(alice, 5e6);
        vm.startPrank(alice);
        b.approve(address(core), 5e6);
        core.deposit(address(b), 5e6);
        vm.stopPrank();
        b.setBlacklisted(bob, true);
        vm.prank(alice);
        vm.expectRevert(bytes("blacklisted"));
        core.withdraw(address(b), 5e6, bob);
        assertEq(core.cashBalance(alice, address(b)), 5e6);
    }

    /// WDW-010 / ORACLE_AND_SETTLEMENT.md section 54: withdrawal syncs matured debt before evaluating.
    function test_WDW_010_maturedDebtSyncedFirst() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, callId, WAD);
        _finalizeMon(callId, 14 * WAD); // debt 4
        assertEq(core.cashBalance(alice, address(usdt)), 10e6); // raw not yet synced
        assertEq(core.effectiveCash(alice, address(usdt)), 6e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientCash.selector, 8e6, 6e6));
        core.withdraw(address(usdt), 8e6, alice);
        vm.prank(alice);
        core.withdraw(address(usdt), 6e6, alice);
        assertEq(core.cashBalance(alice, address(usdt)), 0);
    }

    function test_WDW_011_maturedLockedCreditSyncedFirst() public {
        bytes32 hedge = _monCall(12 * WAD, 3 * WAD);
        _deposit(bob, usdt, 3e6);
        _write(bob, hedge, WAD);
        IOptionToken ht = _token(hedge);
        vm.prank(bob);
        ht.transfer(alice, WAD);
        _deposit(alice, usdt, 2e6);
        _lock(alice, hedge, WAD);
        _write(alice, callId, WAD); // net requirement 2
        _finalizeMon(callId, 20 * WAD); // short 5, long 3 -> net -2
        assertEq(core.effectiveCash(alice, address(usdt)), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientCash.selector, 1, 0));
        core.withdraw(address(usdt), 1, alice);
        assertEq(core.cashBalance(alice, address(usdt)), 2e6); // revert rolled back the sync
    }

    /// WDW-012: the caller cannot omit a finalized position; the canonical index is always complete.
    function test_WDW_012_callerCannotOmitMaturedPosition() public {
        bytes32 other =
            _createSeries(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry2, monUsdtConfig);
        _deposit(alice, usdt, 15e6);
        _write(alice, callId, WAD);
        _write(alice, other, WAD);
        _finalizeMon(callId, 15 * WAD); // debt 5 in group 1
        // withdraw has no position-list parameter: it synchronizes group 1 itself
        assertEq(core.freeCollateral(alice, address(usdt)), 5e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 5e6, alice);
        assertEq(core.accountGroups(alice).length, 1); // only the unfinalized group remains
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 5e6 - 1));
        core.withdraw(address(usdt), 1, alice);
    }

    function test_WDW_013_postWithdrawInvariant() public {
        _deposit(alice, usdt, 12e6);
        _write(alice, callId, 2 * WAD);
        vm.prank(alice);
        core.withdraw(address(usdt), 2e6, alice);
        assertGe(core.cashBalance(alice, address(usdt)), core.requiredMargin(alice, address(usdt)));
    }

    function test_withdrawPaused() public {
        _deposit(alice, usdt, 1e6);
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.WITHDRAW);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.WITHDRAW));
        core.withdraw(address(usdt), 1e6, alice);
    }

    // ------------------------------------------------------------------ MAR
    function test_MAR_001_singleGroup() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, callId, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        assertEq(core.groupRequiredMargin(alice, _groupOf(callId)), 5e6);
    }

    /// MAR-002 / MATH.md section 70: two groups sharing USDT add.
    function test_MAR_002_twoGroupsSameStablecoinSum() public {
        bytes32 eth =
            _createSeries(ETH, address(usdt), OptionType.CALL, 3000 * WAD, 8 * WAD, WAD, expiry1, _ethUsdtConfig());
        _deposit(alice, usdt, 15e6);
        _write(alice, callId, WAD);
        _write(alice, eth, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 13e6);
        assertEq(core.freeCollateral(alice, address(usdt)), 2e6);
    }

    /// MAR-003 / MATH.md section 71: USDT and USDC requirements are separate.
    function test_MAR_003_differentStablecoinsIsolated() public {
        bytes32 eth =
            _createSeries(ETH, address(usdc), OptionType.CALL, 3000 * WAD, 4 * WAD, WAD, expiry1, ethUsdcConfig);
        _deposit(alice, usdt, 20e6);
        _write(alice, callId, WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 4e6, 0));
        core.write(eth, WAD, alice);
        assertEq(core.requiredMargin(alice, address(usdc)), 0);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
    }

    function test_MAR_004_usdtSurplusCannotCoverUsdc() public {
        bytes32 eth =
            _createSeries(ETH, address(usdc), OptionType.CALL, 3000 * WAD, 4 * WAD, WAD, expiry1, ethUsdcConfig);
        _deposit(alice, usdt, 1_000e6);
        _deposit(alice, usdc, 3e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 4e6, 3e6));
        core.write(eth, WAD, alice);
    }

    function test_MAR_005_006_freeAndAdditionalCollateral() public {
        _deposit(alice, usdt, 2e6);
        assertEq(core.additionalCollateralForWrite(alice, callId, WAD), 3e6); // MATH.md section 14 example
        _deposit(alice, usdt, 0.5e6);
        assertEq(core.additionalCollateralForWrite(alice, callId, WAD), 2.5e6);
        _deposit(alice, usdt, 2.5e6);
        assertEq(core.additionalCollateralForWrite(alice, callId, WAD), 0);
        _write(alice, callId, WAD);
        assertEq(core.freeCollateral(alice, address(usdt)), 0);
        _deposit(alice, usdt, 0.7e6);
        assertEq(core.freeCollateral(alice, address(usdt)), 0.7e6);
    }

    function test_MAR_007_coverageMonitoringOnly() public {
        _deposit(alice, usdt, 6e6);
        _write(alice, callId, WAD);
        IOptaraCore.AccountRiskState memory r = core.accountRiskState(alice, address(usdt));
        assertEq(r.cash, 6e6);
        assertEq(r.requiredMargin, 5e6);
        assertEq(r.freeCollateral, 1e6);
        assertEq(r.deficit, 0);
        assertFalse(r.hasUnsyncedMaturedGroups);
        assertEq(uint8(r.assetStatus), uint8(AssetStatus.NORMAL));
    }

    function test_MAR_008_zeroRiskZeroMargin() public view {
        assertEq(core.requiredMargin(alice, address(usdt)), 0);
        assertEq(core.freeCollateral(alice, address(usdt)), 0);
    }

    function test_MAR_009_zeroBuffer() public {
        Group memory g = core.getGroup(_groupOf(callId));
        assertEq(g.bufferBps, 0);
        assertEq(g.fixedBufferNative, 0);
    }

    /// MAR-010 / POL-001: nonzero buffer snapshotted at group creation; later default changes do not apply.
    function test_MAR_010_nonZeroBufferSnapshot() public {
        vm.prank(gov);
        config.setAssetBufferDefaults(address(usdt), 100, 3); // 1% + 3 native
        bytes32 id = _createSeries(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry2, monUsdtConfig);
        _deposit(alice, usdt, 20e6);
        _write(alice, id, WAD);
        // base 5_000_000 + ceil(5_000_000 * 100 / 10_000) + 3
        assertEq(core.requiredMargin(alice, address(usdt)), 5_050_003);
        vm.prank(gov);
        config.setAssetBufferDefaults(address(usdt), 5_000, 1e6);
        assertEq(core.requiredMargin(alice, address(usdt)), 5_050_003); // snapshot unchanged
        // existing zero-buffer group keeps zero
        _write(alice, callId, WAD);
        assertEq(core.groupRequiredMargin(alice, _groupOf(callId)), 5e6);
    }

    // ------------------------------------------------------------------ STB
    function test_STB_001_002_decimalsHandled() public {
        bytes32 id18 =
            _createSeries(MON, address(usde), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdeConfig);
        _deposit(alice, usde, 5e18);
        _write(alice, id18, WAD);
        assertEq(core.requiredMargin(alice, address(usde)), 5e18);
        _deposit(alice, usdt, 5e6);
        _write(alice, callId, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
    }

    function test_STB_003_unusualDecimals() public {
        MockERC20 d0 = new MockERC20("Zero", "Z0", 0);
        MockERC20 d2 = new MockERC20("Two", "Z2", 2);
        _approveNewAsset(address(d0), "Z0");
        _approveNewAsset(address(d2), "Z2");
        vm.startPrank(gov);
        _approvePair(MON, address(d2));
        config.setExposureLimit(ExposureScope.ASSET, bytes32(uint256(uint160(address(d2)))), BIG_LIMIT);
        vm.stopPrank();
        bytes32 cfg = _registerDirect(MON, address(d2), address(monUsdtFeed), 8, address(0), 0);
        vm.prank(gov);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, cfg, BIG_LIMIT);
        bytes32 id = _createSeries(MON, address(d2), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, cfg);
        _deposit(alice, d2, 500);
        vm.prank(alice);
        core.write(id, WAD / 3, alice); // 5/3 = 1.666.. -> 167 cents
        assertEq(core.requiredMargin(alice, address(d2)), 167);
    }

    function test_STB_004_depegAffectsOracleUnitsNotAccounting() public {
        // A USDC depeg changes the derived ETH/USDC price, never the USDC ledger units.
        bytes32 eth =
            _createSeries(ETH, address(usdc), OptionType.CALL, 3000 * WAD, 500 * WAD, WAD / 10, expiry1, ethUsdcConfig);
        _deposit(alice, usdc, 50e6);
        _write(alice, eth, WAD);
        assertEq(core.requiredMargin(alice, address(usdc)), 50e6);
        vm.warp(expiry1 - 60);
        uint80 r1 = ethUsdFeed.pushRound(3100e8, block.timestamp);
        uint80 r2 = usdcUsdFeed.pushRound(0.5e8, block.timestamp); // USDC at $0.50
        vm.warp(expiry1 + MIN_FINAL_DELAY);
        core.finalizeRiskGroup(_groupOf(eth), _data(0, _proof2(r1, 0, r2, 0), _empty()));
        assertEq(core.getGroup(_groupOf(eth)).settlementPriceWad, 6200e18); // 3100 / 0.5 USDC per ETH
        core.syncRiskGroup(alice, _groupOf(eth));
        assertEq(core.cashBalance(alice, address(usdc)), 0); // capped at 500 * 0.1 = 50 USDC units
    }

    function test_STB_005_tokenPauseSafeFailure() public {
        BlacklistERC20 b = new BlacklistERC20("B", "B", 6);
        _approveNewAsset(address(b), "B");
        b.mint(alice, 5e6);
        vm.startPrank(alice);
        b.approve(address(core), 5e6);
        core.deposit(address(b), 5e6);
        vm.stopPrank();
        b.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        core.withdraw(address(b), 1e6, alice);
        assertEq(core.cashBalance(alice, address(b)), 5e6);
    }

    function test_STB_006_blacklistAtomic() public {
        test_WDW_009_tokenTransferRevertRestoresState();
    }

    /// STB-007: a rebasing token is rejected by governance policy (DD-040). If one were approved anyway, a positive
    /// rebase only adds unallocated surplus and never credits an account; a negative rebase is a custody incident.
    function test_STB_007_rebasingTokenNeverCreditsBeyondTransfer() public {
        RebasingERC20 r = new RebasingERC20("R", "R", 6);
        _approveNewAsset(address(r), "R");
        r.mint(alice, 10e6);
        vm.startPrank(alice);
        r.approve(address(core), type(uint256).max);
        core.deposit(address(r), 10e6);
        vm.stopPrank();
        r.rebase(20_000); // doubles every balance
        assertEq(core.cashBalance(alice, address(r)), 10e6);
        assertEq(r.balanceOf(address(core)), 20e6);
        r.rebase(10_000);
        r.mint(bob, 1e6);
        r.rebase(15_000);
        vm.startPrank(bob);
        r.approve(address(core), type(uint256).max);
        // transferFrom moves 1e6 raw units but the balance delta is 1.5e6: not exact -> reverts
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NonExactTransfer.selector, 1e6, 1.5e6));
        core.deposit(address(r), 1e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ DON-002, recapitalize
    function test_DON_002_stablecoinDonationIsSurplusOnly() public {
        _deposit(alice, usdt, 5e6);
        usdt.mint(address(core), 7e6); // direct donation
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
        assertEq(core.totalCash(address(usdt)), 5e6);
        assertEq(core.vaultBalance(address(usdt)), 12e6);
        // no false restriction from a donation
        assertFalse(core.checkAndRestrict(alice, address(usdt)));
        vm.prank(alice);
        core.withdraw(address(usdt), 5e6, alice);
        assertEq(usdt.balanceOf(address(core)), 7e6); // unclaimed surplus remains; no rescue path exists
    }

    function test_recapitalizeCreditsNobody() public {
        _fund(carol, usdt, 4e6);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.Recapitalized(address(usdt), carol, 4e6);
        vm.prank(carol);
        core.recapitalize(address(usdt), 4e6);
        assertEq(core.cashBalance(carol, address(usdt)), 0);
        assertEq(core.totalRecapitalized(address(usdt)), 4e6);
        vm.startPrank(carol);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.recapitalize(address(usdt), 0);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownAsset.selector, address(8)));
        core.recapitalize(address(8), 1);
        vm.stopPrank();
    }

    function _ethUsdtConfig() internal returns (bytes32 cfg) {
        MockAggregator ethUsdt = new MockAggregator(8);
        ethUsdt.pushRound(3000e8, block.timestamp);
        cfg = _registerDirect(ETH, address(usdt), address(ethUsdt), 8, address(0), 0);
        vm.prank(gov);
        config.setExposureLimit(ExposureScope.ORACLE_CONFIG, cfg, BIG_LIMIT);
    }
}
