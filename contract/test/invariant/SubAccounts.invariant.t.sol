// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";
import {SubAccounts} from "../../src/accounts/SubAccounts.sol";
import {PositionLimit} from "../../src/libraries/Errors.sol";

/// @notice Random ledger writes by the three writers across 4 accounts × 5 series (2 groups, 2 underlyings),
///         random cash moves and limit changes. A ghost model mirrors every successful write.
contract LedgerHandler is Test {
    SubAccounts internal ledger;
    address[3] internal writers;
    address internal governance;
    uint256[] public accounts;
    bytes32[] public seriesIds;
    int256 internal minQty;

    mapping(uint256 => mapping(bytes32 => int256)) public ghostBalance;
    mapping(uint256 => uint256) public ghostCash;
    uint256 public successfulWrites;
    uint256 public limitRejections;

    constructor(SubAccounts l, address[3] memory w, address gov, uint256[] memory accs, bytes32[] memory sids) {
        ledger = l;
        writers = w;
        governance = gov;
        accounts = accs;
        seriesIds = sids;
        // forge-lint: disable-next-line(unsafe-typecast)
        minQty = int256(l.minPositionQty()); // 0.01e18
    }

    function accountsLength() external view returns (uint256) {
        return accounts.length;
    }

    function seriesLength() external view returns (uint256) {
        return seriesIds.length;
    }

    function applyDelta(uint256 accSeed, uint256 seriesSeed, int256 units, uint256 writerSeed, bool closeAll) external {
        uint256 id = accounts[accSeed % accounts.length];
        bytes32 s = seriesIds[seriesSeed % seriesIds.length];
        int256 d = closeAll ? -ghostBalance[id][s] : bound(units, -50, 50) * minQty;
        vm.prank(writers[writerSeed % 3]);
        try ledger.applyDelta(id, s, d) returns (int256 bal) {
            ghostBalance[id][s] += d;
            assertEq(bal, ghostBalance[id][s]);
            if (d != 0) successfulWrites++;
        } catch (bytes memory reason) {
            // deltas are multiples of the minimum, so the only legitimate failure is a position limit
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(bytes4(reason), PositionLimit.selector, "unexpected ledger revert");
            limitRejections++;
        }
    }

    function moveCash(uint256 accSeed, uint128 amount, bool add, uint256 writerSeed) external {
        uint256 id = accounts[accSeed % accounts.length];
        vm.prank(writers[writerSeed % 3]);
        if (add) {
            ledger.addCash(id, amount);
            ghostCash[id] += amount;
        } else {
            uint256 amt = bound(amount, 0, ghostCash[id]);
            ledger.subCash(id, amt);
            ghostCash[id] -= amt;
        }
    }

    function setLimits(uint256 maxSeries, uint256 maxBuckets) external {
        maxSeries = bound(maxSeries, 1, 8);
        maxBuckets = bound(maxBuckets, 1, maxSeries < 4 ? maxSeries : 4);
        vm.prank(governance);
        ledger.setPositionLimits(maxSeries, maxBuckets);
    }
}

