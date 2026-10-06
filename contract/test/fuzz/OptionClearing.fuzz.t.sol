// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClearingFixture} from "../utils/ClearingFixture.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {NotHealthy} from "../../src/libraries/Errors.sol";

/// @notice Clearing properties over random quantities: INV-1/2/7/9 after mints, unwraps and closes; previews equal
///         execution (PRV-001, PRV-002); deposits, unwraps and closes never lower health (INV-13).
contract OptionClearingFuzzTest is ClearingFixture {
    uint256 internal writer;
    uint256 internal holder;

    function setUp() public {
        _deployClearingMarket();
        writer = _account(alice);
        holder = _account(bob);
    }

    /// @dev qty in [0.01, 50] contracts, a multiple of minPositionQty (0.01).
    function _qty(uint256 raw) internal pure returns (uint256) {
        return bound(raw, 1, 5000) * 1e16;
    }

    function _inv1and2(bytes32 s) internal view {
        (uint256 longs, uint256 shorts) = ledger.totals(s);
        assertEq(IERC20(_wrapper(s)).totalSupply() + longs, shorts, "INV-1");
        int256 sum = ledger.balanceOf(writer, s) + ledger.balanceOf(holder, s);
        assertEq(sum, int256(longs) - int256(shorts), "INV-2");
    }

    function testFuzz_mintUnwrapClose(uint256 rawMint, uint256 rawUnwrap, uint256 rawClose) public {
        uint256 q = _qty(rawMint);
        _deposit(writer, alice, q * 5000e6 / 1e18 + 100e6); // ample margin
        uint256 fee = fees.previewSellerFee(c4500, q);
        _mint(writer, alice, c4500, q);
        assertEq(ledger.cashOf(writer), q * 5000e6 / 1e18 + 100e6 - fee, "fee debited");
        assertEq(
            insurance.balanceOf(address(usdc)) + fees.treasury(address(usdc)) + fees.keeperReserve(address(usdc)),
            fee,
            "INV-9"
        );
        _inv1and2(c4500);

        uint256 u = bound(rawUnwrap, 0, q / 1e16) * 1e16;
        IERC20 w = IERC20(_wrapper(c4500));
        vm.prank(alice);
        assertTrue(w.transfer(bob, u));
        if (u != 0) {
            vm.prank(bob);
            clearingModule.unwrapLong(holder, c4500, u);
        }
        _inv1and2(c4500);

        uint256 c = bound(rawClose, 0, (q - u) / 1e16) * 1e16;
        if (c != 0) {
            (, int256 e0, uint256 im0,,) = risk.healthOf(writer);
            vm.prank(alice);
            clearingModule.closeShortWithWrapper(writer, c4500, c);
            (, int256 e1, uint256 im1,,) = risk.healthOf(writer);
            assertGe(e1 - int256(im1), e0 - int256(im0), "INV-13: closing never lowers health");
        }
        _inv1and2(c4500);
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(writer) + ledger.cashOf(holder), "INV-7");
    }

    function testFuzz_PRV001_previewMintMatches(uint256 rawQty, uint256 rawHedge, uint256 cash) public {
        uint256 q = _qty(rawQty);
        cash = bound(cash, 1e6, 500_000e6);
        _deposit(writer, alice, cash);
        uint256 h = bound(rawHedge, 0, 20) * 1e17;
        if (h != 0) _giveLongTo(writer, alice, h);
        (uint256 fee, int256 eq, uint256 im, bool ok) = clearingModule.previewMint(writer, c4500, q);
        vm.prank(alice);
        try clearingModule.mintExternalLong(writer, c4500, q, alice, fee, _empty()) {
            assertTrue(ok, "executed, so the preview said ok");
            IPortfolioRiskManager.Risk memory r = risk.riskOf(writer);
            assertEq(r.equity, eq);
            assertEq(r.initialMargin, im);
        } catch {
            assertFalse(ok, "reverted, so the preview said not ok");
        }
    }

    function testFuzz_PRV002_maxWithdrawableIsExact(uint256 rawQty, uint256 cash) public {
        uint256 q = _qty(rawQty);
        cash = bound(cash, q * 4000e6 / 1e18 + 10e6, 1_000_000e6);
        _deposit(writer, alice, cash);
        _mint(writer, alice, c4500, q);
        uint256 maxW = risk.maxWithdrawable(writer);
        if (maxW < ledger.cashOf(writer)) {
            vm.prank(alice);
            vm.expectPartialRevert(NotHealthy.selector);
            clearingModule.withdrawCollateral(writer, maxW + 1, alice, _empty());
        }
        if (maxW != 0) {
            vm.prank(alice);
            clearingModule.withdrawCollateral(writer, maxW, alice, _empty());
        }
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(writer), "INV-7");
    }

    function testFuzz_INV13_depositNeverLowersHealth(uint256 rawQty, uint256 extra) public {
        uint256 q = _qty(rawQty);
        _deposit(writer, alice, q * 5000e6 / 1e18 + 100e6);
        _mint(writer, alice, c4500, q);
        (, int256 e0, uint256 im0,,) = risk.healthOf(writer);
        extra = bound(extra, 1, 1e12);
        _deposit(writer, bob, extra);
        (, int256 e1, uint256 im1,,) = risk.healthOf(writer);
        assertEq(im1, im0);
        assertEq(e1 - e0, int256(extra) * 1e12);
    }

    function _giveLongTo(uint256 accountId, address owner, uint256 qty) internal {
        address helper = makeAddr("helperWriter");
        uint256 hAcct = _account(helper);
        _deposit(hAcct, helper, 100_000e6);
        _mint(hAcct, helper, c5000, qty);
        IERC20 w = IERC20(_wrapper(c5000));
        vm.prank(helper);
        assertTrue(w.transfer(owner, qty));
        vm.prank(owner);
        clearingModule.unwrapLong(accountId, c5000, qty);
    }
}
