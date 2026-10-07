// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {E2EBase} from "../e2e/E2EBase.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {MockKuruOrderBook} from "../mocks/MockVenues.sol";
import {ActionPaused} from "../../src/libraries/Errors.sol";

/// @notice The system invariant suite (TESTING.md §5) on the production deployment: 3 writers (one with two
///         accounts), 2 buyers, a liquidator, a keeper and a guardian act at random across clearing, risk,
///         liquidation, settlement, the venue router and pauses, while the market moves and the surface may go
///         stale. Runs start 12 hours before the 30-day group expires, so it expires, settles and pays out within a run.
///         After every call the cross-module invariants hold; handler-level checks (INV-11, 13, 21, 22, 23, 46)
///         count violations.
contract SystemInvariantTest is E2EBase {
    address[3] internal writers;
    uint256[4] internal accts; // writers' accounts; accts[3] is writer 0's second account
    address[2] internal buyers;
    uint256[2] internal buyerAccts;
    uint256 internal liqAcct;
    bytes32[3] internal ids;
    address[] internal everyAccountOwner;
    uint256[] internal everyAccount;

    uint256 public violations;
    uint256 public priceAtFinal;
    uint256 public ratioAtSet;
    bool public ratioSeen;
    mapping(bytes32 => uint256) public calls;

    function setUp() public override {
        super.setUp();
        (writers[0], writers[1], writers[2]) = (alice, bob, makeAddr("dave"));
        (buyers[0], buyers[1]) = (carol, makeAddr("erin"));
        // writers hold about the margin of one naked call, so a shock makes them liquidatable
        for (uint256 i; i < 3; ++i) {
            accts[i] = _track(writers[i]);
            _deposit(accts[i], writers[i], 4_000e6);
        }
        accts[3] = _track(writers[0]);
        _deposit(accts[3], writers[0], 4_000e6);
        for (uint256 i; i < 2; ++i) {
            buyerAccts[i] = _track(buyers[i]);
            _deposit(buyerAccts[i], buyers[i], 5_000e6);
            usdc.mint(buyers[i], 100_000e6);
            _approveAll(buyers[i]);
        }
        for (uint256 i; i < 3; ++i) {
            _approveAll(writers[i]);
        }
        liqAcct = _track(keeper);
        _deposit(liqAcct, keeper, 500_000e6);
        (ids[0], ids[1], ids[2]) = (c4500, c5000, p3500);
        vm.warp(EXP30 - 12 hours); // runs trade, liquidate, then reach expiry, settlement and payouts
        _moveTo(4000e18, 0.6e18);

        bytes4[] memory sel = new bytes4[](21);
        sel[0] = this.h_deposit.selector;
        sel[1] = this.h_withdraw.selector;
        sel[2] = this.h_mint.selector;
        sel[3] = this.h_wrap.selector;
        sel[4] = this.h_unwrap.selector;
        sel[5] = this.h_closeWithWrapper.selector;
        sel[6] = this.h_closeWithInternalLong.selector;
        sel[7] = this.h_transfer.selector;
        sel[8] = this.h_market.selector;
        sel[9] = this.h_warp.selector;
        sel[10] = this.h_startAuction.selector;
        sel[11] = this.h_slice.selector;
        sel[12] = this.h_wrapperLiquidation.selector;
        sel[13] = this.h_expireAndFinalize.selector;
        sel[14] = this.h_settle.selector;
        sel[15] = this.h_redeemOrClaim.selector;
        sel[16] = this.h_pause.selector;
        sel[17] = this.h_closeOnly.selector;
        sel[18] = this.h_venueSell.selector;
        sel[19] = this.h_venueBuy.selector;
        sel[20] = this.h_shock.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    function _track(address owner) internal returns (uint256 id) {
        id = _account(owner);
        everyAccount.push(id);
        everyAccountOwner.push(owner);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(d.router), type(uint256).max);
        for (uint256 j; j < 3; ++j) {
            IERC20(d.registry.getSeries([c4500, c5000, p3500][j]).wrapper).approve(address(d.router), type(uint256).max);
        }
        vm.stopPrank();
    }

    function _strictHealthy(uint256 acct) internal view returns (bool) {
        IPortfolioRiskManager.Risk memory r = d.risk.riskOf(acct);
        return r.equity >= int256(r.initialMargin);
    }

    function _hp(uint256 acct) internal view returns (int256) {
        return _health(acct);
    }

    /// @dev Handlers that must succeed unless the guardian paused their action: any other revert is a violation.
    function _onlyPaused(bytes memory reason) internal {
        if (bytes4(reason) != ActionPaused.selector) violations++;
        calls["paused"]++;
    }

    function _owner(uint256 i) internal view returns (address) {
        return i == 3 ? writers[0] : writers[i];
    }

    // ------------------------------------------------------------------ clearing

    function h_deposit(uint8 i, uint32 raw) external {
        uint256 acct = accts[i % 4];
        int256 h0 = _hp(acct);
        uint256 amount = bound(raw, 1, 10_000e6);
        address who = _owner(i % 4);
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(d.clearing), amount);
        vm.prank(who);
        try d.clearing.depositCollateral(acct, amount) {
            if (_hp(acct) < h0) violations++; // INV-13
            calls["deposit"]++;
        } catch (bytes memory reason) {
            _onlyPaused(reason);
        }
    }

    function h_withdraw(uint8 i, uint32 raw) external {
        uint256 acct = accts[i % 4];
        uint256 maxW = d.risk.maxWithdrawable(acct);
        if (maxW == 0) return;
        OracleUpdate memory u = _update();
        vm.prank(_owner(i % 4));
        try d.clearing.withdrawCollateral(acct, bound(raw, 1, maxW), _owner(i % 4), u) {
            if (!_strictHealthy(acct)) violations++; // INV-11
            calls["withdraw"]++;
        } catch {}
    }

    /// @dev 0.01–1 contract; three mints in four send the wrappers to a buyer.
    function h_mint(uint8 i, uint8 s, uint16 raw, bool toBuyer) external {
        uint256 acct = accts[i % 4];
        address recipient = toBuyer || raw % 2 == 0 ? buyers[raw % 2] : _owner(i % 4);
        OracleUpdate memory u = _update();
        vm.prank(_owner(i % 4));
        try d.clearing.mintExternalLong(acct, ids[s % 3], bound(raw, 1, 100) * 1e16, recipient, type(uint256).max, u) {
            if (!_strictHealthy(acct)) violations++; // INV-11
            calls["mint"]++;
        } catch {}
    }

    function h_wrap(uint8 i, uint8 s, uint16 raw) external {
        uint256 acct = accts[i % 4];
        int256 bal = d.ledger.balanceOf(acct, ids[s % 3]);
        if (bal <= 0) return;
        OracleUpdate memory u = _update();
        vm.prank(_owner(i % 4));
        // forge-lint: disable-next-line(unsafe-typecast)
        try d.clearing.wrapLong(acct, ids[s % 3], bound(raw, 1, uint256(bal) / 1e16) * 1e16, _owner(i % 4), u) {
            if (!_strictHealthy(acct)) violations++; // INV-11
            calls["wrap"]++;
        } catch {}
    }

    function h_unwrap(uint8 b, uint8 s, uint16 raw) external {
        address who = buyers[b % 2];
        uint256 units = IERC20(_wrapper(ids[s % 3])).balanceOf(who) / 1e16;
        if (units == 0) return;
        uint256 acct = buyerAccts[b % 2];
        int256 h0 = _hp(acct);
        vm.prank(who);
        try d.clearing.unwrapLong(acct, ids[s % 3], bound(raw, 1, units) * 1e16) {
            if (_hp(acct) < h0) violations++; // INV-13
            calls["unwrap"]++;
        } catch {}
    }

    function h_closeWithWrapper(uint8 i, uint8 s, uint16 raw) external {
        uint256 acct = accts[i % 4];
        address who = _owner(i % 4);
        int256 bal = d.ledger.balanceOf(acct, ids[s % 3]);
        uint256 held = IERC20(_wrapper(ids[s % 3])).balanceOf(who);
        if (bal >= 0 || held < 1e16) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 maxQ = (uint256(-bal) < held ? uint256(-bal) : held) / 1e16;
        int256 h0 = _hp(acct);
        vm.prank(who);
        try d.clearing.closeShortWithWrapper(acct, ids[s % 3], bound(raw, 1, maxQ) * 1e16) {
            if (_hp(acct) < h0) violations++; // INV-13
            calls["closeWrapper"]++;
        } catch {}
    }

    /// @dev Between writer 0's two accounts.
    function h_closeWithInternalLong(bool dir, uint8 s, uint16 raw) external {
        (uint256 from, uint256 to) = dir ? (accts[0], accts[3]) : (accts[3], accts[0]);
        int256 fb = d.ledger.balanceOf(from, ids[s % 3]);
        int256 tb = d.ledger.balanceOf(to, ids[s % 3]);
        if (fb <= 0 || tb >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 maxQ = (uint256(fb) < uint256(-tb) ? uint256(fb) : uint256(-tb)) / 1e16;
        int256 h0 = _hp(to);
        OracleUpdate memory u = _update();
        vm.prank(writers[0]);
        try d.clearing.closeShortWithInternalLong(from, to, ids[s % 3], bound(raw, 1, maxQ) * 1e16, u) {
            if (_hp(to) < h0) violations++; // INV-13
            calls["closeInternal"]++;
        } catch {}
    }

    /// @dev Buyers pass wrappers back to writers (who can then close) or to each other.
    function h_transfer(uint8 b, uint8 to, uint8 s, uint16 raw) external {
        IERC20 w = IERC20(_wrapper(ids[s % 3]));
        address from = buyers[b % 2];
        uint256 bal = w.balanceOf(from);
        if (bal == 0) return;
        address dest = to % 3 == 2 ? buyers[(uint256(b) + 1) % 2] : writers[to % 3];
        vm.prank(from);
        assertTrue(w.transfer(dest, bound(raw, 1, bal)));
    }

    // ------------------------------------------------------------------ market and time

    /// @dev Spot moves −6%..+15% (drifting up, so writers of calls get into trouble) and IV ±20%, published with a
    ///      fresh signed surface.
    function h_market(int16 move, int16 ivMove) external {
        int256 p = int256(price) * (10_000 + bound(move, -600, 1500)) / 10_000;
        int256 v = int256(iv) * (10_000 + bound(ivMove, -2000, 2000)) / 10_000;
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(p < 1500e18 ? int256(1500e18) : p > 15_000e18 ? int256(15_000e18) : p);
        // forge-lint: disable-next-line(unsafe-typecast)
        iv = uint256(v < 0.2e18 ? int256(0.2e18) : v > 2e18 ? int256(2e18) : v);
        vm.warp(block.timestamp + 60);
        d.clearing.updateOracles(_update());
        calls["market"]++;
    }

    /// @dev A rare jump of +40%..+80% (a rally that puts call writers under water), published fresh.
    function h_shock(uint16 size) external {
        price = price * (14_000 + bound(size, 0, 4000)) / 10_000;
        if (price > 15_000e18) price = 15_000e18;
        vm.warp(block.timestamp + 60);
        d.clearing.updateOracles(_update());
        calls["shock"]++;
    }

    /// @dev Time passes without new data (the surface may go stale; expiry may pass).
    function h_warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 60, 12 hours));
    }

    // ------------------------------------------------------------------ liquidation

    function h_startAuction(uint8 i) external {
        uint256 acct = accts[i % 4];
        IPortfolioRiskManager.Risk memory r = d.risk.riskOf(acct);
        OracleUpdate memory u = _update();
        try d.liquidation.startAuction(acct, weth, u) {
            if (r.equity >= int256(r.maintenanceMargin)) violations++; // INV-21
            calls["startAuction"]++;
        } catch {}
    }

    /// @dev The keeper starts the auction itself if none is running (INV-21 checked there), then slices.
    function h_slice(uint8 i, uint16 bps) external {
        uint256 acct = accts[i % 4];
        if (d.liquidation.auctionStart(acct, weth) == 0) this.h_startAuction(i);
        (, bool whole) = d.liquidation.currentBonus(acct, weth);
        bps = uint16(bound(bps, 500, whole ? 10_000 : 2500));
        IPortfolioRiskManager.Risk memory r0 = d.risk.riskOf(acct);
        OracleUpdate memory u = _update();
        vm.prank(keeper);
        try d.liquidation.liquidateSlice(acct, weth, liqAcct, bps, 0, type(uint256).max, u) {
            IPortfolioRiskManager.Risk memory r1 = d.risk.riskOf(acct);
            if (r1.equity - int256(r1.maintenanceMargin) <= r0.equity - int256(r0.maintenanceMargin)) violations++;
            if (r0.equity >= 0 && uint256(r0.equity) * 10_000 > r0.initialMargin * 10_500 + 10_000) violations++;
            if (!_strictHealthy(liqAcct)) violations++; // INV-23
            calls["slice"]++;
        } catch {}
    }

    function h_wrapperLiquidation(uint8 b, uint8 i, uint8 s, uint16 raw) external {
        uint256 acct = accts[i % 4];
        uint256 qty = _wrapperQty(buyers[b % 2], acct, ids[s % 3], raw);
        if (qty == 0) return;
        int256 h0 = _hp(acct);
        OracleUpdate memory u = _update();
        vm.prank(buyers[b % 2]);
        try d.liquidation.liquidateWithWrapper(acct, ids[s % 3], qty, buyerAccts[b % 2], 0, u) {
            if (_hp(acct) <= h0) violations++; // INV-22
            calls["wrapperLiq"]++;
        } catch {}
    }

    /// @dev Up to what the buyer holds and the account is short, in whole position units.
    function _wrapperQty(address who, uint256 acct, bytes32 sid, uint16 raw) internal view returns (uint256) {
        uint256 held = IERC20(_wrapper(sid)).balanceOf(who) / 1e16;
        int256 bal = d.ledger.balanceOf(acct, sid);
        if (held == 0 || bal >= 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 maxQ = held < uint256(-bal) / 1e16 ? held : uint256(-bal) / 1e16;
        return maxQ == 0 ? 0 : bound(raw, 1, maxQ) * 1e16;
    }

    // ------------------------------------------------------------------ settlement

    function h_expireAndFinalize(uint16 rawPrice) external {
        if (block.timestamp < EXP30 + 300 || d.window.groupAccounting(group30).finalized) return;
        uint256 px = bound(rawPrice, 2000, 9000) * 1e18;
        // the round in force at expiry and its successor (pushed late is fine: their timestamps are what count)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 inForce = ethFeed.pushRound(int256(px / 1e10), EXP30 - 10);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 next = ethFeed.pushRound(int256(px / 1e10), EXP30 + 10);
        vm.prank(keeper);
        try d.window.finalizeGroup(group30, _proof(inForce, next)) {
            priceAtFinal = d.window.settlementPrice(group30);
            calls["finalize"]++;
        } catch (bytes memory reason) {
            _onlyPaused(reason);
        }
    }

    function h_settle() external {
        ISettlementWindow.GroupAccounting memory g = d.window.groupAccounting(group30);
        if (!g.finalized || g.ratioSet) return;
        vm.prank(keeper);
        try d.window.settleAccountsGroup(everyAccount, group30) {
            d.window.computeRecoveryRatio(group30); // every account was just settled
            (ratioSeen, ratioAtSet) = (true, d.window.groupAccounting(group30).ratioWad);
            calls["settle"]++;
            this.h_redeemOrClaim(0, 0, type(uint16).max); // holders show up as soon as redemption opens
        } catch (bytes memory reason) {
            _onlyPaused(reason);
        }
    }

    /// @dev After the ratio is fixed: each buyer redeems a share of every series it holds; one account claims.
    function h_redeemOrClaim(uint8 b, uint8 s, uint16 raw) external {
        if (!d.window.groupAccounting(group30).ratioSet) return;
        for (uint256 k; k < 2; ++k) {
            address who = buyers[(b + k) % 2];
            for (uint256 j; j < 3; ++j) {
                uint256 bal = IERC20(_wrapper(ids[(s + j) % 3])).balanceOf(who);
                if (bal == 0) continue;
                vm.prank(who);
                try d.window.redeemWrapper(ids[(s + j) % 3], bound(raw, 1, bal), who) {
                    calls["redeem"]++;
                } catch (bytes memory reason) {
                    _onlyPaused(reason);
                }
            }
        }
        uint256 acct = everyAccount[raw % everyAccount.length];
        if (d.window.creditOf(acct, group30) != 0) {
            try d.window.claimSettlement(acct, group30) {
                calls["claim"]++;
            } catch (bytes memory reason) {
                _onlyPaused(reason);
            }
        }
    }

    // ------------------------------------------------------------------ guardian, venue

    function h_pause(uint8 bit, bool unpause) external {
        uint256 mask = uint256(1) << (bit % 12);
        if (unpause) {
            vm.prank(governance);
            d.control.unpause(IProtocolControl.Scope.GLOBAL, bytes32(0), mask);
        } else if (bit % 4 == 0) {
            vm.prank(guardian); // pause only sometimes, so runs keep moving
            d.control.pause(IProtocolControl.Scope.GLOBAL, bytes32(0), mask);
        }
    }

    function h_closeOnly(bool on) external {
        vm.prank(on ? guardian : governance);
        d.control.setProductCloseOnly(eth, on);
    }

    /// @dev A buyer sells wrappers into a Kuru bid the maker posts.
    function h_venueSell(uint8 b, uint8 s, uint16 raw) external {
        bytes32 sid = ids[s % 3];
        if (address(books[sid]) == address(0)) return;
        address who = buyers[b % 2];
        uint256 units = IERC20(_wrapper(sid)).balanceOf(who) / 1e16;
        if (units == 0) return;
        uint256 qty = bound(raw, 1, units) * 1e16;
        MockKuruOrderBook book = books[sid];
        book.setBid(100 * 10_000, qty * 1e16 / 1e18);
        usdc.mint(address(book), qty * 100 / 1e12 + 1);
        vm.prank(who);
        try d.router.sellThroughVenue(_sellOrder(sid, qty, 0, who), "") {
            calls["venueSell"]++;
        } catch {}
    }

    /// @dev A buyer buys whatever wrappers the book holds at 120.
    function h_venueBuy(uint8 b, uint8 s, uint32 raw) external {
        bytes32 sid = ids[s % 3];
        if (address(books[sid]) == address(0)) return;
        MockKuruOrderBook book = books[sid];
        uint256 inventory = IERC20(_wrapper(sid)).balanceOf(address(book));
        if (inventory < 1e16) return;
        book.setAsk(120 * 10_000, inventory * 1e16 / 1e18);
        address who = buyers[b % 2];
        vm.prank(who);
        try d.router.buyThroughVenue(_buyOrder(sid, bound(raw, 1e6, 5_000e6), 0, who), "") {
            calls["venueBuy"]++;
        } catch {}
    }

    // ------------------------------------------------------------------ invariants

    function invariant_INV7_custody() public view {
        uint256 cash;
        for (uint256 i; i < everyAccount.length; ++i) {
            cash += d.ledger.cashOf(everyAccount[i]);
        }
        assertEq(usdc.balanceOf(address(d.clearing)), cash + d.window.groupAccounting(group30).pool);
    }

    /// @dev INV-1 before finalization; INV-2 always (settled balances are zeroed through the same ledger write).
    function invariant_INV1_INV2() public view {
        bool finalized = d.window.groupAccounting(group30).finalized;
        for (uint256 j; j < 3; ++j) {
            (uint256 longs, uint256 shorts) = d.ledger.totals(ids[j]);
            if (!finalized) assertEq(IERC20(_wrapper(ids[j])).totalSupply() + longs, shorts, "INV-1");
            int256 sum;
            for (uint256 i; i < everyAccount.length; ++i) {
                sum += d.ledger.balanceOf(everyAccount[i], ids[j]);
            }
            assertEq(sum, int256(longs) - int256(shorts), "INV-2");
        }
    }

    function invariant_INV27_INV28_participants() public view {
        uint256 n;
        for (uint256 i; i < everyAccount.length; ++i) {
            if (d.ledger.seriesCountInGroup(everyAccount[i], group30) != 0) ++n;
        }
        assertEq(d.ledger.participants(group30), n, "INV-27");
        if (d.window.groupAccounting(group30).ratioSet) assertEq(n, 0, "INV-28");
    }

    function invariant_INV26_INV29_INV31_INV33_settlement() public view {
        ISettlementWindow.GroupAccounting memory g = d.window.groupAccounting(group30);
        if (g.finalized) {
            assertEq(g.priceWad, priceAtFinal, "INV-26");
            for (uint256 j; j < 3; ++j) {
                assertLe(IERC20(_wrapper(ids[j])).totalSupply(), d.window.wrapperSupplyAtFinalization(ids[j]), "INV-33");
            }
        }
        if (g.ratioSet) {
            assertEq(g.ratioWad, ratioAtSet, "INV-29: fixed");
            assertLe(g.ratioWad, 1e18, "INV-29: at most 1");
        }
        assertLe(g.pool, g.collected + g.insurance, "INV-31");
    }

    function invariant_INV50_router() public view {
        for (uint256 j; j < 3; ++j) {
            IERC20 w = IERC20(_wrapper(ids[j]));
            assertEq(w.balanceOf(address(d.router)) + w.balanceOf(address(d.kuruAdapter)), 0, "INV-50");
        }
        assertEq(usdc.balanceOf(address(d.router)) + usdc.balanceOf(address(d.kuruAdapter)), 0, "INV-50");
    }

    function invariant_handlerChecks() public view {
        assertEq(violations, 0, "INV-11/13/21/22/23/46");
    }

    function test_handlerPathsReachable() public {
        this.h_mint(0, 0, 100, true);
        this.h_mint(1, 1, 100, true);
        this.h_mint(0, 2, 50, false);
        this.h_transfer(0, 0, 0, 1e4);
        this.h_unwrap(0, 1, 20);
        this.h_venueSell(0, 0, 30);
        this.h_venueBuy(1, 0, 50e6);
        for (uint256 k; k < 5; ++k) {
            this.h_market(1500, 0); // +15% each: 4,000 → about 8,000
        }
        this.h_startAuction(0);
        this.h_slice(0, 2500);
        this.h_wrapperLiquidation(1, 1, 0, 10);
        this.h_withdraw(2, 1e6);
        this.h_deposit(1, 1e6);
        this.h_pause(4, false);
        this.h_pause(4, true);
        this.h_closeOnly(true);
        this.h_closeOnly(false);
        vm.warp(EXP30 + 300);
        this.h_expireAndFinalize(5000);
        this.h_settle();
        this.h_redeemOrClaim(0, 0, 1000);
        assertGt(calls["mint"], 0);
        assertGt(calls["slice"], 0);
        assertGt(calls["venueSell"] + calls["venueBuy"], 0);
        assertEq(calls["finalize"], 1);
        assertEq(calls["settle"], 1);
        invariant_INV7_custody();
        invariant_INV1_INV2();
        invariant_INV27_INV28_participants();
        invariant_INV26_INV29_INV31_INV33_settlement();
        invariant_INV50_router();
        invariant_handlerChecks();
    }
}
