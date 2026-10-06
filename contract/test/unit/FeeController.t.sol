// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {FeeController} from "../../src/fees/FeeController.sol";
import {InsuranceFund} from "../../src/insurance/InsuranceFund.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {IInsuranceFund} from "../../src/interfaces/IInsuranceFund.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {FeeOnTransferToken} from "../mocks/MockDependencies.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    NonExactTransfer,
    InvalidFeeConfig,
    InsufficientTreasury,
    TokensNotReceived
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for FeeController and InsuranceFund: FEE-001, FEE-003, FEE-004, FEE-006..FEE-013.
///         FEE-002 and FEE-005 need OptionClearing and VenueRouter (steps 9 and 12).
contract FeeControllerTest is RiskFixture {
    bytes32 internal c4500;
    address internal keeper = makeAddr("keeper");

    function _useRealReserves() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        c4500 = _series(ethUsdc, OptionType.CALL, 4500e18, EXP30);
        usdc.mint(clearing, 1_000_000e6);
        usdc.mint(router, 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(insurance), type(uint256).max);
        usdc.approve(address(fees), type(uint256).max);
    }

    /// @dev What OptionClearing will do: push the fee tokens, then notify.
    function _chargeSeller(uint256 fee) internal {
        vm.startPrank(clearing);
        usdc.transfer(address(fees), fee);
        fees.notifySellerFee(1, c4500, address(usdc), fee);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ initialization

    function test_initialState() public view {
        (uint16 s, uint16 b) = fees.feeRates();
        assertEq(s, 300);
        assertEq(b, 300);
        IFeeController.Split memory sp = fees.split();
        assertEq(sp.insuranceBps, 6000);
        assertEq(sp.treasuryBps, 3000);
        assertEq(sp.keeperBps, 1000);
        (address fc, address cl, address lm, address sw) = insurance.modules();
        assertEq(fc, address(fees));
        assertEq(cl, clearing);
        assertEq(lm, liquidationModule);
        assertEq(sw, settlementWindow);
    }

    function test_initializeChecks() public {
        IProtocolControl c = IProtocolControl(address(pc));
        address fImpl = address(new FeeController());
        address iImpl = address(new InsuranceFund());
        vm.startPrank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            fImpl,
            abi.encodeCall(
                FeeController.initialize,
                (
                    c,
                    IInsuranceFund(address(0)),
                    IPortfolioRiskManager(address(risk)),
                    IOptionSeriesRegistry(address(registry)),
                    clearing,
                    router,
                    settlementWindow
                )
            )
        );
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            iImpl, abi.encodeCall(InsuranceFund.initialize, (c, address(fees), address(0), clearing, clearing))
        );
        vm.stopPrank();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        insurance.initialize(c, address(fees), clearing, clearing, clearing);
    }

    // ------------------------------------------------------------------ FEE-001 / FEE-002: seller fee

    function test_FEE001_sellerFeeFormula() public view {
        // FEES.md §2: 10 × 4,500 calls marked at 106.77 at 300 bps → 1,067.75 × 3% = 32.0324 USDC, rounded up
        uint256 fee = fees.previewSellerFee(c4500, 10e18);
        (uint256 mid,,) = risk.priceOf(c4500);
        uint256 expected = (10 * mid * 300 / 10_000 + 1e12 - 1) / 1e12; // native, rounded up
        assertEq(fee, expected);
        assertApproxEqAbs(fee, 32.0324e6, 0.0001e6);
    }

    function test_FEE001_minimumSellerFee() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        fees.setMinSellerFee(address(usdc), 0.1e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.MinSellerFeeSet(address(usdc), 0.1e6);
        vm.prank(governance);
        fees.setMinSellerFee(address(usdc), 0.1e6);
        assertEq(fees.previewSellerFee(c4500, 0.01e18), 0.1e6, "tiny mint pays the minimum");
        assertGt(fees.previewSellerFee(c4500, 10e18), 0.1e6);
    }

    function test_FEE004_buyerFeeRoundsUp() public view {
        assertEq(fees.previewBuyerFee(100e6), 3e6);
        assertEq(fees.previewBuyerFee(1), 1, "0.03 of a unit rounds up to 1");
        assertEq(fees.previewBuyerFee(0), 0);
    }

    // ------------------------------------------------------------------ FEE-003: split

    function test_FEE003_splitIsExact() public {
        vm.startPrank(clearing);
        usdc.transfer(address(fees), 100e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.SellerFeeCharged(1, c4500, address(usdc), 100e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.FeeSplit(address(usdc), 100e6, 60e6, 30e6, 10e6);
        fees.notifySellerFee(1, c4500, address(usdc), 100e6);
        vm.stopPrank();
        assertEq(insurance.balanceOf(address(usdc)), 60e6);
        assertEq(fees.insuranceBalance(address(usdc)), 60e6);
        assertEq(fees.treasury(address(usdc)), 30e6);
        assertEq(fees.keeperReserve(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(address(insurance)), 60e6);
        assertEq(usdc.balanceOf(address(fees)), 40e6);
    }

    function test_FEE003_treasuryTakesTheRemainder() public {
        _chargeSeller(7); // 7 × 60% = 4.2 → 4; 7 × 10% = 0.7 → 0; treasury 3
        assertEq(insurance.balanceOf(address(usdc)), 4);
        assertEq(fees.keeperReserve(address(usdc)), 0);
        assertEq(fees.treasury(address(usdc)), 3);
    }

    function test_FEE011_notifyRequiresTokens() public {
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(TokensNotReceived.selector, 5e6, 0));
        fees.notifySellerFee(1, c4500, address(usdc), 5e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        fees.notifySellerFee(1, c4500, address(usdc), 0);
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, clearing));
        fees.notifyBuyerFee(clearing, c4500, address(usdc), 0); // buyer fees come from the router only
    }

    function test_FEE004_buyerFeeFromRouter() public {
        vm.startPrank(router);
        usdc.transfer(address(fees), 3e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.BuyerFeeCharged(alice, c4500, address(usdc), 3e6);
        fees.notifyBuyerFee(alice, c4500, address(usdc), 3e6);
        vm.stopPrank();
        assertEq(fees.treasury(address(usdc)), 0.9e6);
    }

    // ------------------------------------------------------------------ FEE-006: rates and split admin

    function test_FEE006_ratesAndSplit() public {
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeConfig.selector, 1));
        fees.setFeeRates(1001, 300);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeConfig.selector, 1));
        fees.setFeeRates(300, 1001);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.FeeRatesSet(1000, 0);
        fees.setFeeRates(1000, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeConfig.selector, 2));
        fees.setSplit(6000, 3000, 999);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.SplitSet(10_000, 0, 0);
        fees.setSplit(10_000, 0, 0);
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        fees.setFeeRates(0, 0);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        fees.setSplit(6000, 3000, 1000);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        fees.setMinSellerFee(address(usdc), 1);
    }

    // ------------------------------------------------------------------ FEE-007: treasury

    function test_FEE007_treasuryWithdrawal() public {
        _chargeSeller(100e6);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        fees.withdrawTreasury(address(usdc), 1, guardian);
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InsufficientTreasury.selector, 30e6 + 1, 30e6));
        fees.withdrawTreasury(address(usdc), 30e6 + 1, governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeConfig.selector, 3));
        fees.withdrawTreasury(address(usdc), 1, address(0));
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.TreasuryWithdrawn(address(usdc), 30e6, governance);
        fees.withdrawTreasury(address(usdc), 30e6, governance);
        vm.stopPrank();
        assertEq(usdc.balanceOf(governance), 30e6);
        assertEq(fees.keeperReserve(address(usdc)), 10e6, "INV-10: keeper reserve untouched");
        assertEq(insurance.balanceOf(address(usdc)), 60e6, "INV-10: insurance untouched");
    }

    // ------------------------------------------------------------------ FEE-008: keeper rewards

    function test_FEE008_rewards() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        fees.setRewards(address(usdc), 2e6, 0.5e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.RewardsSet(address(usdc), 2e6, 0.5e6);
        vm.prank(governance);
        fees.setRewards(address(usdc), 2e6, 0.5e6);
        fees.fundKeeperReserve(address(usdc), 10e6);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        fees.payFinalizeReward(address(usdc), keeper);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        fees.paySettleReward(address(usdc), keeper, uint64(block.timestamp));

        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.KeeperRewardPaid(address(usdc), keeper, 2e6, true);
        vm.prank(settlementWindow);
        assertEq(fees.payFinalizeReward(address(usdc), keeper), 2e6);

        uint64 fin = uint64(block.timestamp);
        assertEq(fees.settleRewardAt(address(usdc), fin), 0.5e6);
        vm.warp(block.timestamp + 1 hours);
        assertEq(fees.settleRewardAt(address(usdc), fin), 0.625e6, "+25% after an hour");
        vm.warp(block.timestamp + 11 hours);
        assertEq(fees.settleRewardAt(address(usdc), fin), 2e6, "capped at 4x");
        assertEq(fees.settleRewardAt(address(usdc), uint64(block.timestamp + 1)), 0.5e6, "future time: base");
        vm.prank(settlementWindow);
        assertEq(fees.paySettleReward(address(usdc), keeper, fin), 2e6);
        assertEq(usdc.balanceOf(keeper), 4e6);
        assertEq(fees.keeperReserve(address(usdc)), 6e6);

        // rewards never exceed the reserve, and a zero keeper gets nothing
        vm.prank(governance);
        fees.setRewards(address(usdc), 100e6, 100e6);
        vm.prank(settlementWindow);
        assertEq(fees.payFinalizeReward(address(usdc), keeper), 6e6);
        vm.prank(settlementWindow);
        assertEq(fees.paySettleReward(address(usdc), keeper, fin), 0, "empty reserve pays 0");
        fees.fundKeeperReserve(address(usdc), 1e6);
        vm.prank(settlementWindow);
        assertEq(fees.payFinalizeReward(address(usdc), address(0)), 0);
    }

    function test_FEE013_fundKeeperReserveChecks() public {
        vm.expectRevert(ZeroAmount.selector);
        fees.fundKeeperReserve(address(usdc), 0);
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 100e6);
        fot.approve(address(fees), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NonExactTransfer.selector, 100e6, 99e6));
        fees.fundKeeperReserve(address(fot), 100e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.KeeperReserveFunded(address(usdc), address(this), 5e6);
        fees.fundKeeperReserve(address(usdc), 5e6);
    }

    // ------------------------------------------------------------------ FEE-009 / FEE-010: insurance and minimums

    function test_FEE009_insuranceDeposit() public {
        vm.expectEmit(true, true, true, true, address(insurance));
        emit IInsuranceFund.InsuranceDeposited(address(usdc), address(this), 50e6);
        insurance.deposit(address(usdc), 50e6);
        assertEq(insurance.balanceOf(address(usdc)), 50e6);
        vm.expectRevert(ZeroAmount.selector);
        insurance.deposit(address(usdc), 0);
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 100e6);
        fot.approve(address(insurance), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NonExactTransfer.selector, 100e6, 99e6));
        insurance.deposit(address(fot), 100e6);
    }

    function test_FEE012_insuranceNotifyAndCover() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        insurance.notifyDeposit(address(usdc), 1);
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(TokensNotReceived.selector, 1, 0));
        insurance.notifyDeposit(address(usdc), 1);
        vm.startPrank(clearing); // a liquidation penalty pushed from custody
        usdc.transfer(address(insurance), 20e6);
        insurance.notifyDeposit(address(usdc), 20e6);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        insurance.cover(address(usdc), 1);
        uint256 before = usdc.balanceOf(clearing);
        vm.expectEmit(true, true, true, true, address(insurance));
        emit IInsuranceFund.InsurancePaid(address(usdc), liquidationModule, 15e6);
        vm.prank(liquidationModule);
        assertEq(insurance.cover(address(usdc), 15e6), 15e6);
        vm.prank(settlementWindow);
        assertEq(insurance.cover(address(usdc), 100e6), 5e6, "never more than the balance (INV-25 part)");
        vm.prank(settlementWindow);
        assertEq(insurance.cover(address(usdc), 1e6), 0);
        assertEq(usdc.balanceOf(clearing) - before, 20e6, "coverage goes only to custody");
        assertEq(insurance.balanceOf(address(usdc)), 0);
    }

    function test_FEE010_minimumsAndReserveHealth() public {
        assertTrue(fees.reservesHealthy(address(usdc)), "zero minimums");
        vm.prank(riskAdmin); // raising is instant
        fees.setMinimums(address(usdc), 100e6, 10e6);
        assertFalse(fees.reservesHealthy(address(usdc)));
        assertTrue(risk.isProductCloseOnly(ethUsdc), "the risk manager reads the real reserve check");
        insurance.deposit(address(usdc), 100e6);
        assertFalse(fees.reservesHealthy(address(usdc)));
        fees.fundKeeperReserve(address(usdc), 10e6);
        assertTrue(fees.reservesHealthy(address(usdc)));
        assertFalse(risk.isProductCloseOnly(ethUsdc));

        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        fees.setMinimums(address(usdc), 50e6, 10e6); // lowering needs governance
        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        fees.setMinimums(address(usdc), 200e6, 5e6); // lowering either one needs governance
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        fees.setMinimums(address(usdc), 200e6, 10e6);
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.MinimumsSet(address(usdc), 50e6, 5e6);
        vm.prank(governance);
        fees.setMinimums(address(usdc), 50e6, 5e6);
        IFeeController.AssetConfig memory c = fees.assetConfig(address(usdc));
        assertEq(c.minimumInsuranceSeed, 50e6);
        assertEq(c.minimumKeeperReserve, 5e6);
        vm.prank(guardian); // the guardian may raise too
        fees.setMinimums(address(usdc), 60e6, 5e6);
    }
}
