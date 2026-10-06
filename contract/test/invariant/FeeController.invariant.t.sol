// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice Random fees, deposits, rewards, coverage, withdrawals and split changes. Recorded balances must equal
///         the tokens held, fee parts must sum to the fees (INV-9), rewards never exceed the reserve and treasury
///         withdrawals never touch insurance or the keeper reserve (INV-10, INV-37).
contract FeeControllerInvariantTest is RiskFixture {
    bytes32 internal c4500;
    uint256 public totalFees;
    uint256 public feeToInsurance;
    uint256 public feeToTreasury;
    uint256 public feeToKeeper;
    uint256 public violations;
    uint256 public calls;

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        c4500 = _series(ethUsdc, OptionType.CALL, 4500e18, EXP30);
        usdc.mint(clearing, type(uint128).max);
        usdc.mint(router, type(uint128).max);
        usdc.mint(address(this), type(uint128).max);
        usdc.approve(address(fees), type(uint256).max);
        usdc.approve(address(insurance), type(uint256).max);
        vm.prank(governance);
        fees.setRewards(address(usdc), 2e6, 0.5e6);
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = this.h_sellerFee.selector;
        sel[1] = this.h_buyerFee.selector;
        sel[2] = this.h_depositInsurance.selector;
        sel[3] = this.h_fundKeeper.selector;
        sel[4] = this.h_reward.selector;
        sel[5] = this.h_cover.selector;
        sel[6] = this.h_withdraw.selector;
        sel[7] = this.h_split.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    function _trackSplit(uint256 fee, uint256 i0, uint256 t0, uint256 k0) internal {
        totalFees += fee;
        feeToInsurance += insurance.balanceOf(address(usdc)) - i0;
        feeToTreasury += fees.treasury(address(usdc)) - t0;
        feeToKeeper += fees.keeperReserve(address(usdc)) - k0;
        calls++;
    }

    function h_sellerFee(uint64 fee) external {
        (uint256 i0, uint256 t0, uint256 k0) =
            (insurance.balanceOf(address(usdc)), fees.treasury(address(usdc)), fees.keeperReserve(address(usdc)));
        vm.startPrank(clearing);
        usdc.transfer(address(fees), fee);
        fees.notifySellerFee(1, c4500, address(usdc), fee);
        vm.stopPrank();
        _trackSplit(fee, i0, t0, k0);
    }

    function h_buyerFee(uint64 fee) external {
        (uint256 i0, uint256 t0, uint256 k0) =
            (insurance.balanceOf(address(usdc)), fees.treasury(address(usdc)), fees.keeperReserve(address(usdc)));
        vm.startPrank(router);
        usdc.transfer(address(fees), fee);
        fees.notifyBuyerFee(alice, c4500, address(usdc), fee);
        vm.stopPrank();
        _trackSplit(fee, i0, t0, k0);
    }

    function h_depositInsurance(uint64 amount) external {
        if (amount == 0) return;
        insurance.deposit(address(usdc), amount);
    }

    function h_fundKeeper(uint64 amount) external {
        if (amount == 0) return;
        fees.fundKeeperReserve(address(usdc), amount);
    }

    function h_reward(bool finalize, uint32 age) external {
        uint256 reserve = fees.keeperReserve(address(usdc));
        vm.prank(settlementWindow);
        uint256 paid = finalize
            ? fees.payFinalizeReward(address(usdc), makeAddr("keeper"))
            : fees.paySettleReward(address(usdc), makeAddr("keeper"), uint64(block.timestamp) - (age % 1 days));
        if (paid > reserve || fees.keeperReserve(address(usdc)) != reserve - paid) violations++;
    }

    function h_cover(uint64 amount) external {
        uint256 bal = insurance.balanceOf(address(usdc));
        vm.prank(liquidationModule);
        uint256 paid = insurance.cover(address(usdc), amount);
        if (paid > bal || paid > amount) violations++;
    }

    function h_withdraw(uint64 amount) external {
        uint256 t = fees.treasury(address(usdc));
        if (amount > t) return;
        (uint256 i0, uint256 k0) = (insurance.balanceOf(address(usdc)), fees.keeperReserve(address(usdc)));
        vm.prank(governance);
        fees.withdrawTreasury(address(usdc), amount, governance);
        if (insurance.balanceOf(address(usdc)) != i0 || fees.keeperReserve(address(usdc)) != k0) violations++;
    }

    function h_split(uint16 ins, uint16 keep) external {
        ins = uint16(bound(ins, 0, 10_000));
        keep = uint16(bound(keep, 0, 10_000 - ins));
        vm.prank(governance);
        fees.setSplit(ins, uint16(10_000 - ins - keep), keep);
    }

    // ------------------------------------------------------------------ invariants

    /// @dev Recorded balances equal the tokens each contract holds (no drift, no unbacked credit).
    function invariant_recordedEqualsHeld() public view {
        assertEq(usdc.balanceOf(address(fees)), fees.treasury(address(usdc)) + fees.keeperReserve(address(usdc)));
        assertEq(usdc.balanceOf(address(insurance)), insurance.balanceOf(address(usdc)));
    }

    /// @dev INV-9: every fee was split exactly.
    function invariant_INV9_feesSplitExactly() public view {
        assertEq(feeToInsurance + feeToTreasury + feeToKeeper, totalFees);
    }

    /// @dev INV-10 / INV-37 / INV-25: rewards ≤ reserve, coverage ≤ balance, withdrawals isolated.
    function invariant_INV37_noViolations() public view {
        assertEq(violations, 0);
    }

    function test_handlerPathsReachable() public {
        this.h_sellerFee(100e6);
        this.h_buyerFee(3e6);
        this.h_depositInsurance(50e6);
        this.h_fundKeeper(5e6);
        this.h_reward(true, 0);
        this.h_reward(false, 7200);
        this.h_cover(20e6);
        this.h_withdraw(10e6);
        this.h_split(5000, 2000);
        this.h_sellerFee(7);
        assertEq(calls, 3);
        invariant_recordedEqualsHeld();
        invariant_INV9_feesSplitExactly();
        invariant_INV37_noViolations();
    }
}
