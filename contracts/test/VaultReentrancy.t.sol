// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultBase} from "./base/VaultBase.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {OptionType, SettlementProof, ADMIN_ROLE} from "../src/Types.sol";
import {ReentrantERC20, ReentrancyAttacker} from "./mocks/HostileTokens.sol";

/// A hostile collateral token calls back into the vault from inside transfer / transferFrom. The attacker is
/// a real writer and holder, so each reentrant call is one the vault WOULD accept if it were not guarded.
/// (Tokens are allowlisted and have no hooks; the guard is defense in depth.)
contract VaultReentrancyTest is VaultBase {
    ReentrantERC20 internal evil;
    ReentrancyAttacker internal attacker;
    OptionSeriesVault internal v;

    function setUp() public override {
        super.setUp();
        evil = new ReentrantERC20("Evil", "EVIL", 18);
        attacker = new ReentrancyAttacker();
        v = _deploy(OptionType.CALL, address(evil), address(usdc), 10e18, 10, 25, 0);

        // the attacker is a funded, approved writer
        evil.mint(address(attacker), 1000e18);
        attacker.approve(address(evil), address(v));
    }

    function _arm(bytes memory payload) internal {
        attacker.setPayload(address(v), payload);
        evil.arm(address(attacker), abi.encodeCall(ReentrancyAttacker.reenter, ()));
    }

    function _attackerMints(uint256 amount) internal {
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.mint, (amount, address(attacker))));
        assertTrue(ok, "outer mint should succeed");
    }

    function test_reentrancy_mintCannotBeReentered() public {
        _arm(abi.encodeCall(v.mint, (1e18, address(attacker))));
        _attackerMints(2e18);

        assertTrue(attacker.ran(), "the hook should have fired");
        assertFalse(attacker.succeeded(), "the reentrant mint must fail");
        // only the outer mint happened
        assertEq(v.totalShortAmount(), 2e18);
        assertEq(v.totalSupply(), 2e18);
        assertEq(v.collateralLocked(), 2e18);
        assertGe(evil.balanceOf(address(v)), v.collateralLocked() + v.accruedFees());
    }

    function test_reentrancy_redeemCannotBeReentered() public {
        _attackerMints(5e18);
        _settle(v, 12.5e18);

        // reenter redeem from inside the payout transfer
        _arm(abi.encodeCall(v.redeem, (1e18, address(attacker))));
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.redeem, (2e18, address(attacker))));
        assertTrue(ok);

        assertTrue(attacker.ran());
        assertFalse(attacker.succeeded(), "the reentrant redeem must fail");
        assertEq(v.totalSupply(), 3e18); // only the outer 2e18 was burned
        assertEq(v.totalBuyerPayoutClaimed(), 4e17); // 2 options * 0.2
    }

    function test_reentrancy_claimCannotBeReentered() public {
        _attackerMints(5e18);
        _settle(v, 12.5e18);

        _arm(abi.encodeCall(v.claimWriterResidual, (1e18, address(attacker))));
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.claimWriterResidual, (2e18, address(attacker))));
        assertTrue(ok);

        assertTrue(attacker.ran());
        assertFalse(attacker.succeeded(), "the reentrant claim must fail");
        assertEq(v.writerShortBalance(address(attacker)), 3e18); // only the outer claim
        assertEq(v.totalWriterResidualClaimed(), 16e17); // 2 options * 0.8
    }

    function test_reentrancy_claimCannotReenterRedeemAcrossFunctions() public {
        _attackerMints(5e18);
        _settle(v, 12.5e18);
        // while the claim is paying out, try to redeem instead
        _arm(abi.encodeCall(v.redeem, (1e18, address(attacker))));
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.claimWriterResidual, (2e18, address(attacker))));
        assertTrue(ok);
        assertFalse(attacker.succeeded());
        assertEq(v.totalSupply(), 5e18); // no redemption happened
    }

    function test_reentrancy_sweepFeesCannotBeReentered() public {
        _attackerMints(5e18);
        factory.setRole(ADMIN_ROLE, address(attacker), true);
        _arm(abi.encodeCall(v.sweepFees, ()));
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.sweepFees, ()));
        assertTrue(ok);
        assertTrue(attacker.ran());
        assertFalse(attacker.succeeded());
        assertEq(v.accruedFees(), 0);
    }

    function test_reentrancy_settleCannotBeUsedToReenterAnything() public {
        // settle makes no token call at all, so a hostile token has no hook to abuse during it
        _attackerMints(5e18);
        _arm(abi.encodeCall(v.mint, (1e18, address(attacker))));
        _settle(v, 12.5e18);
        assertFalse(attacker.ran(), "settle must not trigger any token transfer");
    }

    /// During a keeper payout, a hook tries to mint and to call payout again. Neither may double pay.
    function test_reentrancy_payoutCannotBeReentered() public {
        address holder = makeAddr("holderEOA");
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.mint, (5e18, holder)));
        assertTrue(ok);
        _settle(v, 12.5e18);

        // reenter with a mint while payAccount is paying out
        _arm(abi.encodeCall(v.mint, (1e18, address(attacker))));
        address[] memory list = new address[](1);
        list[0] = holder;
        vm.prank(keeper);
        v.payout(list);
        assertTrue(attacker.ran());
        assertFalse(attacker.succeeded(), "mint during payout must fail");
        assertEq(v.totalSupply(), 0);
        assertEq(evil.balanceOf(holder), 9.975e17); // paid exactly once
    }

    function test_reentrancy_payoutInsidePayoutPaysOnlyOnce() public {
        address holder = makeAddr("holderEOA");
        address holder2 = makeAddr("holderEOA2");
        (bool ok,) = attacker.forward(address(v), abi.encodeCall(v.mint, (5e18, holder)));
        assertTrue(ok);
        vm.prank(holder);
        v.transfer(holder2, 2e18);
        _settle(v, 12.5e18);

        address[] memory both = new address[](2);
        both[0] = holder;
        both[1] = holder2;
        // reentrant payout for everyone while the first account is being paid
        _arm(abi.encodeCall(v.payout, (both)));
        vm.prank(keeper);
        v.payout(both);

        assertEq(v.totalSupply(), 0);
        // total paid to holders is exactly the gross payout less fees, never more
        uint256 paid = evil.balanceOf(holder) + evil.balanceOf(holder2);
        assertEq(paid, 5e18 * 2e17 / 1e18 - v.accruedFees() + 5e15 /* mint fee */);
        assertGe(evil.balanceOf(address(v)), v.collateralLocked() + v.accruedFees());
    }
}
