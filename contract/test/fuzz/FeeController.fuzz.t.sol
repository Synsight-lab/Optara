// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice Fee properties: exact split (INV-9), seller fee rounding (FEE-001), buyer fee rounding (FEE-004),
///         reward escalation bounded by 4× and by the reserve (INV-37).
contract FeeControllerFuzzTest is RiskFixture {
    bytes32 internal c4500;

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        c4500 = _series(ethUsdc, OptionType.CALL, 4500e18, EXP30);
        usdc.mint(clearing, type(uint128).max);
        usdc.mint(address(this), type(uint128).max);
        usdc.approve(address(fees), type(uint256).max);
    }

    function testFuzz_INV9_splitSumsExactly(uint128 fee, uint16 ins, uint16 keep) public {
        ins = uint16(bound(ins, 0, 10_000));
        keep = uint16(bound(keep, 0, 10_000 - ins));
        vm.prank(governance);
        fees.setSplit(ins, uint16(10_000 - ins - keep), keep);
        uint256 t0 = fees.treasury(address(usdc));
        uint256 k0 = fees.keeperReserve(address(usdc));
        uint256 i0 = insurance.balanceOf(address(usdc));
        vm.startPrank(clearing);
        usdc.transfer(address(fees), fee);
        fees.notifySellerFee(1, c4500, address(usdc), fee);
        vm.stopPrank();
        uint256 di = insurance.balanceOf(address(usdc)) - i0;
        uint256 dk = fees.keeperReserve(address(usdc)) - k0;
        uint256 dt = fees.treasury(address(usdc)) - t0;
        assertEq(di + dk + dt, fee, "parts sum to the fee");
        assertEq(di, uint256(fee) * ins / 10_000, "insurance rounded down");
        assertEq(dk, uint256(fee) * keep / 10_000, "keeper rounded down");
    }

    function testFuzz_FEE001_sellerFeeRoundsUp(uint256 qty, uint16 bps, uint64 minFee) public {
        qty = bound(qty, 1e16, 1000e18) / 1e16 * 1e16;
        bps = uint16(bound(bps, 0, 1000));
        minFee = uint64(bound(minFee, 0, 10e6));
        vm.startPrank(governance);
        fees.setFeeRates(bps, 300);
        fees.setMinSellerFee(address(usdc), minFee);
        vm.stopPrank();
        uint256 fee = fees.previewSellerFee(c4500, qty);
        (uint256 mid,,) = risk.priceOf(c4500);
        uint256 markWad = qty * mid / 1e18; // CS = 1
        uint256 exactNum = markWad * bps; // fee × 10_000 × 1e12
        uint256 pct = (exactNum + 10_000 * 1e12 - 1) / (10_000 * 1e12);
        assertEq(fee, pct > minFee ? pct : minFee);
        assertGe(fee * 10_000 * 1e12, exactNum, "never below the exact fee");
    }

    function testFuzz_FEE004_buyerFeeRoundsUp(uint128 premium, uint16 bps) public {
        bps = uint16(bound(bps, 0, 1000));
        vm.prank(governance);
        fees.setFeeRates(300, bps);
        uint256 fee = fees.previewBuyerFee(premium);
        assertGe(fee * 10_000, uint256(premium) * bps);
        assertLt(fee * 10_000, uint256(premium) * bps + 10_000);
    }

    function testFuzz_INV37_rewardsBounded(uint64 base, uint32 elapsed, uint64 reserve) public {
        base = uint64(bound(base, 0, 1e12));
        reserve = uint64(bound(reserve, 1, 1e12));
        vm.prank(governance);
        fees.setRewards(address(usdc), base, base);
        fees.fundKeeperReserve(address(usdc), reserve);
        uint64 fin = uint64(block.timestamp);
        vm.warp(block.timestamp + elapsed);
        uint256 r = fees.settleRewardAt(address(usdc), fin);
        assertGe(r, base, "never below base");
        assertLe(r, uint256(base) * 4, "capped at 4x");
        vm.warp(block.timestamp + 1 hours);
        assertGe(fees.settleRewardAt(address(usdc), fin), r, "non-decreasing in time");
        vm.prank(settlementWindow);
        uint256 paid = fees.paySettleReward(address(usdc), makeAddr("k"), fin);
        assertLe(paid, reserve, "never above the reserve");
        assertEq(fees.keeperReserve(address(usdc)), reserve - paid);
    }
}
