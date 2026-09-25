// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReentrantERC20, FeeOnTransferERC20} from "../mocks/HostileTokens.sol";
import {OptionToken} from "../../src/token/OptionToken.sol";
import {ChainlinkSettlementAdapter} from "../../src/oracle/ChainlinkSettlementAdapter.sol";

/// @notice Dedicated tests for TEST_CASES.md IDs that previously had only indirect coverage: exact write/supply
///         deltas (WRT, TOK, SUP), asynchronous ordering (ASY), vault identities (VLT), hostile tokens (WDW-008,
///         DEP-009, STB-008), fees (FEE-001/003), internal authority (ACL-018), the INV-0xx properties as focused
///         scenarios, the policy rule (POL-001) and complete-group synchronization (SYN-015).
contract ConformanceTest is OptaraTestBase {
    bytes32 k10; // MON/USDT call K=10 C=5 CS=1
    bytes32 k12; // MON/USDT call K=12 C=3 CS=1 (same group)
    bytes32 p10; // MON/USDT put  K=10 C=4 CS=1 (same group)
    bytes32 grp;
    IOptionToken t10;
    IOptionToken t12;
    uint256 constant D6 = 1e48; // D_A for a 6-decimal asset

    function setUp() public override {
        super.setUp();
        k10 = _monCall(10 * WAD, 5 * WAD);
        k12 = _monCall(12 * WAD, 3 * WAD);
        p10 = _monPut(10 * WAD, 4 * WAD);
        grp = _groupOf(k10);
        t10 = _token(k10);
        t12 = _token(k12);
    }

    function _writeTo(address writer, bytes32 id, uint256 qty, address to, uint256 depositAmount) internal {
        if (depositAmount > 0) _deposit(writer, usdt, depositAmount);
        vm.prank(writer);
        core.write(id, qty, to);
    }

    function _settle(uint256 priceWad) internal {
        _finalizeMon(k10, priceWad);
    }

    // =============================================================================================
    // WRT-012/013/014: exact write deltas on top of existing state
    // =============================================================================================

    function test_WRT_012_shortQuantityIncreasesExactly() public {
        _writeTo(alice, k10, WAD, alice, 20e6);
        _writeTo(alice, k12, WAD, alice, 0);
        uint256 shortBefore = core.positionOf(alice, k10).shortQty;
        uint256 openBefore = core.getSeriesState(k10).openShortQty;
        uint256 otherBefore = core.positionOf(alice, k12).shortQty;
        vm.prank(alice);
        core.write(k10, 7e17, bob);
        assertEq(core.positionOf(alice, k10).shortQty, shortBefore + 7e17);
        assertEq(core.getSeriesState(k10).openShortQty, openBefore + 7e17);
        assertEq(core.positionOf(alice, k12).shortQty, otherBefore, "other series untouched");
        assertEq(core.positionOf(bob, k10).shortQty, 0, "recipient receives no short");
        assertEq(core.positionOf(alice, k10).lockedQty, 0);
    }

    function test_WRT_013_longSupplyIncreasesExactly(uint256 qty) public {
        qty = bound(qty, 1, 3e18);
        _writeTo(carol, k10, WAD, carol, 20e6);
        uint256 supplyBefore = t10.totalSupply();
        uint256 mintedBefore = core.getSeriesState(k10).minted;
        uint256 otherSupply = t12.totalSupply();
        vm.prank(carol);
        core.write(k10, qty, bob);
        assertEq(t10.totalSupply(), supplyBefore + qty);
        assertEq(core.getSeriesState(k10).minted, mintedBefore + qty);
        assertEq(t12.totalSupply(), otherSupply);
        assertEq(t10.totalSupply(), core.getSeriesState(k10).openShortQty, "L == O before finalization");
    }

    function test_WRT_014_mintRecipientReceivesExactQuantity(uint256 qty) public {
        qty = bound(qty, 1, 3e18);
        _deposit(alice, usdt, 20e6);
        uint256 writerBefore = t10.balanceOf(alice);
        uint256 custodyBefore = t10.balanceOf(address(core));
        vm.prank(alice);
        core.write(k10, qty, bob);
        assertEq(t10.balanceOf(bob), qty);
        assertEq(t10.balanceOf(alice), writerBefore, "writer receives nothing when recipient differs");
        assertEq(t10.balanceOf(address(core)), custodyBefore, "no custody credit from a write");
    }

    // =============================================================================================
    // TOK-010..013: supply changes exactly on each path
    // =============================================================================================

    function test_TOK_010_supplyExactOnWrite(uint256 q1, uint256 q2) public {
        q1 = bound(q1, 1, 2e18);
        q2 = bound(q2, 1, 2e18);
        _deposit(alice, usdt, 30e6);
        vm.startPrank(alice);
        core.write(k10, q1, alice);
        assertEq(t10.totalSupply(), q1);
        core.write(k10, q2, bob);
        vm.stopPrank();
        assertEq(t10.totalSupply(), q1 + q2);
    }

    function test_TOK_011_supplyExactOnClose() public {
        _writeTo(alice, k10, 2 * WAD, alice, 10e6);
        vm.prank(alice);
        core.closeShort(k10, 6e17, CloseSource.EXTERNAL);
        assertEq(t10.totalSupply(), 2 * WAD - 6e17);
        _lock(alice, k10, 4e17);
        assertEq(t10.totalSupply(), 2 * WAD - 6e17, "lock does not burn");
        vm.prank(alice);
        core.closeShort(k10, 4e17, CloseSource.LOCKED);
        assertEq(t10.totalSupply(), WAD);
        assertEq(t10.balanceOf(address(core)), 0, "locked close burns from custody");
        assertEq(core.getSeriesState(k10).closed, WAD);
    }

    function test_TOK_012_supplyExactOnRedemption() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settle(13 * WAD);
        vm.prank(bob);
        core.redeem(k10, 3e17, bob);
        assertEq(t10.totalSupply(), 7e17);
        assertEq(core.getSeriesState(k10).redeemed, 3e17);
        vm.prank(bob);
        core.redeem(k10, 7e17, bob);
        assertEq(t10.totalSupply(), 0);
    }

    function test_TOK_013_supplyExactOnInternalHedgeSettlement() public {
        _writeTo(alice, k10, WAD, alice, 5e6); // alice keeps her k10 long in the wallet
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD);
        _settle(14 * WAD);
        uint256 s10 = t10.totalSupply();
        uint256 s12 = t12.totalSupply();
        core.syncRiskGroup(alice, grp);
        assertEq(t12.totalSupply(), s12 - WAD, "locked hedge consumed exactly");
        assertEq(t10.totalSupply(), s10, "wallet longs are not touched by sync");
        assertEq(core.getSeriesState(k12).hedgeConsumed, WAD);
        assertEq(t12.balanceOf(address(core)), 0);
    }

    // =============================================================================================
    // SUP-003/004/008/009/010: supply identities
    // =============================================================================================

    function test_SUP_003_lockDoesNotChangeSupply() public {
        _writeTo(alice, k10, 2 * WAD, alice, 10e6);
        uint256 supply = t10.totalSupply();
        _lock(alice, k10, WAD);
        assertEq(t10.totalSupply(), supply);
        vm.prank(alice);
        core.unlockLong(k10, 5e17, alice);
        assertEq(t10.totalSupply(), supply);
        assertEq(t10.totalSupply(), core.getSeriesState(k10).openShortQty);
    }

    function test_SUP_004_transferDoesNotChangeSupply(uint256 qty) public {
        _writeTo(alice, k10, 2 * WAD, alice, 10e6);
        qty = bound(qty, 1, 2 * WAD);
        uint256 supply = t10.totalSupply();
        vm.prank(alice);
        t10.transfer(bob, qty);
        assertEq(t10.totalSupply(), supply);
        vm.prank(bob);
        t10.transfer(address(core), qty); // a raw transfer into custody is a donation, not a lock
        assertEq(t10.totalSupply(), supply);
        assertEq(core.positionOf(bob, k10).lockedQty, 0);
    }

    function _assertLongIdentity(bytes32 id) internal view {
        SeriesState memory st = core.getSeriesState(id);
        assertEq(st.closed + st.redeemed + st.hedgeConsumed + _token(id).totalSupply(), st.minted, "M = C + R + H + L");
    }

    function _assertShortIdentity(bytes32 id) internal view {
        SeriesState memory st = core.getSeriesState(id);
        assertEq(st.closed + st.shortSynced + st.openShortQty, st.minted, "M = C + S + O");
    }

    /// Scenario used by SUP-008/009/010: close, post-expiry cancellation, lock, redemption and sync all happen.
    function _supScenario() internal {
        _writeTo(alice, k10, 3 * WAD, alice, 15e6);
        vm.prank(alice);
        t10.transfer(bob, 2 * WAD);
        _lock(alice, k10, WAD);
        vm.prank(bob);
        t10.transfer(alice, 5e17);
        vm.prank(alice);
        core.closeShort(k10, 5e17, CloseSource.EXTERNAL); // C = 0.5
        vm.warp(expiry1 + 1);
        vm.prank(alice);
        core.cancelUnfinalizedShort(k10, 5e17, CloseSource.LOCKED); // C = 1.0, locked left 0.5
    }

    function test_SUP_008_postExpiryCumulativeLongIdentity() public {
        _supScenario();
        _assertLongIdentity(k10);
        _settle(13 * WAD);
        _assertLongIdentity(k10);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        _assertLongIdentity(k10);
        core.syncRiskGroup(alice, grp);
        _assertLongIdentity(k10);
        assertEq(core.getSeriesState(k10).hedgeConsumed, 5e17);
        vm.prank(bob);
        core.redeem(k10, 5e17, bob);
        _assertLongIdentity(k10);
    }

    function test_SUP_009_postExpiryCumulativeShortIdentity() public {
        _supScenario();
        _assertShortIdentity(k10);
        _settle(13 * WAD);
        _assertShortIdentity(k10);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        _assertShortIdentity(k10); // redemption never touches the short side
        core.syncRiskGroup(alice, grp);
        _assertShortIdentity(k10);
        assertEq(core.getSeriesState(k10).shortSynced, 2 * WAD); // 3 written - 0.5 closed - 0.5 cancelled
        assertEq(core.getSeriesState(k10).openShortQty, 0);
    }

    function test_SUP_010_fullySettledTerminalIdentity() public {
        _supScenario();
        _settle(13 * WAD);
        vm.prank(bob);
        core.redeem(k10, 15e17, bob);
        core.syncRiskGroup(alice, grp);
        SeriesState memory st = core.getSeriesState(k10);
        assertEq(t10.totalSupply(), 0, "L = 0");
        assertEq(st.openShortQty, 0, "O = 0");
        assertEq(st.minted - st.closed, st.redeemed + st.hedgeConsumed, "M - C = R + H");
        assertEq(st.redeemed + st.hedgeConsumed, st.shortSynced, "R + H = S");
        assertEq(st.exposureN, 0);
    }

    // =============================================================================================
    // ASY-001..004: each settlement ordering reaches the same economic state
    // =============================================================================================

    /// alice writes 1 k10 to bob, carol writes 1 k10 to dave; settle at 14 (payoff 4 per option).
    function _asySetup() internal {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _writeTo(carol, k10, WAD, dave, 5e6);
        _settle(14 * WAD);
    }

    function _asyAssertFinal() internal view {
        assertEq(core.cashBalance(alice, address(usdt)), 1e6);
        assertEq(core.cashBalance(carol, address(usdt)), 1e6);
        assertEq(usdt.balanceOf(bob), 4e6);
        assertEq(usdt.balanceOf(dave), 4e6);
        assertEq(usdt.balanceOf(address(core)), 2e6);
        assertEq(core.totalCash(address(usdt)), 2e6);
        assertEq(t10.totalSupply(), 0);
        assertEq(core.getSeriesState(k10).openShortQty, 0);
    }

    function test_ASY_001_redeemThenWriterSync() public {
        _asySetup();
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        vm.prank(dave);
        core.redeem(k10, WAD, dave);
        // before sync the writers' effective cash already reflects the debt
        assertEq(core.effectiveCash(alice, address(usdt)), 1e6);
        core.syncRiskGroup(alice, grp);
        core.syncRiskGroup(carol, grp);
        _asyAssertFinal();
    }

    function test_ASY_002_writerSyncThenRedeem() public {
        _asySetup();
        core.syncRiskGroup(alice, grp);
        core.syncRiskGroup(carol, grp);
        assertEq(usdt.balanceOf(address(core)), 10e6, "sync moves no tokens");
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        vm.prank(dave);
        core.redeem(k10, WAD, dave);
        _asyAssertFinal();
    }

    function test_ASY_003_twoRedeemersThenWriterSync() public {
        _writeTo(alice, k10, 2 * WAD, bob, 10e6);
        vm.prank(bob);
        t10.transfer(dave, WAD);
        _settle(14 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        vm.prank(dave);
        core.redeem(k10, WAD, dave);
        assertEq(usdt.balanceOf(bob), 4e6);
        assertEq(usdt.balanceOf(dave), 4e6);
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 2e6);
        assertEq(usdt.balanceOf(address(core)), 2e6);
    }

    function test_ASY_004_writer1SyncRedeemWriter2Sync() public {
        _asySetup();
        core.syncRiskGroup(alice, grp);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        vm.prank(dave);
        core.redeem(k10, WAD, dave);
        core.syncRiskGroup(carol, grp);
        _asyAssertFinal();
    }

    // =============================================================================================
    // VLT-003/004/009: vault identities and no sweep path
    // =============================================================================================

    function test_VLT_003_redemptionIdentity() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settle(13 * WAD);
        uint256 vault = usdt.balanceOf(address(core));
        uint256 cash = core.totalCash(address(usdt));
        uint256 residual = core.roundingResidualN(address(usdt));
        uint256 q = 333_333_333_333_333_333; // 1/3 option: exact claim 0.999999999... USDT
        uint256 n = PayoffMath.payoffNumerator(OptionType.CALL, 10 * WAD, 5 * WAD, WAD, 13 * WAD, q);
        vm.prank(bob);
        uint256 paid = core.redeem(k10, q, bob);
        assertEq(paid, n / D6);
        assertEq(usdt.balanceOf(address(core)), vault - paid, "vault falls by exactly the payout");
        assertEq(core.totalCash(address(usdt)), cash, "no account cash moves");
        assertEq(core.roundingResidualN(address(usdt)), residual + (n - paid * D6), "exact residual");
    }

    function test_VLT_004_writerSyncIdentity() public {
        _writeTo(carol, k10, WAD / 3, bob, 5e6); // short 1/3: debit ceil(1 USDT - 1e-18 ...) exercises rounding
        _settle(13 * WAD);
        uint256 vault = usdt.balanceOf(address(core));
        uint256 cash = core.totalCash(address(usdt));
        uint256 residual = core.roundingResidualN(address(usdt));
        (int256 delta, uint256 shortN, uint256 longN) = core.previewSync(carol, grp);
        assertEq(longN, 0);
        core.syncRiskGroup(carol, grp);
        uint256 debit = uint256(-delta);
        assertEq(debit, FixedPointMath.ceilDiv(shortN, D6));
        assertEq(usdt.balanceOf(address(core)), vault, "sync moves no tokens");
        assertEq(core.totalCash(address(usdt)), cash - debit);
        assertEq(core.roundingResidualN(address(usdt)), residual + (debit * D6 - shortN));
    }

    function test_VLT_009_unauthorizedRescueCannotSweep() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _deposit(dave, usdt, 7e6);
        uint256 vault = usdt.balanceOf(address(core));
        string[8] memory sigs = [
            "sweep(address,address,uint256)",
            "rescueERC20(address,address,uint256)",
            "rescueTokens(address,uint256)",
            "emergencyWithdraw(address,uint256)",
            "withdrawSurplus(address,uint256,address)",
            "transferOut(address,address,uint256)",
            "skim(address,address)",
            "recoverERC20(address,uint256)"
        ];
        address[4] memory callers = [gov, pauser, configAdmin, attacker];
        address[3] memory targets = [address(core), address(config), address(factory)];
        for (uint256 c = 0; c < callers.length; ++c) {
            for (uint256 t = 0; t < targets.length; ++t) {
                for (uint256 s = 0; s < sigs.length; ++s) {
                    vm.prank(callers[c]);
                    (bool ok,) = targets[t].call(abi.encodeWithSignature(sigs[s], address(usdt), callers[c], vault));
                    assertFalse(ok, sigs[s]);
                }
            }
        }
        // governance holds no account cash, so the ordinary withdraw path cannot reach user claims either
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientCash.selector, 1, 0));
        core.withdraw(address(usdt), 1, gov);
        assertEq(usdt.balanceOf(address(core)), vault);
        assertEq(core.cashBalance(dave, address(usdt)), 7e6);
    }

    // =============================================================================================
    // WDW-008 / DEP-009 / STB-008: hostile settlement tokens
    // =============================================================================================

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

    function test_WDW_008_withdrawReentrancyAttemptBlocked() public {
        _setupReentrantAsset();
        vm.prank(alice);
        core.deposit(address(rtk), 20e6);
        // reenter withdraw from inside the withdrawal payout (double-withdraw attempt)
        rtk.arm(address(core), abi.encodeCall(core.withdraw, (address(rtk), 10e6, alice)));
        vm.prank(alice);
        core.withdraw(address(rtk), 10e6, alice);
        _assertReentryBlocked();
        assertEq(core.cashBalance(alice, address(rtk)), 10e6);
        assertEq(rtk.balanceOf(address(core)), 10e6);
        // reenter write from inside the payout: margin was checked before the transfer and cannot be reused
        rtk.arm(address(core), abi.encodeCall(core.write, (rseries, 2 * WAD, alice)));
        vm.prank(alice);
        core.withdraw(address(rtk), 5e6, alice);
        _assertReentryBlocked();
        assertEq(core.positionOf(alice, rseries).shortQty, 0);
        assertEq(core.cashBalance(alice, address(rtk)), 5e6);
        assertEq(rtk.balanceOf(address(core)), 5e6);
    }

    function test_DEP_009_reentrantTokenDepositFailsSafely() public {
        _setupReentrantAsset();
        // reenter deposit from inside the deposit's transferFrom (double-credit attempt)
        rtk.arm(address(core), abi.encodeCall(core.deposit, (address(rtk), 10e6)));
        vm.prank(alice);
        core.deposit(address(rtk), 10e6);
        _assertReentryBlocked();
        assertEq(core.cashBalance(alice, address(rtk)), 10e6, "credited exactly once");
        assertEq(core.totalCash(address(rtk)), 10e6);
        assertEq(rtk.balanceOf(address(core)), 10e6);
        // reenter recapitalize during deposit: blocked as well, no unaccounted surplus
        rtk.arm(address(core), abi.encodeCall(core.recapitalize, (address(rtk), 1e6)));
        vm.prank(alice);
        core.deposit(address(rtk), 1e6);
        _assertReentryBlocked();
        assertEq(core.totalRecapitalized(address(rtk)), 0);
        assertEq(rtk.balanceOf(address(core)), 11e6);
    }

    function test_STB_008_feeOnTransferTokenRejected() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee USD", "fUSD", 6);
        vm.prank(gov);
        config.approveAsset(address(fot), "fUSD", 0, 0);
        fot.mint(alice, 100e6);
        vm.startPrank(alice);
        fot.approve(address(core), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NonExactTransfer.selector, 100e6, 99e6));
        core.deposit(address(fot), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NonExactTransfer.selector, 100e6, 99e6));
        core.recapitalize(address(fot), 100e6);
        vm.stopPrank();
        assertEq(core.cashBalance(alice, address(fot)), 0);
        assertEq(core.totalCash(address(fot)), 0);
        assertEq(core.totalRecapitalized(address(fot)), 0);
        assertEq(fot.balanceOf(address(core)), 0);
    }

    // =============================================================================================
    // FEE-001 / FEE-003: fee-free MVP, oracle fees never reach payouts
    // =============================================================================================

    function test_FEE_001_allMvpOptaraFeesZero() public {
        _deposit(alice, usdt, 5e6);
        vm.prank(alice);
        core.write(k10, WAD, bob);
        assertEq(t10.balanceOf(bob), WAD, "no issuance fee: full quantity minted");
        assertEq(core.cashBalance(alice, address(usdt)), 5e6, "no issuance fee: cash untouched");
        _settle(13 * WAD);
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 3e6, "gross payoff, no settlement fee");
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 2e6, "debit is exactly the payoff");
        vm.prank(alice);
        core.withdraw(address(usdt), 2e6, alice);
        assertEq(usdt.balanceOf(alice), 2e6, "no withdrawal fee");
        assertEq(usdt.balanceOf(address(core)), 0, "no protocol-owned balance accumulates");
        assertEq(core.roundingResidualN(address(usdt)), 0);
    }

    function test_FEE_003_oracleUpdateFeeNotDeductedFromPayout() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        Series memory s = core.getSeries(k10);
        bytes memory data = _directProofData(monUsdtFeed, 13e8, s.expiry);
        vm.warp(uint256(s.expiry) + MIN_FINAL_DELAY);
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        vm.expectRevert(ChainlinkSettlementAdapter.NoFeeRequired.selector);
        core.finalizeRiskGroup{value: 1 wei}(s.groupId, data);
        vm.prank(keeper);
        core.finalizeRiskGroup(s.groupId, data);
        assertEq(keeper.balance, 1 ether, "the finalizer paid nothing");
        vm.prank(bob);
        assertEq(core.redeem(k10, WAD, bob), 3e6, "payout is the full contractual amount");
        assertEq(address(core).balance, 0);
        assertEq(address(adapter).balance, 0);
    }

    // =============================================================================================
    // ACL-018: internal authorities are pinned to the canonical contracts
    // =============================================================================================

    function test_ACL_018_internalRoleOnlyCanonicalContracts() public {
        address[5] memory others = [gov, creator, pauser, address(factory), attacker];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(OptionToken.OnlyCore.selector, others[i]));
            OptionToken(address(t10)).mint(others[i], 1);
            vm.expectRevert(abi.encodeWithSelector(OptionToken.OnlyCore.selector, others[i]));
            OptionToken(address(t10)).burn(bob, 1);
            vm.stopPrank();
        }
        // every series token is bound to this core and to its own series id
        bytes32[3] memory ids = [k10, k12, p10];
        for (uint256 i = 0; i < ids.length; ++i) {
            OptionToken t = OptionToken(address(_token(ids[i])));
            assertEq(t.core(), address(core));
            assertEq(t.seriesId(), ids[i]);
        }
        // only the bound factory registers series; the binding is sealed and cannot be replaced
        Series memory s = core.getSeries(k10);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.OnlySeriesFactory.selector, gov));
        core.registerSeries(keccak256("x"), s);
        vm.expectRevert(IOptaraCoreErrors.AlreadySealed.selector);
        core.bindSeriesFactory(attacker);
        assertEq(core.seriesFactory(), address(factory));
        // canonical contracts hold no configurable role that could be regranted
        bytes32[6] memory roles = [
            config.GOVERNANCE_ROLE(),
            config.CONFIG_ROLE(),
            config.SERIES_CREATOR_ROLE(),
            config.ORACLE_CONFIG_ROLE(),
            config.PAUSER_ROLE(),
            config.UNPAUSER_ROLE()
        ];
        for (uint256 r = 0; r < roles.length; ++r) {
            assertFalse(config.hasRole(roles[r], address(core)));
            assertFalse(config.hasRole(roles[r], address(factory)));
            assertFalse(config.hasRole(roles[r], address(t10)));
        }
    }

    // =============================================================================================
    // INV-005/006/008/011/013/014/017/018/019/020 as focused scenarios
    // =============================================================================================

    function test_INV_005_noDoubleLongConsumption() public {
        _writeTo(alice, k10, WAD, alice, 5e6);
        _writeTo(carol, k12, 2 * WAD, alice, 6e6);
        _lock(alice, k12, WAD);
        // a LOCKED close consumes the hedge unit once: it is not also credited at settlement
        _lock(alice, k10, 5e17);
        vm.prank(alice);
        core.closeShort(k10, 5e17, CloseSource.LOCKED);
        _settle(14 * WAD);
        (,, uint256 longN) = core.previewSync(alice, grp);
        assertEq(longN, 2 * WAD * WAD * WAD, "only the still-locked k12 unit is credited (phi 2 * CS 1 * Q 1)");
        core.syncRiskGroup(alice, grp);
        // the settled hedge can be neither unlocked nor redeemed afterwards
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.unlockLong(k12, 1, alice);
        vm.stopPrank();
        assertEq(t12.balanceOf(address(core)), 0, "consumed hedge left custody by burning");
        // a wallet long redeems once; the second attempt has nothing to burn
        vm.prank(alice);
        core.redeem(k12, WAD, alice);
        vm.prank(alice);
        vm.expectRevert();
        core.redeem(k12, 1, alice);
        SeriesState memory st = core.getSeriesState(k12);
        assertEq(st.redeemed + st.hedgeConsumed + st.closed + t12.totalSupply(), st.minted);
    }

    function test_INV_006_noDoubleShortSettlement() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settle(13 * WAD);
        assertTrue(core.syncRiskGroup(alice, grp));
        uint256 cash = core.cashBalance(alice, address(usdt));
        assertEq(cash, 2e6);
        assertFalse(core.syncRiskGroup(alice, grp), "second sync is a no-op");
        assertEq(core.syncAccount(alice, address(usdt)), 0);
        vm.prank(alice);
        core.withdraw(address(usdt), 1e6, alice); // withdraw's internal sync must not debit again
        assertEq(core.cashBalance(alice, address(usdt)), 1e6);
        assertEq(core.getSeriesState(k10).shortSynced, WAD);
        assertEq(core.positionOf(alice, k10).shortQty, 0);
    }

    function test_INV_008_allGroupSeriesShareSettlementPrice() public {
        _writeTo(alice, k10, WAD, bob, 20e6);
        _writeTo(alice, k12, WAD, bob, 0);
        _writeTo(alice, p10, WAD, bob, 0);
        _settle(11 * WAD);
        uint256 s = core.getGroup(grp).settlementPriceWad;
        assertEq(s, 11 * WAD);
        assertEq(_groupOf(k12), grp);
        assertEq(_groupOf(p10), grp);
        assertEq(core.seriesPayoffPerUnderlying(k10), PayoffMath.phi(OptionType.CALL, 10 * WAD, 5 * WAD, s));
        assertEq(core.seriesPayoffPerUnderlying(k12), PayoffMath.phi(OptionType.CALL, 12 * WAD, 3 * WAD, s));
        assertEq(core.seriesPayoffPerUnderlying(p10), PayoffMath.phi(OptionType.PUT, 10 * WAD, 4 * WAD, s));
        // no series-level price exists: another series of the group cannot be finalized separately
        bytes32 putGroup = _groupOf(p10);
        bytes memory data = _data(0, _proof1(1, 0), _empty());
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.finalizeRiskGroup(putGroup, data);
    }

    function _everyone() internal view returns (address[] memory a, bytes32[] memory s) {
        a = new address[](4);
        (a[0], a[1], a[2], a[3]) = (alice, bob, carol, dave);
        s = new bytes32[](3);
        (s[0], s[1], s[2]) = (k10, k12, p10);
    }

    function test_INV_011_protocolOwnedBalanceNonnegative() public {
        (address[] memory accts, bytes32[] memory ids) = _everyone();
        _writeTo(alice, k10, WAD / 3, bob, 5e6); // fractional quantities force rounding everywhere
        _writeTo(carol, k12, WAD / 7, dave, 5e6);
        _writeTo(carol, p10, 3 * WAD / 11, alice, 0);
        _lock(alice, p10, WAD / 11);
        _fund(gov, usdt, 1e6);
        vm.prank(gov);
        core.recapitalize(address(usdt), 1e6);
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "active");
        _settle(13_4 * WAD / 10); // 13.4: every call pays a fractional amount
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "finalized, nothing settled");
        vm.prank(bob);
        core.redeem(k10, WAD / 9, bob);
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "after a partial redemption");
        core.syncRiskGroup(carol, grp);
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "after one writer sync");
        vm.prank(dave);
        core.redeem(k12, WAD / 7, dave);
        core.syncRiskGroup(alice, grp);
        vm.prank(bob);
        core.redeem(k10, WAD / 3 - WAD / 9, bob);
        assertEq(_protocolOwnedN(address(usdt), accts, ids), 0, "fully settled");
        assertGt(core.roundingResidualN(address(usdt)), 0, "rounding produced a residual, not protocol income");
        assertEq(core.totalRecapitalized(address(usdt)), 1e6);
    }

    function test_INV_017_noUnlockBelowRequiredMargin() public {
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD);
        _writeTo(alice, k10, WAD, alice, 3e6); // K10/C5 short hedged by locked K12/C3 long -> requirement 2
        assertEq(core.requiredMargin(alice, address(usdt)), 2e6);
        uint256 custody = t12.balanceOf(address(core));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 3e6));
        core.unlockLong(k12, WAD, alice);
        assertEq(core.positionOf(alice, k12).lockedQty, WAD, "position unchanged");
        assertEq(t12.balanceOf(address(core)), custody, "custody unchanged");
        assertEq(core.deficit(alice, address(usdt)), 0);
        // the largest safe partial unlock succeeds: 3 cash covers short 5 - hedge 3*q => q >= 2/3
        vm.prank(alice);
        core.unlockLong(k12, WAD / 3, alice);
        assertEq(core.deficit(alice, address(usdt)), 0);
    }

    function test_INV_018_noPostExpiryWrite() public {
        _deposit(alice, usdt, 20e6);
        vm.warp(expiry1 - 1);
        vm.prank(alice);
        core.write(k10, WAD, alice);
        vm.warp(expiry1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.write(k10, WAD, alice);
        vm.warp(expiry1 + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.write(k10, WAD, alice);
        _settle(12 * WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.write(k10, WAD, alice);
        assertEq(core.getSeriesState(k10).minted, WAD);
    }

    function test_INV_019_noRefinalization() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settle(13 * WAD);
        Group memory g = core.getGroup(grp);
        // an equally valid-looking later proof with another price is refused
        vm.warp(block.timestamp + 1 days);
        uint80 r = monUsdtFeed.pushRound(20e8, block.timestamp);
        bytes memory other = _data(0, _proof1(r, 0), _empty());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, grp));
        core.finalizeRiskGroup(grp, other);
        Group memory after_ = core.getGroup(grp);
        assertEq(after_.settlementPriceWad, g.settlementPriceWad);
        assertEq(after_.finalizedAt, g.finalizedAt);
        assertEq(after_.observationTimestamp, g.observationTimestamp);
    }

    function test_INV_020_noRedeemedSupplyResurrection() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _settle(13 * WAD);
        vm.prank(bob);
        core.redeem(k10, WAD, bob);
        assertEq(t10.totalSupply(), 0);
        uint256 minted = core.getSeriesState(k10).minted;
        vm.prank(bob);
        vm.expectRevert();
        core.redeem(k10, WAD, bob); // nothing left to burn, nothing paid
        _deposit(carol, usdt, 5e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.write(k10, WAD, carol); // no path mints settled claims again
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.lockLong(k10, 0 + 1); // nor can a settled series gain locked claims
        assertEq(t10.totalSupply(), 0);
        assertEq(core.getSeriesState(k10).minted, minted);
        assertEq(usdt.balanceOf(bob), 3e6, "paid exactly once");
    }

    // =============================================================================================
    // POL-001: lower count limits and later policy changes never block or rewrite existing positions
    // =============================================================================================

    function test_POL_001_policyChangesAreProspective() public {
        _writeTo(alice, k10, WAD, alice, 20e6);
        _writeTo(alice, k12, WAD, alice, 0);
        _writeTo(alice, p10, WAD, alice, 0);
        uint16 bufferBefore = core.getGroup(grp).bufferBps;
        uint256 incBefore = core.getSeries(k10).quantityIncrement;
        vm.startPrank(gov);
        config.setPositionLimits(1, 1, 1); // far below alice's 3 indexed series
        config.setAssetBufferDefaults(address(usdt), 5_000, 7e6);
        SeriesBounds memory b = config.seriesBounds(config.pairIdOf(MON, address(usdt)));
        b.quantityIncrement = 1e17;
        config.setSeriesBounds(config.pairIdOf(MON, address(usdt)), b);
        vm.stopPrank();
        // existing group snapshot and series terms are unchanged
        assertEq(core.getGroup(grp).bufferBps, bufferBefore);
        assertEq(core.getGroup(grp).fixedBufferNative, 0);
        assertEq(core.getSeries(k10).quantityIncrement, incBefore);
        assertEq(core.requiredMargin(alice, address(usdt)), 8e6); // max(calls 5 + 3 at S >= 15, put 4 at S = 0)
        // existing indexed positions still process: add to an indexed series, lock, close, unlock
        vm.startPrank(alice);
        core.write(k10, 1, alice); // same indexed series, increment 1 still applies to it
        t12.approve(address(core), WAD);
        core.lockLong(k12, WAD);
        core.closeShort(k12, WAD, CloseSource.LOCKED);
        core.closeShort(p10, WAD, CloseSource.EXTERNAL);
        vm.stopPrank();
        // a NEW index entry is what the lower limits block
        bytes32 k14 = _monCall(14 * WAD, 2 * WAD);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.PositionLimitReached.selector);
        core.write(k14, WAD, alice);
        // settlement and withdrawal still complete
        _settle(16 * WAD);
        core.syncRiskGroup(alice, grp);
        uint256 free = core.freeCollateral(alice, address(usdt));
        assertGt(free, 0);
        vm.prank(alice);
        core.withdraw(address(usdt), free, alice);
        assertEq(core.accountSeriesCount(alice), 0);
    }

    // =============================================================================================
    // SYN-015: no per-series settlement selector; a spread settles as one complete group
    // =============================================================================================

    function test_SYN_015_noIsolatedLegSettlement() public {
        _writeTo(alice, k10, WAD, bob, 5e6);
        _writeTo(carol, k12, WAD, alice, 3e6);
        _lock(alice, k12, WAD);
        _settle(14 * WAD);
        string[5] memory sigs = [
            "syncSeries(address,bytes32)",
            "settleSeries(address,bytes32)",
            "syncPosition(address,bytes32)",
            "settleShort(address,bytes32)",
            "redeemLocked(address,bytes32)"
        ];
        for (uint256 i = 0; i < sigs.length; ++i) {
            (bool ok,) = address(core).call(abi.encodeWithSignature(sigs[i], alice, k10));
            assertFalse(ok, sigs[i]);
        }
        // the only settlement entry point nets both spread legs at once: debit 4 - credit 2 = 2
        core.syncRiskGroup(alice, grp);
        assertEq(core.cashBalance(alice, address(usdt)), 3e6);
        assertEq(core.positionOf(alice, k10).shortQty, 0);
        assertEq(core.positionOf(alice, k12).lockedQty, 0);
        assertEq(core.accountGroupSeries(alice, grp).length, 0);
    }
}
