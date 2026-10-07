// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {E2EBase} from "./E2EBase.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";
import {StaleSurface, ProductCloseOnly, RatioNotSet} from "../../src/libraries/Errors.sol";

/// @notice E2E-001..E2E-004 (TEST_CASES.md) covering USER_FLOWS.md F1–F19 on the production deployment.
contract LifecycleE2ETest is E2EBase {
    uint256 internal a; // alice's account
    uint256 internal b; // bob's account

    function setUp() public override {
        super.setUp();
        a = _account(alice);
        b = _account(bob);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Expiry price `px`: the round in force at expiry and its successor, then the finalize window opens.
    function _expireAt(uint256 px) internal returns (bytes memory proof) {
        vm.warp(EXP30 - 30);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 inForce = ethFeed.pushRound(int256(px / 1e10), EXP30 - 30);
        vm.warp(EXP30 + 60);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 next = ethFeed.pushRound(int256(px / 1e10), EXP30 + 60);
        vm.warp(EXP30 + 300);
        return _proof(inForce, next);
    }

    function _approveRouter(address who, bytes32 seriesId) internal {
        IERC20 w = IERC20(_wrapper(seriesId));
        vm.startPrank(who);
        w.approve(address(d.router), type(uint256).max);
        usdc.approve(address(d.router), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ E2E-001: F1 → F2 → F9 → F13, ratio 1

    function test_E2E001_fullLifecycle() public {
        _e2e001WriteAndSell();
        _e2e001BuyHedgeAndClose();
        _e2e001Expiry();
    }

    /// @dev F1 → F2 → F3: deposit, preview, mint, sell on Kuru, deposit the premium.
    function _e2e001WriteAndSell() internal {
        _deposit(a, alice, 4000e6);
        d.clearing.updateOracles(_update());
        (uint256 fee, int256 eqAfter, uint256 imAfter, bool ok) = d.clearing.previewMint(a, c4500, 1e18);
        assertTrue(ok);
        assertApproxEqAbs(fee, 3.2e6, 0.01e6, "USER_FLOWS F2: fee about 3.20");
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c4500, 1e18, alice, fee, _empty());
        assertEq(d.risk.riskOf(a).equity, eqAfter, "PRV-001");
        assertEq(d.risk.riskOf(a).initialMargin, imAfter, "PRV-001");
        MockKuruBookLike(address(books[c4500])).setBid(1_000_000, 1e16);
        usdc.mint(address(books[c4500]), 100e6);
        _approveRouter(alice, c4500);
        vm.prank(alice);
        (, uint256 proceeds,) = d.router.sellThroughVenue(_sellOrder(c4500, 1e18, 99e6, alice), "");
        assertEq(proceeds, 99.7e6, "premium lands in the wallet, net of Kuru's 0.3%");
        int256 h0 = _health(a);
        _depositFromWallet(a, alice, proceeds);
        assertEq(_health(a) - h0, int256(proceeds) * 1e12, "F3: equity rises by the premium");
    }

    /// @dev F9 → F17 → F4/F11 → F6 → F5 → F7.
    function _e2e001BuyHedgeAndClose() internal {
        // F9: the maker re-offers the wrapper at 110; carol buys through the router (exact-in)
        MockKuruBookLike(address(books[c4500])).setAsk(1_100_000, 1e16);
        usdc.mint(carol, 200e6);
        _approveRouter(carol, c4500);
        vm.prank(carol);
        (uint256 bought, uint256 spent, uint256 buyerFee,) =
            d.router.buyThroughVenue(_buyOrder(c4500, 110e6, 0.99e18, carol), "");
        assertEq(bought, 0.997e18);
        assertEq(spent, 110e6);
        assertEq(buyerFee, 3.3e6, "Optara's 3%, shown separately from Kuru's fee");

        // F17 + F4/F11: bob writes a 5000 call and hands the wrapper to alice OTC; she unwraps it as a hedge
        _deposit(b, bob, 4000e6);
        OracleUpdate memory u0 = _update(); // built before the prank (it makes external calls)
        vm.prank(bob);
        d.clearing.mintExternalLong(b, c5000, 1e18, bob, type(uint256).max, u0);
        IERC20 y = IERC20(_wrapper(c5000));
        vm.prank(bob);
        assertTrue(y.transfer(alice, 1e18));
        uint256 imNaked = d.risk.riskOf(a).initialMargin;
        vm.prank(alice);
        d.clearing.unwrapLong(a, c5000, 1e18);
        assertLt(d.risk.riskOf(a).initialMargin * 5, imNaked, "F4: a spread needs a fraction of the naked margin");

        // F6: withdraw part of the freed margin
        uint256 maxW = d.risk.maxWithdrawable(a);
        OracleUpdate memory u1 = _update(); // built before the prank (it makes external calls)
        vm.prank(alice);
        d.clearing.withdrawCollateral(a, maxW / 2, alice, u1);

        // F5: carol sells half her wrapper back to alice OTC; alice closes half her short with it
        IERC20 x = IERC20(_wrapper(c4500));
        vm.prank(carol);
        assertTrue(x.transfer(alice, 0.5e18));
        vm.prank(alice);
        d.clearing.closeShortWithWrapper(a, c4500, 0.5e18);
        assertEq(d.ledger.balanceOf(a, c4500), -0.5e18);

        // F7: alice wraps half her long 5000 and sells it into a 5000 bid
        OracleUpdate memory u2 = _update(); // built before the prank (it makes external calls)
        vm.prank(alice);
        d.clearing.wrapLong(a, c5000, 0.5e18, alice, u2);
        MockKuruBookLike(address(books[c5000])).setBid(500_000, 0.5e16);
        usdc.mint(address(books[c5000]), 25e6);
        _approveRouter(alice, c5000);
        vm.prank(alice);
        d.router.sellThroughVenue(_sellOrder(c5000, 0.5e18, 0, alice), "");
    }

    /// @dev F10 + F13: expiry at 5,200, finalize, settle everyone, ratio 1, redeem, sweep.
    function _e2e001Expiry() internal {
        bytes memory proof = _expireAt(5200e18);
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        d.window.finalizeGroup(group30, proof);
        uint256[] memory accts = new uint256[](2);
        (accts[0], accts[1]) = (a, b);
        vm.prank(keeper);
        d.window.settleAccountsGroup(accts, group30);
        assertGt(usdc.balanceOf(keeper), keeperBefore, "keeper rewards paid");
        d.window.computeRecoveryRatio(group30);
        (, uint256 ratio) = d.window.recoveryRatio(group30);
        assertEq(ratio, 1e18, "everyone solvent: ratio exactly 1");

        IERC20 x = IERC20(_wrapper(c4500));
        uint256 carolX = x.balanceOf(carol);
        uint256 before = usdc.balanceOf(carol);
        vm.prank(carol);
        d.window.redeemWrapper(c4500, carolX, carol);
        assertEq(usdc.balanceOf(carol) - before, carolX * 700 / 1e12, "full payoff");
        _redeemAll(address(books[c4500]), c4500);
        _redeemAll(address(books[c5000]), c5000);
        assertEq(uint8(d.window.groupState(group30)), uint8(ISettlementWindow.GroupState.REDEEMABLE));
        d.window.sweepDust(group30);
        _assertCustody(accts);
    }

    // ------------------------------------------------------------------ E2E-002: crash/rally, liquidation, shortfall

    function test_E2E002_rallyLiquidationShortfall() public {
        IERC20 x = IERC20(_wrapper(c4500));
        // alice writes 2 calls with just enough cash, and sells them to carol OTC
        d.clearing.updateOracles(_update());
        (, int256 eqAfter, uint256 imAfter,) = d.clearing.previewMint(a, c4500, 2e18);
        _deposit(a, alice, uint256(int256(imAfter) - eqAfter) / 1e12 + 1e6); // equity after is negative here
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c4500, 2e18, carol, type(uint256).max, _empty());

        // F8: the market rallies; alice falls below maintenance
        _moveTo(6200e18, 0.6e18);
        (IPortfolioRiskManager.HealthState state,,,,) = d.risk.healthOf(a);
        assertEq(uint8(state), uint8(IPortfolioRiskManager.HealthState.LIQUIDATABLE));

        // F12: the keeper starts an auction and takes a slice with its own capital
        uint256 k = _account(keeper);
        _deposit(k, keeper, 50_000e6);
        vm.prank(keeper);
        d.liquidation.startAuction(a, weth, _empty());
        int256 h0 = _health(a);
        vm.prank(keeper);
        d.liquidation.liquidateSlice(a, weth, k, 2500, 0, 0, _empty());
        assertGt(_health(a), h0, "INV-22");
        assertEq(d.ledger.balanceOf(k, c4500), -0.5e18);
        // carol burns half a wrapper against alice's short (wrapper-burn liquidation)
        uint256 cAcct = _account(carol);
        OracleUpdate memory u3 = _update(); // built before the prank (it makes external calls)
        vm.prank(carol);
        d.liquidation.liquidateWithWrapper(a, c4500, 0.5e18, cAcct, 0, u3);
        assertEq(d.ledger.balanceOf(a, c4500), -1e18);

        // F14: expiry far above the strike: alice can't pay; insurance covers part; the ratio falls below 1
        bytes memory proof = _expireAt(12_000e18);
        d.window.finalizeGroup(group30, proof);
        uint256[] memory accts = new uint256[](3);
        (accts[0], accts[1], accts[2]) = (a, k, cAcct);
        d.window.settleAccountsGroup(accts, group30);
        uint256 insuranceBefore = d.insurance.balanceOf(address(usdc));
        d.window.computeRecoveryRatio(group30);
        ISettlementWindow.GroupAccounting memory g = d.window.groupAccounting(group30);
        assertGt(g.unpaid, 0, "alice's debt was not fully collected");
        assertEq(g.insurance, insuranceBefore, "the whole fund went in");
        assertLt(g.ratioWad, 1e18, "shortfall beyond insurance: ratio < 1");

        uint256 carolX = x.balanceOf(carol);
        uint256 before = usdc.balanceOf(carol);
        vm.prank(carol);
        d.window.redeemWrapper(c4500, carolX, carol);
        assertEq(usdc.balanceOf(carol) - before, carolX * 7500 / 1e12 * g.ratioWad / 1e18, "paid at the ratio");
        if (d.window.creditOf(cAcct, group30) != 0) d.window.claimSettlement(cAcct, group30);
        assertLe(d.window.groupAccounting(group30).pool, g.collected + g.insurance, "INV-31");
        _assertCustody(accts);
    }

    // ------------------------------------------------------------------ E2E-003: publisher outage → close-only → recovery

    function test_E2E003_publisherOutage() public {
        _deposit(a, alice, 20_000e6);
        OracleUpdate memory u4 = _update(); // built before the prank (it makes external calls)
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c4500, 1e18, alice, type(uint256).max, u4);

        // F16: no new report for 10 minutes: risk-increasing calls need a fresh surface
        vm.warp(block.timestamp + 600);
        OracleUpdate memory spotOnly = _spotOnly();
        vm.prank(alice);
        vm.expectPartialRevert(StaleSurface.selector);
        d.clearing.mintExternalLong(a, c4500, 0.1e18, alice, type(uint256).max, spotOnly);

        // beyond maxSurfaceStale the product is close-only; risk-reducing actions still work (LIV-1)
        vm.warp(block.timestamp + 6 hours);
        assertTrue(d.risk.isProductCloseOnly(eth));
        OracleUpdate memory freshSpot = _spotOnly(); // built before the prank (it makes external calls)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProductCloseOnly.selector, eth));
        d.clearing.mintExternalLong(a, c4500, 0.1e18, alice, type(uint256).max, freshSpot);
        _depositFromWallet(a, alice, 0);
        vm.prank(alice);
        d.clearing.closeShortWithWrapper(a, c4500, 0.5e18);

        // F19: publishers come back; a fresh signed report restores normal trading
        OracleUpdate memory u5 = _update(); // built before the prank (it makes external calls)
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c4500, 0.5e18, alice, type(uint256).max, u5);
        assertFalse(d.risk.isProductCloseOnly(eth));
        assertEq(d.ledger.balanceOf(a, c4500), -1e18);
    }

    // ------------------------------------------------------------------ E2E-004: oracle stall at expiry → late finalize

    function test_E2E004_oracleStallLateFinalize() public {
        IERC20 x = IERC20(_wrapper(c4500));
        _deposit(a, alice, 20_000e6);
        OracleUpdate memory u6 = _update(); // built before the prank (it makes external calls)
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c4500, 2e18, carol, type(uint256).max, u6);

        // F15: the in-force round exists but no keeper finalizes before the deadline
        bytes memory proof = _expireAt(5000e18);
        vm.warp(EXP30 + 7 days);
        assertEq(uint8(d.window.groupState(group30)), uint8(ISettlementWindow.GroupState.ORACLE_STALLED));
        d.window.flagOracleStalled(group30);
        // nothing is redeemable; closing with wrappers still works
        vm.prank(carol);
        vm.expectRevert(RatioNotSet.selector);
        d.window.redeemWrapper(c4500, 1e18, carol);
        vm.prank(carol);
        assertTrue(x.transfer(alice, 1e18));
        vm.prank(alice);
        d.clearing.closeShortWithWrapper(a, c4500, 1e18);

        // a late keeper proves the authentic historical round; settlement completes normally
        d.window.finalizeGroup(group30, proof);
        uint256[] memory accts = new uint256[](1);
        accts[0] = a;
        d.window.settleAccountsGroup(accts, group30);
        d.window.computeRecoveryRatio(group30);
        vm.prank(carol);
        d.window.redeemWrapper(c4500, 1e18, carol);
        assertEq(usdc.balanceOf(carol), 500e6, "1 x (5,000 - 4,500) at ratio 1");
        d.window.sweepDust(group30);
        _assertCustody(accts);
    }

    // ------------------------------------------------------------------ helpers

    function _depositFromWallet(uint256 accountId, address from, uint256 amount) internal {
        if (amount == 0) {
            _deposit(accountId, from, 1e6); // deposits need no oracle data even while close-only
            return;
        }
        vm.startPrank(from);
        usdc.approve(address(d.clearing), amount);
        d.clearing.depositCollateral(accountId, amount);
        vm.stopPrank();
    }

    function _spotOnly() internal returns (OracleUpdate memory u) {
        u = _update();
        u.reports = new IVolSurfaceOracle.SurfaceReport[](0); // spot only: no new surface
        u.reportSignatures = new bytes[][](0);
        u.nodes = new IVolSurfaceOracle.NodeProof[](0);
    }

    /// @dev A Kuru maker withdraws what it holds of `seriesId` and redeems it.
    function _redeemAll(address holder, bytes32 seriesId) internal {
        uint256 bal = IERC20(_wrapper(seriesId)).balanceOf(holder);
        if (bal == 0) return;
        vm.prank(holder);
        d.window.redeemWrapper(seriesId, bal, holder);
    }
}

interface MockKuruBookLike {
    function setAsk(uint256 price, uint256 size) external;
    function setBid(uint256 price, uint256 size) external;
}
