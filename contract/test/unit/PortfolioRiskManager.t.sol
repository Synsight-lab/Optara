// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {PortfolioRiskManager} from "../../src/risk/PortfolioRiskManager.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {ISettlementState, IReserveStatus} from "../../src/interfaces/IExternalDependencies.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {
    NotAuthorized,
    ZeroAddress,
    StaleSpot,
    StaleSurface,
    MissingSurfaceNode,
    SeriesNotPriceable,
    SeriesNotActive,
    NotHealthy,
    ProductCloseOnly,
    OpenInterestCap,
    InvalidRiskParams,
    UnknownRiskSet,
    RiskSetExists,
    RiskSetAlreadyAssigned,
    InvalidSeriesParams,
    LengthMismatch
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for PortfolioRiskManager: worked examples (MRG-001..003) and margin behavior.
contract PortfolioRiskManagerTest is RiskFixture {
    uint256 internal acct;
    bytes32 internal c4500;
    bytes32 internal c5000;
    bytes32 internal p3500;

    uint256 internal constant CENT = 0.01e18;

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        c4500 = _series(ethUsdc, OptionType.CALL, 4500e18, EXP30);
        c5000 = _series(ethUsdc, OptionType.CALL, 5000e18, EXP30);
        p3500 = _series(ethUsdc, OptionType.PUT, 3500e18, EXP30);
        acct = _account(alice);
    }

    // ------------------------------------------------------------------ MRG-001..003: MATH.md §10

    function test_MRG001_nakedCall() public {
        _hold(acct, c4500, -1e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.equity, -106.77e18, CENT, "mark");
        assertApproxEqAbs(r.initialMargin, 3417.78e18, CENT, "IM");
        assertApproxEqAbs(r.maintenanceMargin, 1447.43e18, CENT, "MM");
        assertTrue(r.fresh);
    }

    function test_MRG002_callSpread() public {
        _hold(acct, c4500, -1e18);
        _hold(acct, c5000, 1e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.equity, -67.12e18, CENT, "mark");
        assertApproxEqAbs(r.initialMargin, 438.22e18, CENT, "IM");
        assertApproxEqAbs(r.maintenanceMargin, 413.06e18, CENT, "MM");
    }

    function test_MRG003_nakedPut() public {
        _hold(acct, p3500, -1e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.equity, -96.62e18, CENT, "mark");
        assertApproxEqAbs(r.initialMargin, 1423.23e18, CENT, "IM");
        assertApproxEqAbs(r.maintenanceMargin, 676.31e18, CENT, "MM");
    }

    // ------------------------------------------------------------------ initialization

    function test_initializeChecks() public {
        address impl = address(new PortfolioRiskManager());
        IProtocolControl c = IProtocolControl(address(pc));
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            impl,
            abi.encodeCall(
                PortfolioRiskManager.initialize,
                (
                    c,
                    ISubAccounts(address(0)),
                    IOptionSeriesRegistry(address(registry)),
                    ILiveSpotOracle(address(spot)),
                    IVolSurfaceOracle(address(surface)),
                    ISettlementState(address(settlementState)),
                    IReserveStatus(address(reserves))
                )
            )
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        risk.initialize(
            c,
            ISubAccounts(address(ledger)),
            IOptionSeriesRegistry(address(registry)),
            ILiveSpotOracle(address(spot)),
            IVolSurfaceOracle(address(surface)),
            ISettlementState(address(settlementState)),
            IReserveStatus(address(reserves))
        );
    }

    // ------------------------------------------------------------------ equity, health

    function test_emptyAccountIsCashOnly() public {
        _fund(acct, 1234.5e6);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertEq(r.equity, 1234.5e18);
        assertEq(r.initialMargin, 0);
        assertEq(r.maintenanceMargin, 0);
        assertTrue(r.fresh);
        assertEq(risk.equityOf(acct), 1234.5e18);
    }

    function test_MRG007_healthStatesAtBoundaries() public {
        _hold(acct, c4500, -1e18);
        (uint256 im, uint256 mm) = risk.marginOf(acct);
        int256 mark = risk.equityOf(acct); // negative: the short's mark
        // cash so that equity == IM exactly (rounded up to the native unit)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 needIm = (im + uint256(-mark) + 1e12 - 1) / 1e12;
        _fund(acct, needIm);
        (IPortfolioRiskManager.HealthState st,,,,) = risk.healthOf(acct);
        assertEq(uint8(st), uint8(IPortfolioRiskManager.HealthState.HEALTHY));
        risk.requireHealthy(acct);

        uint256 acct2 = _account(alice);
        _hold(acct2, c4500, -1e18);
        // forge-lint: disable-next-line(unsafe-typecast)
        _fund(acct2, (mm + uint256(-mark) + 1e12 - 1) / 1e12); // MM ≤ equity < IM
        (st,,,,) = risk.healthOf(acct2);
        assertEq(uint8(st), uint8(IPortfolioRiskManager.HealthState.CLOSE_ONLY));
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct2);
        vm.expectRevert(abi.encodeWithSelector(NotHealthy.selector, r.equity, r.initialMargin));
        risk.requireHealthy(acct2);

        uint256 acct3 = _account(alice);
        _hold(acct3, c4500, -1e18);
        _fund(acct3, 100e6); // equity < MM
        (st,,,,) = risk.healthOf(acct3);
        assertEq(uint8(st), uint8(IPortfolioRiskManager.HealthState.LIQUIDATABLE));
    }

    function test_insolventWhenNothingLeftToLiquidate() public {
        _hold(acct, c4500, -1e18);
        vm.warp(EXP30); // expired, not finalized: no active legs
        _setSpot(ethUsdc, 5000e18); // short is 500 in the money, no cash
        (IPortfolioRiskManager.HealthState st, int256 eq,,,) = risk.healthOf(acct);
        assertEq(eq, -500e18);
        assertEq(uint8(st), uint8(IPortfolioRiskManager.HealthState.INSOLVENT));
    }

    // ------------------------------------------------------------------ MRG-004: buckets don't offset

    function test_MRG004_differentUnderlyingsDontOffset() public {
        _setSpot(btcUsdc, 90_000e18);
        uint256[] memory k = new uint256[](1);
        uint256[] memory iv = new uint256[](1);
        (k[0], iv[0]) = (90_000e18, 0.5e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        _setSurface(btcUsdc, 90_000e18, k, iv, tenors);
        bytes32 btcCall = _series(btcUsdc, OptionType.CALL, 90_000e18, EXP30);

        uint256 ethOnly = _account(alice);
        _hold(ethOnly, c4500, -1e18);
        uint256 btcOnly = _account(alice);
        _hold(btcOnly, btcCall, 1e18); // long BTC call would offset a short ETH call if buckets were merged
        _hold(acct, c4500, -1e18);
        _hold(acct, btcCall, 1e18);
        (uint256 imE, uint256 mmE) = risk.marginOf(ethOnly);
        (uint256 imB, uint256 mmB) = risk.marginOf(btcOnly);
        (uint256 im, uint256 mm) = risk.marginOf(acct);
        assertEq(im, imE + imB);
        assertEq(mm, mmE + mmB);
        assertEq(risk.equityOf(acct), risk.equityOf(ethOnly) + risk.equityOf(btcOnly));
    }

    // ------------------------------------------------------------------ MRG-008: expired and finalized legs

    function test_MRG008_expiredUnfinalizedIsIntrinsicWithSpotShocks() public {
        _hold(acct, c4500, -1e18);
        vm.warp(EXP30);
        _setSpot(ethUsdc, 4600e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertEq(r.equity, -100e18, "intrinsic at live spot");
        // worst MM scenario: spot +50% → 6900 → loss 2400 − 100 = 2300
        assertEq(r.maintenanceMargin, 2300e18);
        // IM: spot +100% → 9200 → loss 4600; buffer 5% of the 100 mark = 5
        assertEq(r.initialMargin, 4605e18);
        assertTrue(r.fresh, "no surface needed once expired");
    }

    function test_MRG008_finalizedIsExactWithoutScenarios() public {
        _hold(acct, c4500, -1e18);
        _hold(acct, p3500, 2e18);
        vm.warp(EXP30 + 1 hours);
        settlementState.finalize(registry.groupOf(c4500), 4700e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertEq(r.equity, -200e18, "exact payoff: short call 200 ITM, puts worthless");
        assertEq(r.maintenanceMargin, 0);
        assertEq(r.initialMargin, 10e18, "buffer on the short's fixed value only");
        // no oracle data needed at all once finalized
        vm.warp(EXP30 + 30 days);
        risk.riskOf(acct);
    }

    // ------------------------------------------------------------------ freshness modes

    function test_strictModeNeedsFreshSpotAndSurface() public {
        _hold(acct, c4500, -1e18);
        _fund(acct, 10_000e6);
        risk.requireHealthy(acct);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, ethUsdc, uint64(61)));
        risk.requireHealthy(acct);
        _setSpot(ethUsdc, 4000e18);
        vm.warp(T0 + 301);
        _setSpot(ethUsdc, 4000e18);
        vm.expectRevert(abi.encodeWithSelector(StaleSurface.selector, ethUsdc, uint64(301)));
        risk.requireHealthy(acct);
        assertFalse(risk.riskOf(acct).fresh, "VIEW reports staleness instead of reverting");
    }

    function test_liquidationModeAcceptsStaleSurfaceUpToMax() public {
        _hold(acct, c4500, -1e18);
        vm.warp(T0 + 3600);
        _setSpot(ethUsdc, 4000e18);
        IPortfolioRiskManager.Risk memory stale = risk.riskForLiquidation(acct);
        assertFalse(stale.fresh);
        vm.warp(T0 + 21_601);
        _setSpot(ethUsdc, 4000e18);
        vm.expectRevert(abi.encodeWithSelector(StaleSurface.selector, ethUsdc, uint64(21_601)));
        risk.riskForLiquidation(acct);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, ethUsdc, uint64(61)));
        risk.riskForLiquidation(acct);
    }

    function test_INV16_stalePenaltyRaisesShortsAndLowersLongs() public {
        uint256 shortAcct = _account(alice);
        _hold(shortAcct, c4500, -1e18);
        _hold(acct, c4500, 1e18);
        int256 shortFresh = risk.equityOf(shortAcct);
        int256 longFresh = risk.equityOf(acct);
        (uint256 imFresh,) = risk.marginOf(shortAcct);
        vm.warp(T0 + 300 + 1 hours); // one hour stale: ±10 vol points
        _setSpot(ethUsdc, 4000e18);
        assertLt(risk.equityOf(shortAcct), shortFresh, "short liability rises");
        assertLt(risk.equityOf(acct), longFresh, "long value falls");
        // IM alone can fall (the worst scenario is deep in the money, where IV barely matters); health must fall
        (uint256 imStale,) = risk.marginOf(shortAcct);
        assertLt(
            risk.equityOf(shortAcct) - int256(imStale), shortFresh - int256(imFresh), "health of the short worsens"
        );
        (uint256 s, uint256 sShort, uint256 sLong) = risk.ivOf(c4500);
        assertApproxEqAbs(sShort, s + 0.1e18, 1e9);
        assertApproxEqAbs(sLong, s - 0.1e18, 1e9);
    }

    function test_longsAtIntrinsicAfterMaxLongTimeValueStale() public {
        _hold(acct, c4500, 1e18);
        vm.warp(T0 + 1801);
        _setSpot(ethUsdc, 4000e18);
        assertEq(risk.equityOf(acct), 0, "OTM long worth intrinsic (0) on a very stale surface");
        (uint256 mid, uint256 shortPrice, uint256 longPrice) = risk.priceOf(c4500);
        assertGt(mid, 0);
        assertGt(shortPrice, mid);
        assertEq(longPrice, 0);
    }

    function test_missingLeafAndUnpriceableSeries() public {
        // a strike between nodes needs leaves not yet proven on a fresh report
        _setSpot(ethUsdc, 4000e18);
        bytes32 c4700 = _series(ethUsdc, OptionType.CALL, 4700e18, EXP30);
        _hold(acct, c4700, -1e18);
        risk.riskOf(acct); // all leaves proven: fine
        bytes32 far = _series(ethUsdc, OptionType.CALL, 4500e18, T0 + 90 days); // beyond the last tenor
        _hold(acct, far, -1e18);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotPriceable.selector, far));
        risk.riskOf(acct);
    }

    function test_missingSurfaceNodeReverts() public {
        // a new report whose leaves are not proven yet
        _hold(acct, c4500, -1e18);
        vm.warp(T0 + 10);
        _setSpot(ethUsdc, 4000e18);
        IVolSurfaceOracle.SurfaceReport memory r;
        r.chainId = block.chainid;
        r.verifyingContract = address(surface);
        r.productId = ethUsdc;
        r.underlying = weth;
        r.settlementAsset = address(usdc);
        r.surfaceSeq = ++seq[ethUsdc];
        r.validAfter = uint64(block.timestamp);
        r.expiresAt = r.validAfter + 900;
        r.kNodes = new int256[](1);
        r.tenorTimestamps[0] = EXP30;
        r.tenorTimestamps[1] = T0 + 60 days;
        r.atmTotalVarianceByTenor[0] = 0.0295e18;
        r.atmTotalVarianceByTenor[1] = 0.059e18;
        r.surfaceMinIvBps = 1000;
        r.surfaceMaxIvBps = 50_000;
        r.surfaceRoot = keccak256("root");
        surface.submitReport(r, _signAB(r));
        vm.expectRevert(abi.encodeWithSelector(MissingSurfaceNode.selector, ethUsdc, uint8(0), uint8(0)));
        risk.riskOf(acct);
    }

    // ------------------------------------------------------------------ close-only and open interest

    function test_productCloseOnlyCauses() public {
        assertFalse(risk.isProductCloseOnly(ethUsdc));
        vm.prank(guardian);
        pc.setProductCloseOnly(ethUsdc, true);
        assertTrue(risk.isProductCloseOnly(ethUsdc), "manual flag");
        vm.prank(governance);
        pc.setProductCloseOnly(ethUsdc, false);

        vm.prank(guardian);
        surface.setEmergencyMode(ethUsdc, true);
        assertTrue(risk.isProductCloseOnly(ethUsdc), "emergency mode");
        vm.prank(governance);
        surface.setEmergencyMode(ethUsdc, false);

        reserves.setHealthy(address(usdc), false);
        assertTrue(risk.isProductCloseOnly(ethUsdc), "reserves below minimum");
        reserves.setHealthy(address(usdc), true);

        vm.warp(T0 + 21_601);
        assertTrue(risk.isProductCloseOnly(ethUsdc), "surface data expired");
        assertTrue(risk.isProductCloseOnly(btcUsdc), "no surface at all");
    }

    function test_lowConfidenceSurfaceIsCloseOnly() public {
        vm.warp(T0 + 5);
        uint256[] memory k = new uint256[](1);
        uint256[] memory iv = new uint256[](1);
        (k[0], iv[0]) = (4000e18, 0.6e18);
        uint64[] memory tenors = new uint64[](1);
        tenors[0] = EXP30;
        vm.prank(governance);
        IVolSurfaceOracle.SurfaceConfig memory c = _surfaceConfig();
        c.maxConfidenceBps = 50; // the fixture's reports carry 100
        surface.setSurfaceConfig(ethUsdc, c);
        _setSurface(ethUsdc, 4000e18, k, iv, tenors);
        assertTrue(risk.isProductCloseOnly(ethUsdc));
    }

    function test_checkOpenRisk() public {
        risk.checkOpenRisk(c4500, true);
        vm.prank(guardian);
        pc.setProductCloseOnly(ethUsdc, true);
        vm.expectRevert(abi.encodeWithSelector(ProductCloseOnly.selector, ethUsdc));
        risk.checkOpenRisk(c4500, false);
        vm.prank(governance);
        pc.setProductCloseOnly(ethUsdc, false);
        vm.warp(EXP30);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotActive.selector, c4500));
        risk.checkOpenRisk(c4500, false);
    }

    function test_INV42_openInterestCaps() public {
        vm.prank(riskAdmin);
        risk.setOpenInterestCap(RISK_SET, 2e18);
        _hold(acct, c4500, -2e18);
        risk.checkOpenRisk(c4500, true);
        uint256 b = _account(alice);
        _hold(b, c4500, -1e18); // 3 short in total
        vm.expectRevert(abi.encodeWithSelector(OpenInterestCap.selector, c4500));
        risk.checkOpenRisk(c4500, true);
        risk.checkOpenRisk(c4500, false); // wrap-type checks ignore caps

        vm.prank(governance);
        risk.setOpenInterestCap(RISK_SET, 1e24);
        vm.prank(riskAdmin);
        risk.setProductShortCap(ethUsdc, 3e18); // 3 underlying units
        risk.checkOpenRisk(c4500, true);
        _hold(b, p3500, -1e18);
        vm.expectRevert(abi.encodeWithSelector(OpenInterestCap.selector, ethUsdc));
        risk.checkOpenRisk(p3500, true);
    }

    // ------------------------------------------------------------------ previews

    function test_previewWithDeltaMatchesExecution() public {
        _fund(acct, 5000e6);
        IPortfolioRiskManager.Risk memory p = risk.previewWithDelta(acct, c5000, 1e18, -100e6);
        _hold(acct, c5000, 1e18);
        vm.prank(clearing);
        ledger.subCash(acct, 100e6);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertEq(p.equity, r.equity);
        assertEq(p.initialMargin, r.initialMargin);
        assertEq(p.maintenanceMargin, r.maintenanceMargin);
        // a delta on a held series too
        p = risk.previewWithDelta(acct, c5000, -1e18, 0);
        assertEq(p.initialMargin, 0, "flat again");
    }

    /// @dev Several deltas at once equal executing them: held and new series, repeated ids (which add up), zero
    ///      entries (ignored).
    function test_previewWithDeltasMatchesExecution() public {
        _fund(acct, 20_000e6);
        _hold(acct, c4500, -2e18);
        bytes32[] memory ids = new bytes32[](5);
        int256[] memory qs = new int256[](5);
        (ids[0], qs[0]) = (c4500, 1e18); // held
        (ids[1], qs[1]) = (c5000, 1e18); // new
        (ids[2], qs[2]) = (c5000, 0.5e18); // the same new series again
        (ids[3], qs[3]) = (p3500, 0); // ignored
        (ids[4], qs[4]) = (bytes32(0), 1e18); // ignored
        IPortfolioRiskManager.Risk memory p = risk.previewWithDeltas(acct, ids, qs, -100e6);
        _hold(acct, c4500, 1e18);
        _hold(acct, c5000, 1.5e18);
        vm.prank(clearing);
        ledger.subCash(acct, 100e6);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertEq(p.equity, r.equity);
        assertEq(p.initialMargin, r.initialMargin);
        assertEq(p.maintenanceMargin, r.maintenanceMargin);

        vm.expectRevert(LengthMismatch.selector);
        risk.previewWithDeltas(acct, ids, new int256[](4), 0);
    }

    function test_previewWithdrawAndMaxWithdrawable() public {
        _hold(acct, c4500, -1e18);
        _fund(acct, 4000e6);
        uint256 max = risk.maxWithdrawable(acct);
        (,, bool okMax) = risk.previewWithdraw(acct, max);
        assertTrue(okMax);
        (,, bool okMore) = risk.previewWithdraw(acct, max + 1);
        assertFalse(okMore);
        // withdrawing exactly the max leaves the account healthy
        vm.prank(clearing);
        ledger.subCash(acct, max);
        risk.requireHealthy(acct);
        assertEq(risk.maxWithdrawable(acct), 0);
        (,, bool okCash) = risk.previewWithdraw(acct, 1e18); // more than the cash
        assertFalse(okCash);
    }

    function test_maxWithdrawableCappedByCash() public {
        _fund(acct, 10e6);
        _hold(acct, c4500, 1e18); // a long adds equity but isn't withdrawable cash
        assertEq(risk.maxWithdrawable(acct), 10e6);
    }

    function test_previewWrap() public {
        _hold(acct, c5000, 1e18);
        _hold(acct, c4500, -1e18);
        _fund(acct, 600e6);
        (,, bool ok) = risk.previewWrap(acct, c5000, 1e18); // the hedge leaves: naked call needs ~3,525
        assertFalse(ok);
        (,, ok) = risk.previewWrap(acct, c5000, 2e18); // more than held
        assertFalse(ok);
        _fund(acct, 4000e6);
        (,, ok) = risk.previewWrap(acct, c5000, 1e18);
        assertTrue(ok);
    }

    function test_pricesOfExpiredAndFinalizedSeries() public {
        vm.warp(EXP30);
        _setSpot(ethUsdc, 4600e18);
        (uint256 mid, uint256 s, uint256 l) = risk.priceOf(c4500);
        assertEq(mid, 100e18);
        assertEq(s, 100e18);
        assertEq(l, 100e18);
        settlementState.finalize(registry.groupOf(c4500), 4700e18);
        (mid,,) = risk.priceOf(c4500);
        assertEq(mid, 200e18);
    }

    // ------------------------------------------------------------------ MRG-012: risk sets

    function test_MRG012_riskSetLifecycle() public {
        IPortfolioRiskManager.RiskParams memory p = _defaultRiskParams();
        bytes32 id = keccak256("new set");
        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        risk.createRiskSet(id, p);
        vm.startPrank(governance);
        vm.expectEmit(true, true, true, true, address(risk));
        emit IPortfolioRiskManager.RiskSetCreated(id, p);
        risk.createRiskSet(id, p);
        vm.expectRevert(abi.encodeWithSelector(RiskSetExists.selector, id));
        risk.createRiskSet(id, p);
        p.imBufferBps = 100; // less conservative: governance only
        risk.updateRiskSet(id, p);
        vm.stopPrank();
        (IPortfolioRiskManager.RiskParams memory got, bool enabled) = risk.getRiskSet(id);
        assertEq(got.imBufferBps, 100);
        assertTrue(enabled);

        vm.startPrank(riskAdmin); // conservative changes are instant for the risk admin
        risk.raiseImBuffer(id, 700);
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 7));
        risk.raiseImBuffer(id, 600); // not an increase
        risk.raiseMinIv(id, 0.2e18);
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 7));
        risk.raiseMinIv(id, 0.1e18);
        IPortfolioRiskManager.Scenario[] memory add = new IPortfolioRiskManager.Scenario[](1);
        add[0] = IPortfolioRiskManager.Scenario(-9000, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 5)); // initial set already 24
        risk.addScenarios(id, add, new IPortfolioRiskManager.Scenario[](0));
        risk.addScenarios(id, new IPortfolioRiskManager.Scenario[](0), add);
        risk.setOpenInterestCap(id, 1e20); // lowering
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        risk.setOpenInterestCap(id, 1e21); // raising needs governance
        risk.setRiskSetEnabled(id, false);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        risk.setRiskSetEnabled(id, true);
        vm.stopPrank();
        (got, enabled) = risk.getRiskSet(id);
        assertEq(got.imBufferBps, 700);
        assertEq(got.minIv, 0.2e18);
        assertEq(got.maintenanceSet.length, 13);
        assertEq(got.maxOpenInterestPerSeries, 1e20);
        assertFalse(enabled);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        risk.raiseImBuffer(id, 800);
        vm.expectRevert(abi.encodeWithSelector(UnknownRiskSet.selector, keccak256("nope")));
        risk.getRiskSet(keccak256("nope"));
    }

    function test_MRG012_validation() public {
        vm.startPrank(governance);
        IPortfolioRiskManager.RiskParams memory p = _defaultRiskParams();
        p.imBufferBps = 5001;
        _expectParams(p, 1);
        p = _defaultRiskParams();
        p.minIv = 0;
        _expectParams(p, 2);
        p = _defaultRiskParams();
        p.maxIv = p.minIv;
        _expectParams(p, 2);
        p = _defaultRiskParams();
        p.maxIv = 10e18 + 1;
        _expectParams(p, 2);
        p = _defaultRiskParams();
        p.nearExpiryFloorSeconds = 1 days + 1;
        _expectParams(p, 3);
        p = _defaultRiskParams();
        p.maxOpenInterestPerSeries = 0;
        _expectParams(p, 4);
        p.maxOpenInterestPerSeries = 1e24 + 1;
        _expectParams(p, 4);
        p = _defaultRiskParams();
        p.maintenanceSet = new IPortfolioRiskManager.Scenario[](0);
        _expectParams(p, 5);
        p = _defaultRiskParams();
        p.initialSet = new IPortfolioRiskManager.Scenario[](25);
        _expectParams(p, 5);
        p = _defaultRiskParams();
        p.maintenanceSet[0].spotShockBps = -10_001;
        _expectParams(p, 6);
        p = _defaultRiskParams();
        p.maintenanceSet[0].timeMode = 3;
        _expectParams(p, 6);
        p = _defaultRiskParams();
        p.maintenanceSet[0].timeShiftSeconds = 60; // shift only with timeMode 2
        _expectParams(p, 6);
        vm.stopPrank();
    }

    function _expectParams(IPortfolioRiskManager.RiskParams memory p, uint8 reason) internal {
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, reason));
        risk.createRiskSet(keccak256(abi.encode(reason, p.imBufferBps)), p);
    }

    function test_productRiskSetAssignment() public {
        assertEq(risk.productRiskSet(ethUsdc), RISK_SET);
        assertTrue(risk.isRiskSetForProduct(ethUsdc, RISK_SET));
        assertFalse(risk.isRiskSetForProduct(ethUsdc, keccak256("other")));
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(RiskSetAlreadyAssigned.selector, ethUsdc));
        risk.assignProductRiskSet(ethUsdc, RISK_SET);
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 8));
        risk.assignProductRiskSet(keccak256("unknown product"), RISK_SET);
        vm.expectRevert(abi.encodeWithSelector(UnknownRiskSet.selector, keccak256("x")));
        risk.assignProductRiskSet(keccak256("unknown product"), keccak256("x"));
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 8));
        risk.setProductShortCap(keccak256("unknown product"), 1);
        vm.stopPrank();
        // the registry rejects a series whose risk set is not its product's
        vm.prank(guardian);
        risk.setRiskSetEnabled(RISK_SET, false);
        assertFalse(risk.isRiskSetForProduct(ethUsdc, RISK_SET));
    }

    function test_productShortCapPermissions() public {
        vm.prank(riskAdmin);
        risk.setProductShortCap(ethUsdc, 1e18);
        assertEq(risk.productShortCap(ethUsdc), 1e18);
        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        risk.setProductShortCap(ethUsdc, 2e18);
        vm.prank(governance);
        risk.setProductShortCap(ethUsdc, 2e18);
    }

    // ------------------------------------------------------------------ remaining branches

    function test_addScenariosToBothSetsAndOpenInterestBounds() public {
        bytes32 id = keccak256("small set");
        IPortfolioRiskManager.RiskParams memory p = _defaultRiskParams();
        p.initialSet = new IPortfolioRiskManager.Scenario[](1);
        p.initialSet[0] = IPortfolioRiskManager.Scenario(10_000, 0, 0, 0);
        vm.prank(governance);
        risk.createRiskSet(id, p);
        IPortfolioRiskManager.Scenario[] memory add = new IPortfolioRiskManager.Scenario[](1);
        add[0] = IPortfolioRiskManager.Scenario(0, 0, 2, 7 days); // time shift
        vm.prank(riskAdmin);
        risk.addScenarios(id, add, add);
        (IPortfolioRiskManager.RiskParams memory got,) = risk.getRiskSet(id);
        assertEq(got.initialSet.length, 2);
        assertEq(got.initialSet[1].timeShiftSeconds, 7 days);
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 4));
        risk.setOpenInterestCap(id, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidRiskParams.selector, 4));
        risk.setOpenInterestCap(id, 1e24 + 1);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        risk.setRiskSetEnabled(id, false);
        vm.prank(guardian);
        risk.setRiskSetEnabled(id, false);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UnknownRiskSet.selector, id));
        risk.assignProductRiskSet(keccak256("some product"), id); // disabled sets can't be assigned
    }

    function test_mixedLiveAndExpiredLegsInOneBucket() public {
        bytes32 later = _series(ethUsdc, OptionType.CALL, 4500e18, T0 + 45 days);
        _hold(acct, c4500, -1e18);
        _hold(acct, later, 1e18);
        vm.warp(EXP30 + 10); // c4500 expired, not finalized; `later` still live
        _setSpot(ethUsdc, 4600e18);
        uint256[] memory k = new uint256[](1);
        uint256[] memory iv = new uint256[](1);
        (k[0], iv[0]) = (4500e18, 0.6e18);
        uint64[] memory tenors = new uint64[](1);
        tenors[0] = T0 + 45 days;
        _setSurface(ethUsdc, 4600e18, k, iv, tenors); // fresh surface, so the long keeps its time value
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertTrue(r.fresh);
        (uint256 midLater,,) = risk.priceOf(later);
        assertApproxEqAbs(r.equity, int256(midLater) - 100e18, 1e9, "intrinsic short + live long");
        assertGt(r.initialMargin, 0);
    }

    function test_ivClampedToRiskSetBounds() public {
        _hold(acct, c4500, -1e18);
        vm.prank(riskAdmin);
        risk.raiseMinIv(RISK_SET, 0.7e18); // surface says 60%
        (uint256 s,,) = risk.ivOf(c4500);
        assertEq(s, 0.7e18);
        int256 eqFloor = risk.equityOf(acct);
        IPortfolioRiskManager.RiskParams memory p = _defaultRiskParams();
        p.maxIv = 0.5e18; // below the surface's 60%: clamps base IV and every +vol scenario
        vm.prank(governance);
        risk.updateRiskSet(RISK_SET, p);
        (s,,) = risk.ivOf(c4500);
        assertEq(s, 0.5e18);
        assertGt(risk.equityOf(acct), eqFloor, "a lower IV lowers the short's liability");
        risk.riskOf(acct);
    }

    function test_timeShiftAndNearExpiryScenarios() public {
        IPortfolioRiskManager.RiskParams memory p = _defaultRiskParams();
        p.maintenanceSet = new IPortfolioRiskManager.Scenario[](2);
        p.maintenanceSet[0] = IPortfolioRiskManager.Scenario(2000, 0, 2, 1 days);
        p.maintenanceSet[1] = IPortfolioRiskManager.Scenario(0, 0, 2, 365 days); // shift past expiry: T = 0
        vm.prank(governance);
        risk.updateRiskSet(RISK_SET, p);
        _hold(acct, c4500, -1e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertGt(r.maintenanceMargin, 0);
        // a leg already inside the near-expiry floor keeps its own (shorter) time
        vm.warp(EXP30 - 30 minutes);
        _setSpot(ethUsdc, 4000e18);
        uint256[] memory k = new uint256[](1);
        uint256[] memory iv = new uint256[](1);
        (k[0], iv[0]) = (4500e18, 0.6e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        _setSurface(ethUsdc, 4000e18, k, iv, tenors);
        risk.riskOf(acct);
    }

    function test_viewModeMissingData() public {
        bytes32 btcCall = _series(btcUsdc, OptionType.CALL, 90_000e18, EXP30);
        uint256 b = _account(alice);
        _hold(b, btcCall, -1e18);
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, btcUsdc, type(uint64).max));
        risk.riskOf(b); // never had a spot price
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, btcUsdc, type(uint64).max));
        risk.ivOf(btcCall);
        _setSpot(btcUsdc, 90_000e18);
        vm.expectRevert(abi.encodeWithSelector(StaleSurface.selector, btcUsdc, type(uint64).max));
        risk.riskOf(b); // no surface at all

        _hold(acct, c4500, -1e18);
        vm.warp(block.timestamp + 61);
        assertFalse(risk.riskOf(acct).fresh, "stale spot reported, not reverted, in VIEW");
    }

    function test_ivOfErrors() public {
        bytes32 far = _series(ethUsdc, OptionType.CALL, 4500e18, T0 + 90 days);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotPriceable.selector, bytes32(0)));
        risk.ivOf(far);
        // a new report without proven leaves
        vm.warp(T0 + 10);
        _setSpot(ethUsdc, 4000e18);
        IVolSurfaceOracle.SurfaceReport memory r;
        r.chainId = block.chainid;
        r.verifyingContract = address(surface);
        r.productId = ethUsdc;
        r.underlying = weth;
        r.settlementAsset = address(usdc);
        r.surfaceSeq = ++seq[ethUsdc];
        r.validAfter = uint64(block.timestamp);
        r.expiresAt = r.validAfter + 900;
        r.kNodes = new int256[](1);
        r.tenorTimestamps[0] = EXP30;
        r.atmTotalVarianceByTenor[0] = 0.0295e18;
        r.surfaceMinIvBps = 1000;
        r.surfaceMaxIvBps = 50_000;
        r.surfaceRoot = keccak256("root");
        surface.submitReport(r, _signAB(r));
        vm.expectRevert(abi.encodeWithSelector(MissingSurfaceNode.selector, ethUsdc, uint8(0), uint8(0)));
        risk.ivOf(c4500);
    }

    // ------------------------------------------------------------------ pinned reference portfolios
    // Values from reference/pm_model.account_risk with the NR CDF on the same market. Each portfolio makes one
    // margin rule decisive, so dropping that rule changes IM by about 1 USDC or more.

    uint256 internal constant PIN = 1e9; // 1e-9 USDC: fixed-point vs double precision

    function test_MRG006_unionDecidesIm_calendar() public {
        // long 3 × 5,000 call (30 d), short 1 × 5,000 call (45 d): an MM scenario (+30% vol) is the worst case
        bytes32 c5000_45 = _series(ethUsdc, OptionType.CALL, 5000e18, T0 + 45 days);
        _hold(acct, c5000, 3e18);
        _hold(acct, c5000_45, -1e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.equity, int256(41.93464052765347e18), PIN, "equity");
        assertApproxEqAbs(r.initialMargin, 48.58197073101376e18, PIN, "IM (without the union: 47.61)");
        assertApproxEqAbs(r.maintenanceMargin, 44.730515525752544e18, PIN, "MM");
    }

    function test_nearExpiryScenarioDecidesIm() public {
        _hold(acct, _series(ethUsdc, OptionType.PUT, 3000e18, T0 + 45 days), 2e18);
        _hold(acct, _series(ethUsdc, OptionType.CALL, 3000e18, EXP30), 3e18);
        _hold(acct, _series(ethUsdc, OptionType.CALL, 3500e18, T0 + 45 days), -1e18);
        _hold(acct, _series(ethUsdc, OptionType.PUT, 6000e18, T0 + 45 days), -2e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.equity, -1543.842547879346e18, PIN, "equity");
        assertApproxEqAbs(r.initialMargin, 4689.803024904668e18, PIN, "IM (without near-expiry scenarios: ~1.6 less)");
        assertApproxEqAbs(r.maintenanceMargin, 4057.3408068605686e18, PIN, "MM");
    }

    function test_scenarioIvCapDecidesIm() public {
        IPortfolioRiskManager.RiskParams memory p = _defaultRiskParams();
        p.maxIv = 0.9e18; // +75% of 60% = 105%, capped at 90%
        vm.prank(governance);
        risk.updateRiskSet(RISK_SET, p);
        _hold(acct, c4500, -1e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.initialMargin, 3405.4635535564744e18, PIN, "IM (uncapped: 3,417.78)");
        assertApproxEqAbs(r.maintenanceMargin, 1447.4317176611166e18, PIN, "MM");
    }

    function test_nearExpiryScenarioDecidesIm_longPremium() public {
        // longs lose their time value in the near-expiry scenarios: they add 2,938.57 to IM here
        _hold(acct, _series(ethUsdc, OptionType.CALL, 4000e18, T0 + 45 days), 2e18);
        _hold(acct, _series(ethUsdc, OptionType.PUT, 6000e18, T0 + 45 days), 6e18);
        _hold(acct, _series(ethUsdc, OptionType.PUT, 6000e18, EXP30), 3e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertApproxEqAbs(r.equity, int256(18_785.443082289778e18), PIN * 10, "equity");
        assertApproxEqAbs(r.initialMargin, 14_642.737700528425e18, PIN * 10, "IM (scenarios at today's time: ~11,704)");
        assertApproxEqAbs(r.maintenanceMargin, 11_704.16297933862e18, PIN * 10, "MM");
    }

    function test_MRG009_walletWrappersGiveNoMarginCredit() public {
        _hold(acct, c4500, -1e18);
        IPortfolioRiskManager.Risk memory before = risk.riskOf(acct);
        // the owner holds 1 wrapper of the same series in the wallet (outside Optara)
        address w = registry.getSeries(c4500).wrapper;
        vm.prank(clearing);
        ExternalOptionWrapper(w).mint(alice, 1e18);
        IPortfolioRiskManager.Risk memory afterMint = risk.riskOf(acct);
        assertEq(afterMint.equity, before.equity);
        assertEq(afterMint.initialMargin, before.initialMargin);
        assertEq(afterMint.maintenanceMargin, before.maintenanceMargin);
    }
}