contract SubAccountsInvariantTest is LedgerFixture {
    LedgerHandler internal handler;
    bytes32[2] internal groups;
    address[2] internal underlyings;

    function setUp() public {
        _deployLedger();
        uint256[] memory accs = new uint256[](4);
        accs[0] = _newAccount(alice, address(usdc));
        accs[1] = _newAccount(bob, address(usdc));
        accs[2] = _newAccount(alice, address(usdc));
        accs[3] = _newAccount(stranger, address(usdc));
        bytes32[] memory sids = new bytes32[](5);
        (sids[0], sids[1], sids[2], sids[3], sids[4]) = (ethC4500, ethP3500, ethC5000, ethC4500b, btcC90k);
        handler = new LedgerHandler(ledger, [clearing, liquidationModule, settlementWindow], governance, accs, sids);
        groups = [groupA, groupB];
        underlyings = [weth, wbtc];
        targetContract(address(handler));
    }

    /// @dev Ledger balances and cash equal the ghost model (every write applied exactly once).
    function invariant_balancesAndCashMatchModel() public view {
        for (uint256 i; i < handler.accountsLength(); ++i) {
            uint256 id = handler.accounts(i);
            assertEq(ledger.cashOf(id), handler.ghostCash(id));
            for (uint256 j; j < handler.seriesLength(); ++j) {
                bytes32 s = handler.seriesIds(j);
                assertEq(ledger.balanceOf(id, s), handler.ghostBalance(id, s));
            }
        }
    }

    /// @dev INV-2: totals are the sums of positive and negative balances.
    function invariant_INV2_totals() public view {
        for (uint256 j; j < handler.seriesLength(); ++j) {
            bytes32 s = handler.seriesIds(j);
            uint256 longs;
            uint256 shorts;
            for (uint256 i; i < handler.accountsLength(); ++i) {
                int256 b = ledger.balanceOf(handler.accounts(i), s);
                // forge-lint: disable-next-line(unsafe-typecast)
                if (b > 0) longs += uint256(b);
                // forge-lint: disable-next-line(unsafe-typecast)
                else shorts += uint256(-b);
            }
            (uint256 l, uint256 sh) = ledger.totals(s);
            assertEq(l, longs);
            assertEq(sh, shorts);
        }
    }

    /// @dev Product short notional = Σ over accounts and series of the product of |short| × CS.
    function invariant_productShortNotional() public view {
        uint256 eth;
        uint256 btc;
        for (uint256 i; i < handler.accountsLength(); ++i) {
            for (uint256 j; j < handler.seriesLength(); ++j) {
                bytes32 s = handler.seriesIds(j);
                int256 b = ledger.balanceOf(handler.accounts(i), s);
                if (b >= 0) continue;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 n = uint256(-b) * registry.getSeries(s).contractSizeWad;
                if (registry.getSeries(s).underlying == weth) eth += n;
                else btc += n;
            }
        }
        assertEq(ledger.productShortNotional(ethUsdc), eth);
        assertEq(ledger.productShortNotional(btcUsdc), btc);
    }

    /// @dev INV-6: every non-zero balance is at least the minimum and a multiple of it.
    function invariant_INV6_minimum() public view {
        uint256 m = ledger.minPositionQty();
        for (uint256 i; i < handler.accountsLength(); ++i) {
            for (uint256 j; j < handler.seriesLength(); ++j) {
                int256 b = ledger.balanceOf(handler.accounts(i), handler.seriesIds(j));
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 mag = b >= 0 ? uint256(b) : uint256(-b);
                if (mag != 0) {
                    assertGe(mag, m);
                    assertEq(mag % m, 0);
                }
            }
        }
    }

    /// @dev INV-27: participants = accounts with any non-zero balance in the group; per-account group counts exact.
    function invariant_INV27_participants() public view {
        for (uint256 g; g < 2; ++g) {
            uint256 count;
            for (uint256 i; i < handler.accountsLength(); ++i) {
                uint256 id = handler.accounts(i);
                uint256 n;
                for (uint256 j; j < handler.seriesLength(); ++j) {
                    bytes32 s = handler.seriesIds(j);
                    if (registry.groupOf(s) == groups[g] && ledger.balanceOf(id, s) != 0) n++;
                }
                assertEq(ledger.seriesCountInGroup(id, groups[g]), n);
                if (n > 0) count++;
            }
            assertEq(ledger.participants(groups[g]), count);
        }
    }

    /// @dev Position indexes list exactly the non-zero series and their underlyings (no duplicates, no stale
    ///      entries). INV-43 bounds hold for every account built under the current limits.
    function invariant_INV43_indexes() public view {
        for (uint256 i; i < handler.accountsLength(); ++i) {
            uint256 id = handler.accounts(i);
            bytes32[] memory list = ledger.seriesOf(id);
            uint256 nonZero;
            for (uint256 j; j < handler.seriesLength(); ++j) {
                bytes32 s = handler.seriesIds(j);
                bool held = ledger.balanceOf(id, s) != 0;
                if (held) nonZero++;
                assertEq(_count(list, s), held ? 1 : 0);
            }
            assertEq(list.length, nonZero);
            address[] memory buckets = ledger.bucketsOf(id);
            for (uint256 u; u < 2; ++u) {
                bool any;
                for (uint256 j; j < list.length; ++j) {
                    if (registry.getSeries(list[j]).underlying == underlyings[u]) any = true;
                }
                uint256 c;
                for (uint256 k; k < buckets.length; ++k) {
                    if (buckets[k] == underlyings[u]) c++;
                }
                assertEq(c, any ? 1 : 0);
            }
        }
    }

    function _count(bytes32[] memory list, bytes32 x) internal pure returns (uint256 c) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == x) c++;
        }
    }

    /// @dev Proves the handler's paths run: writes succeed, limits reject, cash moves.
    function test_handlerPathsReachable() public {
        handler.applyDelta(0, 0, 5, 0, false);
        handler.applyDelta(0, 4, -3, 1, false);
        handler.applyDelta(1, 0, -7, 2, false);
        assertEq(handler.successfulWrites(), 3);
        handler.setLimits(1, 1);
        handler.applyDelta(0, 2, 1, 0, false); // third series for account 0 → PositionLimit
        assertEq(handler.limitRejections(), 1);
        handler.applyDelta(0, 0, 0, 0, true); // close
        handler.moveCash(0, 100, true, 0);
        handler.moveCash(0, 40, false, 1);
        invariant_balancesAndCashMatchModel();
        invariant_INV2_totals();
        invariant_INV27_participants();
        invariant_INV43_indexes();
    }
}
