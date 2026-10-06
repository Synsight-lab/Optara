// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";
import {SubAccounts} from "../../src/accounts/SubAccounts.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {OptionType, Position, LedgerSeries} from "../../src/libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    UnknownAccount,
    UnknownSeries,
    AssetMismatch,
    AssetNotApproved,
    InsufficientCash,
    PositionLimit,
    PositionBelowMinimum,
    InvalidLimits
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for SubAccounts: ACC-001..ACC-006, ledger accounting (INV-2, INV-5, INV-6, INV-8, INV-27,
///         INV-43), position indexes, limits.
contract SubAccountsTest is LedgerFixture {
    uint256 internal a; // alice, USDC

    function setUp() public {
        _deployLedger();
        a = _newAccount(alice, address(usdc));
    }

    // ------------------------------------------------------------------ initialization

    function test_initializeChecks() public {
        SubAccounts impl = new SubAccounts();
        vm.startPrank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            address(impl),
            abi.encodeCall(
                SubAccounts.initialize,
                (
                    IProtocolControl(address(pc)),
                    IOptionSeriesRegistry(address(0)),
                    clearing,
                    clearing,
                    clearing,
                    16,
                    4,
                    1
                )
            )
        );
        vm.expectRevert(InvalidLimits.selector);
        upgradeAdmin.deployProxy(
            address(impl),
            abi.encodeCall(
                SubAccounts.initialize,
                (
                    IProtocolControl(address(pc)),
                    IOptionSeriesRegistry(address(registry)),
                    clearing,
                    clearing,
                    clearing,
                    16,
                    4,
                    0
                )
            )
        );
        vm.expectRevert(InvalidLimits.selector);
        upgradeAdmin.deployProxy(
            address(impl),
            abi.encodeCall(
                SubAccounts.initialize,
                (
                    IProtocolControl(address(pc)),
                    IOptionSeriesRegistry(address(registry)),
                    clearing,
                    clearing,
                    clearing,
                    16,
                    4,
                    1e18 + 1
                )
            )
        );
        vm.stopPrank();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ledger.initialize(
            IProtocolControl(address(pc)),
            IOptionSeriesRegistry(address(registry)),
            clearing,
            clearing,
            clearing,
            16,
            4,
            1
        );

        (address c, address l, address s) = ledger.writers();
        assertEq(c, clearing);
        assertEq(l, liquidationModule);
        assertEq(s, settlementWindow);
        assertEq(ledger.maxSeriesPerAccount(), 16);
        assertEq(ledger.maxBucketsPerAccount(), 4);
        assertEq(ledger.minPositionQty(), MIN_QTY);
    }

    // ------------------------------------------------------------------ ACC: accounts and operators

    function test_ACC001_createSubAccount() public {
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.SubAccountCreated(2, bob, address(usdc));
        uint256 b = _newAccount(bob, address(usdc));
        assertEq(b, 2, "ids increase from 1");
        assertEq(ledger.ownerOf(b), bob);
        assertEq(ledger.settlementAssetOf(b), address(usdc));
        assertEq(ledger.cashOf(b), 0);
        assertEq(ledger.accountCount(), 2);
    }

    function test_ACC002_unapprovedAssetReverts() public {
        address dai = makeAddr("DAI");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AssetNotApproved.selector, dai));
        ledger.createSubAccount(dai);
    }

    function test_ACC003_operatorSetAndRevoke() public {
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.OperatorSet(a, bob, true);
        vm.prank(alice);
        ledger.setOperator(a, bob, true);
        assertTrue(ledger.isAuthorized(a, bob));
        assertTrue(ledger.isOperator(a, bob));
        assertTrue(ledger.isAuthorized(a, alice));

        vm.prank(alice);
        ledger.setOperator(a, bob, false);
        assertFalse(ledger.isAuthorized(a, bob));
    }

    function test_ACC004_operatorCannotSetOperators() public {
        vm.prank(alice);
        ledger.setOperator(a, bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, bob));
        ledger.setOperator(a, stranger, true);
    }

    function test_ACC005_strangerNotAuthorized() public {
        assertFalse(ledger.isAuthorized(a, stranger));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ledger.setOperator(a, stranger, true);
    }

    function test_ACC006_unknownAccount() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownAccount.selector, 99));
        ledger.ownerOf(99);
        vm.expectRevert(abi.encodeWithSelector(UnknownAccount.selector, 99));
        ledger.setOperator(99, bob, true);
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(UnknownAccount.selector, 99));
        ledger.addCash(99, 1);
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(UnknownAccount.selector, 99));
        ledger.applyDelta(99, ethC4500, 1e18);
        assertFalse(ledger.isAuthorized(99, address(0)), "no account, nobody authorized");
    }

    function test_setOperatorRejectsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        ledger.setOperator(a, address(0), true);
    }

    // ------------------------------------------------------------------ writers

    function test_onlyWritersWrite() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ledger.addCash(a, 1);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ledger.subCash(a, 1);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ledger.applyDelta(a, ethC4500, 1e18);
        vm.stopPrank();
        vm.prank(alice); // even the owner can't write the ledger directly
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, alice));
        ledger.addCash(a, 1);

        address[3] memory writers = [clearing, liquidationModule, settlementWindow];
        for (uint256 i; i < 3; ++i) {
            vm.prank(writers[i]);
            ledger.addCash(a, 1);
        }
        assertEq(ledger.cashOf(a), 3);
    }

    // ------------------------------------------------------------------ cash (INV-8)

    function test_cash() public {
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.CashUpdated(a, 100e6, 100e6);
        vm.prank(clearing);
        ledger.addCash(a, 100e6);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.CashUpdated(a, -40e6, 60e6);
        vm.prank(clearing);
        ledger.subCash(a, 40e6);
        assertEq(ledger.cashOf(a), 60e6);

        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(InsufficientCash.selector, 60e6 + 1, 60e6));
        ledger.subCash(a, 60e6 + 1);
    }

    // ------------------------------------------------------------------ balances, totals, indexes

    function test_openLongUpdatesEverything() public {
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.ParticipantsUpdated(groupA, 1);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.BalanceUpdated(a, ethC4500, 1e18, 1e18);
        assertEq(_delta(a, ethC4500, 1e18), 1e18);

        assertEq(ledger.balanceOf(a, ethC4500), 1e18);
        (uint256 l, uint256 s) = ledger.totals(ethC4500);
        assertEq(l, 1e18);
        assertEq(s, 0);
        assertEq(ledger.seriesOf(a).length, 1);
        assertEq(ledger.bucketsOf(a)[0], weth);
        assertEq(ledger.participants(groupA), 1);
        assertEq(ledger.seriesCountInGroup(a, groupA), 1);
    }

    function test_shortAndSignFlipUpdateTotals() public {
        _delta(a, ethC4500, -2e18);
        (uint256 l, uint256 s) = ledger.totals(ethC4500);
        assertEq(l, 0);
        assertEq(s, 2e18);
        _delta(a, ethC4500, 3e18); // short 2 → long 1
        (l, s) = ledger.totals(ethC4500);
        assertEq(l, 1e18);
        assertEq(s, 0);
        assertEq(ledger.seriesOf(a).length, 1, "still one position");
        assertEq(ledger.participants(groupA), 1);
    }

    function test_INV27_participantsCountAccountsNotSeries() public {
        uint256 b = _newAccount(bob, address(usdc));
        _delta(a, ethC4500, 1e18);
        _delta(a, ethP3500, -1e18); // same group
        assertEq(ledger.participants(groupA), 1);
        assertEq(ledger.seriesCountInGroup(a, groupA), 2);
        _delta(b, ethC4500, -1e18);
        assertEq(ledger.participants(groupA), 2);
        _delta(a, ethC4500, -1e18); // alice still holds the put
        assertEq(ledger.participants(groupA), 2);
        _delta(a, ethP3500, 1e18); // alice flat in group A
        assertEq(ledger.participants(groupA), 1);
        assertEq(ledger.seriesCountInGroup(a, groupA), 0);
        _delta(a, ethC4500b, 1e18); // group B is separate
        assertEq(ledger.participants(groupB), 1);
        assertEq(ledger.participants(groupA), 1);
    }

    function test_closingRemovesFromIndexesSwapAndPop() public {
        _delta(a, ethC4500, 1e18);
        _delta(a, ethP3500, 1e18);
        _delta(a, ethC5000, 1e18);
        _delta(a, btcC90k, 1e18);
        assertEq(ledger.bucketsOf(a).length, 2);

        _delta(a, ethP3500, -1e18); // remove the middle one
        bytes32[] memory list = ledger.seriesOf(a);
        assertEq(list.length, 3);
        assertTrue(_contains(list, ethC4500) && _contains(list, ethC5000) && _contains(list, btcC90k));
        assertFalse(_contains(list, ethP3500));

        _delta(a, btcC90k, -1e18); // BTC bucket disappears
        assertEq(ledger.bucketsOf(a).length, 1);
        assertEq(ledger.bucketsOf(a)[0], weth);

        // re-opening after removal works and indexes stay consistent
        _delta(a, ethP3500, -1e18);
        _delta(a, ethC4500, -1e18);
        list = ledger.seriesOf(a);
        assertEq(list.length, 2);
        assertTrue(_contains(list, ethC5000) && _contains(list, ethP3500));
    }

    function _contains(bytes32[] memory list, bytes32 x) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == x) return true;
        }
        return false;
    }

    function test_positionsOfReturnsSeriesData() public {
        (, bool cachedBefore) = ledger.seriesInfo(ethP3500);
        assertFalse(cachedBefore);
        _delta(a, ethC4500, 2e18);
        _delta(a, ethP3500, -1e18);
        Position[] memory ps = ledger.positionsOf(a);
        assertEq(ps.length, 2);
        Position memory put = ps[0].seriesId == ethP3500 ? ps[0] : ps[1];
        assertEq(put.balance, -1e18);
        assertEq(put.series.strikeWad, 3500e18);
        assertEq(uint8(put.series.optionType), uint8(OptionType.PUT));
        assertEq(put.series.contractSizeWad, 1e18);
        assertEq(put.series.expiry, EXP1);
        assertEq(put.series.underlying, weth);
        assertEq(put.series.settlementAsset, address(usdc));
        assertEq(put.series.groupId, groupA);
        assertEq(put.series.productId, ethUsdc);
        assertEq(put.series.riskParameterSetId, RISK_SET);
        (LedgerSeries memory info, bool cached) = ledger.seriesInfo(ethP3500);
        assertTrue(cached);
        assertEq(info.strikeWad, 3500e18);
    }

    function test_productShortNotional() public {
        uint256 b = _newAccount(bob, address(usdc));
        _delta(a, ethC4500, -2e18); // 2 × CS 1
        _delta(b, ethP3500, -1e18);
        _delta(a, btcC90k, -1e18); // other product
        assertEq(ledger.productShortNotional(ethUsdc), 3e36);
        _delta(a, ethC4500, 3e18); // short 2 → long 1
        assertEq(ledger.productShortNotional(ethUsdc), 1e36);
        _delta(b, ethP3500, 1e18);
        assertEq(ledger.productShortNotional(ethUsdc), 0);
        assertEq(ledger.productShortNotional(btcUsdc), 1e36);
    }

    function test_zeroDeltaIsNoOp() public {
        _delta(a, ethC4500, 1e18);
        vm.recordLogs();
        assertEq(_delta(a, ethC4500, 0), 1e18);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ------------------------------------------------------------------ INV-6 minimum position

    function test_CLR012_minimumPosition() public {
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(PositionBelowMinimum.selector, MIN_QTY_I - 1));
        ledger.applyDelta(a, ethC4500, MIN_QTY_I - 1);

        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(PositionBelowMinimum.selector, int256(1.005e18)));
        ledger.applyDelta(a, ethC4500, 1.005e18); // not a multiple of 0.01

        _delta(a, ethC4500, MIN_QTY_I); // exactly the minimum
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(PositionBelowMinimum.selector, MIN_QTY_I / 2));
        ledger.applyDelta(a, ethC4500, -MIN_QTY_I / 2); // leaving dust
        _delta(a, ethC4500, -MIN_QTY_I); // closing fully is fine
        assertEq(ledger.balanceOf(a, ethC4500), 0);
    }

    // ------------------------------------------------------------------ INV-5 asset matching, unknown series

    function test_CLR008_assetMismatch() public {
        uint256 t = _newAccount(alice, address(usdt));
        vm.prank(clearing);
        vm.expectRevert(AssetMismatch.selector);
        ledger.applyDelta(t, ethC4500, 1e18);
    }

    function test_unknownSeriesReverts() public {
        bytes32 x = keccak256("nope");
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, x));
        ledger.applyDelta(a, x, 1e18);
    }

    // ------------------------------------------------------------------ INV-43 position limits

    function test_CLR020_seriesLimit() public {
        vm.prank(governance);
        ledger.setPositionLimits(3, 2);
        _delta(a, ethC4500, 1e18);
        _delta(a, ethP3500, 1e18);
        _delta(a, ethC5000, 1e18);
        vm.prank(clearing);
        vm.expectRevert(PositionLimit.selector);
        ledger.applyDelta(a, ethC4500b, 1e18);
        // changing an existing position is always allowed
        _delta(a, ethC4500, 1e18);
    }

    function test_CLR020_bucketLimit() public {
        vm.prank(governance);
        ledger.setPositionLimits(16, 1);
        _delta(a, ethC4500, 1e18);
        vm.prank(clearing);
        vm.expectRevert(PositionLimit.selector);
        ledger.applyDelta(a, btcC90k, 1e18);
    }

    function test_loweringLimitsForcesNothing() public {
        _delta(a, ethC4500, 1e18);
        _delta(a, ethP3500, 1e18);
        vm.prank(governance);
        ledger.setPositionLimits(1, 1);
        assertEq(ledger.seriesOf(a).length, 2, "existing positions kept");
        _delta(a, ethC4500, -1e18); // reducing works
        vm.prank(clearing);
        vm.expectRevert(PositionLimit.selector);
        ledger.applyDelta(a, ethC5000, 1e18);
    }

    function test_setPositionLimits() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ledger.setPositionLimits(8, 2);
        vm.startPrank(governance);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.PositionLimitsSet(8, 2);
        ledger.setPositionLimits(8, 2);
        vm.expectRevert(InvalidLimits.selector);
        ledger.setPositionLimits(0, 1);
        vm.expectRevert(InvalidLimits.selector);
        ledger.setPositionLimits(65, 4);
        vm.expectRevert(InvalidLimits.selector);
        ledger.setPositionLimits(8, 0);
        vm.expectRevert(InvalidLimits.selector);
        ledger.setPositionLimits(32, 17);
        vm.expectRevert(InvalidLimits.selector);
        ledger.setPositionLimits(2, 3); // more buckets than series
        vm.stopPrank();
    }

    function test_setMinPositionQtyOnlyToDivisor() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ledger.setMinPositionQty(1e15);
        vm.startPrank(governance);
        vm.expectRevert(InvalidLimits.selector);
        ledger.setMinPositionQty(0.02e18); // raising would invalidate 0.01 balances
        vm.expectRevert(InvalidLimits.selector);
        ledger.setMinPositionQty(0.003e18); // not a divisor
        vm.expectRevert(InvalidLimits.selector);
        ledger.setMinPositionQty(0);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISubAccounts.MinPositionQtySet(0.001e18);
        ledger.setMinPositionQty(0.001e18);
        vm.stopPrank();
        _delta(a, ethC4500, 0.001e18);
        assertEq(ledger.balanceOf(a, ethC4500), 0.001e18);
    }
}
