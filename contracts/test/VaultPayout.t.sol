// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultBase} from "./base/VaultBase.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {OptionType, SettlementProof} from "../src/Types.sol";
import "../src/Errors.sol";
import {BlacklistERC20} from "./mocks/HostileTokens.sol";

/// The keeper batch payout: pays everyone what they are owed, never blocks, never pays the caller.
contract VaultPayoutTest is VaultBase {
    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function test_payout_revertsBeforeSettlement() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(keeper);
        vm.expectRevert(NotSettled.selector);
        vault.payout(_list(bob));
    }

    function test_payout_paysHoldersAndWritersInOneCall() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);

        vm.prank(keeper);
        vault.payout(_list(bob, alice));

        assertEq(mon.balanceOf(bob), 9.975e17); // gross 1 MON less the 25 bps exercise fee
        assertEq(mon.balanceOf(alice), 4e18); // the writer's residual
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.writerShortBalance(alice), 0);
        assertEq(vault.totalUnclaimedShortAmount(), 0);
        assertEq(vault.collateralLocked(), 0);
        assertEq(vault.accruedFees(), 7.5e15);
        _assertVaultSolvent(vault);
    }

    function test_payout_neverPaysTheCaller() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(keeper);
        vault.payout(_list(bob, alice));
        assertEq(mon.balanceOf(keeper), 0);
        assertEq(vault.balanceOf(keeper), 0);
    }

    function test_payout_matchesOwnerCallsExactly() public {
        // two identical vaults: one paid by the keeper, one by the owners themselves
        OptionSeriesVault a = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
        OptionSeriesVault b = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
        _mint(a, alice, bob, 5e18);
        _mint(b, carol, dave, 5e18);
        feed.push(_id(1, 1), 12.5e8, expiry - 100);
        feed.push(_id(1, 2), 1e8, expiry + 100);
        vm.warp(expiry + 200);
        a.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        b.settle(SettlementProof(_id(1, 1), _id(1, 2)));

        vm.prank(keeper);
        a.payout(_list(bob, alice));
        vm.prank(dave);
        b.redeem(5e18, dave);
        vm.prank(carol);
        b.claimWriterResidual(5e18, carol);

        assertEq(mon.balanceOf(bob), mon.balanceOf(dave));
        assertEq(mon.balanceOf(alice), mon.balanceOf(carol));
        assertEq(a.collateralLocked(), b.collateralLocked());
        assertEq(a.accruedFees(), b.accruedFees());
        assertEq(a.totalBuyerPayoutClaimed(), b.totalBuyerPayoutClaimed());
        assertEq(a.totalWriterResidualClaimed(), b.totalWriterResidualClaimed());
        assertEq(mon.balanceOf(address(a)), mon.balanceOf(address(b)));
    }

    function test_payout_duplicatesAndZeroOwedAreNoOps() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);

        address[] memory l = new address[](6);
        l[0] = bob;
        l[1] = bob; // duplicate: nothing more to pay
        l[2] = carol; // owed nothing
        l[3] = address(0); // skipped
        l[4] = alice;
        l[5] = alice; // duplicate
        vm.prank(keeper);
        vault.payout(l);

        assertEq(mon.balanceOf(bob), 9.975e17); // paid once
        assertEq(mon.balanceOf(alice), 4e18); // paid once
        assertEq(mon.balanceOf(carol), 0);
        _assertVaultSolvent(vault);
    }

    function test_payout_accountThatIsBothHolderAndWriterGetsBoth() public {
        _mint(vault, alice, alice, 5e18); // alice writes and keeps the tokens
        _settle(vault, 12.5e18);
        vm.prank(keeper);
        vault.payout(_list(alice));
        assertEq(mon.balanceOf(alice), 9.975e17 + 4e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.writerShortBalance(alice), 0);
        assertEq(vault.collateralLocked(), 0);
    }

    function test_payout_afterOwnersAlreadyActedIsANoOp() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(5e18, bob);
        vm.prank(alice);
        vault.claimWriterResidual(5e18, alice);
        uint256 locked = vault.collateralLocked();
        uint256 fees = vault.accruedFees();

        vm.prank(keeper);
        vault.payout(_list(bob, alice));
        assertEq(vault.collateralLocked(), locked);
        assertEq(vault.accruedFees(), fees);
        assertEq(mon.balanceOf(bob), 9.975e17);
    }

    function test_payout_partialOwnerRedemptionThenKeeperPaysTheRest() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(2e18, bob); // bob redeems part himself
        vm.prank(keeper);
        vault.payout(_list(bob)); // the keeper redeems the rest of his balance
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_payout_outOfTheMoney() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 9e18);
        vm.prank(keeper);
        vault.payout(_list(bob, alice));
        assertEq(mon.balanceOf(bob), 0); // worthless: burned, nothing paid, no fee
        assertEq(vault.balanceOf(bob), 0);
        assertEq(mon.balanceOf(alice), 5e18); // the whole collateral back
        assertEq(vault.accruedFees(), 5e15); // only the mint fee
    }

    // ------------------------------------------------------------------ contracts are skipped

    /// A contract may hold option tokens on behalf of other people (for example an order book). Redeeming
    /// them without its knowledge would break its accounting, so payout skips every address with code.
    function test_payout_skipsContractHolders() public {
        _mint(vault, alice, bob, 5e18);
        vm.etch(bob, hex"00"); // bob is now a contract
        _settle(vault, 12.5e18);

        vm.prank(keeper);
        vault.payout(_list(bob, alice));
        assertEq(vault.balanceOf(bob), 5e18); // untouched
        assertEq(mon.balanceOf(bob), 0);
        assertEq(mon.balanceOf(alice), 4e18); // the EOA writer was still paid

        // the contract can still redeem for itself
        vm.prank(bob);
        vault.redeem(5e18, bob);
        assertEq(mon.balanceOf(bob), 9.975e17);
    }

    function test_payout_skipsContractWriters() public {
        _mint(vault, alice, bob, 5e18);
        vm.etch(alice, hex"00");
        _settle(vault, 12.5e18);
        vm.prank(keeper);
        vault.payout(_list(alice));
        assertEq(vault.writerShortBalance(alice), 5e18); // still owed, claimed by the contract itself
        vm.prank(alice);
        vault.claimWriterResidual(5e18, alice);
        assertEq(mon.balanceOf(alice), 4e18);
    }

    function test_payout_skipsTheVaultItself() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(keeper);
        vault.payout(_list(address(vault)));
        assertEq(vault.totalSupply(), 5e18); // nothing happened
    }

    // ------------------------------------------------------------------ access

    function test_payAccount_onlyTheVaultItselfCanCallIt() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(keeper);
        vm.expectRevert(Unauthorized.selector);
        vault.payAccount(bob);
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.payAccount(bob);
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        vault.payAccount(bob); // not even the admin
    }

    // ------------------------------------------------------------------ non-blocking

    /// One recipient the token refuses to pay must not block anyone else, and its own state must be untouched.
    function test_payout_oneFailingRecipientDoesNotBlockTheRest() public {
        BlacklistERC20 bl = new BlacklistERC20("Blacklisting USD", "BUSD", 6);
        // a put collateralized in the blacklisting token
        OptionSeriesVault put = _deploy(OptionType.PUT, address(mon), address(bl), 10e18, 0, 0, 0);
        _mint(put, alice, bob, 1e18);
        vm.prank(bob);
        put.transfer(carol, 4e17);
        vm.prank(bob);
        put.transfer(dave, 3e17); // bob 0.3, carol 0.4, dave 0.3

        _settle(put, 5e18); // a put, in the money
        bl.setBlacklisted(bob, true);

        address[] memory l = new address[](3);
        l[0] = bob;
        l[1] = carol;
        l[2] = dave;
        vm.prank(keeper);
        put.payout(l); // must not revert

        assertEq(bl.balanceOf(carol), 2e6); // 0.4 * 5 USDC
        assertEq(bl.balanceOf(dave), 1.5e6); // 0.3 * 5 USDC
        assertEq(put.balanceOf(carol), 0);
        assertEq(put.balanceOf(dave), 0);

        // the failing account is rolled back completely: its tokens are still there and still owed
        assertEq(put.balanceOf(bob), 3e17);
        assertEq(bl.balanceOf(bob), 0);
        assertEq(put.totalSupply(), 3e17);
        _assertVaultSolvent(put);

        // once the token stops refusing, the same call pays him
        bl.setBlacklisted(bob, false);
        vm.prank(keeper);
        put.payout(_list(bob));
        assertEq(bl.balanceOf(bob), 1.5e6);
        assertEq(put.totalSupply(), 0);
    }

    function test_payout_aFailingWriterDoesNotBlockHolders() public {
        BlacklistERC20 bl = new BlacklistERC20("Blacklisting USD", "BUSD", 6);
        OptionSeriesVault put = _deploy(OptionType.PUT, address(mon), address(bl), 10e18, 0, 0, 0);
        _mint(put, alice, bob, 1e18);
        _settle(put, 5e18);
        bl.setBlacklisted(alice, true); // the writer cannot be paid

        vm.prank(keeper);
        put.payout(_list(alice, bob));
        assertEq(bl.balanceOf(bob), 5e6);
        assertEq(put.writerShortBalance(alice), 1e18); // still owed
        _assertVaultSolvent(put);
    }

    // ------------------------------------------------------------------ scale

    function test_payout_manyAccounts_gasAndSolvency() public {
        uint256 n = 50;
        address[] memory accounts = new address[](n + 1);
        _fund(vault, alice, 50e18);
        vm.prank(alice);
        vault.mint(50e18, alice);
        for (uint256 i; i < n; i++) {
            address holder = address(uint160(0x10000 + i));
            accounts[i] = holder;
            vm.prank(alice);
            vault.transfer(holder, 1e18);
        }
        accounts[n] = alice;
        _settle(vault, 12.5e18);

        vm.prank(keeper);
        uint256 g = gasleft();
        vault.payout(accounts);
        uint256 used = g - gasleft();
        emit log_named_uint("gas for a 51 account payout", used);
        emit log_named_uint("gas per account", used / (n + 1));

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalUnclaimedShortAmount(), 0);
        assertEq(vault.collateralLocked(), 0);
        _assertVaultSolvent(vault);
        assertLt(used / (n + 1), 200_000); // sanity bound on cost per account
    }

    // ------------------------------------------------------------------ gas floor

    /// With too little gas the call must REVERT, never silently skip accounts. (A gas estimator looks for the
    /// smallest limit at which the outer call survives; without this floor it would pick one that starves the
    /// try/catch'd accounts and pays only some of them.)
    function test_payout_revertsLoudlyWhenGasIsTooLow() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        address[] memory l = _list(bob, alice);

        vm.prank(keeper);
        vm.expectRevert(InsufficientGas.selector);
        vault.payout{gas: 240_000}(l); // below the per-account floor: refuses to start
        assertEq(vault.totalSupply(), 5e18); // nothing was skipped silently, nothing happened

        vm.prank(keeper);
        vault.payout{gas: 1_500_000}(l); // with enough gas everyone is paid
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.writerShortBalance(alice), 0);
    }

    /// Every account in a batch is paid whenever the call does not revert: there is no gas level at which the
    /// call succeeds but leaves an EOA account unpaid because the vault ran out of gas.
    function test_payout_neverSucceedsWhileSilentlyLeavingAnAccountUnpaid() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        address[] memory l = _list(bob, alice);
        uint256 snapshot = vm.snapshotState();

        for (uint256 gasLimit = 200_000; gasLimit <= 1_200_000; gasLimit += 25_000) {
            vm.revertToState(snapshot);
            vm.prank(keeper);
            (bool ok,) = address(vault).call{gas: gasLimit}(abi.encodeCall(vault.payout, (l)));
            if (ok) {
                assertEq(vault.totalSupply(), 0, "succeeded but left a holder unpaid");
                assertEq(vault.writerShortBalance(alice), 0, "succeeded but left a writer unpaid");
            }
        }
    }
}
