// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultBase} from "./base/VaultBase.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {OptionType, SettlementProof} from "../src/Types.sol";
import "../src/Errors.sol";

/// Several writers mint into the SAME series and their collateral is pooled in one vault. These tests try to make a
/// malicious writer take collateral that belongs to someone else, and check that every writer gets exactly their own
/// share and that no writer's actions change what any other writer or holder receives.
contract VaultMultiWriterTest is VaultBase {
    address internal mallory = makeAddr("mallory"); // the malicious writer

    /// alice writes 5, carol writes 4, mallory writes 1. Bob and dave hold the tokens.
    function _threeWriters(OptionSeriesVault v) internal {
        _mint(v, alice, bob, 5e18);
        _mint(v, carol, dave, 4e18);
        _mint(v, mallory, bob, 1e18);
    }

    // ------------------------------------------------------------------ the entitlement is per writer

    function test_eachWriterGetsExactlyTheirOwnShare() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18); // residual rate 0.8 MON per option

        vm.prank(alice);
        assertEq(v.claimWriterResidual(5e18, alice), 4e18); // 5 * 0.8
        vm.prank(carol);
        assertEq(v.claimWriterResidual(4e18, carol), 3.2e18); // 4 * 0.8
        vm.prank(mallory);
        assertEq(v.claimWriterResidual(1e18, mallory), 0.8e18); // 1 * 0.8

        // holders (6 + 4 = 10 options at 0.2 MON) are paid in full from the same pool
        vm.prank(bob);
        v.redeem(6e18, bob);
        vm.prank(dave);
        v.redeem(4e18, dave);
        assertEq(mon.balanceOf(bob), 1.2e18);
        assertEq(mon.balanceOf(dave), 0.8e18);

        assertEq(v.collateralLocked(), 0);
        assertEq(mon.balanceOf(address(v)), 0); // 10 MON in, 10 MON out, no dust in this case
    }

    // ------------------------------------------------------------------ every way to take someone else's share

    function test_malloryCannotClaimMoreThanHisOwnShort() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);

        vm.startPrank(mallory);
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(1e18 + 1, mallory); // one wei more than he wrote
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(5e18, mallory); // alice's amount
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(10e18, mallory); // everyone's amount
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(type(uint256).max, mallory);
        vm.stopPrank();

        assertEq(mon.balanceOf(mallory), 0);
        assertEq(v.writerShortBalance(alice), 5e18); // untouched
        assertEq(v.writerShortBalance(carol), 4e18);
    }

    function test_malloryCannotClaimTwice() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);
        vm.startPrank(mallory);
        v.claimWriterResidual(1e18, mallory);
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(1, mallory);
        vm.stopPrank();
        assertEq(mon.balanceOf(mallory), 0.8e18);
    }

    /// Naming another writer as the receiver spends MALLORY's short and pays THAT address. He gains nothing.
    function test_receiverArgumentCannotBeUsedToTouchAnotherWritersShort() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);

        vm.prank(mallory);
        v.claimWriterResidual(1e18, alice); // pays alice, burns mallory's short
        assertEq(v.writerShortBalance(mallory), 0);
        assertEq(v.writerShortBalance(alice), 5e18); // alice's own short is untouched
        assertEq(mon.balanceOf(mallory), 0);

        vm.prank(alice);
        assertEq(v.claimWriterResidual(5e18, alice), 4e18); // and she still gets all of hers
    }

    /// The keeper batch pays each writer to that writer. It can never route one writer's residual to another.
    function test_payoutCannotRedirectAnyoneElsesMoney() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);

        address[] memory list = new address[](4);
        list[0] = alice;
        list[1] = carol;
        list[2] = mallory;
        list[3] = mallory; // the attacker also lists himself twice, hoping for a double pay
        vm.prank(mallory);
        v.payout(list);

        assertEq(mon.balanceOf(alice), 4e18);
        assertEq(mon.balanceOf(carol), 3.2e18);
        assertEq(mon.balanceOf(mallory), 0.8e18); // exactly his own, once
    }

    function test_malloryCannotCallPayAccountDirectly() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);
        vm.prank(mallory);
        vm.expectRevert(Unauthorized.selector);
        v.payAccount(alice);
    }

    function test_malloryCannotRedeemTokensHeDoesNotHold() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);
        vm.prank(mallory);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        v.redeem(1e18, mallory); // his tokens went to bob; he holds none
    }

    function test_beingAWriterGivesNoClaimOnTheTokensOrTheirPayout() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        _settle(v, 12.5e18);
        // mallory writes but holds no tokens: he cannot receive any HOLDER payout
        assertEq(v.balanceOf(mallory), 0);
        vm.prank(mallory);
        v.claimWriterResidual(1e18, mallory);
        assertEq(mon.balanceOf(mallory), 0.8e18); // only the residual on what he wrote, never the buyers' 0.2
    }

    function test_cannotClaimBeforeSettlement() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _threeWriters(v);
        vm.prank(mallory);
        vm.expectRevert(NotSettled.selector);
        v.claimWriterResidual(1e18, mallory);
        // and no way to pull collateral out early
        assertEq(mon.balanceOf(mallory), 0);
        assertEq(v.collateralLocked(), 10e18);
    }

    // ------------------------------------------------------------------ writers cannot affect each other

    /// A writer who mints a huge amount at the last second changes nothing for anyone else: entitlements are
    /// fixed per option at settlement, so other writers and holders receive exactly the same in both universes.
    function test_aLateHugeMintChangesNothingForOthers() public {
        OptionSeriesVault quiet = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
        OptionSeriesVault noisy = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
        _mint(quiet, alice, bob, 5e18);
        _mint(noisy, alice, bob, 5e18);

        // in one universe mallory piles in with a huge position just before expiry, and dumps tokens on bob
        vm.warp(expiry - 1);
        _mint(noisy, mallory, bob, 1_000e18);

        feed.push(_id(1, 1), 12.5e8, expiry - 100);
        feed.push(_id(1, 2), 1e8, expiry + 100);
        vm.warp(expiry + 200);
        quiet.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        noisy.settle(SettlementProof(_id(1, 1), _id(1, 2)));

        // the payout RATES are identical
        assertEq(quiet.buyerPayoutRate(), noisy.buyerPayoutRate());
        assertEq(quiet.writerResidualRate(), noisy.writerResidualRate());

        // alice's residual and bob's payout on the original 5 options are identical in both
        vm.prank(alice);
        uint256 aliceQuiet = quiet.claimWriterResidual(5e18, alice);
        uint256 balBeforeNoisy = mon.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceNoisy = noisy.claimWriterResidual(5e18, alice);
        assertEq(aliceQuiet, aliceNoisy);
        assertEq(mon.balanceOf(alice) - balBeforeNoisy, aliceNoisy);

        vm.prank(bob);
        (uint256 bobQuiet,) = quiet.redeem(5e18, bob);
        vm.prank(bob);
        (uint256 bobNoisy,) = noisy.redeem(5e18, bob);
        assertEq(bobQuiet, bobNoisy);

        _assertVaultSolvent(quiet);
        _assertVaultSolvent(noisy);
    }

    /// Order of claims among writers and holders never changes anyone's amount.
    function test_claimOrderNeverChangesAnyAmount() public {
        OptionSeriesVault a = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
        OptionSeriesVault b = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
        _threeWriters(a);
        _threeWriters(b);
        feed.push(_id(1, 1), 12.5e8, expiry - 100);
        feed.push(_id(1, 2), 1e8, expiry + 100);
        vm.warp(expiry + 200);
        a.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        b.settle(SettlementProof(_id(1, 1), _id(1, 2)));

        // vault a: writers first, then holders. vault b: holders first, then writers in reverse order.
        uint256 aAlice; uint256 aCarol; uint256 aMallory; uint256 aBob; uint256 aDave;
        vm.prank(alice);   aAlice = a.claimWriterResidual(5e18, alice);
        vm.prank(carol);   aCarol = a.claimWriterResidual(4e18, carol);
        vm.prank(mallory); aMallory = a.claimWriterResidual(1e18, mallory);
        vm.prank(bob);     (aBob,) = a.redeem(6e18, bob);
        vm.prank(dave);    (aDave,) = a.redeem(4e18, dave);

        uint256 bAlice; uint256 bCarol; uint256 bMallory; uint256 bBob; uint256 bDave;
        vm.prank(dave);    (bDave,) = b.redeem(4e18, dave);
        vm.prank(bob);     (bBob,) = b.redeem(6e18, bob);
        vm.prank(mallory); bMallory = b.claimWriterResidual(1e18, mallory);
        vm.prank(carol);   bCarol = b.claimWriterResidual(4e18, carol);
        vm.prank(alice);   bAlice = b.claimWriterResidual(5e18, alice);

        assertEq(aAlice, bAlice);
        assertEq(aCarol, bCarol);
        assertEq(aMallory, bMallory);
        assertEq(aBob, bBob);
        assertEq(aDave, bDave);
        assertEq(a.collateralLocked(), b.collateralLocked());
    }

    // ------------------------------------------------------------------ fuzz: N writers, an attacker, random everything

    /// Four writers with random sizes and a random settlement price. Every writer claims in a random order, an
    /// attacker tries to over-claim on top, and each honest writer must receive EXACTLY floor(short * rate / scale),
    /// never more and never less, whatever anyone else did.
    function testFuzz_everyWriterGetsExactlyTheirOwnEntitlement(
        uint64[4] memory sizes,
        uint32 priceSeed,
        uint8 orderSeed,
        bool isPut
    ) public {
        address[4] memory writers = [alice, carol, mallory, dave];
        OptionSeriesVault v = isPut
            ? _deploy(OptionType.PUT, address(wbtc), address(usdc), 60000e18, 10, 25, 0)
            : _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);

        uint256[4] memory short_;
        for (uint256 i; i < 4; i++) {
            short_[i] = bound(sizes[i], 1e16, 1e21);
            _mint(v, writers[i], bob, short_[i]);
        }

        uint256 price = bound(priceSeed, 1, 200_000) * 1e15; // 0.001 to 200 (calls) - puts use the same range
        if (isPut) price = bound(priceSeed, 1, 120_000) * 1e18; // up to 120,000 around the 60,000 strike
        _settle(v, price - (price % 1e10));

        uint256 rw = v.writerResidualRate();
        // the attacker (mallory, index 2) first tries to over-claim: every attempt must revert
        vm.startPrank(mallory);
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(short_[2] + 1, mallory);
        vm.expectRevert(InsufficientShortBalance.selector);
        v.claimWriterResidual(short_[0] + short_[1] + short_[2] + short_[3], mallory);
        vm.stopPrank();

        // everyone claims in a pseudo-random order
        uint256 start = orderSeed % 4;
        uint256 paidToWriters;
        address collateral = v.collateralAsset();
        for (uint256 k; k < 4; k++) {
            uint256 i = (start + k) % 4;
            uint256 before_ = _bal(collateral, writers[i]);
            vm.prank(writers[i]);
            uint256 got = v.claimWriterResidual(short_[i], writers[i]);
            assertEq(_bal(collateral, writers[i]) - before_, got);
            // exactly floor(short * rate / scale): never more, never less
            assertEq(got, (short_[i] * rw) / 1e18);
            paidToWriters += got;
        }

        // holders are still fully covered after every writer has been paid
        uint256 supply = v.totalSupply();
        vm.prank(bob);
        v.redeem(supply, bob);
        assertEq(v.totalSupply(), 0);
        assertEq(v.totalUnclaimedShortAmount(), 0);
        _assertVaultSolvent(v);
    }
}
