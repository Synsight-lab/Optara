// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementFixture} from "../utils/SettlementFixture.sol";
import {SettlementWindow} from "../../src/settlement/SettlementWindow.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {OptionType, ProductConfig, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {MockSettlementOracle} from "../mocks/MockDependencies.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    GroupAlreadyFinalized,
    GroupNotFinalized,
    NotParticipant,
    SettlementIncomplete,
    RatioAlreadySet,
    RatioNotSet,
    NothingToClaim,
    UnknownGroup,
    OracleNotStalled,
    PayoutsOutstanding,
    ActionPaused
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for SettlementWindow: STL-001 (window side), STL-004..STL-021, PRV-004 (settle/redeem
///         previews). The round-in-force proofs themselves are SettlementOracle tests (step 6); an end-to-end
///         finalization through the real oracle is in SettlementWindowOracle.t.sol.
contract SettlementWindowTest is SettlementFixture {
    uint256 internal a; // MATH.md §13.2 account A: short 1 X, internal long 1 Y
    uint256 internal b; // account B: short 1 Y
    address internal w = makeAddr("walletW"); // holds 1 X wrapper
    address internal keeper = makeAddr("keeper");
    uint256 internal _mintFee;

    function setUp() public {
        _deployClearingMarket();
        a = _account(alice);
        b = _account(bob);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev MATH.md §13.2: X = C4500 (A minted the wrapper W holds), Y = C5000 (B short, A long, internal).
    function _example(uint256 bCash) internal {
        _deposit(a, alice, 4000e6);
        _mintFee = fees.previewSellerFee(c4500, 1e18);
        vm.prank(alice);
        clearingModule.mintExternalLong(a, c4500, 1e18, w, type(uint256).max, _empty());
        if (bCash != 0) _deposit(b, bob, bCash);
        _hold(b, c5000, -1e18);
        _hold(a, c5000, 1e18);
        vm.warp(EXP30 + 1);
    }

    function _settleAll() internal {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        window.settleAccountsGroup(ids, group30);
    }

    /// @dev Lowers an account's cash and moves the matching tokens out of custody (keeps INV-7).
    function _drainTo(uint256 accountId, uint256 cash) internal {
        uint256 excess = ledger.cashOf(accountId) - cash;
        vm.prank(clearing);
        ledger.subCash(accountId, excess);
        vm.prank(clearing);
        assertTrue(usdc.transfer(stranger, excess));
    }

    function _seedInsurance(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(insurance), amount);
        insurance.deposit(address(usdc), amount);
    }

    function _acct(bytes32 g) internal view returns (ISettlementWindow.GroupAccounting memory) {
        return window.groupAccounting(g);
    }

    function _checkPool() internal view {
        ISettlementWindow.GroupAccounting memory x = _acct(group30);
        assertLe(x.pool, x.collected + x.insurance, "INV-31");
    }

    // ------------------------------------------------------------------ initialization

    function test_initialState() public view {
        ISettlementWindow.Modules memory m = window.modules();
        assertEq(m.ledger, address(ledger));
        assertEq(m.registry, address(registry));
        assertEq(m.settlementOracle, settlementOracle);
        assertEq(m.fees, address(fees));
        assertEq(m.insurance, address(insurance));
        assertEq(m.clearing, address(clearingModule));
    }

    function test_initializeChecks() public {
        IProtocolControl c = IProtocolControl(address(pc));
        address impl = address(new SettlementWindow());
        ISettlementWindow.Modules memory good = window.modules();
        for (uint256 i; i < 6; ++i) {
            ISettlementWindow.Modules memory m = good;
            assembly {
                mstore(add(m, mul(i, 0x20)), 0)
            }
            vm.prank(governance);
            vm.expectRevert(ZeroAddress.selector);
            upgradeAdmin.deployProxy(impl, abi.encodeCall(SettlementWindow.initialize, (c, m)));
        }
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        window.initialize(c, good);
    }

    // ------------------------------------------------------------------ STL-001 / STL-004 / STL-005: finalization

    function test_STL001_STL005_finalize() public {
        _example(1000e6);
        assertEq(uint8(window.groupState(group30)), uint8(ISettlementWindow.GroupState.EXPIRED));
        vm.expectRevert(MockSettlementOracle.NoPrice.selector);
        window.finalizeGroup(group30, ""); // no valid proof yet

        MockSettlementOracle(settlementOracle).setPrice(ETH_CFG, EXP30, 5200e18);
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.GroupFinalized(group30, 5200e18, EXP30, 2);
        window.finalizeGroup(group30, "");
        assertEq(window.settlementPrice(group30), 5200e18);
        (bool fin, uint256 px) = window.settlementPriceOf(group30);
        assertTrue(fin);
        assertEq(px, 5200e18);
        assertEq(window.wrapperSupplyAtFinalization(c4500), 1e18, "INV-33: snapshot");
        assertEq(window.wrapperSupplyAtFinalization(c5000), 0);
        assertEq(_acct(group30).wrapperClaimN, 1e18 * 700e18 * 1e18);
        assertEq(uint8(window.groupState(group30)), uint8(ISettlementWindow.GroupState.FINALIZED));

        vm.expectRevert(abi.encodeWithSelector(GroupAlreadyFinalized.selector, group30));
        window.finalizeGroup(group30, ""); // INV-26
        // the clearing sees the finalized group too
        vm.prank(w);
        vm.expectRevert(abi.encodeWithSelector(GroupAlreadyFinalized.selector, group30));
        clearingModule.closeShortWithWrapper(a, c4500, 1e18);
    }

    function test_STL004_oracleStalled() public {
        _example(1000e6);
        uint64 deadline = EXP30 + 7 days;
        vm.expectRevert(abi.encodeWithSelector(OracleNotStalled.selector, group30, deadline));
        window.flagOracleStalled(group30);
        assertFalse(window.isOracleStalled(group30));
        vm.warp(deadline);
        assertTrue(window.isOracleStalled(group30));
        assertEq(uint8(window.groupState(group30)), uint8(ISettlementWindow.GroupState.ORACLE_STALLED));
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.OracleStalled(group30, deadline);
        window.flagOracleStalled(group30);
        vm.recordLogs();
        window.flagOracleStalled(group30); // once: a second flag is a no-op
        assertEq(vm.getRecordedLogs().length, 0, "no second event");
        assertTrue(_acct(group30).stalledFlagged);
        // a late authentic price still finalizes
        _finalize30(5200e18);
        assertFalse(window.isOracleStalled(group30));
        vm.expectRevert(abi.encodeWithSelector(OracleNotStalled.selector, group30, deadline));
        window.flagOracleStalled(group30);
    }

    function test_STL023_groupStateLifecycle() public {
        assertEq(uint8(window.groupState(group30)), uint8(ISettlementWindow.GroupState.ACTIVE));
        _example(1000e6);
        _finalize30(5200e18);
        _settleAll();
        assertEq(uint8(window.groupState(group30)), uint8(ISettlementWindow.GroupState.ALL_SETTLED));
        window.computeRecoveryRatio(group30);
        assertEq(uint8(window.groupState(group30)), uint8(ISettlementWindow.GroupState.REDEEMABLE));
        bytes32 bogus = keccak256("no group");
        vm.expectRevert(abi.encodeWithSelector(UnknownGroup.selector, bogus));
        window.groupState(bogus);
        vm.expectRevert(abi.encodeWithSelector(UnknownGroup.selector, bogus));
        window.finalizeGroup(bogus, "");
    }

    /// @dev C-14: the payoff price is capped at min over the group's series of floor(1e50 / CS).
    function test_STL023_priceCapPerGroup() public {
        address wsol = makeAddr("WSOL");
        bytes32 solCfg = keccak256("SOL/USDC settlement");
        settlementConfigs.set(solCfg, wsol, address(usdc), true);
        ProductConfig memory cfg = _productConfig("SOL");
        cfg.maxContractSizeWad = 1000e18;
        cfg.maxSettlementPriceWad = 1e29; // 1000e18 × 1e29 = 1e50
        vm.startPrank(governance);
        bytes32 sol = registry.approveProduct(wsol, address(usdc), cfg);
        risk.assignProductRiskSet(sol, RISK_SET);
        vm.stopPrank();
        SeriesParams memory p = SeriesParams({
            underlying: wsol,
            settlementAsset: address(usdc),
            optionType: OptionType.CALL,
            strikeWad: 100e18,
            contractSizeWad: 1000e18,
            expiry: EXP30,
            settlementOracleConfigId: solCfg,
            volSurfaceProductId: sol,
            riskParameterSetId: RISK_SET
        });
        vm.prank(seriesCreator);
        bytes32 big = registry.createSeries(p);
        bytes32 g = registry.groupOf(big);
        address bigWrapper = _wrapper(big);
        vm.prank(clearing); // the clearing is the wrappers' minter; one wrapper outstanding
        IExternalOptionWrapperLike(bigWrapper).mint(w, 1e18);
        vm.warp(EXP30 + 1);
        MockSettlementOracle(settlementOracle).setPrice(solCfg, EXP30, 5e29); // above the product bound
        window.finalizeGroup(g, "");
        assertEq(window.settlementPrice(g), 1e29, "capped at 1e50 / CS");
        assertEq(
            window.groupAccounting(g).wrapperClaimN, 1e18 * (1e29 - 100e18) * 1000e18, "claims at the capped price"
        );
    }

    // ------------------------------------------------------------------ STL-006 / STL-008: settling, netting

    function test_STL006_STL008_PRV004_nettingExample() public {
        _example(1000e6);
        _finalize30(5200e18);
        uint256 cashA = ledger.cashOf(a);
        (int256 netA, uint256 debtA, uint256 collA) = window.previewSettle(a, group30);
        assertEq(netA, -500e18 * 1e36);
        assertEq(debtA, 500e6);
        assertEq(collA, 500e6);
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.AccountSettled(a, group30, netA, 500e6, 0);
        vm.prank(keeper); // anyone can settle any participant
        window.settleAccountGroup(a, group30);
        assertEq(ledger.cashOf(a), cashA - 500e6);
        assertEq(ledger.balanceOf(a, c4500), 0);
        assertEq(ledger.balanceOf(a, c5000), 0);
        assertEq(ledger.participants(group30), 1, "INV-27: A left");

        window.settleAccountGroup(b, group30);
        assertEq(ledger.participants(group30), 0);
        ISettlementWindow.GroupAccounting memory x = _acct(group30);
        assertEq(x.collected, 700e6);
        assertEq(x.pool, 700e6);
        assertEq(x.unpaid, 0);

        window.computeRecoveryRatio(group30);
        (bool set, uint256 ratio) = window.recoveryRatio(group30);
        assertTrue(set);
        assertEq(ratio, 1e18, "INV-30: netted claims give exactly 1");

        (uint256 preview, bool fixed_) = window.previewRedeem(c4500, 1e18);
        assertEq(preview, 700e6);
        assertTrue(fixed_);
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.WrapperRedeemed(c4500, w, keeper, 1e18, 700e6);
        vm.prank(w);
        window.redeemWrapper(c4500, 1e18, keeper); // paid to the recipient, burned from the holder
        assertEq(usdc.balanceOf(keeper), 700e6);
        assertEq(usdc.balanceOf(w), 0);
        assertEq(_acct(group30).pool, 0);
        assertEq(IERC20(_wrapper(c4500)).totalSupply(), 0, "INV-33: supply falls only by redemption");
    }

    /// @dev Settling one group leaves the account's positions in other groups alone.
    function test_STL023_otherGroupsUntouched() public {
        bytes32 c45 = _series(ethUsdc, OptionType.CALL, 4500e18, T0 + 45 days);
        _hold(a, c45, 1e18);
        _example(1000e6);
        _finalize30(5200e18);
        (int256 net,,) = window.previewSettle(a, group30);
        assertEq(net, -500e18 * 1e36, "only the 30-day group counts");
        window.settleAccountGroup(a, group30);
        assertEq(ledger.balanceOf(a, c45), 1e18);
        assertEq(ledger.participants(registry.groupOf(c45)), 1);
    }

    /// @dev MATH.md §13.2 with B holding only 50: collected 550, insurance 100, ratio 0.928571…, W gets 649.999999.
    function test_STL009_STL012_STL016_shortfallExample() public {
        _example(50e6);
        _seedInsurance(100e6 - insurance.balanceOf(address(usdc))); // exactly 100 (A's seller fee funded some)
        _finalize30(5200e18);
        (, uint256 debtB, uint256 collectableB) = window.previewSettle(b, group30);
        assertEq(debtB, 200e6);
        assertEq(collectableB, 50e6, "only the cash it has");
        _settleAll();
        ISettlementWindow.GroupAccounting memory x = _acct(group30);
        assertEq(x.collected, 550e6);
        assertEq(x.unpaid, 150e6);
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.InsuranceCovered(group30, address(usdc), 100e6);
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.RecoveryRatioSet(group30, 928_571_428_571_428_571, 700e6, 550e6, 100e6);
        window.computeRecoveryRatio(group30);
        assertEq(insurance.balanceOf(address(usdc)), 0);
        _checkPool();

        vm.expectRevert(abi.encodeWithSelector(PayoutsOutstanding.selector, group30));
        window.sweepDust(group30); // STL-016: the wrapper is not redeemed yet
        vm.prank(w);
        window.redeemWrapper(c4500, 1e18, w);
        assertEq(usdc.balanceOf(w), 649_999_999, "649.999999: ratio and payout round down");
        assertEq(_acct(group30).pool, 1, "1 micro-USDC of dust");
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.DustSwept(group30, 1);
        window.sweepDust(group30);
        assertEq(insurance.balanceOf(address(usdc)), 1);
        assertEq(_acct(group30).pool, 0);
        assertEq(usdc.balanceOf(address(clearingModule)), ledger.cashOf(a) + ledger.cashOf(b), "INV-7");
    }

    function test_STL007_STL021_ordering() public {
        _example(1000e6);
        vm.expectRevert(abi.encodeWithSelector(GroupNotFinalized.selector, group30));
        window.settleAccountGroup(a, group30);
        vm.expectRevert(abi.encodeWithSelector(GroupNotFinalized.selector, group30));
        window.previewSettle(a, group30);
        vm.expectRevert(abi.encodeWithSelector(GroupNotFinalized.selector, group30));
        window.previewRedeem(c4500, 1e18);
        _finalize30(5200e18);
        vm.expectRevert(abi.encodeWithSelector(SettlementIncomplete.selector, 2));
        window.computeRecoveryRatio(group30); // INV-28
        vm.prank(w);
        vm.expectRevert(RatioNotSet.selector);
        window.redeemWrapper(c4500, 1e18, w);
        vm.expectRevert(RatioNotSet.selector);
        window.claimSettlement(a, group30);
        vm.expectRevert(RatioNotSet.selector);
        window.sweepDust(group30);
        (uint256 preview, bool fixed_) = window.previewRedeem(c4500, 1e18);
        assertEq(preview, 700e6, "at ratio 1 until fixed");
        assertFalse(fixed_);
    }

    // ------------------------------------------------------------------ STL-010 / STL-014 / STL-018: creditors

    /// @dev W passes 0.4 X to carol, who unwraps it: carol is a net creditor (0.4 × 700 = 280).
    function test_STL010_STL014_STL018_creditorsShareTheRatio() public {
        address carol = makeAddr("carol");
        uint256 cAcct = _account(carol);
        _deposit(a, alice, 4000e6);
        vm.prank(alice);
        clearingModule.mintExternalLong(a, c4500, 1e18, w, type(uint256).max, _empty());
        IERC20 x = IERC20(_wrapper(c4500));
        vm.prank(w);
        assertTrue(x.transfer(carol, 0.4e18));
        vm.prank(carol);
        clearingModule.unwrapLong(cAcct, c4500, 0.4e18);
        vm.warp(EXP30 + 1);
        _drainTo(a, 600e6); // A can pay only 600
        _finalize30(5200e18);

        window.settleAccountGroup(a, group30); // debt 700, collects 600
        window.settleAccountGroup(cAcct, group30);
        assertEq(window.creditOf(cAcct, group30), 0.4e18 * 700e18 * 1e18);
        vm.expectRevert(abi.encodeWithSelector(NotParticipant.selector, a, group30));
        window.settleAccountGroup(a, group30); // INV-48: once

        uint256 ins = insurance.balanceOf(address(usdc)); // only the seller fee's insurance share
        window.computeRecoveryRatio(group30); // ratio (600 + ins) / 700, rounded down
        (, uint256 ratio) = window.recoveryRatio(group30);
        assertEq(ratio, (600e6 + ins) * 1e18 / 700e6);
        vm.expectRevert(RatioAlreadySet.selector);
        window.computeRecoveryRatio(group30);

        vm.prank(w);
        window.redeemWrapper(c4500, 0.6e18, w);
        uint256 perUnitW = usdc.balanceOf(w) * 1e18 / 0.6e18;
        vm.expectRevert(abi.encodeWithSelector(PayoutsOutstanding.selector, group30));
        window.sweepDust(group30); // every wrapper is redeemed, but carol has not claimed
        uint256 credit = 280e6 * ratio / 1e18; // floor(creditN × ratio / (D × 1e18))
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.SettlementClaimed(cAcct, group30, credit);
        vm.prank(stranger); // anyone may claim; it pays into the account
        window.claimSettlement(cAcct, group30);
        assertEq(ledger.cashOf(cAcct), credit);
        uint256 perUnitC = ledger.cashOf(cAcct) * 1e18 / 0.4e18;
        assertApproxEqAbs(perUnitW, perUnitC, 3, "INV-29: the same ratio for wrappers and creditors");
        vm.expectRevert(NothingToClaim.selector);
        window.claimSettlement(cAcct, group30); // INV-48
        _checkPool();
        window.sweepDust(group30);
    }

    // ------------------------------------------------------------------ STL-013 / STL-019

    function test_STL013_zeroPayoffRedeemsForZero() public {
        uint256 pAcct = _account(bob);
        _deposit(pAcct, bob, 4000e6);
        vm.prank(bob);
        clearingModule.mintExternalLong(pAcct, p3500, 1e18, w, type(uint256).max, _empty());
        vm.warp(EXP30 + 1);
        _finalize30(5200e18);
        window.settleAccountGroup(pAcct, group30);
        window.computeRecoveryRatio(group30);
        (, uint256 ratio) = window.recoveryRatio(group30);
        assertEq(ratio, 1e18, "nothing owed: ratio 1");
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.WrapperRedeemed(p3500, w, bob, 1e18, 0);
        vm.prank(w);
        window.redeemWrapper(p3500, 1e18, bob);
        assertEq(IERC20(_wrapper(p3500)).balanceOf(w), 0, "burned");
        window.sweepDust(group30);
    }

    /// @dev Price 5,200 + 1 wei: B's debt rounds up to 200.000001, the payout down to 700.
    function test_STL019_rounding() public {
        _example(1000e6);
        _finalize30(5200e18 + 1);
        (, uint256 debtB,) = window.previewSettle(b, group30);
        assertEq(debtB, 200_000_001, "debt rounds up (B: 200 + 1e-12)");
        _settleAll();
        window.computeRecoveryRatio(group30);
        (uint256 payout,) = window.previewRedeem(c4500, 1e18);
        assertEq(payout, 700e6, "payout rounds down");
        vm.prank(w);
        window.redeemWrapper(c4500, 1e18, w);
        window.sweepDust(group30);
        assertEq(insurance.balanceOf(address(usdc)), _seedlessDust(), "fee share + dust");
    }

    /// @dev The seller fee's insurance share plus the swept dust: collected 700.000001 − paid 700 = 1 micro-USDC.
    function _seedlessDust() internal view returns (uint256) {
        return fees.split().insuranceBps * _mintFee / 10_000 + 1;
    }

    /// @dev grossClaim rounds up: with price 5,200 + 1 wei, B short of cash and enough insurance, the fund pays
    ///      150.000001 (not 150) and the ratio is exactly 1.
    function test_STL019_grossClaimRoundsUp() public {
        _example(50e6);
        _seedInsurance(200e6);
        _finalize30(5200e18 + 1);
        _settleAll();
        window.computeRecoveryRatio(group30);
        ISettlementWindow.GroupAccounting memory x = _acct(group30);
        assertEq(x.collected, 550e6);
        assertEq(x.insurance, 150_000_001);
        assertEq(x.ratioWad, 1e18);
    }

    /// @dev An in-the-money put: P3500 at 3,000 pays 500 per contract.
    function test_STL013_inTheMoneyPut() public {
        uint256 pAcct = _account(bob);
        _deposit(pAcct, bob, 4000e6);
        vm.prank(bob);
        clearingModule.mintExternalLong(pAcct, p3500, 1e18, w, type(uint256).max, _empty());
        uint256 cash = ledger.cashOf(pAcct);
        vm.warp(EXP30 + 1);
        _finalize30(3000e18);
        (int256 net, uint256 debt,) = window.previewSettle(pAcct, group30);
        assertEq(net, -500e18 * 1e36);
        assertEq(debt, 500e6);
        window.settleAccountGroup(pAcct, group30);
        assertEq(ledger.cashOf(pAcct), cash - 500e6);
        window.computeRecoveryRatio(group30);
        vm.prank(w);
        window.redeemWrapper(p3500, 1e18, w);
        assertEq(usdc.balanceOf(w), 500e6);
    }

    // ------------------------------------------------------------------ STL-015 / STL-020: batches and rewards

    function test_STL015_STL020_batchAndRewards() public {
        _example(1000e6);
        vm.prank(governance);
        fees.setRewards(address(usdc), 2e6, 0.5e6);
        usdc.mint(address(this), 100e6);
        usdc.approve(address(fees), 100e6);
        fees.fundKeeperReserve(address(usdc), 100e6);
        MockSettlementOracle(settlementOracle).setPrice(ETH_CFG, EXP30, 5200e18);
        vm.prank(keeper);
        window.finalizeGroup(group30, "");
        assertEq(usdc.balanceOf(keeper), 2e6, "finalize reward");
        vm.warp(block.timestamp + 2 hours); // +50%
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (a, 999, b, a); // a stranger id and a duplicate are skipped
        vm.prank(keeper);
        window.settleAccountsGroup(ids, group30);
        assertEq(usdc.balanceOf(keeper), 2e6 + 2 * 0.75e6, "two escalated settle rewards");
        assertEq(ledger.participants(group30), 0);
    }

    // ------------------------------------------------------------------ inputs, pauses, risk integration

    function test_redeemInputChecks() public {
        _example(1000e6);
        _finalize30(5200e18);
        _settleAll();
        window.computeRecoveryRatio(group30);
        vm.startPrank(w);
        vm.expectRevert(ZeroAmount.selector);
        window.redeemWrapper(c4500, 0, w);
        vm.expectRevert(InvalidRecipient.selector);
        window.redeemWrapper(c4500, 1e18, address(0));
        vm.expectRevert(); // more than held: the burn fails
        window.redeemWrapper(c4500, 2e18, w);
        vm.stopPrank();
    }

    function test_pauseBits() public {
        _example(1000e6);
        MockSettlementOracle(settlementOracle).setPrice(ETH_CFG, EXP30, 5200e18);
        _pause(PauseBits.FINALIZE);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.FINALIZE));
        window.finalizeGroup(group30, "");
        _unpause(PauseBits.FINALIZE);
        window.finalizeGroup(group30, "");
        _pause(PauseBits.SETTLE);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.SETTLE));
        window.settleAccountGroup(a, group30);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.SETTLE));
        window.computeRecoveryRatio(group30);
        _unpause(PauseBits.SETTLE);
        _settleAll();
        window.computeRecoveryRatio(group30);
        _pause(PauseBits.CLAIM_REDEEM);
        vm.prank(w);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.CLAIM_REDEEM));
        window.redeemWrapper(c4500, 1e18, w);
    }

    /// @dev Once finalized, the risk manager values the group's legs at the window's payoff.
    function test_riskUsesFinalPayoff() public {
        _example(1000e6);
        uint256 cashA = ledger.cashOf(a);
        _finalize30(5200e18);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(a);
        assertEq(r.equity, int256(cashA * 1e12) - 500e18);
    }

    function _pause(uint8 bit) internal {
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.GLOBAL, bytes32(0), uint256(1) << bit);
    }

    function _unpause(uint8 bit) internal {
        vm.prank(governance);
        pc.unpause(IProtocolControl.Scope.GLOBAL, bytes32(0), uint256(1) << bit);
    }
}

interface IExternalOptionWrapperLike {
    function mint(address to, uint256 amount) external;
}
