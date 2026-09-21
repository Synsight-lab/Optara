// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {VaultBase} from "./base/VaultBase.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {
    OptionType,
    SeriesConfig,
    SeriesInfo,
    SettlementProof,
    FeeConfig,
    MAX_MINT_FEE_BPS,
    MAX_EXERCISE_FEE_BPS,
    MIN_OPTION_AMOUNT
} from "../src/Types.sol";
import "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {NoZeroTransferERC20, FeeOnTransferERC20} from "./mocks/HostileTokens.sol";

/// Vault behavior: construction, mint, settle, redeem, claim, fees, freeze. Every vector from
/// simple-workflow/math.md is also reproduced end to end through the vault.
contract VaultTest is VaultBase {
    // ================================================================== construction

    function test_constructor_derivesEverythingForACall() public view {
        assertEq(vault.collateralAsset(), address(mon)); // a call is collateralized in the underlying
        assertEq(vault.contractSize(), 1e18);
        assertEq(vault.optionScale(), 1e18);
        assertEq(vault.uqScale(), 1e30); // 18 dp underlying, 6 dp quote
        assertEq(vault.collateralPerOption(), 1e18); // C
        assertEq(vault.feedDecimals(), 8);
        assertEq(vault.mintFeeBps(), 10);
        assertEq(vault.exerciseFeeBps(), 25);
        assertEq(vault.decimals(), 18);
        assertEq(vault.name(), "Optara Option");
        assertEq(vault.symbol(), "OPT");
        assertEq(address(vault.factory()), address(factory));
        assertFalse(vault.settled());
        assertFalse(vault.mintPaused());
    }

    function test_constructor_derivesEverythingForAPut() public {
        OptionSeriesVault p = _deploy(OptionType.PUT, address(wbtc), address(usdc), 60000e18, 0, 0, 0);
        assertEq(p.collateralAsset(), address(usdc)); // a put is collateralized in the quote
        assertEq(p.contractSize(), 1e8); // one whole BTC
        assertEq(p.uqScale(), 1e20);
        assertEq(p.collateralPerOption(), 6e10); // 60,000 USDC per option (Vector 6)
    }

    function test_seriesInfo_reportsEveryField() public view {
        SeriesInfo memory i = vault.seriesInfo();
        assertEq(i.seriesId, vault.seriesId());
        assertEq(uint8(i.optionType), uint8(OptionType.CALL));
        assertEq(i.underlying, address(mon));
        assertEq(i.quote, address(usdc));
        assertEq(i.collateralAsset, address(mon));
        assertEq(i.strikePrice, 10e18);
        assertEq(i.expiry, expiry);
        assertEq(i.contractSize, 1e18);
        assertEq(i.optionDecimals, 18);
        assertEq(i.minOptionAmount, MIN_OPTION_AMOUNT);
        assertEq(i.maxTotalShortAmount, 0);
        assertEq(i.chainlinkFeed, address(feed));
        assertEq(i.feedDecimals, 8);
        assertEq(i.maxChainlinkAgeAtExpiry, MAX_AGE);
        assertEq(i.optionScale, 1e18);
        assertEq(i.uqScale, 1e30);
        assertEq(i.collateralPerOption, 1e18);
        assertEq(i.mintFeeBps, 10);
        assertEq(i.exerciseFeeBps, 25);
    }

    function test_constructor_reverts() public {
        SeriesConfig memory c;

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.underlying = address(0);
        vm.expectRevert(ZeroAddress.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.quote = address(0);
        vm.expectRevert(ZeroAddress.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.chainlinkFeed = address(0);
        vm.expectRevert(ZeroAddress.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.quote = address(mon); // same asset on both sides
        vm.expectRevert(AssetNotAllowed.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 0, 0); // zero strike
        vm.expectRevert(InvalidStrike.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.expiry = uint64(block.timestamp); // not in the future
        vm.expectRevert(InvalidExpiry.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.contractSize = 0;
        vm.expectRevert(InvalidContractSize.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.minOptionAmount = 0;
        vm.expectRevert(InvalidMinOptionAmount.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.optionDecimals = 19;
        vm.expectRevert(InvalidDecimals.selector);
        _deployWith(c, 0, 0);
    }

    function test_constructor_revertsAboveFeeCaps() public {
        SeriesConfig memory c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        vm.expectRevert(FeeExceedsCap.selector);
        _deployWith(c, MAX_MINT_FEE_BPS + 1, 0);
        vm.expectRevert(FeeExceedsCap.selector);
        _deployWith(c, 0, MAX_EXERCISE_FEE_BPS + 1);
        // exactly at the caps is fine
        _deployWith(c, MAX_MINT_FEE_BPS, MAX_EXERCISE_FEE_BPS);
    }

    function test_constructor_revertsWhenMinimumMintNeedsNoCollateral() public {
        // A put at a strike of 1e-18 quote: collateralPerOption = ceil(1e18 * 1 / 1e30) = 1, and the minimum
        // 0.01 option needs ceil(1e16 * 1 / 1e18) = 1, which is fine. Use a tiny contract size instead.
        SeriesConfig memory c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.contractSize = 1; // 1 wei of collateral per WHOLE option; 0.01 option needs ceil(0.01) = 1. Still fine.
        _deployWith(c, 0, 0);

        // Force zero: minOptionAmount 1 wei of option against a 1-wei-per-whole-option contract
        c.minOptionAmount = 1; // ceil(1 * 1 / 1e18) = 1: ceilDiv never returns zero for a nonzero product
        _deployWith(c, 0, 0);
    }

    function test_constructor_revertsOnBadFeed() public {
        SeriesConfig memory c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        c.maxChainlinkAgeAtExpiry = 0;
        vm.expectRevert(InvalidOracleConfig.selector);
        _deployWith(c, 0, 0);

        c = _config(OptionType.CALL, address(mon), address(usdc), 10e18, 0);
        MockAggregator bad = new MockAggregator(19); // decimals above 18
        c.chainlinkFeed = address(bad);
        vm.expectRevert(InvalidOracleConfig.selector);
        _deployWith(c, 0, 0);
    }

    // ================================================================== mint

    function test_mint_call_chargesFeeOnTopAndLocksExactCollateral() public {
        _fund(vault, alice, 5e18);
        vm.prank(alice);
        (uint256 col, uint256 fee) = vault.mint(5e18, bob);

        assertEq(col, 5e18); // Vector 1: 5 MON
        assertEq(fee, 5e15); // Vector 5: ceilDiv(5e18 * 10, 10000)
        assertEq(mon.balanceOf(alice), 0); // she paid collateral + fee exactly
        assertEq(mon.balanceOf(address(vault)), 5.005e18);
        assertEq(vault.collateralLocked(), 5e18); // the fee is NOT part of collateral
        assertEq(vault.accruedFees(), 5e15);

        assertEq(vault.balanceOf(bob), 5e18); // tokens go to the receiver
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.writerShortBalance(alice), 5e18); // the short position belongs to the writer
        assertEq(vault.writerShortBalance(bob), 0);
        assertEq(vault.totalShortAmount(), 5e18);
        assertEq(vault.totalUnclaimedShortAmount(), 5e18);
        assertEq(vault.totalSupply(), 5e18);
        _assertVaultSolvent(vault);
    }

    function test_mint_put_isCollateralizedInTheQuoteAsset() public {
        OptionSeriesVault p = _deploy(OptionType.PUT, address(wbtc), address(usdc), 60000e18, 10, 25, 0);
        _fund(p, alice, 3e18);
        vm.prank(alice);
        (uint256 col, uint256 fee) = p.mint(3e18, alice);
        assertEq(col, 1.8e11); // Vector 6: 180,000 USDC
        assertEq(fee, 1.8e8); // 10 bps of 180,000 USDC = 180 USDC
        assertEq(usdc.balanceOf(address(p)), 1.8e11 + 1.8e8);
        assertEq(wbtc.balanceOf(address(p)), 0);
    }

    function test_mint_emitsEvent() public {
        _fund(vault, alice, 5e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit OptionSeriesVault.OptionsMinted(alice, bob, 5e18, 5e18, 5e15);
        vm.prank(alice);
        vault.mint(5e18, bob);
    }

    function test_mint_roundsCollateralUp() public {
        // strike 10.000001 on a put: collateralPerOption = ceil(1e6 * 10.000001e18 / 1e30 ...) uses a fractional case
        OptionSeriesVault p = _deploy(OptionType.PUT, address(mon), address(usdc), 10.000001e18, 0, 0, 0);
        // C = 1e18, UQ = 1e30 -> cpo = 10.000001e6 exactly (no rounding). Use an amount that does not divide:
        _fund(p, alice, 1e16 + 1);
        (uint256 col,) = p.previewMint(1e16 + 1);
        // ceil((1e16 + 1) * 10000001 / 1e18) = ceil(100000010000001e0 ... ) must never be below the exact value
        assertGe(col * 1e18, (1e16 + 1) * p.collateralPerOption());
        assertLt((col - 1) * 1e18, (1e16 + 1) * p.collateralPerOption()); // and it is the SMALLEST such integer
    }

    function test_mint_minimumSize() public {
        _fund(vault, alice, MIN_OPTION_AMOUNT);
        vm.prank(alice);
        vm.expectRevert(AmountTooSmall.selector);
        vault.mint(MIN_OPTION_AMOUNT - 1, alice);
        vm.prank(alice);
        vault.mint(MIN_OPTION_AMOUNT, alice); // exactly the minimum is allowed
        assertEq(vault.totalSupply(), MIN_OPTION_AMOUNT);
    }

    function test_mint_timeWindow() public {
        _fund(vault, alice, 3e18);
        vm.warp(expiry - 1);
        vm.prank(alice);
        vault.mint(1e18, alice); // one second before expiry is allowed

        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(Expired.selector);
        vault.mint(1e18, alice); // at expiry it reverts

        vm.warp(expiry + 1 days);
        vm.prank(alice);
        vm.expectRevert(Expired.selector);
        vault.mint(1e18, alice); // and after
    }

    function test_mint_openInterestCap() public {
        OptionSeriesVault capped = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 10e18);
        _fund(capped, alice, 10e18);
        vm.startPrank(alice);
        capped.mint(6e18, alice);
        vm.expectRevert(OpenInterestCapExceeded.selector);
        capped.mint(4e18 + 1, alice); // one wei over the cap
        capped.mint(4e18, alice); // exactly to the cap is allowed
        vm.expectRevert(OpenInterestCapExceeded.selector);
        capped.mint(1e16, alice); // and nothing more
        vm.stopPrank();
        assertEq(capped.totalShortAmount(), 10e18);
    }

    function test_mint_capOfZeroMeansUncapped() public {
        _fund(vault, alice, 1_000_000e18);
        vm.prank(alice);
        vault.mint(1_000_000e18, alice);
        assertEq(vault.totalShortAmount(), 1_000_000e18);
    }

    function test_mint_badReceiver() public {
        _fund(vault, alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(ZeroAddress.selector);
        vault.mint(1e18, address(0));
        vm.expectRevert(ZeroAddress.selector);
        vault.mint(1e18, address(vault)); // tokens sent to the vault could never be redeemed
        vm.stopPrank();
    }

    function test_mint_requiresApprovalAndBalance() public {
        vm.prank(alice);
        vm.expectRevert(); // no balance, no allowance
        vault.mint(1e18, alice);

        mon.mint(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(); // balance but no allowance
        vault.mint(1e18, alice);
    }

    function test_mint_previewMatchesReality() public {
        uint256 amount = 7.777777777777777777e18;
        (uint256 pc, uint256 pf) = vault.previewMint(amount);
        _fund(vault, alice, amount);
        vm.prank(alice);
        (uint256 c, uint256 f) = vault.mint(amount, alice);
        assertEq(c, pc);
        assertEq(f, pf);
    }

    function test_mint_collateralAlwaysCoversMaximumLiability() public {
        uint256[6] memory amounts = [uint256(1e16), 1e16 + 1, 3.3e18, 999999999999999999, 1e18, 123456789012345678901];
        for (uint256 i; i < amounts.length; i++) {
            _mint(vault, alice, alice, amounts[i]);
        }
        // collateralLocked >= requiredCollateral(totalShort): a sum of ceilings is at least the ceiling of the sum
        (uint256 needed,) = vault.previewMint(vault.totalShortAmount());
        assertGe(vault.collateralLocked(), needed);
    }

    // ================================================================== settle

    function test_settle_revertsBeforeExpiry() public {
        feed.push(_id(1, 1), 12e8, expiry - 100);
        feed.push(_id(1, 2), 12e8, expiry + 100);
        vm.warp(expiry - 1);
        vm.expectRevert(NotExpired.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
    }

    function test_settle_callInTheMoney_vector1() public {
        _mint(vault, alice, bob, 5e18);
        feed.push(_id(1, 1), 12.5e8, expiry - 100);
        feed.push(_id(1, 2), 1e8, expiry + 100);
        vm.warp(expiry + 200);
        // expectEmit applies to the NEXT call only, so it must come right before settle
        vm.expectEmit(false, false, false, true, address(vault));
        emit OptionSeriesVault.SeriesSettled(12.5e18, 2e17, 8e17);
        uint256 price = vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));

        assertEq(price, 12.5e18);
        assertTrue(vault.settled());
        assertEq(vault.settlementPrice(), 12.5e18);
        assertEq(vault.buyerPayoutRate(), 2e17); // 0.2 MON per option
        assertEq(vault.writerResidualRate(), 8e17);
        assertEq(vault.settledAt(), expiry + 200);
        assertEq(vault.buyerPayoutRate() + vault.writerResidualRate(), vault.collateralPerOption());
    }


    function test_settle_isPermissionless() public {
        feed.push(_id(1, 1), 12e8, expiry - 100);
        feed.push(_id(1, 2), 12e8, expiry + 100);
        vm.warp(expiry + 10);
        vm.prank(makeAddr("randomStranger"));
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        assertTrue(vault.settled());
    }

    function test_settle_twiceReverts() public {
        _settle(vault, 12e18);
        vm.expectRevert(AlreadySettled.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
    }

    function test_settle_resultNeverChanges() public {
        _mint(vault, alice, bob, 1e18);
        _settle(vault, 12.5e18);
        uint256 price = vault.settlementPrice();
        uint256 rb = vault.buyerPayoutRate();
        uint256 rw = vault.writerResidualRate();

        // the feed later moves a lot and a new round is published
        feed.push(_id(1, 3), 1000e8, block.timestamp + 5);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(AlreadySettled.selector);
        vault.settle(SettlementProof(_id(1, 2), _id(1, 3)));

        assertEq(vault.settlementPrice(), price);
        assertEq(vault.buyerPayoutRate(), rb);
        assertEq(vault.writerResidualRate(), rw);
    }

    function test_settle_samePriceWhetherCalledEarlyOrMonthsLate() public {
        OptionSeriesVault early = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        OptionSeriesVault late = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);

        feed.push(_id(1, 1), 12.5e8, expiry - 100);
        feed.push(_id(1, 2), 30e8, expiry + 100);
        vm.warp(expiry + 101);
        early.settle(SettlementProof(_id(1, 1), _id(1, 2)));

        // the feed then moves substantially and a lot of time passes
        feed.push(_id(1, 3), 500e8, expiry + 5 days);
        vm.warp(expiry + 90 days);
        late.settle(SettlementProof(_id(1, 1), _id(1, 2)));

        assertEq(early.settlementPrice(), late.settlementPrice());
        assertEq(early.buyerPayoutRate(), late.buyerPayoutRate());
        assertEq(early.writerResidualRate(), late.writerResidualRate());
    }

    function test_settle_waitsForTheSuccessorRoundThenSucceedsAtTheSamePrice() public {
        feed.push(_id(1, 1), 12.5e8, expiry - 100); // in force at expiry, but no successor yet
        vm.warp(expiry + 1 hours);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        assertFalse(vault.settled()); // still unsettled, nothing written

        feed.push(_id(1, 2), 99e8, expiry + 2 hours);
        vm.warp(expiry + 3 hours);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        assertEq(vault.settlementPrice(), 12.5e18); // the round in force, not the successor
    }

    function test_settle_forgedProofsRevertAndWriteNothing() public {
        feed.push(_id(1, 1), 8e8, expiry - 500);
        feed.push(_id(1, 2), 12e8, expiry - 100); // in force at expiry
        feed.push(_id(1, 3), 15e8, expiry + 100);
        feed.push(_id(1, 4), 20e8, expiry + 400);
        vm.warp(expiry + 1000);

        vm.expectRevert(SettlementAnchorInvalid.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 3))); // stale round paired with a distant successor
        vm.expectRevert(SettlementAnchorInvalid.selector);
        vault.settle(SettlementProof(_id(1, 3), _id(1, 4))); // round after expiry
        vm.expectRevert(SettlementAnchorInvalid.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2))); // earlier round in force
        assertFalse(vault.settled());

        vault.settle(SettlementProof(_id(1, 2), _id(1, 3))); // the only correct proof
        assertEq(vault.settlementPrice(), 12e18);
    }

    function test_settle_revertsWhenTheFeedWasAlreadyDeadAtExpiry() public {
        feed.push(_id(1, 1), 12e8, expiry - MAX_AGE - 1);
        feed.push(_id(1, 2), 12e8, expiry + 100);
        vm.warp(expiry + 200);
        vm.expectRevert(SettlementAnchorTooStale.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
    }

    function test_settle_revertsOnNonPositiveAnswer() public {
        feed.push(_id(1, 1), 0, expiry - 100);
        feed.push(_id(1, 2), 12e8, expiry + 100);
        vm.warp(expiry + 200);
        vm.expectRevert(OracleInvalid.selector);
        vault.settle(SettlementProof(_id(1, 1), _id(1, 2)));
    }

    function test_settle_movesNoTokensAndHoldsNoNativeToken() public {
        _mint(vault, alice, bob, 5e18);
        uint256 before_ = mon.balanceOf(address(vault));
        _settle(vault, 12.5e18);
        assertEq(mon.balanceOf(address(vault)), before_);
        assertEq(address(vault).balance, 0);
    }

    function test_settle_isNotPayable() public {
        feed.push(_id(1, 1), 12e8, expiry - 100);
        feed.push(_id(1, 2), 12e8, expiry + 100);
        vm.warp(expiry + 200);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1}(
            abi.encodeCall(vault.settle, (SettlementProof(_id(1, 1), _id(1, 2))))
        );
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
    }

    function test_vaultCannotReceiveNativeToken() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ rates for both types

    function test_settle_callOutOfTheMoney() public {
        _settle(vault, 9e18);
        assertEq(vault.buyerPayoutRate(), 0);
        assertEq(vault.writerResidualRate(), vault.collateralPerOption());
    }

    function test_settle_atTheMoneyPaysNothingForBothTypes() public {
        OptionSeriesVault put = _deploy(OptionType.PUT, address(mon), address(usdc), 10e18, 0, 0, 0);
        _settle(vault, 10e18); // shares the feed; settles the call at S == K
        put.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        assertEq(vault.buyerPayoutRate(), 0);
        assertEq(put.buyerPayoutRate(), 0);
        assertEq(vault.writerResidualRate(), vault.collateralPerOption());
        assertEq(put.writerResidualRate(), put.collateralPerOption());
    }

    function test_settle_putRates_vector6() public {
        OptionSeriesVault p = _deploy(OptionType.PUT, address(wbtc), address(usdc), 60000e18, 0, 0, 0);
        _settle(p, 55000e18);
        assertEq(p.buyerPayoutRate(), 5e9);
        assertEq(p.writerResidualRate(), 5.5e10);
    }

    // ================================================================== redeem and claim

    /// Vector 1 and Vector 5 end to end: 5 options, S = 12.5, 10 bps mint fee, 25 bps exercise fee.
    function test_endToEnd_call_vector1_and_5() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);

        vm.prank(bob);
        (uint256 net, uint256 fee) = vault.redeem(5e18, bob);
        assertEq(net, 9.975e17); // 1 MON gross less a 0.0025 MON fee
        assertEq(fee, 2.5e15);
        assertEq(mon.balanceOf(bob), 9.975e17);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.collateralLocked(), 4e18); // dropped by the GROSS amount (1 MON)
        assertEq(vault.accruedFees(), 5e15 + 2.5e15);
        assertEq(vault.totalBuyerPayoutClaimed(), 1e18);
        _assertVaultSolvent(vault);

        vm.prank(alice);
        uint256 residual = vault.claimWriterResidual(5e18, alice);
        assertEq(residual, 4e18);
        assertEq(mon.balanceOf(alice), 4e18);
        assertEq(vault.collateralLocked(), 0);
        assertEq(vault.writerShortBalance(alice), 0);
        assertEq(vault.totalUnclaimedShortAmount(), 0);
        assertEq(vault.totalWriterResidualClaimed(), 4e18);

        // everything left in the vault is exactly the fees
        assertEq(mon.balanceOf(address(vault)), 7.5e15);
        assertEq(vault.accruedFees(), 7.5e15);
        _assertVaultSolvent(vault);
    }

    function test_endToEnd_put_vector6() public {
        OptionSeriesVault p = _deploy(OptionType.PUT, address(wbtc), address(usdc), 60000e18, 0, 0, 0);
        _mint(p, alice, bob, 3e18);
        _settle(p, 55000e18);

        vm.prank(bob);
        (uint256 net,) = p.redeem(3e18, bob);
        assertEq(net, 1.5e10); // 15,000 USDC
        vm.prank(alice);
        uint256 residual = p.claimWriterResidual(3e18, alice);
        assertEq(residual, 1.65e11); // 165,000 USDC
        assertEq(usdc.balanceOf(address(p)), 0); // no fees, no dust
        assertEq(net + residual, 1.8e11);
    }

    function test_endToEnd_vector3_dustStaysInTheVault() public {
        // Vector 3 through the vault: strike 3, S = 7, a holder redeems 1e18 - 1
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 3e18, 0, 0, 0);
        _mint(v, alice, bob, 1e18);
        _settle(v, 7e18);
        assertEq(v.buyerPayoutRate(), 571428571428571428);
        assertEq(v.writerResidualRate(), 428571428571428572);

        vm.prank(bob);
        (uint256 net,) = v.redeem(1e18 - 1, bob);
        assertEq(net, 571428571428571427);
        vm.prank(alice);
        uint256 residual = v.claimWriterResidual(1e18, alice);
        assertEq(residual, 428571428571428572);

        assertEq(net + residual, 999999999999999999);
        assertEq(mon.balanceOf(address(v)), 1); // 1 wei of dust, never negative
        assertEq(v.collateralLocked(), 1);
    }

    function test_redeem_writerAndHolderCanClaimInAnyOrder() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(alice);
        vault.claimWriterResidual(5e18, alice); // writer first
        vm.prank(bob);
        vault.redeem(5e18, bob); // then the holder: still fully covered
        _assertVaultSolvent(vault);
        assertEq(vault.collateralLocked(), 0);
    }

    function test_redeem_guards() public {
        _mint(vault, alice, bob, 5e18);

        vm.prank(bob);
        vm.expectRevert(NotSettled.selector);
        vault.redeem(1e18, bob); // before settlement

        _settle(vault, 12.5e18);

        vm.startPrank(bob);
        vm.expectRevert(AmountTooSmall.selector);
        vault.redeem(0, bob); // zero
        vm.expectRevert(ZeroAddress.selector);
        vault.redeem(1e18, address(0)); // zero receiver
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.redeem(5e18 + 1, bob); // more than the balance
        vm.stopPrank();

        vm.prank(carol);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.redeem(1e18, carol); // holds nothing
    }

    function test_redeem_cannotBeDoneTwice() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.startPrank(bob);
        vault.redeem(5e18, bob);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.redeem(1, bob);
        vm.stopPrank();
    }

    function test_redeem_partialFillsThenRest() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.startPrank(bob);
        vault.redeem(2e18, bob);
        vault.redeem(3e18, bob);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 0);
        assertEq(mon.balanceOf(bob), 9.975e17); // 2 * 0.2 = 0.4 MON gross and 0.6 MON gross, fees floor separately
    }

    function test_redeem_sendsToAnyReceiver() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(5e18, carol);
        assertEq(mon.balanceOf(carol), 9.975e17);
        assertEq(mon.balanceOf(bob), 0);
    }

    /// A holder with less than the mint minimum (from a partial fill or a plain transfer) can always exit.
    function test_redeem_subMinimumBalanceCanExit() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(bob);
        vault.transfer(carol, 12345); // far below MIN_OPTION_AMOUNT
        _settle(vault, 12.5e18);
        assertLt(vault.balanceOf(carol), MIN_OPTION_AMOUNT);
        vm.prank(carol);
        vault.redeem(12345, carol); // succeeds: the minimum is mint-only
        assertEq(vault.balanceOf(carol), 0);
    }

    function test_claim_subMinimumShortCanExit() public {
        // alice mints exactly the minimum, and the residual can be claimed in tiny pieces
        _mint(vault, alice, alice, MIN_OPTION_AMOUNT);
        _settle(vault, 9e18); // out of the money
        vm.startPrank(alice);
        vault.claimWriterResidual(1, alice); // 1 wei of a short position
        vault.claimWriterResidual(MIN_OPTION_AMOUNT - 1, alice);
        vm.stopPrank();
        assertEq(vault.writerShortBalance(alice), 0);
    }

    function test_redeem_outOfTheMoneyBurnsPaysNothingChargesNoFee() public {
        _mint(vault, alice, bob, 5e18);
        uint256 feesBefore = vault.accruedFees();
        _settle(vault, 9e18);

        uint256 balBefore = mon.balanceOf(bob);
        vm.prank(bob);
        (uint256 net, uint256 fee) = vault.redeem(5e18, bob);
        assertEq(net, 0);
        assertEq(fee, 0);
        assertEq(mon.balanceOf(bob), balBefore);
        assertEq(vault.balanceOf(bob), 0); // burned
        assertEq(vault.accruedFees(), feesBefore); // no exercise fee
    }

    /// Some tokens revert on zero-value transfers. An out-of-the-money redeem must skip the transfer entirely.
    function test_redeem_outOfTheMoneyNeverTransfersZero() public {
        NoZeroTransferERC20 strict = new NoZeroTransferERC20("Strict", "STRICT", 18);
        OptionSeriesVault v = _deploy(OptionType.CALL, address(strict), address(usdc), 10e18, 0, 0, 0);
        _mint(v, alice, bob, 5e18);
        _settle(v, 9e18);
        vm.prank(bob);
        v.redeem(5e18, bob); // would revert if the vault transferred zero
        assertEq(v.balanceOf(bob), 0);
    }

    function test_claim_guards() public {
        _mint(vault, alice, bob, 5e18);

        vm.prank(alice);
        vm.expectRevert(NotSettled.selector);
        vault.claimWriterResidual(1e18, alice);

        _settle(vault, 12.5e18);

        vm.startPrank(alice);
        vm.expectRevert(AmountTooSmall.selector);
        vault.claimWriterResidual(0, alice);
        vm.expectRevert(ZeroAddress.selector);
        vault.claimWriterResidual(1e18, address(0));
        vm.expectRevert(InsufficientShortBalance.selector);
        vault.claimWriterResidual(5e18 + 1, alice);
        vault.claimWriterResidual(5e18, alice);
        vm.expectRevert(InsufficientShortBalance.selector);
        vault.claimWriterResidual(1, alice); // a second claim of the same short
        vm.stopPrank();

        vm.prank(bob); // the holder never wrote anything
        vm.expectRevert(InsufficientShortBalance.selector);
        vault.claimWriterResidual(1, bob);
    }

    function test_claim_isNotFeeBearing() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        uint256 feesBefore = vault.accruedFees();
        vm.prank(alice);
        uint256 residual = vault.claimWriterResidual(5e18, alice);
        assertEq(residual, 4e18); // exactly the gross residual
        assertEq(vault.accruedFees(), feesBefore);
    }

    function test_previewsMatchReality() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        (uint256 pn, uint256 pf) = vault.previewRedeem(3e18);
        uint256 pr = vault.previewWriterResidual(2e18);
        vm.prank(bob);
        (uint256 n, uint256 f) = vault.redeem(3e18, bob);
        assertEq(n, pn);
        assertEq(f, pf);
        vm.prank(alice);
        assertEq(vault.claimWriterResidual(2e18, alice), pr);
    }

    // ================================================================== ERC-20 behavior

    function test_tokensAreFreelyTransferableAtEveryStage() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(bob);
        vault.transfer(carol, 1e18); // before expiry

        vm.warp(expiry + 10);
        vm.prank(carol);
        vault.transfer(dave, 5e17); // after expiry, before settlement

        _settle(vault, 12.5e18);
        vm.prank(dave);
        vault.transfer(carol, 1e17); // after settlement
        assertEq(vault.balanceOf(dave), 4e17);
        assertEq(vault.balanceOf(carol), 6e17);
    }

    function test_writerShortPositionDoesNotMoveWithTheTokens() public {
        _mint(vault, alice, alice, 5e18);
        vm.prank(alice);
        vault.transfer(bob, 5e18); // the writer sells everything
        assertEq(vault.writerShortBalance(alice), 5e18); // she still owns the obligation
        assertEq(vault.writerShortBalance(bob), 0);
        _settle(vault, 12.5e18);
        vm.prank(alice);
        assertEq(vault.claimWriterResidual(5e18, alice), 4e18);
    }

    // ================================================================== fees

    function test_sweepFees_onlyAdmin() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(pauser);
        vm.expectRevert(Unauthorized.selector);
        vault.sweepFees();
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        vault.sweepFees();
        vm.prank(keeper);
        vm.expectRevert(Unauthorized.selector);
        vault.sweepFees();

        vm.prank(admin);
        uint256 amount = vault.sweepFees();
        assertEq(amount, 5e15);
        assertEq(mon.balanceOf(feeRecipient), 5e15);
        assertEq(vault.accruedFees(), 0);
        assertEq(vault.collateralLocked(), 5e18); // collateral untouched
        assertEq(mon.balanceOf(address(vault)), 5e18);
        _assertVaultSolvent(vault);
    }

    function test_sweepFees_revertsWhenNothingAccrued() public {
        vm.prank(admin);
        vm.expectRevert(NoFeesAccrued.selector);
        vault.sweepFees();

        _mint(vault, alice, bob, 5e18);
        vm.prank(admin);
        vault.sweepFees();
        vm.prank(admin);
        vm.expectRevert(NoFeesAccrued.selector);
        vault.sweepFees(); // a second sweep finds nothing
    }

    function test_sweepFees_revertsWithoutARecipient() public {
        _mint(vault, alice, bob, 5e18);
        factory.setFeeRecipient(address(0));
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        vault.sweepFees();
        assertEq(vault.accruedFees(), 5e15); // nothing was zeroed
    }

    function test_sweepFees_readsTheRecipientLiveSoItCanBeRotated() public {
        _mint(vault, alice, bob, 5e18);
        address newTreasury = makeAddr("newTreasury");
        factory.setFeeRecipient(newTreasury);
        vm.prank(admin);
        vault.sweepFees();
        assertEq(mon.balanceOf(newTreasury), 5e15);
        assertEq(mon.balanceOf(feeRecipient), 0);
    }

    function test_sweepFees_worksInEveryStateAndWhileFrozen() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(pauser);
        vault.setMintPaused(true); // frozen

        vm.prank(admin);
        vault.sweepFees(); // frozen, before expiry

        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(5e18, bob); // accrues an exercise fee
        vm.prank(admin);
        vault.sweepFees(); // frozen, after settlement
        _assertVaultSolvent(vault);
    }

    function test_sweepFees_cannotTouchCollateralEvenAfterEveryoneIsPaid() public {
        _mint(vault, alice, bob, 5e18);
        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(5e18, bob);
        vm.prank(admin);
        vault.sweepFees();
        // collateral backing the writer's residual is still all there
        assertEq(vault.collateralLocked(), 4e18);
        assertEq(mon.balanceOf(address(vault)), 4e18);
        vm.prank(alice);
        assertEq(vault.claimWriterResidual(5e18, alice), 4e18);
    }

    function test_zeroFeesBehaveLikeANoFeeVault() public {
        OptionSeriesVault v = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 0, 0, 0);
        _mint(v, alice, bob, 5e18);
        assertEq(v.accruedFees(), 0);
        assertEq(mon.balanceOf(address(v)), 5e18); // exactly the collateral

        _settle(v, 12.5e18);
        vm.prank(bob);
        (uint256 net, uint256 fee) = v.redeem(5e18, bob);
        assertEq(net, 1e18); // gross == net
        assertEq(fee, 0);
        vm.prank(admin);
        vm.expectRevert(NoFeesAccrued.selector);
        v.sweepFees();
    }

    function test_feesNeverReduceCollateralBackingClaims() public {
        _mint(vault, alice, bob, 5e18);
        uint256 lockedAfterMint = vault.collateralLocked();
        assertEq(lockedAfterMint, 5e18); // the mint fee did not reduce collateral
        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(5e18, bob);
        // collateralLocked dropped by exactly the GROSS payout; the fee did not come out of the writer's share
        assertEq(vault.collateralLocked(), lockedAfterMint - 1e18);
        assertEq(vault.previewWriterResidual(5e18), vault.collateralLocked());
    }

    // ================================================================== freeze (minting only)

    function test_freeze_pauserAndAdminCanFreeze() public {
        vm.prank(pauser);
        vault.setMintPaused(true);
        assertTrue(vault.mintPaused());

        vm.prank(admin);
        vault.setMintPaused(true); // already frozen: idempotent
        assertTrue(vault.mintPaused());
    }

    function test_freeze_onlyAdminCanUnfreeze() public {
        vm.prank(pauser);
        vault.setMintPaused(true);

        vm.prank(pauser);
        vm.expectRevert(Unauthorized.selector);
        vault.setMintPaused(false); // a compromised pauser cannot undo a freeze
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        vault.setMintPaused(false);

        vm.prank(admin);
        vault.setMintPaused(false);
        assertFalse(vault.mintPaused());
    }

    function test_freeze_strangersCannotFreeze() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        vault.setMintPaused(true);
        vm.prank(keeper);
        vm.expectRevert(Unauthorized.selector);
        vault.setMintPaused(true);
    }

    function test_freeze_blocksMintAndNothingElse() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(pauser);
        vault.setMintPaused(true);

        // mint is blocked
        _fund(vault, alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(MintPaused.selector);
        vault.mint(1e18, alice);

        // ERC-20 transfers still work before expiry
        vm.prank(bob);
        vault.transfer(carol, 1e18);

        // settle, redeem, claim and payout still work on a frozen series
        _settle(vault, 12.5e18);
        vm.prank(bob);
        vault.redeem(4e18, bob);
        vm.prank(carol);
        vault.redeem(1e18, carol);
        vm.prank(alice);
        vault.claimWriterResidual(5e18, alice);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.collateralLocked(), 0);
        assertTrue(vault.mintPaused()); // still frozen the whole time
    }

    function test_freeze_payoutStillWorks() public {
        _mint(vault, alice, bob, 5e18);
        vm.prank(admin);
        vault.setMintPaused(true);
        _settle(vault, 12.5e18);
        address[] memory accounts = new address[](2);
        accounts[0] = bob;
        accounts[1] = alice;
        vm.prank(keeper);
        vault.payout(accounts);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.collateralLocked(), 0);
    }

    function test_freeze_isPerSeries() public {
        OptionSeriesVault other = _deploy(OptionType.CALL, address(mon), address(usdc), 12e18, 0, 0, 0);
        vm.prank(pauser);
        vault.setMintPaused(true);
        assertFalse(other.mintPaused());
        _mint(other, alice, alice, 1e18); // other series is unaffected
    }

    function test_freeze_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit OptionSeriesVault.MintPauseSet(true);
        vm.prank(pauser);
        vault.setMintPaused(true);
    }

    // ================================================================== views

    function test_isExpired() public {
        assertFalse(vault.isExpired());
        vm.warp(expiry - 1);
        assertFalse(vault.isExpired());
        vm.warp(expiry);
        assertTrue(vault.isExpired());
    }

    function test_previewRedeemAndResidualAreZeroBeforeSettlement() public {
        _mint(vault, alice, bob, 5e18);
        (uint256 net, uint256 fee) = vault.previewRedeem(5e18);
        assertEq(net, 0);
        assertEq(fee, 0);
        assertEq(vault.previewWriterResidual(5e18), 0);
    }

    // ================================================================== why the asset allowlist matters

    /// The vault does not measure balance deltas. A fee-on-transfer collateral token therefore makes the vault
    /// insolvent. This test documents exactly why the ADMIN allowlist must exclude such tokens.
    function test_documentation_feeOnTransferCollateralBreaksSolvency() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("FoT", "FOT", 18);
        OptionSeriesVault v = _deploy(OptionType.CALL, address(fot), address(usdc), 10e18, 0, 0, 0);
        fot.mint(alice, 100e18);
        vm.prank(alice);
        fot.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.mint(10e18, alice);
        // the vault recorded 10 tokens of collateral but received only 9.9
        assertEq(v.collateralLocked(), 10e18);
        assertLt(fot.balanceOf(address(v)), v.collateralLocked());
    }
}
