// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {LiquidationFixture} from "../utils/LiquidationFixture.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";

/// @notice Writers mint real wrappers (to the keeper), the market moves, and the keeper starts auctions, slices,
///         burns wrappers and ends auctions. After every call: custody = Σ cash (INV-7), wrapper supply + internal
///         longs = internal shorts (INV-1, so INV-24 holds), totals = Σ balances (INV-2). Handlers record any
///         auction started on an account at or above MM (INV-21), any successful liquidation that did not improve
///         equity − MM (INV-22), any slice that left the liquidator below IM (INV-23), any insurance top-up above
///         the per-call max (INV-25) and any slice taken at or above the target (INV-46).
contract LiquidationModuleInvariantTest is LiquidationFixture {
    uint256[3] internal writers;
    address[3] internal owners;
    bytes32[2] internal seriesList;
    uint256 internal liq;
    address internal keeper = makeAddr("keeper");
    uint256 internal price;
    uint256 internal constant MAX_INSURANCE = 300e6;

    uint256 public violations;
    uint256 public starts;
    uint256 public slices;
    uint256 public burns;

    bytes32 internal constant BAD_DEBT_TOPIC = keccak256("BadDebtCovered(uint256,address,uint256,uint256)");

    function setUp() public {
        _deployClearingMarket();
        (owners[0], owners[1], owners[2]) = (alice, bob, makeAddr("carol"));
        for (uint256 i; i < 3; ++i) {
            writers[i] = _account(owners[i]);
        }
        (seriesList[0], seriesList[1]) = (c4500, c5000);
        liq = _account(keeper);
        _deposit(liq, keeper, 100_000_000e6);
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(insurance), 2000e6);
        insurance.deposit(address(usdc), 2000e6);
        vm.startPrank(governance);
        liquidation.setMaxInsurancePerLiquidation(address(usdc), MAX_INSURANCE);
        liquidation.setLiquidationParams(_params(100, 1000));
        vm.stopPrank();
        // every writer starts just above IM, so a modest rally makes it liquidatable
        for (uint256 i; i < 3; ++i) {
            _deposit(writers[i], owners[i], 4000e6);
            vm.prank(owners[i]);
            clearingModule.mintExternalLong(writers[i], c4500, 1e18, keeper, type(uint256).max, _empty());
            uint256 free = risk.maxWithdrawable(writers[i]); // evaluated before the prank
            vm.prank(owners[i]);
            clearingModule.withdrawCollateral(writers[i], free, owners[i], _empty());
        }
        // a writer at IM becomes liquidatable near 5,440 (IM ≈ 2.4 × MM here): start just above MM
        price = 5300e18;
        vm.warp(block.timestamp + 60);
        clearingModule.updateOracles(_marketUpdate(price));

        bytes4[] memory sel = new bytes4[](7);
        sel[0] = this.h_write.selector;
        sel[1] = this.h_market.selector;
        sel[2] = this.h_start.selector;
        sel[3] = this.h_slice.selector;
        sel[4] = this.h_burn.selector;
        sel[5] = this.h_end.selector;
        sel[6] = this.h_withdraw.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    // ------------------------------------------------------------------ handlers

    /// @dev Writer 0 or 1 tops up exactly to the post-mint IM (per previewMint) and mints 0.1–3 contracts to the
    ///      keeper. Writer 2 stays passive near MM.
    function h_write(uint8 w, uint8 s, uint16 raw) external {
        uint256 i = w % 2;
        bytes32 sid = seriesList[s % 2];
        uint256 qty = bound(raw, 10, 300) * 1e16;
        (, int256 eqAfter, uint256 imAfter,) = clearingModule.previewMint(writers[i], sid, qty);
        if (int256(imAfter) > eqAfter) _deposit(writers[i], owners[i], uint256(int256(imAfter) - eqAfter) / 1e12 + 2);
        vm.prank(owners[i]);
        try clearingModule.mintExternalLong(writers[i], sid, qty, keeper, type(uint256).max, _empty()) {} catch {}
    }

    function h_withdraw(uint8 w, uint64 raw) external {
        uint256 i = w % 2;
        uint256 maxW = risk.maxWithdrawable(writers[i]);
        if (maxW == 0) return;
        vm.prank(owners[i]);
        clearingModule.withdrawCollateral(writers[i], bound(raw, 1, maxW), owners[i], _empty());
    }

    /// @dev 60 s pass; spot moves −3%..+8% (clamped to [3,000, 9,000]); a fresh surface is published.
    function h_market(int16 moveBps) external {
        moveBps = int16(bound(moveBps, -300, 800));
        price = uint256(int256(price) * (10_000 + moveBps) / 10_000);
        if (price < 3000e18) price = 3000e18;
        if (price > 9000e18) price = 9000e18;
        vm.warp(block.timestamp + 60);
        clearingModule.updateOracles(_marketUpdate(price));
    }

    /// @dev Tries every writer. Liveness: a liquidatable account with unexpired positions and no auction must be
    ///      startable; INV-21: a start never succeeds at or above MM.
    function h_start() external {
        for (uint256 i; i < 3; ++i) {
            uint256 a = writers[i];
            IPortfolioRiskManager.Risk memory r = risk.riskOf(a);
            bool startable = r.equity < int256(r.maintenanceMargin) && liquidation.auctionStart(a, weth) == 0
                && (ledger.balanceOf(a, c4500) != 0 || ledger.balanceOf(a, c5000) != 0);
            try liquidation.startAuction(a, weth, _empty()) {
                if (r.equity >= int256(r.maintenanceMargin)) violations++; // INV-21
                starts++;
            } catch {
                if (startable) violations++; // liveness
            }
        }
    }

    function h_slice(uint8 w, uint16 bps) external {
        uint256 a = writers[w % 3];
        (, bool whole) = liquidation.currentBonus(a, weth);
        bps = uint16(bound(bps, 500, whole ? 10_000 : 2500));
        IPortfolioRiskManager.Risk memory r0 = risk.riskOf(a);
        uint256 target = r0.initialMargin * 10_500 / 10_000;
        vm.recordLogs();
        vm.prank(keeper);
        try liquidation.liquidateSlice(a, weth, liq, bps, 0, type(uint256).max, _empty()) {
            slices++;
            _afterLiquidation(a, r0);
            if (r0.equity >= 0 && uint256(r0.equity) > target) violations++; // INV-46
            IPortfolioRiskManager.Risk memory rl = risk.riskOf(liq);
            if (rl.equity < int256(rl.initialMargin)) violations++; // INV-23
        } catch {}
    }

    function h_burn(uint8 w, uint8 s, uint16 raw) external {
        uint256 a = writers[w % 3];
        bytes32 sid = seriesList[s % 2];
        int256 bal = ledger.balanceOf(a, sid);
        uint256 held = IERC20(_wrapper(sid)).balanceOf(keeper);
        if (bal >= 0 || held < 1e16) return;
        uint256 maxQ = (uint256(-bal) < held ? uint256(-bal) : held) / 1e16;
        uint256 qty = bound(raw, 1, maxQ) * 1e16;
        IPortfolioRiskManager.Risk memory r0 = risk.riskOf(a);
        vm.recordLogs();
        vm.prank(keeper);
        try liquidation.liquidateWithWrapper(a, sid, qty, liq, 0, _empty()) {
            burns++;
            _afterLiquidation(a, r0);
        } catch {}
    }

    function h_end(uint8 w) external {
        try liquidation.endAuction(writers[w % 3], weth, _empty()) {} catch {}
    }

    function _afterLiquidation(uint256 a, IPortfolioRiskManager.Risk memory r0) internal {
        IPortfolioRiskManager.Risk memory r1 = risk.riskOf(a);
        if (r1.equity - int256(r1.maintenanceMargin) <= r0.equity - int256(r0.maintenanceMargin)) violations++; // INV-22
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].topics[0] == BAD_DEBT_TOPIC) {
                (uint256 paid,) = abi.decode(logs[k].data, (uint256, uint256));
                if (paid > MAX_INSURANCE) violations++; // INV-25
            }
        }
    }

    // ------------------------------------------------------------------ invariants

    function invariant_INV7_custody() public view {
        uint256 cash = ledger.cashOf(liq);
        for (uint256 i; i < 3; ++i) {
            cash += ledger.cashOf(writers[i]);
        }
        assertEq(usdc.balanceOf(address(clearingModule)), cash);
    }

    function invariant_INV1_INV2_INV24() public view {
        for (uint256 j; j < 2; ++j) {
            bytes32 sid = seriesList[j];
            (uint256 longs, uint256 shorts) = ledger.totals(sid);
            assertEq(IERC20(_wrapper(sid)).totalSupply() + longs, shorts, "INV-1");
            int256 sum = ledger.balanceOf(liq, sid);
            for (uint256 i; i < 3; ++i) {
                sum += ledger.balanceOf(writers[i], sid);
            }
            assertEq(sum, int256(longs) - int256(shorts), "INV-2");
        }
    }

    function invariant_noViolations() public view {
        assertEq(violations, 0);
    }

    function test_handlerPathsReachable() public {
        this.h_market(800);
        this.h_start();
        this.h_slice(0, 2500);
        this.h_burn(1, 0, 20);
        this.h_end(0);
        this.h_write(0, 1, 100);
        this.h_withdraw(0, 1);
        assertEq(starts, 3, "all three writers were below MM after the rally");
        assertEq(slices, 1);
        assertEq(burns, 1);
        invariant_INV7_custody();
        invariant_INV1_INV2_INV24();
        invariant_noViolations();
    }
}
