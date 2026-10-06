// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidationFixture} from "../utils/LiquidationFixture.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";

/// @notice Liquidation properties over random sizes, prices, bonus times and slice sizes: every slice improves
///         equity − MM by at least sliceMM × (1 − bonus − penalty) up to 3 native units (INV-22); previews equal
///         execution (PRV-004); the liquidator stays healthy (INV-23); net balances are preserved (INV-24);
///         insurance pays at most the per-call max and its balance (INV-25); custody equals Σ cash (INV-7).
contract LiquidationModuleFuzzTest is LiquidationFixture {
    uint256 internal acct;
    uint256 internal liq;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _deployClearingMarket();
        acct = _account(alice);
        liq = _account(keeper);
        _deposit(liq, keeper, 1_000_000e6);
    }

    function _health(uint256 a) internal view returns (int256) {
        IPortfolioRiskManager.Risk memory r = risk.riskOf(a);
        return r.equity - int256(r.maintenanceMargin);
    }

    /// @dev A short C4500 (and optionally a long C5000 hedge) that a rally to `price` makes liquidatable.
    function _setup(uint256 rawQty, uint256 rawCash, uint256 rawPrice, bool hedge) internal returns (bool) {
        uint256 qty = bound(rawQty, 10, 500) * 1e16;
        _hold(acct, c4500, -int256(qty));
        if (hedge) _hold(acct, c5000, int256(qty / 2e16 * 1e16));
        _deposit(acct, alice, bound(rawCash, 1e6, qty * 3000e6 / 1e18));
        vm.warp(T0 + 10 days);
        _flatMarket(bound(rawPrice, 5000, 8000) * 1e18, 0.6e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        vm.assume(r.equity < int256(r.maintenanceMargin)); // rejected runs count against max_test_rejects
        liquidation.startAuction(acct, weth, _empty());
        return true;
    }

    struct Snap {
        int256 mark;
        uint256 mm;
        uint256 disc;
        uint256 pen;
        int256 cash;
        uint256 bonus;
        int256 health;
        uint256 accountMM;
        uint256 liqCash;
        uint256 acctCash;
    }

    function testFuzz_INV22_PRV004_slice(
        uint256 rawQty,
        uint256 rawCash,
        uint256 rawPrice,
        bool hedge,
        uint256 elapsed,
        uint16 sliceBps
    ) public {
        if (!_setup(rawQty, rawCash, rawPrice, hedge)) return;
        elapsed = bound(elapsed, 0, 3600);
        if (elapsed != 0) {
            (uint256 px,) = spot.spotPrice(ethUsdc);
            vm.warp(block.timestamp + elapsed);
            _flatMarket(px, 0.6e18);
        }
        Snap memory b;
        bool whole;
        (b.bonus, whole) = liquidation.currentBonus(acct, weth);
        sliceBps = uint16(bound(sliceBps, 500, whole ? 10_000 : 2500));
        (b.mark, b.mm, b.disc, b.pen, b.cash) = liquidation.previewSlice(acct, weth, sliceBps);
        b.health = _health(acct);
        b.accountMM = risk.riskOf(acct).maintenanceMargin;
        b.liqCash = ledger.cashOf(liq);
        b.acctCash = ledger.cashOf(acct);

        vm.prank(keeper);
        try liquidation.liquidateSlice(acct, weth, liq, sliceBps, 0, type(uint256).max, _empty()) {
            _checkSlice(b);
        } catch {
            // only dust slices may fail here (the liquidator is rich and slippage limits are open)
            assertLt(b.mm, 3e12, "a non-dust slice reverted");
        }
        (uint256 longs, uint256 shorts) = ledger.totals(c4500);
        assertEq(int256(longs) - int256(shorts), ledger.balanceOf(acct, c4500) + ledger.balanceOf(liq, c4500), "INV-24");
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(acct) + ledger.cashOf(liq), "INV-7");
    }

    function _checkSlice(Snap memory b) internal view {
        int256 gain = _health(acct) - b.health;
        assertGt(gain, 0, "INV-22: strictly better");
        assertGe(gain, int256(b.mm * (10_000 - b.bonus - 200) / 10_000) - 3e12, "INV-22: bound");
        assertEq(b.accountMM - risk.riskOf(acct).maintenanceMargin, b.mm, "PRV-004: sliceMM");
        assertEq(int256(ledger.cashOf(liq)) - int256(b.liqCash), b.cash, "PRV-004: cash to liquidator");
        if (b.mark < 0 && uint256(b.cash) * 1e12 >= uint256(-b.mark) + b.disc) {
            assertEq(b.acctCash - ledger.cashOf(acct), uint256(b.cash) + b.pen, "paid in full, penalty too");
        }
        IPortfolioRiskManager.Risk memory rl = risk.riskOf(liq);
        assertGe(rl.equity, int256(rl.initialMargin), "INV-23");
    }

    function testFuzz_INV25_insuranceTopUpBounded(uint256 rawCash, uint256 maxIns, uint256 seed) public {
        _hold(acct, c4500, -1e18);
        _deposit(acct, alice, bound(rawCash, 1, 400e6));
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        maxIns = bound(maxIns, 0, 1000e6);
        seed = bound(seed, 0, 1000e6);
        if (seed != 0) {
            usdc.mint(address(this), seed);
            usdc.approve(address(insurance), seed);
            insurance.deposit(address(usdc), seed);
        }
        vm.prank(governance);
        liquidation.setMaxInsurancePerLiquidation(address(usdc), maxIns);
        liquidation.startAuction(acct, weth, _empty());
        uint256 cash0 = ledger.cashOf(acct);
        _slice();
        uint256 received = ledger.cashOf(liq) - 1_000_000e6;
        uint256 topUp = received - cash0; // the account paid all its cash (it owes ~464 > 400)
        assertLe(topUp, maxIns, "INV-25: per-call max");
        assertLe(topUp, seed, "INV-25: fund balance");
        assertEq(insurance.balanceOf(address(usdc)), seed - topUp, "no penalty: cash ran out");
    }

    function _slice() internal {
        vm.prank(keeper);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
    }
}
