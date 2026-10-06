// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClearingFixture} from "../utils/ClearingFixture.sol";

/// @notice Random deposits, withdrawals, mints, wraps, unwraps, closes, wrapper transfers and market moves across
///         three accounts and three series. After every call: custody = Σ cash (INV-7, no pools before step 11),
///         wrappers + internal longs = internal shorts (INV-1), totals = Σ balances (INV-2), participants = accounts
///         holding the group (INV-27), fee parts = fees charged (INV-9). Handlers also record any risk-increasing
///         success that left the account unhealthy (INV-11) and any deposit / unwrap / close that lowered health
///         (INV-13).
contract OptionClearingInvariantTest is ClearingFixture {
    uint256[3] internal accts;
    address[3] internal owners;
    bytes32[3] internal seriesList;
    uint256 public feesCharged;
    uint256 public violations;
    uint256 public successes;
    uint256 internal price = 4000e18;

    function setUp() public {
        _deployClearingMarket();
        (owners[0], owners[1], owners[2]) = (alice, alice, bob);
        for (uint256 i; i < 3; ++i) {
            accts[i] = _account(owners[i]);
            _deposit(accts[i], owners[i], 20_000e6);
        }
        (seriesList[0], seriesList[1], seriesList[2]) = (c4500, c5000, p3500);
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = this.h_deposit.selector;
        sel[1] = this.h_withdraw.selector;
        sel[2] = this.h_mint.selector;
        sel[3] = this.h_wrap.selector;
        sel[4] = this.h_unwrap.selector;
        sel[5] = this.h_closeWithWrapper.selector;
        sel[6] = this.h_closeWithInternalLong.selector;
        sel[7] = this.h_transfer.selector;
        sel[8] = this.h_market.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    // ------------------------------------------------------------------ handlers

    function h_deposit(uint8 a, uint64 amount) external {
        uint256 i = a % 3;
        amount = uint64(bound(amount, 1, 10_000e6));
        int256 h0 = _health(accts[i]);
        _deposit(accts[i], owners[i], amount);
        if (_health(accts[i]) < h0) violations++;
        successes++;
    }

    function h_withdraw(uint8 a, uint64 raw) external {
        uint256 i = a % 3;
        uint256 maxW = risk.maxWithdrawable(accts[i]);
        if (maxW == 0) return;
        uint256 amount = bound(raw, 1, maxW);
        vm.prank(owners[i]);
        clearingModule.withdrawCollateral(accts[i], amount, owners[i], _empty());
        _checkHealthy(accts[i]);
        successes++;
    }

    function h_mint(uint8 a, uint8 s, uint16 raw) external {
        uint256 i = a % 3;
        bytes32 sid = seriesList[s % 3];
        uint256 qty = bound(raw, 1, 300) * 1e16;
        uint256 fee = fees.previewSellerFee(sid, qty);
        vm.prank(owners[i]);
        try clearingModule.mintExternalLong(accts[i], sid, qty, owners[i], type(uint256).max, _empty()) {
            feesCharged += fee;
            _checkHealthy(accts[i]);
            successes++;
        } catch {}
    }

    function h_wrap(uint8 a, uint8 s, uint16 raw) external {
        uint256 i = a % 3;
        bytes32 sid = seriesList[s % 3];
        int256 bal = ledger.balanceOf(accts[i], sid);
        if (bal <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 qty = bound(raw, 1, uint256(bal) / 1e16) * 1e16;
        vm.prank(owners[i]);
        try clearingModule.wrapLong(accts[i], sid, qty, owners[i], _empty()) {
            _checkHealthy(accts[i]);
            successes++;
        } catch {}
    }

    function h_unwrap(uint8 a, uint8 s, uint16 raw) external {
        uint256 i = a % 3;
        bytes32 sid = seriesList[s % 3];
        uint256 held = IERC20(_wrapper(sid)).balanceOf(owners[i]) / 1e16;
        if (held == 0) return;
        uint256 qty = bound(raw, 1, held) * 1e16;
        int256 h0 = _health(accts[i]);
        vm.prank(owners[i]);
        try clearingModule.unwrapLong(accts[i], sid, qty) {
            if (_health(accts[i]) < h0) violations++;
            successes++;
        } catch {}
    }

    function h_closeWithWrapper(uint8 a, uint8 s, uint16 raw) external {
        uint256 i = a % 3;
        bytes32 sid = seriesList[s % 3];
        int256 bal = ledger.balanceOf(accts[i], sid);
        uint256 held = IERC20(_wrapper(sid)).balanceOf(owners[i]);
        if (bal >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 maxQ = (uint256(-bal) < held ? uint256(-bal) : held) / 1e16;
        if (maxQ == 0) return;
        uint256 qty = bound(raw, 1, maxQ) * 1e16;
        int256 h0 = _health(accts[i]);
        vm.prank(owners[i]);
        clearingModule.closeShortWithWrapper(accts[i], sid, qty);
        if (_health(accts[i]) < h0) violations++;
        successes++;
    }

    /// @dev Between alice's two accounts (she is authorized for both).
    function h_closeWithInternalLong(bool dir, uint8 s, uint16 raw) external {
        (uint256 from, uint256 to) = dir ? (accts[0], accts[1]) : (accts[1], accts[0]);
        bytes32 sid = seriesList[s % 3];
        int256 fb = ledger.balanceOf(from, sid);
        int256 tb = ledger.balanceOf(to, sid);
        if (fb <= 0 || tb >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 maxQ = (uint256(fb) < uint256(-tb) ? uint256(fb) : uint256(-tb)) / 1e16;
        uint256 qty = bound(raw, 1, maxQ) * 1e16;
        int256 h0 = _health(to);
        vm.prank(alice);
        try clearingModule.closeShortWithInternalLong(from, to, sid, qty, _empty()) {
            _checkHealthy(from);
            if (_health(to) < h0) violations++;
            successes++;
        } catch {}
    }

    function h_transfer(bool toBob, uint8 s, uint16 raw) external {
        (address from, address to) = toBob ? (alice, bob) : (bob, alice);
        IERC20 w = IERC20(_wrapper(seriesList[s % 3]));
        uint256 held = w.balanceOf(from) / 1e16;
        if (held == 0) return;
        uint256 qty = bound(raw, 1, held) * 1e16; // whole position units, so the receiver can unwrap
        vm.prank(from);
        assertTrue(w.transfer(to, qty));
    }

    /// @dev 30 s pass; spot moves within ±5% (kept in [3000, 5500]) and a fresh surface is published.
    function h_market(int16 moveBps) external {
        moveBps = int16(bound(moveBps, -500, 500));
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(int256(price) * (10_000 + moveBps) / 10_000);
        if (price < 3000e18) price = 3000e18;
        if (price > 5500e18) price = 5500e18;
        vm.warp(block.timestamp + 30);
        clearingModule.updateOracles(_marketUpdate(price));
    }

    function _health(uint256 accountId) internal view returns (int256) {
        (, int256 e, uint256 im,,) = risk.healthOf(accountId);
        return e - int256(im);
    }

    function _checkHealthy(uint256 accountId) internal view {
        if (_health(accountId) < 0) revert("INV-11: risk-increasing success left the account unhealthy");
    }

    // ------------------------------------------------------------------ invariants

    function invariant_INV7_custodyEqualsCash() public view {
        uint256 cash;
        for (uint256 i; i < 3; ++i) {
            cash += ledger.cashOf(accts[i]);
        }
        assertEq(usdc.balanceOf(address(clearingModule)), cash);
    }

    function invariant_INV1_INV2_supplyAndTotals() public view {
        for (uint256 j; j < 3; ++j) {
            bytes32 sid = seriesList[j];
            (uint256 longs, uint256 shorts) = ledger.totals(sid);
            assertEq(IERC20(_wrapper(sid)).totalSupply() + longs, shorts, "INV-1");
            int256 sum;
            for (uint256 i; i < 3; ++i) {
                sum += ledger.balanceOf(accts[i], sid);
            }
            assertEq(sum, int256(longs) - int256(shorts), "INV-2");
        }
    }

    function invariant_INV27_participants() public view {
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                if (ledger.balanceOf(accts[i], seriesList[j]) != 0) {
                    ++n;
                    break;
                }
            }
        }
        assertEq(ledger.participants(group30), n);
    }

    function invariant_INV9_feesConserved() public view {
        assertEq(
            insurance.balanceOf(address(usdc)) + fees.treasury(address(usdc)) + fees.keeperReserve(address(usdc)),
            feesCharged
        );
    }

    function invariant_INV13_noViolations() public view {
        assertEq(violations, 0);
    }

    /// @dev Each run must make real progress, not just revert quietly inside try/catch.
    function afterInvariant() public view {
        assertGt(successes, 10, "handlers made progress");
    }

    function test_handlerPathsReachable() public {
        this.h_mint(0, 0, 100);
        this.h_mint(1, 1, 50);
        this.h_transfer(true, 0, 60);
        this.h_unwrap(2, 0, 30);
        this.h_wrap(2, 0, 10);
        this.h_closeWithWrapper(0, 0, 20);
        this.h_mint(0, 1, 50);
        this.h_unwrap(0, 1, 80); // alice holds 1.0 c5000: acct0 goes from -0.5 to +0.3
        this.h_closeWithInternalLong(true, 1, 30);
        this.h_market(200);
        this.h_withdraw(0, 1e6);
        this.h_deposit(2, 5e6);
        assertEq(successes, 10, "every success path above runs (transfer and market do not count)");
        invariant_INV7_custodyEqualsCash();
        invariant_INV1_INV2_supplyAndTotals();
        invariant_INV27_participants();
        invariant_INV9_feesConserved();
        invariant_INV13_noViolations();
    }
}
