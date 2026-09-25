// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SeriesStatus} from "../../src/libraries/OptaraTypes.sol";

/// @notice Finalization, redemption, account-group sync, asynchronous ordering, supply identities, vault
///         identity and oracle-stall recovery (TEST_CASES.md Parts XVI-XXI, REC-*, FIX-019).
contract SettlementTest is OptaraTestBase {
    bytes32 k10; // call K10 C5
    bytes32 k12; // call K12 C3
    bytes32 p10; // put K10 C4
    bytes32 grp;
    IOptionToken t10;
    IOptionToken t12;
    IOptionToken tp;

    function setUp() public override {
        super.setUp();
        k10 = _monCall(10 * WAD, 5 * WAD);
        k12 = _monCall(12 * WAD, 3 * WAD);
        p10 = _monPut(10 * WAD, 4 * WAD);
        grp = _groupOf(k10);
        t10 = _token(k10);
        t12 = _token(k12);
        tp = _token(p10);
    }

    function _writeTo(address writer, bytes32 id, uint256 qty, address holder, uint256 cash) internal {
        _deposit(writer, usdt, cash);
        vm.prank(writer);
        core.write(id, qty, holder);
    }

    // ------------------------------------------------------------------ FIN
    function test_FIN_001_beforeExpiryReverts() public {
        bytes memory data = _data(0, _proof1(1, 0), _empty());
        vm.expectRevert(
            abi.encodeWithSelector(IOptaraCoreErrors.FinalizationTooEarly.selector, uint256(expiry1) + MIN_FINAL_DELAY)
        );
        core.finalizeRiskGroup(grp, data);
    }

    function test_FIN_002_003_finalityDelay() public {
        bytes memory data = _directProofData(monUsdtFeed, 12e8, expiry1);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IOptaraCoreErrors.FinalizationTooEarly.selector, uint256(expiry1) + MIN_FINAL_DELAY)
        );
        core.finalizeRiskGroup(grp, data);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY); // FIN-003 earliest valid
        core.finalizeRiskGroup(grp, data);
        assertTrue(core.getGroup(grp).finalized);
    }

    function test_FIN_004_invalidOracleDataReverts() public {
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY);
        vm.expectRevert();
        core.finalizeRiskGroup(grp, hex"1234");
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkSettlementAdapter.RoundUnavailable.selector, address(monUsdtFeed), uint80(99)
            )
        );
        core.finalizeRiskGroup(grp, _data(0, _proof1(99, 0), _empty()));
        assertFalse(core.getGroup(grp).finalized);
    }

    function test_FIN_005_006_storedPriceAndTime() public {
        bytes memory data = _directProofData(monUsdtFeed, 13.25e8, expiry1);
        vm.warp(uint256(expiry1) + 1 hours);
        vm.expectEmit(true, true, true, true, address(core));
        emit IOptaraCoreEvents.RiskGroupFinalized(
            grp, monUsdtConfig, address(usdt), 13.25e18, expiry1 - 10, keeper, 0, keccak256(data)
        );
        vm.prank(keeper);
        core.finalizeRiskGroup(grp, data);
        Group memory g = core.getGroup(grp);
        assertEq(g.settlementPriceWad, 13.25e18);
        assertEq(g.finalizedAt, uint64(block.timestamp));
        assertEq(g.observationTimestamp, expiry1 - 10);
        assertEq(uint8(core.seriesStatus(k10)), uint8(SeriesStatus.SETTLED));
    }

    /// FIN-007/008 / ACL-011 / INV-007: a second finalization cannot change S, whoever calls with whatever data.
    function test_FIN_007_008_noRefinalization() public {
        _finalizeMon(k10, 12 * WAD);
        vm.warp(block.timestamp + 1 days);
        uint80 r = monUsdtFeed.pushRound(99e8, block.timestamp);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.finalizeRiskGroup(grp, _data(0, _proof1(r, 0), _empty()));
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.finalizeRiskGroup(grp, _data(0, _proof1(r, 0), _empty()));
        assertEq(core.getGroup(grp).settlementPriceWad, 12 * WAD);
    }

    /// FIN-008: two keepers submitting the same valid data: first wins, economics identical.
    function test_FIN_008_differentCallerSameResult() public {
        bytes memory data = _directProofData(monUsdtFeed, 12e8, expiry1);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY);
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 p1 = core.finalizeRiskGroup(grp, data);
        vm.revertToState(snap);
        vm.prank(attacker);
        uint256 p2 = core.finalizeRiskGroup(grp, data);
        assertEq(p1, p2);
    }

    function test_FIN_009_allSeriesShareS() public {
        _finalizeMon(k10, 13 * WAD);
        assertEq(core.seriesPayoffPerUnderlying(k10), 3 * WAD);
        assertEq(core.seriesPayoffPerUnderlying(k12), 1 * WAD);
        assertEq(core.seriesPayoffPerUnderlying(p10), 0);
    }

    /// FIN-012: governance has no path to set an ad hoc price; finalization pause stops finalization only.
    function test_FIN_012_governanceCannotSetPrice() public {
        vm.prank(pauser);
        config.pause(monUsdtConfig, Actions.FINALIZE);
        bytes memory data = _directProofData(monUsdtFeed, 12e8, expiry1);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.FINALIZE));
        core.finalizeRiskGroup(grp, data);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownGroup.selector, bytes32(0)));
        core.finalizeRiskGroup(bytes32(0), data);
    }

    // ------------------------------------------------------------------ RED
    function _settleAt(uint256 price) internal {
        _finalizeMon(k10, price);
    }

    function test_RED_001_itmCallRedeem() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 3e6);
        assertEq(usdt.balanceOf(bob), 3e6);
    }

    function test_RED_002_cappedCallRedeem() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(100 * WAD); // USER_FLOWS.md section 23
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 5e6);
    }

    function test_RED_003_otmCallZeroPayoutBurn() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(8 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 0);
        assertEq(t10.totalSupply(), 0);
    }

    function test_RED_004_itmPutRedeem() public {
        _writeTo(alice, p10, 3 * WAD, bob, 12e6);
        _settleAt(7 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(p10, WAD, bob), 3e6);
    }

    function test_RED_005_cappedPut() public {
        _writeTo(alice, p10, WAD, bob, 4e6);
        _settleAt(1 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(p10, WAD, bob), 4e6);
    }

    function test_RED_006_otmPut() public {
        _writeTo(alice, p10, WAD, bob, 4e6);
        _settleAt(12 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(p10, WAD, bob), 0);
        assertEq(tp.balanceOf(bob), 0);
    }

    function test_RED_007_beforeFinalizationReverts() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        vm.warp(expiry1 + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupNotFinalized.selector, grp));
        core.redeem(k10, WAD, bob);
    }

    function test_RED_008_009_balanceAndAuthorization() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, WAD, 2 * WAD));
        core.redeem(k10, 2 * WAD, bob);
        // a third party cannot redeem bob's tokens (burn is always from msg.sender)
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, attacker, 0, WAD));
        core.redeem(k10, WAD, attacker);
        vm.startPrank(bob);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.redeem(k10, 0, bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRecipient.selector, address(0)));
        core.redeem(k10, WAD, address(0));
        vm.stopPrank();
    }

    function test_RED_010_011_012_burnPayRoundDown() public {
        // 1/3 option at S = 13: exact 1e6 USDT, floor = 999_999.. let us compute: 3 * 1/3 = 1 USDT exactly minus dust
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        uint256 q = WAD / 3;
        vm.expectEmit(true, true, true, true, address(core));
        emit IOptaraCoreEvents.LongRedeemed(bob, carol, k10, q, address(usdt), 999_999, 999_999);
        vm.prank(bob);
        uint256 paid = core.redeem(k10, q, carol);
        assertEq(paid, 999_999); // floor(3e18 * 1e18 * 333..3e17 / 1e48)
        assertEq(core.roundingResidualN(address(usdt)), 3 * WAD * WAD * q - 999_999 * 1e48);
        assertEq(t10.balanceOf(bob), WAD - q); // RED-010
        assertEq(usdt.balanceOf(carol), 999_999); // RED-011
        (uint256 payout, uint256 preview) = core.previewRedeem(k10, q);
        assertEq(payout, 999_999);
        assertEq(preview, 999_999);
    }

    function test_RED_013_doubleRedemptionImpossible() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, WAD));
        core.redeem(k10, WAD, bob);
    }

    function test_RED_014_015_transferAfterSettlement() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        vm.prank(bob);
        t10.transfer(dave, WAD);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, WAD));
        core.redeem(k10, WAD, bob); // RED-015
        vm.prank(dave);
        assertEq(core.redeem(k10, WAD, dave), 3e6); // RED-014
    }

    /// RED-016: a balance held inside a venue's own accounting is not redeemable from Optara.
    function test_RED_016_venueBalanceNotSyntheticallyRedeemable() public {
        address kuru = makeAddr("kuruMarginAccount");
        _writeTo(alice, k10, WAD, kuru, 5e6);
        _settleAt(13 * WAD);
        vm.prank(bob); // bob "owns" it inside Kuru but holds no ERC-20
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, WAD));
        core.redeem(k10, WAD, bob);
        vm.prank(kuru); // after actual withdrawal, the real holder redeems
        core.redeem(k10, WAD, bob);
        assertEq(usdt.balanceOf(bob), 3e6);
    }

    function test_redeemPaused() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.REDEEM);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.REDEEM));
        core.redeem(k10, WAD, bob);
    }

    // ------------------------------------------------------------------ SYN
    function test_SYN_001_shortOnlyGroup() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(14 * WAD);
        vm.expectEmit(true, true, true, true, address(core));
        emit IOptaraCoreEvents.RiskGroupSynced(alice, grp, address(usdt), 4 * WAD * WAD * WAD, 0, -4e6, keeper);
        vm.prank(keeper);
        assertTrue(core.syncRiskGroup(alice, grp));
        assertEq(core.cashBalance(alice, address(usdt)), 1e6);
        assertEq(core.accountGroups(alice).length, 0);
    }

    function test_SYN_002_lockedLongOnlyGroup() public {
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD);
        _settleAt(20 * WAD);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 3e6); // credited, not transferred
        assertEq(t12.balanceOf(address(core)), 0);
        assertEq(core.getSeriesState(k12).hedgeConsumed, WAD);
    }

    /// SYN-003/004 and MATH.md section 72: cash 2, short 5, locked long 3 -> cash 0, no false insolvency.
    function test_SYN_003_004_atomicNet() public {
        _writeTo(carol, k12, WAD, alice, 3e6);
        _deposit(alice, usdt, 2e6);
        _lock(alice, k12, WAD);
        _write(alice, k10, WAD);
        _settleAt(20 * WAD);
        (int256 delta, uint256 s, uint256 l) = core.previewSync(alice, grp);
        assertEq(delta, -2e6);
        assertEq(s, 5 * WAD * WAD * WAD);
        assertEq(l, 3 * WAD * WAD * WAD);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 0);
    }

    function test_SYN_005_positiveDeltaRoundsDown() public {
        // locked 1/3 of K12 C3 at S=20: exact 1 USDT - dust -> floor
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD / 3);
        _settleAt(20 * WAD);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 999_999);
        // exact credit 2 * 1/3 * ... = 3e54/3 - dust; residual = exact - floor * D_A
        (uint256 d) = 1e48;
        uint256 exact = 3 * WAD * WAD * (WAD / 3);
        assertEq(core.roundingResidualN(address(usdt)), exact - 999_999 * d);
    }

    function test_SYN_006_negativeDeltaRoundsUp() public {
        _deposit(alice, usdt, 5e6);
        vm.prank(alice);
        core.write(k10, WAD / 3, alice); // margin ceil(5/3) = 1_666_667
        assertEq(core.requiredMargin(alice, address(usdt)), 1_666_667);
        _settleAt(13 * WAD);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 5e6 - 1_000_000); // debit ceil(0.999..) = 1_000_000
        assertEq(core.roundingResidualN(address(usdt)), 1_000_000 * 1e48 - 3 * WAD * WAD * (WAD / 3));
    }

    function test_SYN_007_beforeFinalizationReverts() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupNotFinalized.selector, grp));
        core.syncRiskGroup(alice, grp);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownGroup.selector, bytes32(uint256(7))));
        core.syncRiskGroup(alice, bytes32(uint256(7)));
    }

    /// SYN-008/009/010/011/012: the complete group is enumerated from the canonical index; locked longs consumed,
    /// shorts cleared, indexes updated. There is no caller-supplied list to alter.
    function test_SYN_008_to_012_completeGroup() public {
        _writeTo(carol, k12, 2 * WAD, alice, 6e6);
        _deposit(alice, usdt, 20e6);
        _lock(alice, k12, 2 * WAD);
        _write(alice, k10, WAD);
        _write(alice, p10, WAD);
        assertEq(core.accountGroupSeries(alice, grp).length, 3);
        _settleAt(13 * WAD); // k10 short 3, k12 long 2*1 = 2, put 0
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 20e6 - 1e6);
        assertEq(core.positionOf(alice, k12).lockedQty, 0);
        assertEq(core.positionOf(alice, k10).shortQty, 0);
        assertEq(core.positionOf(alice, p10).shortQty, 0);
        assertEq(core.accountGroupSeries(alice, grp).length, 0);
        assertEq(core.accountSeriesCount(alice), 0);
        assertEq(t12.balanceOf(address(core)), 0);
    }

    function test_SYN_013_secondSyncNoEffect() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(14 * WAD);
        core.syncRiskGroup(alice, grp);
        uint256 cash = core.cashBalance(alice, address(usdt));
        assertFalse(core.syncRiskGroup(alice, grp));
        assertEq(core.cashBalance(alice, address(usdt)), cash);
        assertEq(core.syncAccount(alice, address(usdt)), 0);
    }

    /// SYN-014 / AC-INV-08: a permissionless caller cannot redirect value.
    function test_SYN_014_permissionlessCannotRedirect() public {
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD);
        _settleAt(20 * WAD);
        vm.prank(attacker);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 3e6);
        assertEq(core.cashBalance(attacker, address(usdt)), 0);
        assertEq(usdt.balanceOf(attacker), 0);
    }

    function test_syncPausedAndSyncAccount() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(14 * WAD);
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.SYNC);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.SYNC));
        core.syncRiskGroup(alice, grp);
        // withdraw needs sync, so it also stops while settlement is paused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.SYNC));
        core.withdraw(address(usdt), 1, alice);
        vm.prank(gov);
        config.unpause(bytes32(0), Actions.SYNC);
        assertEq(core.syncAccount(alice, address(usdt)), 1);
    }

    /// INV-LIQ-10 / LIQUIDATION.md section 45: a debit above cash reverts atomically (corrupted harness state).
    function test_negativeSettlementReverts() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(15 * WAD);
        // corrupt: move alice's cash away via storage manipulation of the ledger (test-only)
        bytes32 slot = _cashSlot(alice, address(usdt));
        vm.store(address(core), slot, bytes32(uint256(1e6)));
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SettlementDeficit.selector, alice, grp, 1e6, 5e6));
        core.syncRiskGroup(alice, grp);
        assertEq(core.positionOf(alice, k10).shortQty, WAD);
    }

    // ------------------------------------------------------------------ ASY / VLT
    /// Two writers, one hedged, several holders. Every permutation of redemptions and syncs leaves the vault
    /// holding exactly the rounding residuals and surplus, never a deficit (ASY-001..005, VLT-003/004/008).
    function test_ASY_permutationsConserve() public {
        for (uint256 perm = 0; perm < 6; ++perm) {
            uint256 snap = vm.snapshotState();
            _asyScenario(perm);
            vm.revertToState(snap);
        }
    }

    function _asyScenario(uint256 perm) internal {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _writeTo(carol, k10, WAD / 3, dave, 2e6);
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD);
        _settleAt(14 * WAD); // k10 pays 4, k12 pays 2
        uint8[4][6] memory orders = [[0, 1, 2, 3], [3, 2, 1, 0], [1, 3, 0, 2], [2, 0, 3, 1], [0, 2, 1, 3], [3, 0, 2, 1]];
        for (uint256 i = 0; i < 4; ++i) {
            uint8 step = orders[perm][i];
            if (step == 0) {
                vm.prank(bob);
                core.redeem(k10, WAD, bob);
            } else if (step == 1) {
                vm.prank(dave);
                core.redeem(k10, WAD / 3, dave);
            } else if (step == 2) {
                core.syncRiskGroup(alice, grp);
            } else {
                core.syncRiskGroup(carol, grp);
            }
        }
        // alice: short 4, long 2 -> debit 2 from 5 -> 3; carol: short 4/3 (ceil 1_333_334) + k12 short 2 -> 5_000_000 - 3_333_334
        assertEq(core.cashBalance(alice, address(usdt)), 3e6);
        assertEq(core.cashBalance(carol, address(usdt)), 5e6 - 3_333_334);
        assertEq(usdt.balanceOf(bob), 4e6);
        assertEq(usdt.balanceOf(dave), 1_333_333);
        uint256 vault = usdt.balanceOf(address(core));
        uint256 claims = core.totalCash(address(usdt));
        assertEq(vault - claims, 1); // rounding reserve: 1_333_334 debited vs 1_333_333 paid
        SeriesState memory st = core.getSeriesState(k10);
        assertEq(st.minted, WAD + WAD / 3);
        assertEq(st.redeemed + st.hedgeConsumed + t10.totalSupply() + st.closed, st.minted); // SUP-008
        assertEq(st.shortSynced + st.openShortQty + st.closed, st.minted); // SUP-009
        assertEq(t10.totalSupply(), 0); // SUP-010 terminal
        assertEq(st.openShortQty, 0);
    }

    /// ASY-006/007/008: effective claims before sync; writer cannot withdraw around debt.
    function test_ASY_006_007_008_effectiveBeforeSync() public {
        _writeTo(alice, k10, WAD, bob, 6e6);
        _settleAt(15 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        assertEq(core.effectiveCash(alice, address(usdt)), 1e6);
        assertTrue(core.accountRiskState(alice, address(usdt)).hasUnsyncedMaturedGroups);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientCash.selector, 2e6, 1e6));
        core.withdraw(address(usdt), 2e6, alice);
        assertEq(usdt.balanceOf(address(core)), 1e6);
    }

    /// FIX-019 / INV-VAULT-08: a fractional claim with zero native payout still burns; the value becomes residual.
    function test_FIX_019_zeroPayoutFractionalBurn() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settleAt(13 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(k10, 1e11, bob), 0); // 3 * 1e-7 option = 3e-7 USDT < 1 unit
        assertEq(t10.balanceOf(bob), WAD - 1e11);
        core.syncRiskGroup(alice, grp);
        vm.prank(bob);
        uint256 rest = core.redeem(k10, WAD - 1e11, bob);
        assertEq(rest, 2_999_999);
        assertEq(usdt.balanceOf(address(core)) - core.totalCash(address(usdt)), 1);
    }

    function test_VLT_001_002_depositWithdrawIdentity() public {
        _deposit(alice, usdt, 9e6);
        _deposit(bob, usdt, 1e6);
        assertEq(usdt.balanceOf(address(core)), core.totalCash(address(usdt)));
        vm.prank(bob);
        core.withdraw(address(usdt), 1e6, bob);
        assertEq(usdt.balanceOf(address(core)), core.totalCash(address(usdt)));
    }

    function test_VLT_005_006_007_feeFreeAndIsolation() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _deposit(alice, usdc, 7e6);
        _settleAt(13 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        core.syncRiskGroup(alice, grp);
        assertEq(usdc.balanceOf(address(core)), 7e6); // USDC untouched by USDT settlement
        assertEq(core.cashBalance(alice, address(usdc)), 7e6);
        assertGe(usdt.balanceOf(address(core)), core.totalCash(address(usdt))); // reserve >= 0
        assertEq(usdt.balanceOf(address(core)), core.totalCash(address(usdt))); // no protocol-owned balance (fee-free)
    }

    // ------------------------------------------------------------------ SUP
    function test_SUP_001_002_005_006_007_supply() public {
        _writeTo(alice, k10, 3 * WAD, alice, 15e6);
        SeriesState memory st = core.getSeriesState(k10);
        assertEq(st.minted, 3 * WAD);
        assertEq(t10.totalSupply(), st.openShortQty); // SUP-002
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL); // SUP-005
        st = core.getSeriesState(k10);
        assertEq(t10.totalSupply(), 2 * WAD);
        assertEq(st.openShortQty, 2 * WAD);
        _lock(alice, k10, WAD);
        assertEq(t10.totalSupply(), 2 * WAD); // SUP-003
        vm.prank(alice);
        t10.transfer(bob, WAD);
        assertEq(t10.totalSupply(), 2 * WAD); // SUP-004
        _settleAt(12 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob); // SUP-006: supply only
        st = core.getSeriesState(k10);
        assertEq(t10.totalSupply(), WAD);
        assertEq(st.openShortQty, 2 * WAD);
        core.syncRiskGroup(alice, grp); // SUP-007: internal settlement burns locked
        st = core.getSeriesState(k10);
        assertEq(t10.totalSupply(), 0);
        assertEq(st.hedgeConsumed, WAD);
        assertEq(st.shortSynced, 2 * WAD);
    }

    // ------------------------------------------------------------------ REC (oracle-stall recovery)
    /// REC-001: an expired-unfinalized group stays reserved; unrelated free cash withdraws; encumbered cash does not.
    function test_REC_001_reservedWhileUnfinalized() public {
        _writeTo(alice, k10, WAD, bob, 8e6);
        vm.warp(uint256(expiry1) + 30 days);
        assertTrue(core.isOracleStalled(grp));
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 3e6, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 5e6 - 1));
        core.withdraw(address(usdt), 1, alice);
    }

    /// REC-002: owner cancellation burns long and short, updates C and caps, pays no option cash.
    function test_REC_002_cancelUnfinalized() public {
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        _writeTo(alice, k10, WAD, alice, 5e6);
        vm.warp(expiry1 + 1);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.ShortCancelledUnfinalized(alice, k10, WAD, CloseSource.EXTERNAL);
        vm.prank(alice);
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(t10.totalSupply(), 0);
        assertEq(core.getSeriesState(k10).closed, WAD);
        (uint256 pairN,,) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN, 0);
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
        vm.prank(alice);
        core.withdraw(address(usdt), 5e6, alice);
    }

    /// REC-003: wrong series/owner/quantity and finalized cancellation revert atomically.
    function test_REC_003_cancelRejections() public {
        _writeTo(alice, k10, WAD, alice, 5e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotExpired.selector, k10));
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
        vm.warp(expiry1 + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientShort.selector, WAD, 0));
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientShort.selector, 2 * WAD, WAD));
        core.cancelUnfinalizedShort(k10, 2 * WAD, CloseSource.EXTERNAL);
        vm.prank(alice); // wrong series: alice has no k12 short
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientShort.selector, WAD, 0));
        core.cancelUnfinalizedShort(k12, WAD, CloseSource.EXTERNAL);
        _settleAt(12 * WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
    }

    /// REC-004: cancel/finalize race follows transaction ordering without double consumption.
    function test_REC_004_cancelFinalizeRace() public {
        _writeTo(alice, k10, WAD, alice, 5e6);
        bytes memory data = _directProofData(monUsdtFeed, 13e8, expiry1);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY);
        uint256 snap = vm.snapshotState();
        // order A: cancel first, then finalize
        vm.prank(alice);
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
        core.finalizeRiskGroup(grp, data);
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
        assertFalse(core.syncRiskGroup(alice, grp));
        vm.revertToState(snap);
        // order B: finalize first, then cancel reverts; settle normally
        core.finalizeRiskGroup(grp, data);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
        vm.prank(alice);
        core.redeem(k10, WAD, alice);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 2e6);
        assertEq(usdt.balanceOf(alice), 3e6);
    }

    /// REC-005: safe unfinalized unlock succeeds; unsafe fails.
    function test_REC_005_unfinalizedUnlock() public {
        _writeTo(carol, k12, WAD, alice, 3e6);
        _deposit(alice, usdt, 2e6);
        _lock(alice, k12, WAD);
        _write(alice, k10, WAD);
        vm.warp(expiry1 + 1 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 2e6));
        core.unlockLong(k12, WAD, alice);
        _deposit(alice, usdt, 3e6);
        vm.prank(alice);
        core.unlockLong(k12, WAD, alice);
        assertEq(t12.balanceOf(alice), WAD);
    }

    /// REC-006: escalation deadline flags stalled without changing claims; a late authentic observation finalizes.
    function test_REC_006_stalledThenLateFinalization() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        vm.warp(expiry1 - 10);
        uint80 r = monUsdtFeed.pushRound(14e8, block.timestamp);
        vm.warp(uint256(expiry1) + MAX_FINAL_DELAY - 1);
        assertFalse(core.isOracleStalled(grp));
        vm.warp(uint256(expiry1) + MAX_FINAL_DELAY);
        assertTrue(core.isOracleStalled(grp));
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        core.finalizeRiskGroup(grp, _data(0, _proof1(r, 0), _empty())); // latest-round proof, no successor
        assertFalse(core.isOracleStalled(grp));
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 4e6);
    }

    /// REC-007: with all sources unavailable no price is invented and nothing is released.
    function test_REC_007_permanentFailureNoInventedPrice() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        monUsdtFeed.setBroken(true);
        monUsdtBackupFeed.setBroken(true);
        vm.warp(uint256(expiry1) + 60 days);
        vm.expectRevert();
        core.finalizeRiskGroup(grp, _data(0, _proof1(1, 0), _empty()));
        vm.expectRevert();
        core.finalizeRiskGroup(grp, _data(1, _proof1(1, 0), _proof1(1, 0)));
        assertFalse(core.getGroup(grp).finalized);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        assertEq(uint8(core.seriesStatus(k10)), uint8(SeriesStatus.EXPIRED_UNSETTLED));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupNotFinalized.selector, grp));
        core.redeem(k10, WAD, bob);
    }

    /// REC-008: LOCKED-source cancellation consumes the own identical hedge only when named.
    function test_REC_008_lockedSourceCancellation() public {
        _writeTo(alice, k10, 2 * WAD, alice, 10e6);
        _lock(alice, k10, WAD);
        vm.warp(expiry1 + 1);
        vm.prank(alice);
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(core.positionOf(alice, k10).lockedQty, WAD); // EXTERNAL never touches locked
        vm.prank(alice);
        core.cancelUnfinalizedShort(k10, WAD, CloseSource.LOCKED);
        Position memory p = core.positionOf(alice, k10);
        assertEq(p.lockedQty, 0);
        assertEq(p.shortQty, 0);
        assertEq(t10.totalSupply(), 0);
        assertEq(core.accountGroups(alice).length, 0);
    }

    // ------------------------------------------------------------------ helpers
    /// Storage slot of _cash[account][asset] (slot 6 per `forge inspect OptaraCore storageLayout`; OZ v5
    /// ReentrancyGuard uses namespaced storage and takes no sequential slot).
    function _cashSlot(address account, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(asset, keccak256(abi.encode(account, uint256(6)))));
    }
}
