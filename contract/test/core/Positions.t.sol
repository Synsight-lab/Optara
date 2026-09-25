// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PairStatus, OracleConfigStatus} from "../../src/libraries/OptaraTypes.sol";

/// @notice write, lockLong, unlockLong, closeShort and aggregate caps (TEST_CASES.md Parts IX-XII, CAP-*, DON-001).
contract PositionsTest is OptaraTestBase {
    bytes32 k10; // short call K10 C5
    bytes32 k12; // hedge call K12 C3
    IOptionToken t10;
    IOptionToken t12;

    function setUp() public override {
        super.setUp();
        k10 = _monCall(10 * WAD, 5 * WAD);
        k12 = _monCall(12 * WAD, 3 * WAD);
        t10 = _token(k10);
        t12 = _token(k12);
    }

    /// Carol writes the K12 hedge and hands it to `who`.
    function _giveHedge(address who, uint256 qty) internal {
        _deposit(carol, usdt, 3e6 * qty / WAD + 1e6);
        _write(carol, k12, qty);
        vm.prank(carol);
        t12.transfer(who, qty);
    }

    // ------------------------------------------------------------------ WRT
    function test_WRT_001_validUnhedgedCall() public {
        _deposit(alice, usdt, 5e6);
        vm.expectEmit(true, true, true, true, address(core));
        emit IOptaraCoreEvents.OptionWritten(alice, k10, bob, WAD, 5 * WAD * WAD * WAD);
        vm.prank(alice);
        core.write(k10, WAD, bob);
        assertEq(t10.balanceOf(bob), WAD); // WRT-014 recipient gets exact quantity
        assertEq(core.positionOf(alice, k10).shortQty, WAD); // WRT-012
        assertEq(t10.totalSupply(), WAD); // WRT-013
    }

    function test_WRT_002_validUnhedgedPut() public {
        bytes32 put = _monPut(10 * WAD, 4 * WAD);
        _deposit(alice, usdt, 4e6);
        _write(alice, put, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 4e6);
    }

    function test_WRT_003_validHedgedPostWrite() public {
        _giveHedge(alice, WAD);
        _lock(alice, k12, WAD);
        _deposit(alice, usdt, 2e6);
        _write(alice, k10, WAD); // needs only 2 thanks to the locked K12
        assertEq(core.requiredMargin(alice, address(usdt)), 2e6);
    }

    function test_WRT_004_rejectZero() public {
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.write(k10, 0, alice);
    }

    function test_WRT_005_rejectUnknownSeries() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownSeries.selector, bytes32(uint256(1))));
        core.write(bytes32(uint256(1)), WAD, alice);
    }

    function test_WRT_006_rejectExpired() public {
        _deposit(alice, usdt, 5e6);
        vm.warp(expiry1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.write(k10, WAD, alice);
        vm.warp(expiry1 - 1); // one second before expiry is still ACTIVE
        _write(alice, k10, WAD);
    }

    function test_WRT_007_rejectPausedNewRisk() public {
        _deposit(alice, usdt, 5e6);
        vm.prank(pauser);
        config.pause(monUsdtConfig, Actions.WRITE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.WRITE));
        core.write(k10, WAD, alice);
        vm.prank(gov);
        config.unpause(monUsdtConfig, Actions.WRITE);
        // disabled pair / asset / oracle config also block new risk
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        vm.prank(pauser);
        config.setPairStatus(pid, PairStatus.NEW_RISK_DISABLED);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.NewRiskDisabled.selector);
        core.write(k10, WAD, alice);
        vm.prank(configAdmin);
        config.setPairStatus(pid, PairStatus.ENABLED);
        vm.prank(pauser);
        config.setAssetNewRiskEnabled(address(usdt), false);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.NewRiskDisabled.selector);
        core.write(k10, WAD, alice);
        vm.prank(gov);
        config.setAssetNewRiskEnabled(address(usdt), true);
        vm.prank(pauser);
        registry.setStatus(monUsdtConfig, OracleConfigStatus.SUSPENDED_FOR_NEW_SERIES);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.NewRiskDisabled.selector);
        core.write(k10, WAD, alice);
    }

    function test_WRT_008_rejectInvalidRecipient() public {
        _deposit(alice, usdt, 5e6);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRecipient.selector, address(0)));
        core.write(k10, WAD, address(0));
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRecipient.selector, address(core)));
        core.write(k10, WAD, address(core));
        vm.stopPrank();
    }

    function test_WRT_009_rejectInsufficientCash() public {
        _deposit(alice, usdt, 5e6 - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 5e6 - 1));
        core.write(k10, WAD, alice);
    }

    function test_WRT_010_ignoreHugeOtherStablecoin() public {
        _deposit(alice, usdc, 1e30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 0));
        core.write(k10, WAD, alice);
    }

    function test_WRT_011_groupPositionLimitPlusOne() public {
        vm.prank(gov);
        config.setPositionLimits(2, 8, 32);
        bytes32 k14 = _monCall(14 * WAD, 1 * WAD);
        _deposit(alice, usdt, 100e6);
        _write(alice, k10, WAD);
        _write(alice, k12, WAD);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.PositionLimitReached.selector);
        core.write(k14, WAD, alice);
        _write(alice, k10, WAD); // existing index entries keep working
    }

    function test_WRT_015_016_safeAfterWriteRevertLeavesStateUnchanged() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        assertGe(core.cashBalance(alice, address(usdt)), core.requiredMargin(alice, address(usdt)));
        bytes32 before = keccak256(abi.encode(core.getSeriesState(k10), core.positionOf(alice, k10), t10.totalSupply()));
        vm.prank(alice);
        vm.expectRevert();
        core.write(k10, 1, alice);
        assertEq(
            keccak256(abi.encode(core.getSeriesState(k10), core.positionOf(alice, k10), t10.totalSupply())), before
        );
    }

    function test_WRT_017_externalPremiumNotCounted() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        usdt.mint(alice, 0.5e6); // "premium" received outside Optara
        assertEq(core.freeCollateral(alice, address(usdt)), 0);
        _deposit(alice, usdt, 0.5e6);
        assertEq(core.freeCollateral(alice, address(usdt)), 0.5e6);
    }

    /// WRT-018 / SDK-017: a stale preview does not bypass the execution-time check.
    function test_WRT_018_stalePreviewCannotBypass() public {
        _deposit(alice, usdt, 5e6);
        assertEq(core.additionalCollateralForWrite(alice, k10, WAD), 0); // preview: OK
        vm.prank(alice);
        core.withdraw(address(usdt), 1, alice); // state changes before inclusion
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 5e6 - 1));
        core.write(k10, WAD, alice);
    }

    function test_writeQuantityGranularity() public {
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        SeriesBounds memory b = _defaultBounds();
        b.quantityIncrement = WAD / 100;
        vm.prank(configAdmin);
        config.setSeriesBounds(pid, b);
        bytes32 id = _monCall(20 * WAD, 5 * WAD);
        _deposit(alice, usdt, 10e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IOptaraCoreErrors.QuantityGranularity.selector, WAD / 100 + 1, WAD / 100)
        );
        core.write(id, WAD / 100 + 1, alice);
        _write(alice, id, WAD / 100);
        // the snapshot does not change for the existing series (POL-001)
        b.quantityIncrement = 1;
        vm.prank(configAdmin);
        config.setSeriesBounds(pid, b);
        assertEq(core.getSeries(id).quantityIncrement, WAD / 100);
    }

    // ------------------------------------------------------------------ LCK
    function test_LCK_001_002_003_004_lockCompatibleLong() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
        _giveHedge(alice, WAD);
        vm.startPrank(alice);
        t12.approve(address(core), WAD);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.LongLocked(alice, k12, WAD);
        core.lockLong(k12, WAD);
        vm.stopPrank();
        assertEq(t12.balanceOf(address(core)), WAD); // LCK-002
        assertEq(core.positionOf(alice, k12).lockedQty, WAD); // LCK-003
        assertEq(core.requiredMargin(alice, address(usdt)), 2e6); // LCK-004
        assertEq(t12.totalSupply(), WAD); // SUP-003: lock does not change supply
    }

    function test_LCK_005_irrelevantHedgeUnchanged() public {
        bytes32 lowPut = _monPut(5 * WAD, 1 * WAD);
        _deposit(bob, usdt, 1e6);
        _write(bob, lowPut, WAD);
        IOptionToken tp = _token(lowPut);
        vm.prank(bob);
        tp.transfer(alice, WAD);
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _lock(alice, lowPut, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
    }

    function test_LCK_006_007_rejectZeroAndInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.lockLong(k12, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(core), 0, WAD));
        core.lockLong(k12, WAD);
        _giveHedge(alice, WAD);
        vm.startPrank(alice);
        t12.approve(address(core), 2 * WAD);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, WAD, 2 * WAD));
        core.lockLong(k12, 2 * WAD);
        vm.stopPrank();
    }

    /// LCK-008/009: wallet- or venue-held longs give no margin credit.
    function test_LCK_008_009_externalLongNoCredit() public {
        _giveHedge(alice, WAD);
        address kuruVault = makeAddr("kuruMarginAccount");
        vm.prank(alice);
        t12.transfer(kuruVault, WAD / 2);
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
    }

    function test_LCK_010_sameTokenCannotBeLockedTwice() public {
        _giveHedge(alice, WAD);
        _lock(alice, k12, WAD);
        assertEq(t12.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        core.lockLong(k12, WAD);
        // bob cannot claim alice's locked units
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientLocked.selector, WAD, 0));
        core.unlockLong(k12, WAD, bob);
    }

    function test_LCK_011_lockExpiredReverts() public {
        _giveHedge(alice, WAD);
        vm.prank(alice);
        t12.approve(address(core), WAD);
        vm.warp(expiry1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k12));
        core.lockLong(k12, WAD);
    }

    /// LCK-012 / DON-001: a direct token donation is unallocated surplus; lock credits only the transferred amount.
    function test_LCK_012_DON_001_lockCreditsOnlyTransferredAmount() public {
        _giveHedge(alice, 2 * WAD);
        vm.prank(alice);
        t12.transfer(address(core), WAD); // donation
        _lock(alice, k12, WAD / 2);
        assertEq(core.positionOf(alice, k12).lockedQty, WAD / 2);
        assertEq(t12.balanceOf(address(core)), WAD + WAD / 2);
        // donation does not block unlock or sync
        vm.prank(alice);
        core.unlockLong(k12, WAD / 2, alice);
        assertEq(t12.balanceOf(address(core)), WAD);
    }

    function test_LCK_013_boundsRevertBeforeCustody() public {
        // A position whose C*CS*Q exceeds int256 cannot be locked; custody is unchanged.
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        SeriesBounds memory b = _defaultBounds();
        b.maxCapWad = 1e38;
        b.maxStrikeWad = 1e38;
        b.maxContractSizeWad = 1e38;
        vm.prank(configAdmin);
        config.setSeriesBounds(pid, b);
        bytes32 big = _createSeries(MON, address(usdt), OptionType.CALL, 1e38, 1e38, 1e38, expiry1, monUsdtConfig);
        IOptionToken tb = _token(big);
        vm.prank(address(core));
        tb.mint(alice, 1e3); // 1e38 * 1e38 * 1e3 > int256.max
        vm.startPrank(alice);
        tb.approve(address(core), 1e3);
        vm.expectRevert(bytes4(keccak256("NumeratorBoundExceeded()")));
        core.lockLong(big, 1e3);
        vm.stopPrank();
        assertEq(tb.balanceOf(address(core)), 0);
        assertEq(core.accountSeriesCount(alice), 0);
    }

    /// FIX-018: products and account/group sums at the supported int256 bound succeed; bound + 1 reverts before
    /// custody or issuance, including a zero-net-risk locked-only hedge.
    function test_FIX_018_numeratorBoundsExact() public {
        uint256 cap = 1e30;
        uint256 cs = 1e24; // cap * cs = 1e54
        uint256 qMax = uint256(type(int256).max) / (cap * cs);
        bytes32 big = _createSeries(MON, address(usdt), OptionType.CALL, 1e30, cap, cs, expiry1, monUsdtConfig);
        IOptionToken tb = _token(big);
        // locked-only (zero net risk) at the bound succeeds; one more unit fails before custody changes
        vm.prank(address(core));
        tb.mint(alice, qMax + 1);
        vm.startPrank(alice);
        tb.approve(address(core), qMax + 1);
        core.lockLong(big, qMax);
        vm.expectRevert(bytes4(keccak256("NumeratorBoundExceeded()")));
        core.lockLong(big, 1);
        vm.stopPrank();
        assertEq(tb.balanceOf(address(core)), qMax);
        assertEq(core.positionOf(alice, big).lockedQty, qMax);
        // short side: writing exactly to the bound is accepted, one more unit reverts before issuance
        uint256 needed = qMax * 1e6 + 1e6; // C*CS/D_A = 1e6 native per unit
        _deposit(bob, usdt, needed);
        vm.prank(bob);
        core.write(big, qMax, bob);
        uint256 supplyBefore = tb.totalSupply();
        vm.prank(bob);
        vm.expectRevert(bytes4(keccak256("NumeratorBoundExceeded()")));
        core.write(big, 1, bob);
        assertEq(tb.totalSupply(), supplyBefore);
    }

    function test_lockPausedAndUnknown() public {
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.LOCK));
        core.lockLong(k12, WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownSeries.selector, bytes32(0)));
        core.lockLong(bytes32(0), WAD);
    }

    // ------------------------------------------------------------------ ULK
    function _hedgedAlice() internal {
        _giveHedge(alice, WAD);
        _lock(alice, k12, WAD);
        _deposit(alice, usdt, 2e6);
        _write(alice, k10, WAD);
    }

    function test_ULK_001_safeUnlock() public {
        _hedgedAlice();
        _deposit(alice, usdt, 3e6);
        vm.expectEmit(true, true, true, true, address(core));
        emit IOptaraCoreEvents.LongUnlocked(alice, k12, alice, WAD);
        vm.prank(alice);
        core.unlockLong(k12, WAD, alice);
        assertEq(t12.balanceOf(alice), WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
    }

    /// ULK-002/003 and USER_FLOWS.md section 17: unsafe unlock reverts before release.
    function test_ULK_002_003_unsafeUnlockReverts() public {
        _hedgedAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientMargin.selector, 5e6, 2e6));
        core.unlockLong(k12, WAD, alice);
        assertEq(t12.balanceOf(address(core)), WAD);
        assertEq(core.positionOf(alice, k12).lockedQty, WAD);
    }

    function test_ULK_004_depositThenUnlock() public {
        _hedgedAlice();
        _deposit(alice, usdt, 3e6);
        vm.prank(alice);
        core.unlockLong(k12, WAD, bob);
        assertEq(t12.balanceOf(bob), WAD);
    }

    function test_ULK_005_partialUnlock() public {
        _hedgedAlice();
        _deposit(alice, usdt, 1.5e6);
        vm.prank(alice);
        core.unlockLong(k12, WAD / 2, alice); // requirement 5 - 1.5 = 3.5
        assertEq(core.requiredMargin(alice, address(usdt)), 3.5e6);
        assertEq(core.positionOf(alice, k12).lockedQty, WAD / 2);
    }

    function test_ULK_006_rejectAboveLocked() public {
        _hedgedAlice();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientLocked.selector, 2 * WAD, WAD));
        core.unlockLong(k12, 2 * WAD, alice);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.unlockLong(k12, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRecipient.selector, address(0)));
        core.unlockLong(k12, 1, address(0));
        vm.stopPrank();
    }

    /// ULK-007: once the group is finalized, a hedge settles atomically and cannot be unlocked.
    function test_ULK_007_maturedHedgeUsesSettlement() public {
        _hedgedAlice();
        _finalizeMon(k10, 20 * WAD);
        bytes32 g = _groupOf(k12);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.GroupAlreadyFinalized.selector, g));
        core.unlockLong(k12, WAD, alice);
    }

    function test_ULK_008_requiredMarginMonotoneAfterRemoval() public {
        _hedgedAlice();
        uint256 before = core.requiredMargin(alice, address(usdt));
        assertGe(core.requiredMarginAfter(alice, k12, 0, -int256(WAD / 3)), before);
        assertGe(core.requiredMarginAfter(alice, k12, 0, -int256(WAD)), before);
    }

    function test_unlockPaused() public {
        _hedgedAlice();
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.UNLOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.UNLOCK));
        core.unlockLong(k12, 1, alice);
    }

    // ------------------------------------------------------------------ CLS
    function test_CLS_001_partialClose() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, 2 * WAD);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.ShortClosed(alice, k10, WAD, CloseSource.EXTERNAL);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(core.positionOf(alice, k10).shortQty, WAD);
        assertEq(t10.totalSupply(), WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), 5e6);
    }

    function test_CLS_002_009_010_011_012_fullClose() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(t10.balanceOf(alice), 0); // CLS-009 long burned exactly
        assertEq(core.positionOf(alice, k10).shortQty, 0); // CLS-010
        assertEq(core.requiredMargin(alice, address(usdt)), 0); // CLS-011
        assertEq(core.freeCollateral(alice, address(usdt)), 5e6); // CLS-012
        assertEq(core.accountGroups(alice).length, 0); // index cleaned
        SeriesState memory st = core.getSeriesState(k10);
        assertEq(st.openShortQty, 0);
        assertEq(st.closed, WAD);
        assertEq(st.exposureN, 0);
    }

    /// CLS-003..006: only the identical series closes the short.
    function test_CLS_003_to_006_wrongSeriesRejected() public {
        bytes32 k10c4 = _monCall(10 * WAD, 4 * WAD);
        bytes32 k10e2 =
            _createSeries(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry2, monUsdtConfig);
        _deposit(alice, usdt, 30e6);
        _write(alice, k10, WAD);
        _write(alice, k12, WAD);
        _write(alice, k10c4, WAD);
        _write(alice, k10e2, WAD);
        // alice holds only the k12 token now for k10's short: burn from the wrong token is impossible
        vm.prank(alice);
        t10.transfer(bob, WAD);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, WAD));
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        vm.stopPrank();
        assertEq(core.positionOf(alice, k10).shortQty, WAD);
        assertEq(t12.balanceOf(alice), WAD); // untouched wrong-strike token
    }

    function test_CLS_007_008_quantityChecks() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientShort.selector, 2 * WAD, WAD));
        core.closeShort(k10, 2 * WAD, CloseSource.EXTERNAL);
        vm.expectRevert(IOptaraCoreErrors.ZeroAmount.selector);
        core.closeShort(k10, 0, CloseSource.EXTERNAL);
        vm.stopPrank();
    }

    /// CLS-013/014: a venue fill alone changes nothing; the actual token then closes.
    function test_CLS_013_014_kuruFillThenClose() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        address kuru = makeAddr("kuru");
        vm.prank(alice);
        t10.transfer(kuru, WAD); // sold on Kuru
        vm.prank(kuru);
        t10.transfer(bob, WAD); // buyer
        assertEq(core.positionOf(alice, k10).shortQty, WAD); // COMP-INV-03
        vm.prank(bob);
        t10.transfer(alice, WAD); // alice buys back
        assertEq(core.positionOf(alice, k10).shortQty, WAD);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(core.positionOf(alice, k10).shortQty, 0);
    }

    /// CLS-015: LOCKED-source close consumes the caller's own identical hedge; risk never rises.
    function test_CLS_015_lockedSourceClose() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, 2 * WAD);
        _lock(alice, k10, WAD); // identical series locked
        uint256 before = core.requiredMargin(alice, address(usdt));
        assertEq(before, 5e6);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.LOCKED);
        Position memory p = core.positionOf(alice, k10);
        assertEq(p.shortQty, WAD);
        assertEq(p.lockedQty, 0);
        assertEq(t10.balanceOf(address(core)), 0);
        assertLe(core.requiredMargin(alice, address(usdt)), before);
        assertEq(t10.totalSupply(), WAD);
    }

    /// CLS-016: a close never consumes a locked hedge unless LOCKED is named; LOCKED needs enough own locked units.
    function test_CLS_016_lockedNeverImplicit() public {
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, 2 * WAD);
        _lock(alice, k10, WAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientLocked.selector, 2 * WAD, WAD));
        core.closeShort(k10, 2 * WAD, CloseSource.LOCKED);
        // EXTERNAL close uses wallet tokens only
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        assertEq(core.positionOf(alice, k10).lockedQty, WAD);
        // wallet empty now: EXTERNAL fails even though a locked unit exists
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, WAD));
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
        // another account cannot use alice's hedge
        _deposit(bob, usdt, 5e6);
        _write(bob, k10, WAD);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InsufficientLocked.selector, WAD, 0));
        core.closeShort(k10, WAD, CloseSource.LOCKED);
    }

    function test_closeAfterExpiryUsesCancellation() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        vm.warp(expiry1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.SeriesNotActive.selector, k10));
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
    }

    function test_closePaused() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.CLOSE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.CLOSE));
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
    }

    // ------------------------------------------------------------------ CAP (PROTOCOL_SPEC.md section 42)
    function _capAt(ExposureScope scope, bytes32 key, uint256 n) internal {
        vm.prank(pauser);
        config.setExposureLimit(scope, key, n);
    }

    /// CAP-001: several accounts each within their own limits cannot collectively exceed a shared cap.
    function test_CAP_001_accountSplittingCannotExceedCap() public {
        uint256 unit = 5 * WAD * WAD * WAD; // C*CS*1 option
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        ExposureScope[4] memory scopes =
            [ExposureScope.SERIES, ExposureScope.PAIR, ExposureScope.ORACLE_CONFIG, ExposureScope.ASSET];
        bytes32[4] memory keys = [pid, pid, monUsdtConfig, bytes32(uint256(uint160(address(usdt))))];
        for (uint256 i = 0; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            _capAt(scopes[i], keys[i], 2 * unit);
            _deposit(alice, usdt, 5e6);
            _deposit(bob, usdt, 5e6);
            _deposit(carol, usdt, 5e6);
            _write(alice, k10, WAD);
            _write(bob, k10, WAD);
            vm.prank(carol);
            vm.expectRevert(
                abi.encodeWithSelector(IOptaraCoreErrors.ExposureLimitExceeded.selector, scopes[i], 3 * unit, 2 * unit)
            );
            core.write(k10, WAD, carol);
            vm.revertToState(snap);
        }
    }

    /// CAP-002: transfers, locks and short-only syncs never release capacity; each burn releases once.
    function test_CAP_002_onlyBurnsReleaseCapacity() public {
        uint256 unit = 5 * WAD * WAD * WAD;
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, 2 * WAD);
        (uint256 pairN,,) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN, 2 * unit);
        vm.prank(alice);
        t10.transfer(bob, WAD);
        _lock(alice, k10, WAD);
        (pairN,,) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN, 2 * unit);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.LOCKED);
        (pairN,,) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN, unit);
        assertEq(core.getSeriesState(k10).exposureN, unit);
    }

    /// CAP-003: a cap lowered below exposure blocks writes but never exits; raising is governance-only.
    function test_CAP_003_lowerCapBlocksWritesNotExits() public {
        uint256 unit = 5 * WAD * WAD * WAD;
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        _deposit(alice, usdt, 10e6);
        _write(alice, k10, 2 * WAD);
        _capAt(ExposureScope.PAIR, pid, unit);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IOptaraCoreErrors.ExposureLimitExceeded.selector, ExposureScope.PAIR, 3 * unit, unit)
        );
        core.write(k10, WAD, alice);
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL); // exit still works
        vm.prank(alice);
        core.withdraw(address(usdt), 5e6, alice);
        _finalizeMon(k10, 12 * WAD); // settlement still works
        core.syncRiskGroup(alice, _groupOf(k10));
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        config.setExposureLimit(ExposureScope.PAIR, pid, 10 * unit);
    }

    /// CAP-004 / CAP-005: finalization releases the group from pair/oracle/asset in O(1); unfinalized and stalled
    /// groups keep consuming capacity; later burns touch only series/group counters.
    function test_CAP_004_005_releaseAtFinalization() public {
        uint256 unit = 5 * WAD * WAD * WAD;
        bytes32 pid = config.pairIdOf(MON, address(usdt));
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        vm.warp(uint256(expiry1) + MAX_FINAL_DELAY + 1); // expired and ORACLE_STALLED
        assertTrue(core.isOracleStalled(_groupOf(k10)));
        (uint256 pairN, uint256 oracleN, uint256 assetN) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN, unit); // CAP-005 still consumed
        assertEq(oracleN, unit);
        assertEq(assetN, unit);
        // finalize late with an authentic historical observation (REC-006)
        vm.warp(expiry1 - 10);
        uint80 r = monUsdtFeed.pushRound(9e8, block.timestamp); // OTM: zero payoff
        vm.warp(uint256(expiry1) + MAX_FINAL_DELAY + 10);
        uint80 n = monUsdtFeed.pushRound(9e8, block.timestamp);
        core.finalizeRiskGroup(_groupOf(k10), _data(0, _proof1(r, n), _empty()));
        (pairN, oracleN, assetN) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN + oracleN + assetN, 0); // released although the zero-payoff long is abandoned
        Group memory g = core.getGroup(_groupOf(k10));
        assertTrue(g.released);
        assertEq(g.exposureN, unit);
        vm.prank(alice);
        core.redeem(k10, WAD, alice); // later burn touches series/group only
        (pairN,,) = core.exposureOf(pid, monUsdtConfig, address(usdt));
        assertEq(pairN, 0);
        assertEq(core.getGroup(_groupOf(k10)).exposureN, 0);
        assertEq(core.getSeriesState(k10).exposureN, 0);
    }

    function test_positionAndSeriesLimits() public {
        vm.prank(gov);
        config.setPositionLimits(8, 1, 2);
        bytes32 e2 = _createSeries(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry2, monUsdtConfig);
        bytes32 k14 = _monCall(14 * WAD, 1 * WAD);
        _deposit(alice, usdt, 100e6);
        _write(alice, k10, WAD);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.PositionLimitReached.selector); // second group
        core.write(e2, WAD, alice);
        _write(alice, k12, WAD);
        vm.prank(alice);
        vm.expectRevert(IOptaraCoreErrors.PositionLimitReached.selector); // third series
        core.write(k14, WAD, alice);
        // lowering limits below current use never blocks processing (POL-001)
        vm.prank(gov);
        config.setPositionLimits(1, 1, 1);
        _write(alice, k10, WAD);
        vm.prank(alice);
        core.closeShort(k12, WAD, CloseSource.EXTERNAL);
        vm.prank(alice);
        core.withdraw(address(usdt), 1e6, alice);
    }
}
