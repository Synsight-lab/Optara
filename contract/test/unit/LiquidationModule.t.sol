// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidationFixture} from "../utils/LiquidationFixture.sol";
import {LiquidationModule} from "../../src/liquidation/LiquidationModule.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../mocks/MockDependencies.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    AssetMismatch,
    SeriesNotActive,
    InsufficientShort,
    NotHealthy,
    NotLiquidatable,
    EmptyBucket,
    InvalidLiquidationParams,
    AuctionNotActive,
    AuctionActive,
    SliceOutOfBounds,
    HealthNotImproved,
    SlippageExceeded,
    StaleSpot,
    StaleSurface,
    PositionLimit,
    ActionPaused,
    RefundFailed
} from "../../src/libraries/Errors.sol";

/// @dev Calls payable liquidation entry points without accepting the refund.
contract RejectsEth {
    function start(LiquidationModule l, uint256 accountId, address underlying, OracleUpdate calldata u)
        external
        payable
    {
        l.startAuction{value: msg.value}(accountId, underlying, u);
    }
}

/// @notice Unit tests for LiquidationModule: LIQ-001..LIQ-013, LIQ-015..LIQ-017, PRV-004 (LIQ-014 needs the venue
///         adapter, step 12).
contract LiquidationModuleTest is LiquidationFixture {
    uint256 internal acct;
    uint256 internal liq;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _deployClearingMarket();
        acct = _account(alice);
        liq = _account(keeper);
        _deposit(liq, keeper, 10_000e6);
    }

    // ------------------------------------------------------------------ helpers

    function _riskOf(uint256 a) internal view returns (IPortfolioRiskManager.Risk memory) {
        return risk.riskOf(a);
    }

    function _health(uint256 a) internal view returns (int256) {
        IPortfolioRiskManager.Risk memory r = risk.riskOf(a);
        return r.equity - int256(r.maintenanceMargin);
    }

    /// @dev MATH.md §12.1: cash 3,700, short 1 × C4500, ETH 6,200 with 20 days left, IV 60%.
    function _underwater() internal {
        _deposit(acct, alice, 3700e6);
        _hold(acct, c4500, -1e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
    }

    function _setParams(uint16 startBonus, uint16 maxBonus) internal {
        vm.prank(governance);
        liquidation.setLiquidationParams(_params(startBonus, maxBonus));
    }

    function _start() internal {
        liquidation.startAuction(acct, weth, _empty());
    }

    function _slice(uint16 bps) internal {
        vm.prank(keeper);
        liquidation.liquidateSlice(acct, weth, liq, bps, 0, type(uint256).max, _empty());
    }

    function _seedInsurance(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(insurance), amount);
        insurance.deposit(address(usdc), amount);
    }

    // ------------------------------------------------------------------ initialization and admin

    function test_initialState() public view {
        ILiquidationModule.LiquidationParams memory p = liquidation.liquidationParams();
        assertEq(p.startBonusBps, 0);
        assertEq(p.maxBonusBps, 1000);
        assertEq(p.auctionDuration, 1800);
        assertEq(p.minSliceBps, 500);
        assertEq(p.maxSliceBps, 2500);
        assertEq(p.targetHealthBufferBps, 500);
        assertEq(p.liquidationPenaltyBps, 200);
        ILiquidationModule.Modules memory m = liquidation.modules();
        assertEq(m.ledger, address(ledger));
        assertEq(m.registry, address(registry));
        assertEq(m.risk, address(risk));
        assertEq(m.insurance, address(insurance));
        assertEq(m.clearing, address(clearingModule));
        assertEq(m.spot, address(spot));
        assertEq(m.surface, address(surface));
    }

    function test_initializeChecks() public {
        IProtocolControl c = IProtocolControl(address(pc));
        address impl = address(new LiquidationModule());
        ILiquidationModule.Modules memory good = liquidation.modules();
        for (uint256 i; i < 7; ++i) {
            ILiquidationModule.Modules memory m = good;
            assembly {
                mstore(add(m, mul(i, 0x20)), 0)
            }
            vm.prank(governance);
            vm.expectRevert(ZeroAddress.selector);
            upgradeAdmin.deployProxy(impl, abi.encodeCall(LiquidationModule.initialize, (c, m)));
        }
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        liquidation.initialize(c, good);
    }

    function test_LIQ018_setLiquidationParams() public {
        ILiquidationModule.LiquidationParams memory p = _params(100, 900);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        liquidation.setLiquidationParams(p);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.LiquidationParamsSet(p);
        vm.prank(governance);
        liquidation.setLiquidationParams(p);
        assertEq(liquidation.liquidationParams().startBonusBps, 100);

        _badParams(_params(901, 900), 1); // start > max
        _badParams(_params(0, 9800), 1); // max + penalty = 10,000
        p = _params(0, 1000);
        p.auctionDuration = 0;
        _badParams(p, 2);
        p.auctionDuration = 7 days + 1;
        _badParams(p, 2);
        p = _params(0, 1000);
        p.minSliceBps = 0;
        _badParams(p, 3);
        p.minSliceBps = 2600;
        _badParams(p, 3); // min > max
        p.minSliceBps = 500;
        p.maxSliceBps = 10_001;
        _badParams(p, 3);
        p = _params(0, 1000);
        p.targetHealthBufferBps = 10_001;
        _badParams(p, 4);
    }

    function _badParams(ILiquidationModule.LiquidationParams memory p, uint8 reason) internal {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidLiquidationParams.selector, reason));
        liquidation.setLiquidationParams(p);
    }

    function test_LIQ018_setMaxInsurancePerLiquidation() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        liquidation.setMaxInsurancePerLiquidation(address(usdc), 1);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.MaxInsurancePerLiquidationSet(address(usdc), 500e6);
        vm.prank(governance);
        liquidation.setMaxInsurancePerLiquidation(address(usdc), 500e6);
        assertEq(liquidation.maxInsurancePerLiquidation(address(usdc)), 500e6);
    }

    // ------------------------------------------------------------------ LIQ-001 / LIQ-017: starting

    function test_LIQ001_startAuction() public {
        _deposit(acct, alice, 3700e6);
        _hold(acct, c4500, -1e18);
        IPortfolioRiskManager.Risk memory r = _riskOf(acct);
        vm.expectRevert(abi.encodeWithSelector(NotLiquidatable.selector, r.equity, r.maintenanceMargin));
        _start(); // healthy at 4,000

        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        r = _riskOf(acct);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.AuctionStarted(acct, weth, r.equity, r.maintenanceMargin, uint64(block.timestamp));
        _start();
        assertEq(liquidation.auctionStart(acct, weth), block.timestamp);

        vm.expectRevert(AuctionActive.selector);
        _start(); // LIQ-017
        vm.expectRevert(abi.encodeWithSelector(EmptyBucket.selector, acct, wbtc));
        liquidation.startAuction(acct, wbtc, _empty());
    }

    /// @dev Between MM and IM: close-only, not liquidatable.
    function test_LIQ001_betweenMmAndImIsNotLiquidatable() public {
        _underwater();
        IPortfolioRiskManager.Risk memory r = _riskOf(acct);
        _deposit(acct, alice, (r.maintenanceMargin - uint256(r.equity)) / 1e12 + 100e6);
        r = _riskOf(acct);
        assertLt(uint256(r.equity), r.initialMargin);
        vm.expectRevert(abi.encodeWithSelector(NotLiquidatable.selector, r.equity, r.maintenanceMargin));
        _start();
    }

    function test_LIQ017_sliceGuards() public {
        _underwater();
        vm.prank(keeper);
        vm.expectRevert(AuctionNotActive.selector);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
        _start();
        _deposit(acct, alice, 50_000e6); // far above IM x 1.05
        IPortfolioRiskManager.Risk memory r = _riskOf(acct);
        uint256 target = r.initialMargin * 10_500 / 10_000 + (r.initialMargin * 10_500 % 10_000 == 0 ? 0 : 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NotLiquidatable.selector, r.equity, target));
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
    }

    // ------------------------------------------------------------------ LIQ-002 / LIQ-003 / PRV-004: slices

    function test_LIQ002_PRV004_workedExample() public {
        _underwater();
        _setParams(500, 500); // bonus 5% from the start
        IPortfolioRiskManager.Risk memory r = _riskOf(acct);
        assertApproxEqAbs(r.equity, 1997.14e18, 0.01e18);
        assertApproxEqAbs(r.maintenanceMargin, 3097.15e18, 0.01e18);
        _start();
        (int256 mark, uint256 mm, uint256 disc, uint256 pen, int256 cash) = liquidation.previewSlice(acct, weth, 2500);
        assertApproxEqAbs(mark, -425.71e18, 0.01e18);
        assertApproxEqAbs(mm, 774.29e18, 0.01e18);
        assertApproxEqAbs(disc, 38.71e18, 0.01e18);
        assertEq(disc, (mm * 500 + 9999) / 10_000, "discount rounds up");
        assertEq(pen, 15_485_751); // 15.49 USDC, rounded up
        assertEq(cash, 464_429_199); // 464.43 USDC, rounded up
        assertApproxEqAbs(_health(acct), -1100.01e18, 0.01e18);

        uint256 insBefore = insurance.balanceOf(address(usdc));
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.SliceLiquidated(acct, weth, liq, 2500, mark, mm, disc, pen, cash);
        _slice(2500);
        assertApproxEqAbs(_health(acct), -379.92e18, 0.01e18);
        assertEq(ledger.balanceOf(acct, c4500), -0.75e18);
        assertEq(ledger.balanceOf(liq, c4500), -0.25e18);
        assertEq(ledger.cashOf(acct), 3700e6 - 464_429_199 - 15_485_751);
        assertEq(ledger.cashOf(liq), 10_000e6 + 464_429_199);
        assertEq(insurance.balanceOf(address(usdc)) - insBefore, 15_485_751, "penalty to insurance");
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(acct) + ledger.cashOf(liq), "INV-7");
    }

    function test_LIQ003_improvementBound() public {
        _underwater();
        _setParams(300, 800);
        _start();
        vm.warp(block.timestamp + 600);
        _flatMarket(6200e18, 0.6e18);
        (uint256 bonus,) = liquidation.currentBonus(acct, weth);
        assertEq(bonus, 466, "300 + 500 x 600 / 1800, rounded down");
        int256 h0 = _health(acct);
        (, uint256 mm, uint256 disc,,) = liquidation.previewSlice(acct, weth, 2000);
        assertGt(mm * bonus % 10_000, 0, "a remainder, so the rounding direction matters");
        assertEq(disc, mm * bonus / 10_000 + 1, "discount rounds up");
        _slice(2000);
        int256 gain = _health(acct) - h0;
        int256 expected = int256(mm * (10_000 - bonus - 200) / 10_000);
        assertLe(gain, expected, "paid in full: equality up to rounding");
        assertApproxEqAbs(gain, expected, 3e12, "within 3 native units");
    }

    /// @dev 25% of 0.07 = 0.0175, rounded down to 0.01 (minPositionQty).
    function test_LIQ003_movedQuantityRoundsDown() public {
        _deposit(acct, alice, 1e6);
        _hold(acct, c4500, -0.07e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _start();
        _slice(2500);
        assertEq(ledger.balanceOf(acct, c4500), -0.06e18);
        assertEq(ledger.balanceOf(liq, c4500), -0.01e18);
    }

    function test_LIQ003_dustSliceReverts() public {
        _deposit(acct, alice, 1e6);
        _hold(acct, c4500, -0.04e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _start();
        vm.prank(keeper);
        vm.expectRevert(HealthNotImproved.selector); // 5% of 0.04 rounds to 0
        liquidation.liquidateSlice(acct, weth, liq, 500, 0, 0, _empty());
    }

    /// @dev MM falls, but by less than the native-unit rounding of the payment: the strict check reverts. A large
    ///      expired leg keeps the account liquidatable; the only movable leg is 1,000 wei of a call, which loses in
    ///      the bucket's worst scenario (spot +50%).
    function test_LIQ003_roundingErasesGain() public {
        vm.prank(governance);
        ledger.setMinPositionQty(1);
        bytes32 c45 = _series(ethUsdc, OptionType.CALL, 4500e18, T0 + 45 days);
        _deposit(acct, alice, 1000e6);
        _hold(acct, c4500, -1e18);
        _hold(acct, c45, -1000);
        vm.warp(EXP30 + 1);
        _flatMarket(6200e18, 0.6e18);
        _start();
        (, uint256 mm,,,) = liquidation.previewSlice(acct, weth, 2500);
        assertGt(mm, 0, "MM does fall");
        assertLt(mm, 1e12, "by less than one native unit");
        vm.prank(keeper);
        vm.expectRevert(HealthNotImproved.selector);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
    }

    function test_LIQ004_liquidatorMustBeHealthy() public {
        _underwater();
        uint256 poor = _account(keeper);
        _deposit(poor, keeper, 1e6);
        _start();
        vm.prank(keeper);
        vm.expectPartialRevert(NotHealthy.selector);
        liquidation.liquidateSlice(acct, weth, poor, 2500, 0, 0, _empty());
    }

    function test_LIQ005_LIQ006_boundsBonusAndWholeBucket() public {
        _underwater();
        (uint256 b0, bool w0) = liquidation.currentBonus(acct, weth);
        assertEq(b0, 0);
        assertFalse(w0);
        _start();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SliceOutOfBounds.selector, uint16(499)));
        liquidation.liquidateSlice(acct, weth, liq, 499, 0, 0, _empty());
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SliceOutOfBounds.selector, uint16(2501)));
        liquidation.liquidateSlice(acct, weth, liq, 2501, 0, 0, _empty());

        vm.warp(block.timestamp + 900);
        (uint256 b1, bool w1) = liquidation.currentBonus(acct, weth);
        assertEq(b1, 500, "linear");
        assertFalse(w1);
        vm.warp(block.timestamp + 900);
        (uint256 b2, bool w2) = liquidation.currentBonus(acct, weth);
        assertEq(b2, 1000, "capped");
        assertTrue(w2, "whole-bucket mode");
        vm.warp(block.timestamp + 5000);
        (b2,) = liquidation.currentBonus(acct, weth);
        assertEq(b2, 1000);

        _flatMarket(6200e18, 0.6e18);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.AuctionEnded(acct, weth, 1);
        _slice(10_000);
        assertEq(ledger.balanceOf(acct, c4500), 0);
        assertEq(liquidation.auctionStart(acct, weth), 0);
    }

    /// @dev Long 2 x C4500 + short 1 x P3500 is worth more than zero, so a slice is a net asset.
    /// @dev A leg that keeps one unit after the slice keeps the auction open (minPositionQty = 1 wei).
    function test_LIQ005_lastUnitKeepsAuctionOpen() public {
        vm.prank(governance);
        ledger.setMinPositionQty(1);
        _hold(acct, c4500, -10);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _start();
        vm.warp(block.timestamp + 1800); // whole-bucket mode
        _flatMarket(6200e18, 0.6e18);
        _slice(9000); // moves 9 of 10 units
        assertEq(ledger.balanceOf(acct, c4500), -1);
        assertGt(liquidation.auctionStart(acct, weth), 0, "one unit left: still active");
    }

    /// @dev Wrapper path: the liquidator only receives cash, so the module itself must reject another asset.
    function test_LIQ016_wrapperLiquidatorAssetMismatch() public {
        _deposit(acct, alice, 4000e6);
        vm.prank(alice);
        clearingModule.mintExternalLong(acct, c4500, 1e18, keeper, type(uint256).max, _empty());
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        vm.prank(governance);
        registry.setSettlementAssetApproved(address(usdt), true);
        vm.prank(keeper);
        uint256 other = ledger.createSubAccount(address(usdt));
        vm.prank(keeper);
        vm.expectRevert(AssetMismatch.selector);
        liquidation.liquidateWithWrapper(acct, c4500, 0.25e18, other, 0, _empty());
    }

    function test_LIQ007_PRV004_netAssetSlice() public {
        _deposit(acct, alice, 100e6);
        _hold(acct, c4500, 2e18);
        _hold(acct, p3500, -1e18);
        _setParams(500, 500);
        _start();
        (int256 mark, uint256 mm, uint256 disc, uint256 pen, int256 cash) = liquidation.previewSlice(acct, weth, 2500);
        assertGt(mark, int256(disc), "net asset worth more than the discount");
        assertEq(cash, -int256((uint256(mark) - disc) / 1e12), "the liquidator pays mark - discount, rounded down");

        vm.prank(keeper);
        vm.expectRevert(SlippageExceeded.selector);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, uint256(-cash) - 1, _empty());

        int256 h0 = _health(acct);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.SliceLiquidated(acct, weth, liq, 2500, mark, mm, disc, pen, cash);
        vm.prank(keeper);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, uint256(-cash), _empty());
        assertEq(ledger.cashOf(liq), 10_000e6 - uint256(-cash));
        assertEq(ledger.cashOf(acct), 100e6 + uint256(-cash) - pen);
        assertGt(_health(acct), h0);
        assertEq(ledger.balanceOf(liq, c4500), 0.5e18);
        assertEq(ledger.balanceOf(liq, p3500), -0.25e18);
    }

    function test_LIQ007_discountAboveMarkPaysNothing() public {
        _deposit(acct, alice, 100e6);
        _hold(acct, c4500, 2e18);
        _hold(acct, p3500, -1e18);
        _setParams(5000, 5000);
        _start();
        (,,,, int256 cash) = liquidation.previewSlice(acct, weth, 2500);
        assertEq(cash, 0);
        _slice(2500);
        assertEq(ledger.cashOf(liq), 10_000e6);
    }

    // ------------------------------------------------------------------ LIQ-008 / LIQ-009: cash limits

    function test_LIQ008_badDebtInsuranceTopUp() public {
        _deposit(acct, alice, 100e6);
        _hold(acct, c4500, -1e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _setParams(500, 500);
        _seedInsurance(1000e6);
        vm.prank(governance);
        liquidation.setMaxInsurancePerLiquidation(address(usdc), 200e6);
        _start();
        (,,,, int256 owed) = liquidation.previewSlice(acct, weth, 2500);
        assertEq(owed, 300e6, "100 cash + 200 insurance (the per-call max)");
        // the full debt would be ~464.43: 164.43 stays unpaid
        int256 h0 = _health(acct);
        vm.expectEmit(true, true, false, false, address(liquidation));
        emit ILiquidationModule.BadDebtCovered(acct, address(usdc), 200e6, 0);
        vm.prank(keeper); // the insurance top-up counts toward minCashToLiquidator
        liquidation.liquidateSlice(acct, weth, liq, 2500, 300e6, 0, _empty());
        assertEq(ledger.cashOf(acct), 0, "all cash to the liquidator; no penalty left to pay");
        assertEq(ledger.cashOf(liq), 10_000e6 + 300e6);
        assertEq(insurance.balanceOf(address(usdc)), 800e6, "INV-25: at most the per-call max");
        assertGt(_health(acct), h0);
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(acct) + ledger.cashOf(liq), "INV-7");
    }

    function test_LIQ008_insuranceBalanceLimitsTopUp() public {
        _deposit(acct, alice, 100e6);
        _hold(acct, c4500, -1e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _seedInsurance(50e6);
        vm.prank(governance);
        liquidation.setMaxInsurancePerLiquidation(address(usdc), 200e6);
        _start();
        _slice(2500);
        assertEq(ledger.cashOf(liq), 10_000e6 + 150e6, "100 cash + the fund's whole 50");
        assertEq(insurance.balanceOf(address(usdc)), 0);
    }

    function test_LIQ008_noInsuranceConfigured() public {
        _deposit(acct, alice, 100e6);
        _hold(acct, c4500, -1e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _seedInsurance(1000e6);
        _start();
        vm.expectEmit(true, true, false, false, address(liquidation));
        emit ILiquidationModule.BadDebtCovered(acct, address(usdc), 0, 0);
        _slice(2500);
        assertEq(ledger.cashOf(liq), 10_000e6 + 100e6);
        assertEq(insurance.balanceOf(address(usdc)), 1000e6);
    }

    function test_LIQ009_minCashToLiquidator() public {
        _underwater();
        _setParams(500, 500);
        _start();
        (,,,, int256 cash) = liquidation.previewSlice(acct, weth, 2500);
        vm.prank(keeper);
        vm.expectRevert(SlippageExceeded.selector);
        liquidation.liquidateSlice(acct, weth, liq, 2500, uint256(cash) + 1, 0, _empty());
        vm.prank(keeper);
        liquidation.liquidateSlice(acct, weth, liq, 2500, uint256(cash), 0, _empty());
    }

    // ------------------------------------------------------------------ LIQ-010: wrapper burn

    function test_LIQ010_wrapperLiquidation() public {
        _deposit(acct, alice, 4000e6);
        vm.prank(alice);
        clearingModule.mintExternalLong(acct, c4500, 1e18, keeper, type(uint256).max, _empty());
        vm.prank(keeper);
        vm.expectPartialRevert(NotLiquidatable.selector);
        liquidation.liquidateWithWrapper(acct, c4500, 0.25e18, liq, 0, _empty()); // healthy at 4,000

        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _setParams(500, 500);
        _start();
        IPortfolioRiskManager.Risk memory r0 = _riskOf(acct);
        uint256 cash0 = ledger.cashOf(acct);
        vm.prank(keeper);
        vm.expectRevert(SlippageExceeded.selector);
        liquidation.liquidateWithWrapper(acct, c4500, 0.25e18, liq, 1000e6, _empty());

        vm.prank(keeper);
        liquidation.liquidateWithWrapper(acct, c4500, 0.25e18, liq, 0, _empty());
        IPortfolioRiskManager.Risk memory r1 = _riskOf(acct);
        assertEq(ledger.balanceOf(acct, c4500), -0.75e18);
        assertEq(IERC20(_wrapper(c4500)).balanceOf(keeper), 0.75e18, "burned");
        uint256 dMM = r0.maintenanceMargin - r1.maintenanceMargin;
        uint256 paid = cash0 - ledger.cashOf(acct);
        // liability mark 425.71 + 5% of dMM, plus 2% of dMM penalty
        assertApproxEqAbs(paid, 425.71e6 + dMM * 700 / 10_000 / 1e12, 0.02e6);
        assertGt(r1.equity - int256(r1.maintenanceMargin), r0.equity - int256(r0.maintenanceMargin));
        (uint256 longs, uint256 shorts) = ledger.totals(c4500);
        assertEq(IERC20(_wrapper(c4500)).totalSupply() + longs, shorts, "INV-1");
    }

    function test_LIQ010_wrapperChecks() public {
        _deposit(acct, alice, 4000e6);
        vm.prank(alice);
        clearingModule.mintExternalLong(acct, c4500, 1e18, keeper, type(uint256).max, _empty());
        vm.startPrank(keeper);
        vm.expectRevert(ZeroAmount.selector);
        liquidation.liquidateWithWrapper(acct, c4500, 0, liq, 0, _empty());
        vm.expectRevert(abi.encodeWithSelector(InsufficientShort.selector, int256(-1e18), 2e18));
        liquidation.liquidateWithWrapper(acct, c4500, 2e18, liq, 0, _empty());
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(InvalidRecipient.selector);
        liquidation.liquidateWithWrapper(acct, c4500, 1e18, acct, 0, _empty()); // own account as liquidator
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        liquidation.liquidateWithWrapper(acct, c4500, 1e18, liq, 0, _empty());
        vm.warp(EXP30);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotActive.selector, c4500));
        liquidation.liquidateWithWrapper(acct, c4500, 1e18, liq, 0, _empty());
    }

    // ------------------------------------------------------------------ LIQ-011: ending

    function test_LIQ011_endAuction() public {
        _underwater();
        vm.expectRevert(AuctionNotActive.selector);
        liquidation.endAuction(acct, weth, _empty());
        _start();
        vm.expectRevert(AuctionActive.selector);
        liquidation.endAuction(acct, weth, _empty());
        _deposit(acct, alice, 50_000e6);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.AuctionEnded(acct, weth, 0);
        liquidation.endAuction(acct, weth, _empty());
        assertEq(liquidation.auctionStart(acct, weth), 0);
    }

    /// @dev Above MM but below IM x 1.05: the auction is still needed.
    function test_LIQ011_cannotEndBelowTarget() public {
        _underwater();
        _start();
        IPortfolioRiskManager.Risk memory r = _riskOf(acct);
        _deposit(acct, alice, (r.initialMargin - uint256(r.equity)) / 1e12 + 1); // equity just above IM
        vm.expectRevert(AuctionActive.selector);
        liquidation.endAuction(acct, weth, _empty());
    }

    function test_LIQ011_sliceReachingTargetEndsAuction() public {
        _underwater();
        _start();
        IPortfolioRiskManager.Risk memory r = _riskOf(acct);
        // bring equity to IM: above MM, below IM x 1.05, so the auction still runs
        _deposit(acct, alice, (r.initialMargin - uint256(r.equity)) / 1e12 + 1);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.AuctionEnded(acct, weth, 0);
        _slice(2500);
        assertEq(liquidation.auctionStart(acct, weth), 0);
    }

    function test_LIQ011_expiredBucketEnds() public {
        _underwater();
        _start();
        vm.warp(EXP30);
        vm.expectEmit(true, true, true, true, address(liquidation));
        emit ILiquidationModule.AuctionEnded(acct, weth, 1);
        liquidation.endAuction(acct, weth, _empty());
    }

    // ------------------------------------------------------------------ LIQ-012 / LIQ-013

    function test_LIQ012_expiredAndFinalizedLegsStay() public {
        bytes32 p5000 = _series(ethUsdc, OptionType.PUT, 5000e18, T0 + 45 days);
        _deposit(acct, alice, 3000e6);
        _hold(acct, c4500, -1e18);
        _hold(acct, p5000, -1e18);
        vm.warp(T0 + 10 days);
        _flatMarket(6200e18, 0.6e18);
        _start();
        vm.warp(EXP30 + 1);
        _flatMarket(6200e18, 0.6e18);
        settlementState.finalize(group30, 6200e18);
        _slice(2500);
        assertEq(ledger.balanceOf(acct, c4500), -1e18, "expired, finalized leg untouched");
        assertEq(ledger.balanceOf(acct, p5000), -0.75e18);
        assertEq(ledger.balanceOf(liq, c4500), 0);
    }

    function test_LIQ013_nettingWithTheLiquidator() public {
        _underwater();
        _hold(liq, c4500, 0.1e18);
        _start();
        (uint256 l0, uint256 s0) = ledger.totals(c4500);
        _slice(2500);
        (uint256 l1, uint256 s1) = ledger.totals(c4500);
        assertEq(int256(l1) - int256(s1), int256(l0) - int256(s0), "INV-24: net internal balance unchanged");
        assertLt(s1, s0, "total short fell through netting");
        assertEq(ledger.balanceOf(liq, c4500), -0.15e18);
    }

    function test_CLR020_liquidatorPositionLimits() public {
        _underwater();
        bytes32 btcCall = _series(btcUsdc, OptionType.CALL, 100_000e18, EXP30);
        _hold(liq, btcCall, 1e18);
        vm.prank(governance);
        ledger.setPositionLimits(16, 1);
        _start();
        vm.prank(keeper);
        vm.expectRevert(PositionLimit.selector);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
    }

    // ------------------------------------------------------------------ LIQ-015 / LIQ-016

    function test_LIQ015_freshness() public {
        _underwater();
        vm.warp(block.timestamp + 61);
        vm.expectPartialRevert(StaleSpot.selector);
        _start();
        _setSpot(ethUsdc, 6200e18);
        _start();
        vm.warp(block.timestamp + 400); // surface stale, within maxSurfaceStale: penalties apply
        _setSpot(ethUsdc, 6200e18);
        _slice(500);
        vm.warp(block.timestamp + 21_600);
        _setSpot(ethUsdc, 6200e18);
        vm.prank(keeper);
        vm.expectPartialRevert(StaleSurface.selector);
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
    }

    function test_LIQ016_liquidatorAccountChecks() public {
        _underwater();
        _start();
        vm.prank(alice);
        vm.expectRevert(InvalidRecipient.selector);
        liquidation.liquidateSlice(acct, weth, acct, 2500, 0, 0, _empty());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        vm.prank(governance);
        registry.setSettlementAssetApproved(address(usdt), true);
        vm.prank(keeper);
        uint256 other = ledger.createSubAccount(address(usdt));
        vm.prank(keeper);
        vm.expectRevert(AssetMismatch.selector);
        liquidation.liquidateSlice(acct, weth, other, 2500, 0, 0, _empty());
    }

    // ------------------------------------------------------------------ pauses and refunds

    function test_pauseLiquidate() public {
        _underwater();
        _start();
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.GLOBAL, bytes32(0), uint256(1) << PauseBits.LIQUIDATE);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.LIQUIDATE));
        liquidation.startAuction(acct, wbtc, _empty());
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.LIQUIDATE));
        liquidation.liquidateSlice(acct, weth, liq, 2500, 0, 0, _empty());
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.LIQUIDATE));
        liquidation.liquidateWithWrapper(acct, c4500, 1e18, liq, 0, _empty());
        _deposit(acct, alice, 50_000e6);
        liquidation.endAuction(acct, weth, _empty()); // ending is never paused
    }

    function test_refunds() public {
        _underwater();
        RejectsEth r = new RejectsEth();
        vm.deal(address(r), 1);
        vm.expectRevert(RefundFailed.selector);
        r.start{value: 1}(liquidation, acct, weth, _empty());
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        liquidation.startAuction{value: 10}(acct, weth, _empty());
        assertEq(stranger.balance, 1 ether, "unused value refunded");
        assertEq(address(liquidation).balance, 0);
    }
}
