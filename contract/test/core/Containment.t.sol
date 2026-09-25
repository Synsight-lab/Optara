// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";

/// @notice Incident containment, verified-shortfall resolution, pause matrix and privilege boundaries
///         (TEST_CASES.md EMR-*, PAU-*, ACL-*, VER-*, POL-001; LIQUIDATION.md sections 101-102).
contract ContainmentTest is OptaraTestBase {
    bytes32 k10;
    bytes32 grp;
    IOptionToken t10;
    uint256 constant CASH_SLOT = 6;

    function setUp() public override {
        super.setUp();
        k10 = _monCall(10 * WAD, 5 * WAD);
        grp = _groupOf(k10);
        t10 = _token(k10);
    }

    function _corruptCash(address who, uint256 newCash) internal {
        vm.store(
            address(core), keccak256(abi.encode(address(usdt), keccak256(abi.encode(who, CASH_SLOT)))), bytes32(newCash)
        );
    }

    /// Alice writes one K10C5 (needs 5) with 5 deposited, then the ledger is corrupted to 3: a verified deficit of 2.
    function _deficitAlice() internal {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _corruptCash(alice, 3e6);
    }

    // ------------------------------------------------------------------ EMR
    /// EMR-001: an unsafe call reverts and persists nothing.
    function test_EMR_001_rejectedCallPersistsNothing() public {
        _deposit(alice, usdt, 4e6);
        vm.recordLogs();
        vm.prank(alice);
        vm.expectRevert();
        core.write(k10, WAD, alice);
        assertEq(vm.getRecordedLogs().length, 0);
        (AssetStatus st,) = core.assetStatus(address(usdt));
        assertEq(uint8(st), uint8(AssetStatus.NORMAL));
    }

    /// EMR-002: a separate verified deficit check commits the restriction; healthy/invalid checks cannot grief.
    function test_EMR_002_verifiedDeficitRestricts() public {
        _deposit(bob, usdt, 5e6);
        _write(bob, k10, WAD);
        usdt.mint(address(core), 100e6); // donation cannot trigger restriction
        assertFalse(core.checkAndRestrict(bob, address(usdt)));
        vm.expectRevert(IOptaraCoreErrors.ZeroAddress.selector);
        core.checkAndRestrict(address(0), address(usdt));
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownAsset.selector, address(5)));
        core.checkAndRestrict(bob, address(5));
        _deficitAlice();
        assertEq(core.deficit(alice, address(usdt)), 2e6);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.AssetRestricted(address(usdt), alice, 2e6, bytes32("VERIFIED_DEFICIT"), attacker);
        vm.prank(attacker); // permissionless
        assertTrue(core.checkAndRestrict(alice, address(usdt)));
        (AssetStatus st,) = core.assetStatus(address(usdt));
        assertEq(uint8(st), uint8(AssetStatus.RESTRICTED));
        assertTrue(core.checkAndRestrict(bob, address(usdt))); // already restricted: no-op true
        assertEq(core.cashBalance(alice, address(usdt)), 3e6); // restriction rewrites nothing
    }

    /// Deficit includes finalized-unsynced deltas and unfinalized reservations.
    function test_EMR_002_deficitIncludesPendingDeltas() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        _finalizeMon(k10, 20 * WAD); // owes 5, pending
        _corruptCash(alice, 4e6);
        assertEq(core.effectiveCash(alice, address(usdt)), -1e6);
        assertEq(core.deficit(alice, address(usdt)), 1e6);
        assertTrue(core.checkAndRestrict(alice, address(usdt)));
    }

    /// EMR-003: the asset restriction gates every specified outflow for all accounts; another asset works.
    function test_EMR_003_restrictionGatesAllOutflows() public {
        bytes32 hedge = _monCall(12 * WAD, 3 * WAD);
        _deposit(bob, usdt, 20e6);
        _write(bob, k10, WAD);
        _write(bob, hedge, WAD);
        _lock(bob, hedge, WAD);
        _deposit(carol, usdc, 5e6);
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "ALARM");
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetIsRestricted.selector, address(usdt)));
        core.write(k10, WAD, bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetIsRestricted.selector, address(usdt)));
        core.withdraw(address(usdt), 1, bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetIsRestricted.selector, address(usdt)));
        core.unlockLong(hedge, WAD, bob);
        vm.stopPrank();
        _finalizeMon(k10, 11 * WAD);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetIsRestricted.selector, address(usdt)));
        core.redeem(k10, WAD, bob);
        // unrelated asset keeps operating
        vm.prank(carol);
        core.withdraw(address(usdc), 5e6, carol);
        // sync (internal, unscaled) still works while restricted
        assertTrue(core.syncRiskGroup(bob, grp));
    }

    /// EMR-004: guardian restrict / governance clear authorization and events; balances and terms unchanged.
    function test_EMR_004_restrictClearAuthorization() public {
        _deposit(alice, usdt, 5e6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, attacker));
        core.restrictAsset(address(usdt), "X");
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.UnknownAsset.selector, address(3)));
        core.restrictAsset(address(3), "X");
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.AssetRestricted(address(usdt), address(0), 0, "RECON_ALARM", pauser);
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "RECON_ALARM");
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetIsRestricted.selector, address(usdt)));
        core.restrictAsset(address(usdt), "AGAIN");
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, pauser));
        core.clearAssetRestriction(address(usdt), "REF");
        vm.expectEmit(true, false, false, true, address(core));
        emit IOptaraCoreEvents.AssetRestrictionCleared(address(usdt), "REF", gov);
        vm.prank(gov);
        core.clearAssetRestriction(address(usdt), "REF");
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetNotRestricted.selector, address(usdt)));
        core.clearAssetRestriction(address(usdt), "REF");
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
    }

    /// EMR-005: resolution rejects unrestricted asset, rho >= 1, rho = 0, second call, non-governance, no timelock.
    function test_EMR_005_resolutionRejections() public {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetNotRestricted.selector, address(usdt)));
        core.proposeShortfallResolution(address(usdt), 0.5e18, "R");
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "LOSS");
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRho.selector, 1e18));
        core.proposeShortfallResolution(address(usdt), 1e18, "R");
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.InvalidRho.selector, 0));
        core.proposeShortfallResolution(address(usdt), 0, "R");
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NoPendingResolution.selector, address(usdt)));
        core.executeShortfallResolution(address(usdt));
        core.proposeShortfallResolution(address(usdt), 0.5e18, "R");
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ShortfallResolutionExists.selector, address(usdt)));
        core.proposeShortfallResolution(address(usdt), 0.6e18, "R");
        uint64 eta = uint64(block.timestamp) + SHORTFALL_DELAY;
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ResolutionTimelocked.selector, eta));
        core.executeShortfallResolution(address(usdt)); // missing timelock
        vm.stopPrank();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, pauser));
        core.executeShortfallResolution(address(usdt));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, attacker));
        core.proposeShortfallResolution(address(usdt), 0.5e18, "R");
        vm.warp(eta);
        vm.prank(gov);
        core.executeShortfallResolution(address(usdt));
        (AssetStatus st, uint256 rho) = core.assetStatus(address(usdt));
        assertEq(uint8(st), uint8(AssetStatus.WIND_DOWN));
        assertEq(rho, 0.5e18);
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetNotRestricted.selector, address(usdt)));
        core.proposeShortfallResolution(address(usdt), 0.4e18, "R2"); // set once
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetNotRestricted.selector, address(usdt)));
        core.clearAssetRestriction(address(usdt), "R");
        vm.stopPrank();
    }

    function test_cancelResolution() public {
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "LOSS");
        vm.prank(gov);
        core.proposeShortfallResolution(address(usdt), 0.5e18, "R");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, attacker));
        core.cancelShortfallResolution(address(usdt));
        vm.prank(gov);
        core.cancelShortfallResolution(address(usdt));
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NoPendingResolution.selector, address(usdt)));
        core.cancelShortfallResolution(address(usdt));
        // clearing a restriction also drops a pending proposal
        vm.prank(gov);
        core.proposeShortfallResolution(address(usdt), 0.5e18, "R");
        vm.prank(gov);
        core.clearAssetRestriction(address(usdt), "OK");
        assertEq(core.assetIncident(address(usdt)).pendingEta, 0);
    }

    /// EMR-006: after resolution every outflow pays floor(rho * amount) in any order; total outflow <= vault balance;
    /// other assets untouched. MATH.md section 119.
    function test_EMR_006_uniformRatioAnyOrder() public {
        for (uint256 order = 0; order < 2; ++order) {
            uint256 snap = vm.snapshotState();
            _windDownScenario(order);
            vm.revertToState(snap);
        }
    }

    function _windDownScenario(uint256 order) internal {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD); // alice short 1, bob holds the long
        vm.prank(alice);
        t10.transfer(bob, WAD);
        _deposit(carol, usdt, 10e6); // plain depositor
        _deposit(dave, usdc, 8e6);
        _finalizeMon(k10, 13 * WAD); // bob claim 3, alice effective 2, carol 10: total claims 15
        usdt.burnFrom(address(core), 3e6); // custody loss: vault 15 -> 12
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "CUSTODY_LOSS");
        // governance reconciliation: rho = 12 / 15 = 0.8
        vm.prank(gov);
        core.proposeShortfallResolution(address(usdt), 0.8e18, "RECON-1");
        vm.warp(block.timestamp + SHORTFALL_DELAY);
        vm.expectEmit(true, false, false, true, address(core));
        emit IOptaraCoreEvents.ShortfallResolved(address(usdt), 0.8e18, "RECON-1");
        vm.prank(gov);
        core.executeShortfallResolution(address(usdt));
        uint256 vaultBefore = usdt.balanceOf(address(core));
        if (order == 0) {
            vm.prank(bob);
            assertEq(core.redeem(k10, WAD, bob), 2.4e6);
            vm.prank(carol);
            core.withdraw(address(usdt), 10e6, carol);
            vm.prank(alice);
            core.withdraw(address(usdt), 2e6, alice); // syncs first (internal, unscaled)
        } else {
            vm.prank(alice);
            core.withdraw(address(usdt), 2e6, alice);
            vm.prank(carol);
            core.withdraw(address(usdt), 10e6, carol);
            vm.prank(bob);
            assertEq(core.redeem(k10, WAD, bob), 2.4e6);
        }
        assertEq(usdt.balanceOf(bob), 2.4e6);
        assertEq(usdt.balanceOf(carol), 8e6);
        assertEq(usdt.balanceOf(alice), 1.6e6);
        assertLe(vaultBefore - usdt.balanceOf(address(core)), vaultBefore);
        assertEq(usdt.balanceOf(address(core)), 0);
        assertEq(core.cashBalance(carol, address(usdt)), 0); // ledger debited by the full amount
        (uint256 payout, uint256 paid) = core.previewRedeem(k10, 0);
        assertEq(payout + paid, 0);
        // other asset untouched
        vm.prank(dave);
        core.withdraw(address(usdc), 8e6, dave);
        assertEq(usdc.balanceOf(dave), 8e6);
        // deposits, recapitalization and new risk are permanently disabled in wind-down (EMR-007 part)
        _fund(alice, usdt, 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetInWindDown.selector, address(usdt)));
        core.deposit(address(usdt), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.AssetInWindDown.selector, address(usdt)));
        core.recapitalize(address(usdt), 1e6);
    }

    /// EMR-007: reserve + surplus covering the deficit yields rho = 1: restriction cleared, no haircut.
    function test_EMR_007_recapitalizedClearsWithoutHaircut() public {
        _deposit(carol, usdt, 10e6);
        usdt.burnFrom(address(core), 2e6);
        vm.prank(pauser);
        core.restrictAsset(address(usdt), "CUSTODY_LOSS");
        _fund(gov, usdt, 2e6);
        vm.prank(gov);
        core.recapitalize(address(usdt), 2e6); // allowed while restricted
        assertEq(usdt.balanceOf(address(core)), core.totalCash(address(usdt)));
        vm.prank(gov);
        core.clearAssetRestriction(address(usdt), "RECON-OK");
        vm.prank(carol);
        core.withdraw(address(usdt), 10e6, carol);
        assertEq(usdt.balanceOf(carol), 10e6);
    }

    /// EMR-008: while restricted, ordinary deposit reverts; a cure deposit is accepted up to the deficit only.
    function test_EMR_008_cureDepositOnly() public {
        _deficitAlice();
        assertTrue(core.checkAndRestrict(alice, address(usdt)));
        _fund(bob, usdt, 5e6);
        vm.prank(bob); // healthy account: no deficit, ordinary deposit rejected
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.CureDepositExceedsDeficit.selector, 1e6, 0));
        core.deposit(address(usdt), 1e6);
        _fund(alice, usdt, 5e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.CureDepositExceedsDeficit.selector, 2e6 + 1, 2e6));
        core.deposit(address(usdt), 2e6 + 1);
        vm.expectEmit(true, true, false, true, address(core));
        emit IOptaraCoreEvents.CollateralDeposited(alice, address(usdt), 2e6, true);
        vm.prank(alice);
        core.deposit(address(usdt), 2e6);
        assertEq(core.deficit(alice, address(usdt)), 0);
        vm.prank(bob); // recapitalize credits no account
        core.recapitalize(address(usdt), 1e6);
        assertEq(core.cashBalance(bob, address(usdt)), 0);
        // LIQUIDATION.md section 17: lock and close stay available while restricted
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL);
    }

    // ------------------------------------------------------------------ PAU
    function test_PAU_001_to_005_riskPauseMatrix() public {
        bytes32 hedge = _monCall(12 * WAD, 3 * WAD);
        _deposit(alice, usdt, 20e6);
        _write(alice, k10, WAD);
        _write(alice, hedge, WAD);
        vm.prank(pauser);
        config.pause(bytes32(0), Actions.WRITE | Actions.WITHDRAW | Actions.UNLOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.WRITE));
        core.write(k10, WAD, alice); // PAU-001
        _deposit(alice, usdt, 1e6); // PAU-002
        vm.prank(alice);
        core.closeShort(k10, WAD, CloseSource.EXTERNAL); // PAU-003
        _lock(alice, hedge, WAD); // PAU-004
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.WITHDRAW));
        core.withdraw(address(usdt), 1, alice); // PAU-005
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.UNLOCK));
        core.unlockLong(hedge, WAD, alice);
    }

    function test_PAU_006_settlementPauseBlocksFinalization() public {
        bytes memory data = _directProofData(monUsdtFeed, 12e8, expiry1);
        bytes32 assetScope = config.assetScope(address(usdt));
        vm.prank(pauser);
        config.pause(assetScope, Actions.FINALIZE | Actions.SYNC | Actions.REDEEM);
        vm.warp(uint256(expiry1) + MIN_FINAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.FINALIZE));
        core.finalizeRiskGroup(grp, data);
    }

    function test_PAU_007_unaffectedPairOperational() public {
        bytes32 eth =
            _createSeries(ETH, address(usdc), OptionType.CALL, 3000 * WAD, 10 * WAD, WAD, expiry1, ethUsdcConfig);
        vm.prank(pauser);
        config.pause(monUsdtConfig, Actions.WRITE);
        _deposit(alice, usdc, 10e6);
        _write(alice, eth, WAD);
        assertEq(core.positionOf(alice, eth).shortQty, WAD);
    }

    /// PAU-008/009, ACL-006/007, AC-INV-07: pausers and config admins cannot change terms or move collateral.
    function test_PAU_008_009_pauserCannotRewriteOrSeize() public {
        _deposit(alice, usdt, 5e6);
        _write(alice, k10, WAD);
        Series memory before = core.getSeries(k10);
        vm.startPrank(pauser);
        config.pause(bytes32(0), Actions.ALL);
        core.restrictAsset(address(usdt), "INCIDENT");
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.OnlySeriesFactory.selector, pauser));
        core.registerSeries(k10, before);
        vm.stopPrank();
        assertEq(keccak256(abi.encode(core.getSeries(k10))), keccak256(abi.encode(before)));
        assertEq(core.cashBalance(alice, address(usdt)), 5e6);
        assertEq(usdt.balanceOf(pauser), 0);
        assertEq(usdt.balanceOf(configAdmin), 0);
    }

    // ------------------------------------------------------------------ ACL
    /// ACL-001/004/006: no user, keeper or pauser can mint; ACL-002/007: no one can move vault collateral directly;
    /// ACL-012..014: there is no SDK/Kuru/frontend role at all (roles are exactly the documented set).
    function test_ACL_001_to_014_privileges() public {
        address[5] memory callers = [alice, keeper, pauser, configAdmin, gov];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert();
            t10.mint(callers[i], 1);
        }
        // the core exposes no arbitrary transfer, sweep or rescue function: every outflow is withdraw/redeem
        bytes4[4] memory forbidden = [
            bytes4(keccak256("rescueToken(address,uint256)")),
            bytes4(keccak256("sweep(address,address,uint256)")),
            bytes4(keccak256("transferOut(address,address,uint256)")),
            bytes4(keccak256("setSettlementPrice(bytes32,uint256)"))
        ];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(gov);
            (bool ok,) = address(core).call(abi.encodeWithSelector(forbidden[i], address(usdt), 1));
            assertFalse(ok);
        }
        // ACL-012..014: no SDK_ROLE/KURU_ROLE/FRONTEND_ROLE/UPGRADER_ROLE members
        assertEq(config.getRoleMemberCount(keccak256("SDK_ROLE")), 0);
        assertEq(config.getRoleMemberCount(keccak256("KURU_ROLE")), 0);
        assertEq(config.getRoleMemberCount(keccak256("FRONTEND_ROLE")), 0);
        assertEq(config.getRoleMemberCount(keccak256("UPGRADER_ROLE")), 0);
    }

    function test_ACL_008_009_seriesCreatorBounded() public {
        SeriesFactory.SeriesParams memory p =
            _params(ETH, address(usde), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdeConfig);
        vm.prank(creator);
        vm.expectRevert(SeriesFactory.PairNotEnabled.selector);
        factory.createSeries(p); // ACL-008
        p = _params(MON, address(usdt), OptionType.CALL, 11 * WAD, 5 * WAD, WAD, expiry1, keccak256("fake"));
        vm.prank(creator);
        vm.expectRevert(SeriesFactory.OracleConfigNotApproved.selector);
        factory.createSeries(p); // ACL-009
    }

    // ------------------------------------------------------------------ VER
    /// VER-001: no proxy/beacon/peer/role-admin route can replace financial logic or custody authority.
    function test_VER_001_noReplacementPath() public {
        vm.expectRevert(IOptaraCoreErrors.AlreadySealed.selector);
        core.bindSeriesFactory(address(this));
        assertTrue(core.isSealed());
        assertEq(core.seriesFactory(), address(factory));
        assertEq(t10.core(), address(core)); // token authority pinned immutably
        assertEq(address(core.config()), address(config));
        assertEq(address(core.oracleRegistry()), address(registry));
        // no EIP-1967 implementation/admin/beacon slots are used
        assertEq(vm.load(address(core), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)), bytes32(0));
        assertEq(vm.load(address(core), bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)), bytes32(0));
        assertEq(vm.load(address(core), bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)), bytes32(0));
        // an oracle config's adapter cannot be replaced for existing groups
        OracleConfig memory c = registry.getConfig(monUsdtConfig);
        assertEq(c.adapter, address(adapter));
    }

    /// VER-002: a new core's ids never collide with, or redirect, the old core's series.
    function test_VER_002_newCoreDoesNotCollide() public {
        OptaraCore core2 = new OptaraCore(config, registry, SHORTFALL_DELAY);
        SeriesFactory factory2 = new SeriesFactory(core2, config, registry);
        core2.bindSeriesFactory(address(factory2));
        assertTrue(core2.protocolSeriesDomain() != core.protocolSeriesDomain());
        vm.prank(creator);
        (bytes32 id2, address token2) = factory2.createSeries(
            _params(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, expiry1, monUsdtConfig)
        );
        assertTrue(id2 != k10);
        assertTrue(token2 != address(t10));
        assertFalse(core2.seriesExists(k10));
        assertEq(core.getSeries(k10).optionToken, address(t10));
    }
}
