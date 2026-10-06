// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClearingFixture} from "../utils/ClearingFixture.sol";
import {OptionClearing} from "../../src/clearing/OptionClearing.sol";
import {IOptionClearing} from "../../src/interfaces/IOptionClearing.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {FeeOnTransferToken, MockERC20} from "../mocks/MockDependencies.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    UnknownSeries,
    UnknownAccount,
    AssetMismatch,
    NonExactTransfer,
    SeriesNotActive,
    GroupFinalized,
    ProductCloseOnly,
    InsuranceBelowMinimum,
    StaleSpot,
    StaleSurface,
    InsufficientCash,
    NotHealthy,
    InsufficientShort,
    InsufficientLong,
    PositionLimit,
    PositionBelowMinimum,
    OpenInterestCap,
    FeeTooHigh,
    ActionPaused,
    InsufficientProviderFee,
    RefundFailed,
    InvalidOracleUpdate
} from "../../src/libraries/Errors.sol";

/// @dev A caller that cannot receive ETH (for the refund failure path).
contract NoReceive {
    function callUpdate(OptionClearing c, OracleUpdate calldata u) external payable {
        c.updateOracles{value: msg.value}(u);
    }
}

/// @notice Unit tests for OptionClearing: CLR-001..CLR-024, FEE-002, PRV-001.
contract OptionClearingTest is ClearingFixture {
    uint256 internal acct;

    function setUp() public {
        _deployClearingMarket();
        acct = _account(alice);
    }

    // ------------------------------------------------------------------ initialization

    function test_initialState() public view {
        IOptionClearing.Modules memory m = clearingModule.modules();
        assertEq(m.ledger, address(ledger));
        assertEq(m.registry, address(registry));
        assertEq(m.risk, address(risk));
        assertEq(m.fees, address(fees));
        assertEq(m.insurance, address(insurance));
        assertEq(m.spot, address(spot));
        assertEq(m.surface, address(surface));
        assertEq(m.settlementState, address(settlementState));
        assertEq(m.liquidationModule, liquidationModule);
        assertEq(m.settlementWindow, settlementWindow);
    }

    function test_initializeChecks() public {
        IProtocolControl c = IProtocolControl(address(pc));
        address impl = address(new OptionClearing());
        IOptionClearing.Modules memory good = clearingModule.modules();
        for (uint256 i; i < 10; ++i) {
            IOptionClearing.Modules memory m = good;
            assembly {
                mstore(add(m, mul(i, 0x20)), 0) // zero the i-th address field
            }
            vm.prank(governance);
            vm.expectRevert(ZeroAddress.selector);
            upgradeAdmin.deployProxy(impl, abi.encodeCall(OptionClearing.initialize, (c, m)));
        }
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clearingModule.initialize(c, good);
    }

    // ------------------------------------------------------------------ CLR-001 / CLR-015: deposits

    function test_CLR001_depositCreditsExactCash() public {
        usdc.mint(alice, 4000e6);
        vm.startPrank(alice);
        usdc.approve(address(clearingModule), 4000e6);
        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.CollateralDeposited(acct, alice, 4000e6);
        clearingModule.depositCollateral(acct, 4000e6);
        vm.stopPrank();
        assertEq(ledger.cashOf(acct), 4000e6);
        assertEq(usdc.balanceOf(address(clearingModule)), 4000e6);
    }

    function test_CLR001_feeOnTransferReverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        vm.prank(governance);
        registry.setSettlementAssetApproved(address(fot), true);
        vm.prank(alice);
        uint256 a = ledger.createSubAccount(address(fot));
        fot.mint(alice, 100e6);
        vm.startPrank(alice);
        fot.approve(address(clearingModule), 100e6);
        vm.expectRevert(abi.encodeWithSelector(NonExactTransfer.selector, 100e6, 99e6));
        clearingModule.depositCollateral(a, 100e6);
        vm.stopPrank();
    }

    function test_CLR015_anyoneDepositsIntoAnyAccount() public {
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        (, int256 e0, uint256 im0,,) = risk.healthOf(acct);
        _deposit(acct, stranger, 100e6); // a stranger tops up alice's account
        (, int256 e1, uint256 im1,,) = risk.healthOf(acct);
        assertEq(e1 - e0, 100e18, "equity rises by the deposit");
        assertEq(im1, im0, "margin unchanged");
        assertEq(ledger.cashOf(acct), 4000e6 - fees.previewSellerFee(c4500, 1e18) + 100e6);
    }

    function test_depositInputChecks() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownAccount.selector, 99));
        clearingModule.depositCollateral(99, 1);
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.depositCollateral(acct, 0);
    }

    // ------------------------------------------------------------------ CLR-002 / CLR-003 / PRV-002: withdrawals

    function test_CLR002_withdrawWithinFreeMargin() public {
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        uint256 maxW = risk.maxWithdrawable(acct);
        assertGt(maxW, 0);
        assertLt(maxW, ledger.cashOf(acct));
        vm.prank(alice);
        vm.expectPartialRevert(NotHealthy.selector);
        clearingModule.withdrawCollateral(acct, maxW + 1, alice, _empty());

        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.CollateralWithdrawn(acct, bob, maxW);
        vm.prank(alice);
        clearingModule.withdrawCollateral(acct, maxW, bob, _empty());
        assertEq(usdc.balanceOf(bob), maxW);
        assertEq(risk.maxWithdrawable(acct), 0);
    }

    function test_CLR003_withdrawNeedsFreshDataOnlyWithPositions() public {
        _deposit(acct, alice, 4000e6);
        uint256 other = _account(bob);
        _deposit(other, bob, 4000e6);
        _mint(other, bob, c4500, 1e18);
        vm.warp(block.timestamp + 1 days); // every oracle is stale
        vm.prank(alice);
        clearingModule.withdrawCollateral(acct, 4000e6, alice, _empty()); // no positions: no oracle data needed
        assertEq(ledger.cashOf(acct), 0);
        vm.prank(bob);
        vm.expectPartialRevert(StaleSpot.selector);
        clearingModule.withdrawCollateral(other, 1e6, bob, _empty());
    }

    function test_withdrawInputChecks() public {
        _deposit(acct, alice, 10e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        clearingModule.withdrawCollateral(acct, 1, bob, _empty());
        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.withdrawCollateral(acct, 0, alice, _empty());
        vm.expectRevert(InvalidRecipient.selector);
        clearingModule.withdrawCollateral(acct, 1, address(0), _empty());
        vm.expectRevert(abi.encodeWithSelector(InsufficientCash.selector, 11e6, 10e6));
        clearingModule.withdrawCollateral(acct, 11e6, alice, _empty());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ CLR-004: mint

    function test_CLR004_mint() public {
        _deposit(acct, alice, 4000e6);
        uint256 fee = fees.previewSellerFee(c4500, 1e18);
        assertApproxEqAbs(fee, 3.2032e6, 0.0001e6, "FEES.md s2: 106.77 x 3%");
        vm.expectEmit(true, true, true, true, address(fees));
        emit IFeeController.SellerFeeCharged(acct, c4500, address(usdc), fee);
        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.ExternalLongMinted(acct, c4500, 1e18, bob, fee);
        vm.prank(alice);
        clearingModule.mintExternalLong(acct, c4500, 1e18, bob, fee, _empty());

        assertEq(ledger.balanceOf(acct, c4500), -1e18, "short");
        assertEq(IERC20(_wrapper(c4500)).balanceOf(bob), 1e18, "wrappers to the recipient");
        assertEq(ledger.cashOf(acct), 4000e6 - fee, "fee debited");
        uint256 toIns = fee * 6000 / 10_000;
        uint256 toKeep = fee * 1000 / 10_000;
        assertEq(insurance.balanceOf(address(usdc)), toIns);
        assertEq(fees.keeperReserve(address(usdc)), toKeep);
        assertEq(fees.treasury(address(usdc)), fee - toIns - toKeep);
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(acct), "INV-7: custody = cash");
        (uint256 longs, uint256 shorts) = ledger.totals(c4500);
        assertEq(longs, 0);
        assertEq(shorts, 1e18);
        assertEq(IERC20(_wrapper(c4500)).totalSupply(), shorts, "INV-1: wrappers = shorts - internal longs");
        risk.requireHealthy(acct);
    }

    function test_CLR004_zeroFeeSkipsCollection() public {
        vm.prank(governance);
        fees.setFeeRates(0, 0);
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        assertEq(ledger.cashOf(acct), 4000e6);
        assertEq(fees.treasury(address(usdc)), 0);
    }

    function test_CLR004_oneUnitFeeIsCharged() public {
        vm.startPrank(governance);
        fees.setFeeRates(0, 0);
        fees.setMinSellerFee(address(usdc), 1);
        vm.stopPrank();
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        assertEq(ledger.cashOf(acct), 4000e6 - 1);
        assertEq(
            fees.treasury(address(usdc)) + fees.keeperReserve(address(usdc)) + insurance.balanceOf(address(usdc)), 1
        );
    }

    // ------------------------------------------------------------------ CLR-005 / CLR-018 / FEE-002: mint guards

    function test_CLR005_mintRevertsOnStaleSpot() public {
        _deposit(acct, alice, 4000e6);
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, ethUsdc, 61));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
    }

    function test_CLR005_mintRevertsOnStaleSurface() public {
        _deposit(acct, alice, 4000e6);
        vm.warp(block.timestamp + 301);
        OracleUpdate memory u = _spotUpdate(4000e18); // spot fresh again, surface not
        vm.prank(alice);
        vm.expectPartialRevert(StaleSurface.selector);
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, u);
        // the same mint goes through with a full update
        u = _marketUpdate(4000e18);
        vm.prank(alice);
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, u);
        assertEq(ledger.balanceOf(acct, c4500), -1e18);
    }

    function test_CLR005_CLR018_mintRevertsWhenCloseOnly() public {
        _deposit(acct, alice, 4000e6);
        vm.prank(guardian);
        pc.setProductCloseOnly(ethUsdc, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProductCloseOnly.selector, ethUsdc));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
        vm.prank(governance);
        pc.setProductCloseOnly(ethUsdc, false);

        vm.prank(guardian);
        surface.setEmergencyMode(ethUsdc, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProductCloseOnly.selector, ethUsdc));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
    }

    function test_CLR005_CLR018_mintRevertsBelowReserveMinimums() public {
        _deposit(acct, alice, 4000e6);
        vm.prank(riskAdmin);
        fees.setMinimums(address(usdc), 1e6, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsuranceBelowMinimum.selector, address(usdc)));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
        _seedInsurance(1e6);
        vm.prank(riskAdmin);
        fees.setMinimums(address(usdc), 1e6, 1e6); // keeper reserve minimum
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsuranceBelowMinimum.selector, address(usdc)));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
        _seedKeeper(1e6);
        _mint(acct, alice, c4500, 1e18);
    }

    function test_CLR005_FEE002_feeAboveMaxReverts() public {
        _deposit(acct, alice, 4000e6);
        uint256 fee = fees.previewSellerFee(c4500, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, fee, fee - 1));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, fee - 1, _empty());
    }

    function test_CLR005_unhealthyMintReverts() public {
        _deposit(acct, alice, 1000e6);
        vm.prank(alice);
        vm.expectPartialRevert(NotHealthy.selector);
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
    }

    function test_CLR005_feeBeyondCashReverts() public {
        uint256 fee = fees.previewSellerFee(c4500, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientCash.selector, fee, 0));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
    }

    // ------------------------------------------------------------------ CLR-006

    function test_CLR006_mintAfterExpiryReverts() public {
        _deposit(acct, alice, 4000e6);
        vm.warp(EXP30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotActive.selector, c4500));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
    }

    // ------------------------------------------------------------------ CLR-007 / CLR-008: unwrap

    function test_CLR007_unwrap() public {
        uint256 writer = _account(bob);
        _deposit(writer, bob, 4000e6);
        _mint(writer, bob, c4500, 1e18);
        _sendWrapper(c4500, bob, alice, 1e18);
        vm.warp(block.timestamp + 1 hours); // stale oracles: unwrap needs none
        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.LongUnwrapped(acct, c4500, 0.4e18, alice);
        vm.prank(alice);
        clearingModule.unwrapLong(acct, c4500, 0.4e18);
        assertEq(ledger.balanceOf(acct, c4500), 0.4e18);
        assertEq(IERC20(_wrapper(c4500)).balanceOf(alice), 0.6e18);
        (uint256 longs, uint256 shorts) = ledger.totals(c4500);
        assertEq(IERC20(_wrapper(c4500)).totalSupply() + longs, shorts, "INV-1");
    }

    function test_CLR007_unwrapChecks() public {
        uint256 writer = _account(bob);
        _deposit(writer, bob, 4000e6);
        _mint(writer, bob, c4500, 1e18);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        clearingModule.unwrapLong(acct, c4500, 1e18); // bob is not authorized for alice's account
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.unwrapLong(writer, c4500, 0);
        vm.stopPrank();
        vm.warp(EXP30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotActive.selector, c4500));
        clearingModule.unwrapLong(writer, c4500, 1e18);
    }

    function test_CLR008_assetMismatchReverts() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        vm.prank(governance);
        registry.setSettlementAssetApproved(address(usdt), true);
        vm.prank(alice);
        uint256 other = ledger.createSubAccount(address(usdt));
        usdt.mint(alice, 4000e6);
        vm.startPrank(alice);
        usdt.approve(address(clearingModule), 4000e6);
        clearingModule.depositCollateral(other, 4000e6);
        vm.expectRevert(AssetMismatch.selector);
        clearingModule.mintExternalLong(other, c4500, 1e18, alice, type(uint256).max, _empty());
        vm.stopPrank();

        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        vm.prank(alice);
        vm.expectRevert(AssetMismatch.selector);
        clearingModule.unwrapLong(other, c4500, 1e18);
    }

    // ------------------------------------------------------------------ CLR-009: wrap

    function test_CLR009_wrap() public {
        _deposit(acct, alice, 1000e6);
        _giveLong(acct, alice, c5000, 1e18);
        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.LongWrapped(acct, c5000, 1e18, bob);
        vm.prank(alice);
        clearingModule.wrapLong(acct, c5000, 1e18, bob, _empty());
        assertEq(ledger.balanceOf(acct, c5000), 0);
        assertEq(IERC20(_wrapper(c5000)).balanceOf(bob), 1e18);
    }

    function test_CLR009_wrapNeedsALongAndHealth() public {
        _deposit(acct, alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLong.selector, int256(0), 1e18));
        clearingModule.wrapLong(acct, c5000, 1e18, alice, _empty());
        // a spread: short 4500 hedged by long 5000, with cash only for the spread
        _giveLong(acct, alice, c5000, 1e18);
        _mint(acct, alice, c4500, 1e18);
        vm.prank(alice);
        vm.expectPartialRevert(NotHealthy.selector);
        clearingModule.wrapLong(acct, c5000, 1e18, alice, _empty()); // the long was the hedge
    }

    function test_CLR009_wrapChecks() public {
        _deposit(acct, alice, 1000e6);
        _giveLong(acct, alice, c5000, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        clearingModule.wrapLong(acct, c5000, 1e18, bob, _empty());
        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.wrapLong(acct, c5000, 0, alice, _empty());
        vm.expectRevert(InvalidRecipient.selector);
        clearingModule.wrapLong(acct, c5000, 1e18, address(0), _empty());
        vm.stopPrank();
        vm.warp(EXP30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SeriesNotActive.selector, c5000));
        clearingModule.wrapLong(acct, c5000, 1e18, alice, _empty());
    }

    // ------------------------------------------------------------------ CLR-010: close with wrapper

    function test_CLR010_closeWithWrapper() public {
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.ShortClosedWithWrapper(acct, c4500, 0.3e18);
        vm.prank(alice);
        clearingModule.closeShortWithWrapper(acct, c4500, 0.3e18);
        assertEq(ledger.balanceOf(acct, c4500), -0.7e18);
        assertEq(IERC20(_wrapper(c4500)).balanceOf(alice), 0.7e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientShort.selector, -0.7e18, 0.8e18));
        clearingModule.closeShortWithWrapper(acct, c4500, 0.8e18);

        vm.warp(EXP30 + 1); // after expiry, before finalization: still allowed, no oracle data
        vm.prank(alice);
        clearingModule.closeShortWithWrapper(acct, c4500, 0.2e18);
        assertEq(ledger.balanceOf(acct, c4500), -0.5e18);

        settlementState.finalize(group30, 4100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GroupFinalized.selector, group30));
        clearingModule.closeShortWithWrapper(acct, c4500, 0.5e18);
    }

    function test_CLR010_closeChecks() public {
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        clearingModule.closeShortWithWrapper(acct, c4500, 1e18);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.closeShortWithWrapper(acct, c4500, 0);
        _sendWrapper(c4500, alice, bob, 1e18);
        vm.prank(alice); // alice has no wrappers left: the burn fails
        vm.expectRevert();
        clearingModule.closeShortWithWrapper(acct, c4500, 1e18);
    }

    // ------------------------------------------------------------------ CLR-011: close with internal long

    function test_CLR011_closeWithInternalLong() public {
        uint256 longAcct = _account(alice);
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        _giveLong(longAcct, alice, c4500, 1e18);
        (, int256 eTo0, uint256 imTo0,,) = risk.healthOf(acct);

        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.ShortClosedWithInternalLong(longAcct, acct, c4500, 0.6e18);
        vm.prank(alice);
        clearingModule.closeShortWithInternalLong(longAcct, acct, c4500, 0.6e18, _empty());
        assertEq(ledger.balanceOf(longAcct, c4500), 0.4e18);
        assertEq(ledger.balanceOf(acct, c4500), -0.4e18);
        (, int256 eTo1, uint256 imTo1,,) = risk.healthOf(acct);
        assertGe(eTo1 - int256(imTo1), eTo0 - int256(imTo0), "INV-13: the target's health never falls");
    }

    function test_CLR011_sourceMustStayHealthy() public {
        uint256 src = _account(alice);
        uint256 dst = _account(alice);
        // src: short 4500 hedged by long 5000 (spread margin only); dst: short 5000
        _deposit(src, alice, 1000e6);
        _giveLong(src, alice, c5000, 1e18);
        _mint(src, alice, c4500, 1e18);
        _deposit(dst, alice, 4000e6);
        _mint(dst, alice, c5000, 1e18);
        vm.prank(alice);
        vm.expectPartialRevert(NotHealthy.selector);
        clearingModule.closeShortWithInternalLong(src, dst, c5000, 1e18, _empty());
    }

    function test_CLR011_checks() public {
        uint256 bobAcct = _account(bob);
        _deposit(acct, alice, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        _giveLong(bobAcct, bob, c4500, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, alice));
        clearingModule.closeShortWithInternalLong(bobAcct, acct, c4500, 1e18, _empty()); // needs both accounts
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        clearingModule.closeShortWithInternalLong(bobAcct, acct, c4500, 1e18, _empty());
        vm.prank(bob);
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.closeShortWithInternalLong(bobAcct, bobAcct, c4500, 0, _empty());

        vm.prank(alice);
        ledger.setOperator(acct, bob, true);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLong.selector, int256(1e18), 2e18));
        clearingModule.closeShortWithInternalLong(bobAcct, acct, c4500, 2e18, _empty());
        vm.expectRevert(abi.encodeWithSelector(InsufficientShort.selector, int256(1e18), 1e18));
        clearingModule.closeShortWithInternalLong(bobAcct, bobAcct, c4500, 1e18, _empty()); // same account
        clearingModule.closeShortWithInternalLong(bobAcct, acct, c4500, 1e18, _empty()); // operator of both
        vm.stopPrank();
        assertEq(ledger.balanceOf(acct, c4500), 0);

        settlementState.finalize(group30, 4100e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GroupFinalized.selector, group30));
        clearingModule.closeShortWithInternalLong(bobAcct, acct, c4500, 1e18, _empty());
    }

    // ------------------------------------------------------------------ CLR-012 / CLR-013

    function test_CLR012_belowMinimumQuantityReverts() public {
        _deposit(acct, alice, 4000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionBelowMinimum.selector, -0.005e18));
        clearingModule.mintExternalLong(acct, c4500, 0.005e18, alice, type(uint256).max, _empty());
    }

    function test_CLR013_participantsCountAccounts() public {
        uint256 bobAcct = _account(bob);
        _deposit(acct, alice, 8000e6);
        _deposit(bobAcct, bob, 4000e6);
        _mint(acct, alice, c4500, 1e18);
        assertEq(ledger.participants(group30), 1);
        _mint(acct, alice, c5000, 1e18); // same group, same account
        assertEq(ledger.participants(group30), 1);
        _mint(bobAcct, bob, c4500, 1e18);
        assertEq(ledger.participants(group30), 2);
        vm.startPrank(alice);
        clearingModule.closeShortWithWrapper(acct, c4500, 1e18);
        assertEq(ledger.participants(group30), 2, "still holds c5000");
        clearingModule.closeShortWithWrapper(acct, c5000, 1e18);
        vm.stopPrank();
        assertEq(ledger.participants(group30), 1);
    }

    // ------------------------------------------------------------------ CLR-016 / CLR-023: oracle updates

    function test_CLR016_updateOraclesAlone() public {
        _deposit(acct, alice, 4000e6);
        vm.warp(block.timestamp + 400);
        assertFalse(spot.isSpotFresh(ethUsdc));
        OracleUpdate memory u = _marketUpdate(4100e18);
        uint64 seqBefore = surface.header(ethUsdc).surfaceSeq;
        vm.recordLogs();
        vm.prank(stranger);
        clearingModule.updateOracles(u);
        assertTrue(spot.isSpotFresh(ethUsdc));
        (uint256 px,) = spot.spotPrice(ethUsdc);
        assertEq(px, 4100e18);
        assertEq(surface.header(ethUsdc).surfaceSeq, seqBefore + 1);
        (IVolSurfaceOracle.SurfaceStatus st,) = surface.surfaceStatus(ethUsdc);
        assertEq(uint8(st), uint8(IVolSurfaceOracle.SurfaceStatus.FRESH));
        (bool proven,) = surface.nodeValue(ethUsdc, 0, 0);
        assertTrue(proven, "leaves cached");
        assertEq(ledger.cashOf(acct), 4000e6, "no other effect");
        // the same update again (e.g. another user's transaction in the same block) is skipped, not reverted
        vm.prank(bob);
        clearingModule.updateOracles(u);
        assertEq(surface.header(ethUsdc).surfaceSeq, seqBefore + 1);
    }

    /// @dev A keeper pushed the price to Pyth directly: product ids alone refresh the stored spot.
    function test_CLR016_refreshWithoutBlobs() public {
        vm.warp(block.timestamp + 120);
        bytes[] memory blobs = new bytes[](1);
        blobs[0] = _spotBlob(ethUsdc, 4200e18);
        pyth.updatePriceFeeds(blobs);
        assertFalse(spot.isSpotFresh(ethUsdc));
        OracleUpdate memory u;
        u.spotProductIds = new bytes32[](1);
        u.spotProductIds[0] = ethUsdc;
        clearingModule.updateOracles(u);
        (uint256 px,) = spot.spotPrice(ethUsdc);
        assertEq(px, 4200e18);
        assertTrue(spot.isSpotFresh(ethUsdc));
    }

    function test_CLR016_mismatchedSignatureListsRevert() public {
        OracleUpdate memory u = _marketUpdate(4000e18);
        u.reportSignatures = new bytes[][](0);
        vm.expectRevert(InvalidOracleUpdate.selector);
        clearingModule.updateOracles(u);
    }

    function test_CLR023_providerFeeAndRefund() public {
        pyth.setFeePerUpdate(5);
        vm.deal(alice, 1 ether);
        OracleUpdate memory u = _spotUpdate(4000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientProviderFee.selector, 5, 4));
        clearingModule.updateOracles{value: 4}(u);
        vm.prank(alice);
        clearingModule.updateOracles{value: 100}(u);
        assertEq(alice.balance, 1 ether - 5, "excess refunded");
        assertEq(address(pyth).balance, 5);
        assertEq(address(clearingModule).balance, 0);
        // a payable action with no spot data refunds everything
        _deposit(acct, alice, 10e6);
        vm.prank(alice);
        clearingModule.withdrawCollateral{value: 7}(acct, 1e6, alice, _empty());
        assertEq(alice.balance, 1 ether - 5);
        // a caller that rejects ETH
        NoReceive nr = new NoReceive();
        vm.deal(address(nr), 1);
        vm.expectRevert(RefundFailed.selector);
        nr.callUpdate{value: 1}(clearingModule, _empty());
    }

    // ------------------------------------------------------------------ CLR-019 / CLR-020: caps and limits

    function test_CLR019_openInterestCaps() public {
        _deposit(acct, alice, 20_000e6);
        vm.prank(riskAdmin);
        risk.setOpenInterestCap(RISK_SET, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OpenInterestCap.selector, c4500));
        clearingModule.mintExternalLong(acct, c4500, 1.01e18, alice, type(uint256).max, _empty());
        _mint(acct, alice, c4500, 1e18);

        vm.prank(riskAdmin);
        risk.setProductShortCap(ethUsdc, 1.5e18); // 1.5 ETH of underlying across the product
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OpenInterestCap.selector, ethUsdc));
        clearingModule.mintExternalLong(acct, c5000, 1e18, alice, type(uint256).max, _empty());

        // lowering below current OI forces nothing: closing still works, new mints don't
        vm.prank(riskAdmin);
        risk.setOpenInterestCap(RISK_SET, 0.5e18);
        vm.prank(alice);
        clearingModule.closeShortWithWrapper(acct, c4500, 0.2e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OpenInterestCap.selector, c4500));
        clearingModule.mintExternalLong(acct, c4500, 0.01e18, alice, type(uint256).max, _empty());
    }

    function test_CLR020_positionLimits() public {
        vm.prank(governance);
        ledger.setPositionLimits(2, 1);
        _deposit(acct, alice, 20_000e6);
        _mint(acct, alice, c4500, 1e18);
        _mint(acct, alice, c5000, 1e18);
        vm.prank(alice);
        vm.expectRevert(PositionLimit.selector);
        clearingModule.mintExternalLong(acct, p3500, 1e18, alice, type(uint256).max, _empty());

        uint256 bobAcct = _account(bob);
        _deposit(bobAcct, bob, 4000e6);
        _mint(bobAcct, bob, p3500, 1e18);
        _sendWrapper(p3500, bob, alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(PositionLimit.selector);
        clearingModule.unwrapLong(acct, p3500, 1e18);

        // a second underlying bucket
        vm.prank(alice);
        clearingModule.closeShortWithWrapper(acct, c5000, 1e18);
        bytes32 btcCall = _series(btcUsdc, OptionType.CALL, 100_000e18, EXP30);
        vm.prank(alice);
        vm.expectRevert(PositionLimit.selector);
        clearingModule.mintExternalLong(acct, btcCall, 1e18, alice, type(uint256).max, _empty());
    }

    // ------------------------------------------------------------------ CLR-021 / CLR-022

    function test_CLR021_riskReducingActionsNeedNoOracleData() public {
        uint256 bobAcct = _account(bob);
        _deposit(bobAcct, bob, 8000e6);
        _mint(bobAcct, bob, c4500, 2e18);
        _sendWrapper(c4500, bob, alice, 1e18);
        vm.warp(block.timestamp + 2 days); // surface beyond maxSurfaceStale: product close-only
        assertTrue(risk.isProductCloseOnly(ethUsdc));
        _deposit(bobAcct, bob, 1e6);
        vm.prank(alice);
        clearingModule.unwrapLong(acct, c4500, 1e18);
        vm.prank(bob);
        clearingModule.closeShortWithWrapper(bobAcct, c4500, 1e18);
        assertEq(ledger.balanceOf(bobAcct, c4500), -1e18);
        assertEq(ledger.balanceOf(acct, c4500), 1e18);
    }

    function test_CLR022_unknownSeries() public {
        bytes32 bogus = keccak256("nope");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, bogus));
        clearingModule.mintExternalLong(acct, bogus, 1e18, alice, 0, _empty());
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, bogus));
        clearingModule.unwrapLong(acct, bogus, 1e18);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, bogus));
        clearingModule.closeShortWithWrapper(acct, bogus, 1e18);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, bogus));
        clearingModule.previewMint(acct, bogus, 1e18);
        vm.stopPrank();
    }

    function test_CLR022_mintInputChecks() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        clearingModule.mintExternalLong(acct, c4500, 1e18, bob, 0, _empty());
        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        clearingModule.mintExternalLong(acct, c4500, 0, alice, 0, _empty());
        vm.expectRevert(InvalidRecipient.selector);
        clearingModule.mintExternalLong(acct, c4500, 1e18, address(0), 0, _empty());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ pauses

    function test_pauseBits() public {
        _deposit(acct, alice, 4000e6);
        _giveLong(acct, alice, c5000, 1e18);
        _mint(acct, alice, c4500, 1e18);
        _pause(PauseBits.DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.DEPOSIT));
        clearingModule.depositCollateral(acct, 1);
        _pause(PauseBits.WITHDRAW);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.WITHDRAW));
        clearingModule.withdrawCollateral(acct, 1, alice, _empty());
        _pause(PauseBits.MINT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.MINT));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, 0, _empty());
        _pause(PauseBits.WRAP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.WRAP));
        clearingModule.wrapLong(acct, c5000, 1e18, alice, _empty());
        _pause(PauseBits.UNWRAP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.UNWRAP));
        clearingModule.unwrapLong(acct, c4500, 1e18);
        _pause(PauseBits.CLOSE);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.CLOSE));
        clearingModule.closeShortWithWrapper(acct, c4500, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.CLOSE));
        clearingModule.closeShortWithInternalLong(acct, acct, c4500, 1e18, _empty());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ custody

    function test_CLR024_custodyPayments() public {
        _deposit(acct, alice, 100e6);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        vm.prank(stranger);
        clearingModule.payInsurance(address(usdc), 1e6);
        vm.prank(liquidationModule);
        clearingModule.payInsurance(address(usdc), 0); // no-op
        vm.prank(liquidationModule);
        clearingModule.payInsurance(address(usdc), 2e6);
        vm.prank(settlementWindow);
        clearingModule.payInsurance(address(usdc), 1e6);
        assertEq(insurance.balanceOf(address(usdc)), 3e6);

        vm.prank(liquidationModule);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, liquidationModule));
        clearingModule.payOut(address(usdc), bob, 1e6);
        vm.startPrank(settlementWindow);
        vm.expectRevert(InvalidRecipient.selector);
        clearingModule.payOut(address(usdc), address(0), 1e6);
        clearingModule.payOut(address(usdc), bob, 0); // no-op
        clearingModule.payOut(address(usdc), bob, 4e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 4e6);
        assertEq(usdc.balanceOf(address(clearingModule)), 93e6);
    }

    // ------------------------------------------------------------------ PRV-001

    function test_PRV001_previewMintMatchesExecution() public {
        _deposit(acct, alice, 10_000e6);
        _giveLong(acct, alice, c5000, 0.5e18);
        (uint256 fee, int256 equityAfter, uint256 imAfter, bool ok) = clearingModule.previewMint(acct, c4500, 2e18);
        assertTrue(ok);
        vm.expectEmit(true, true, true, true, address(clearingModule));
        emit IOptionClearing.ExternalLongMinted(acct, c4500, 2e18, alice, fee);
        _mint(acct, alice, c4500, 2e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertEq(r.equity, equityAfter, "equity after");
        assertEq(r.initialMargin, imAfter, "IM after");
    }

    /// @dev USER_FLOWS.md F2: 4,000 USDC, 1 x C4500 -> fee 3.20, IM after ~3,418, equity after ~3,890.
    function test_PRV001_userFlowF2() public {
        _deposit(acct, alice, 4000e6);
        (uint256 fee, int256 equityAfter, uint256 imAfter, bool ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertTrue(ok);
        assertApproxEqAbs(fee, 3.2032e6, 0.0001e6);
        assertApproxEqAbs(imAfter, 3417.78e18, 0.01e18);
        assertApproxEqAbs(equityAfter, 3890.03e18, 0.01e18);
    }

    /// @dev Longs cover the margin but there is no cash for the fee: not ok, and the mint reverts. Long C3500 +
    ///      long P5000 pays at least 1,500 at any spot; with the new short C4500 the minimum is still 1,000.
    function test_PRV001_okFalseWhenCashBelowFee() public {
        bytes32 c3500 = _series(ethUsdc, OptionType.CALL, 3500e18, EXP30);
        bytes32 p5000 = _series(ethUsdc, OptionType.PUT, 5000e18, EXP30);
        _giveLong(acct, alice, c3500, 1e18);
        _giveLong(acct, alice, p5000, 1e18);
        (uint256 fee, int256 equityAfter, uint256 imAfter, bool ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertGt(equityAfter - int256(imAfter), 500e18, "margin is ample");
        assertFalse(ok, "but cash can't pay the fee");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientCash.selector, fee, 0));
        clearingModule.mintExternalLong(acct, c4500, 1e18, alice, type(uint256).max, _empty());
    }

    function test_PRV001_previewMintOkFlag() public {
        (,,, bool ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertFalse(ok, "no cash for the fee");
        _deposit(acct, alice, 1000e6);
        (,,, ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertFalse(ok, "not enough margin");
        _deposit(acct, alice, 3000e6);
        (,,, ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertTrue(ok);
        vm.prank(guardian);
        pc.setProductCloseOnly(ethUsdc, true);
        (,,, ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertFalse(ok, "close-only");
        vm.prank(governance);
        pc.setProductCloseOnly(ethUsdc, false);
        vm.warp(block.timestamp + 61);
        (,,, ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertFalse(ok, "stale spot");
        _setSpot(ethUsdc, 4000e18);
        (,,, ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertTrue(ok);
        vm.warp(EXP30);
        _setSpot(ethUsdc, 4000e18);
        (,,, ok) = clearingModule.previewMint(acct, c4500, 1e18);
        assertFalse(ok, "expired");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Gives `accountId` an internal long by minting from a well-funded helper account and unwrapping.
    function _giveLong(uint256 accountId, address owner, bytes32 seriesId, uint256 qty) internal {
        address writer = makeAddr("helperWriter");
        uint256 w = _account(writer);
        _deposit(w, writer, 100_000e6);
        _mint(w, writer, seriesId, qty);
        _sendWrapper(seriesId, writer, owner, qty);
        vm.prank(owner);
        clearingModule.unwrapLong(accountId, seriesId, qty);
    }

    function _sendWrapper(bytes32 seriesId, address from, address to, uint256 qty) internal {
        IERC20 w = IERC20(_wrapper(seriesId));
        vm.prank(from);
        assertTrue(w.transfer(to, qty));
    }

    function _pause(uint8 bit) internal {
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.GLOBAL, bytes32(0), uint256(1) << bit);
    }

    function _seedInsurance(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(insurance), amount);
        insurance.deposit(address(usdc), amount);
    }

    function _seedKeeper(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(fees), amount);
        fees.fundKeeperReserve(address(usdc), amount);
    }
}
