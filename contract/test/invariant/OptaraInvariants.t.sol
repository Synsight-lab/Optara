// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";
import {OptaraHandler} from "./OptaraHandler.sol";
import {PayoffMath} from "../../src/libraries/PayoffMath.sol";
import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";
import {console2} from "forge-std/console2.sol";

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
/// forge-config: ci.invariant.runs = 512
/// forge-config: ci.invariant.depth = 400
/// @notice Stateful invariant campaign (TEST_CASES.md Part XXXIV INV-001..020; INVARIANTS.md; TESTING.md 110-112).
contract OptaraInvariants is OptaraTestBase {
    OptaraHandler handler;
    address[] actors;
    bytes32[] ids;
    MockERC20[] assetList;
    bytes32[] groupList;

    function setUp() public override {
        super.setUp();
        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(dave);
        uint64 shortExpiry = uint64(block.timestamp + 3 days);
        uint64 longExpiry = uint64(block.timestamp + 6 days);
        // group A: MON/USDT (6 decimals), mixed calls/puts and contract sizes, short-dated
        ids.push(_createSeries(MON, address(usdt), OptionType.CALL, 10 * WAD, 5 * WAD, WAD, shortExpiry, monUsdtConfig));
        ids.push(
            _createSeries(MON, address(usdt), OptionType.CALL, 12 * WAD, 3 * WAD, WAD / 2, shortExpiry, monUsdtConfig)
        );
        ids.push(_createSeries(MON, address(usdt), OptionType.PUT, 10 * WAD, 4 * WAD, WAD, shortExpiry, monUsdtConfig));
        // group B: MON/USDe (18 decimals), longer-dated
        ids.push(
            _createSeries(MON, address(usde), OptionType.CALL, 10 * WAD, 5 * WAD, WAD / 10, longExpiry, monUsdeConfig)
        );
        ids.push(_createSeries(MON, address(usde), OptionType.PUT, 8 * WAD, 2 * WAD, WAD, longExpiry, monUsdeConfig));
        assetList.push(usdt);
        assetList.push(usde);
        groupList.push(_groupOf(ids[0]));
        groupList.push(_groupOf(ids[3]));
        MockAggregator[] memory feeds = new MockAggregator[](2);
        feeds[0] = monUsdtFeed;
        feeds[1] = monUsdeFeed;
        handler = new OptaraHandler(core, actors, ids, assetList, groupList, feeds);
        targetContract(address(handler));
        // Weighted action mix: state-building actions appear more often than time jumps.
        bytes4[] memory sel = new bytes4[](27);
        uint256 k;
        for (uint256 i = 0; i < 4; ++i) {
            sel[k++] = OptaraHandler.write.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.deposit.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.transferLong.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.lock.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.close.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.withdraw.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.sync.selector;
        }
        for (uint256 i = 0; i < 2; ++i) {
            sel[k++] = OptaraHandler.redeem.selector;
        }
        sel[k++] = OptaraHandler.unlock.selector;
        sel[k++] = OptaraHandler.finalize.selector;
        sel[k++] = OptaraHandler.warp.selector;
        sel[k++] = OptaraHandler.donate.selector;
        sel[k++] = OptaraHandler.withdrawTooMuch.selector;
        sel[k++] = OptaraHandler.finalize.selector;
        sel[k++] = OptaraHandler.refinalize.selector;
        sel[k++] = OptaraHandler.writeAfterExpiry.selector;
        sel[k++] = OptaraHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// INV-001 / INV-MARGIN-03 / INV-SETTLE-02: every account is solvent in every asset at every checkpoint.
    function invariant_INV_001_accountsSolvent() public view {
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = 0; j < assetList.length; ++j) {
                assertEq(core.deficit(actors[i], address(assetList[j])), 0, "deficit");
            }
        }
    }

    /// INV-002/003/005/006/020 and INV-SUPPLY-01..05: cumulative identities per series.
    function invariant_INV_002_003_supplyIdentities() public view {
        for (uint256 i = 0; i < ids.length; ++i) {
            SeriesState memory st = core.getSeriesState(ids[i]);
            uint256 supply = _token(ids[i]).totalSupply();
            assertEq(st.closed + st.redeemed + st.hedgeConsumed + supply, st.minted, "M = C + R + H + L");
            assertEq(st.closed + st.shortSynced + st.openShortQty, st.minted, "M = C + S + O");
            if (!core.getGroup(_groupOf(ids[i])).finalized) {
                assertEq(supply, st.openShortQty, "pre-finalization L == O");
                assertEq(st.redeemed + st.hedgeConsumed + st.shortSynced, 0);
            }
        }
    }

    /// INV-004 / INV-HEDGE-02: custody covers assigned locked quantity (plus any donated surplus).
    function invariant_INV_004_custodyCoversLocked() public view {
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 locked;
            for (uint256 a = 0; a < actors.length; ++a) {
                locked += core.positionOf(actors[a], ids[i]).lockedQty;
            }
            assertGe(_token(ids[i]).balanceOf(address(core)), locked, "custody");
        }
    }

    /// INV-009 / INV-VAULT-04 / INV-ROUND-05: pooled per-asset identity with a nonnegative rounding reserve.
    /// VB * D >= (sum effective cash + donated surplus) * D + exact outstanding external claim numerators.
    function invariant_INV_009_010_pooledVault() public view {
        for (uint256 j = 0; j < assetList.length; ++j) {
            address asset = address(assetList[j]);
            uint8 dec = assetList[j].decimals();
            uint256 d = FixedPointMath.nativeDenominator(dec);
            int256 effective;
            for (uint256 a = 0; a < actors.length; ++a) {
                effective += core.effectiveCash(actors[a], asset);
            }
            uint256 externalN;
            for (uint256 i = 0; i < ids.length; ++i) {
                Series memory s = core.getSeries(ids[i]);
                if (s.settlementAsset != asset) continue;
                Group memory g = core.getGroup(s.groupId);
                if (!g.finalized) continue;
                uint256 locked;
                for (uint256 a = 0; a < actors.length; ++a) {
                    locked += core.positionOf(actors[a], ids[i]).lockedQty;
                }
                uint256 external_ = _token(ids[i]).totalSupply() - locked;
                externalN += PayoffMath.payoffNumerator(
                    s.optionType, s.strikeWad, s.capWad, s.contractSizeWad, g.settlementPriceWad, external_
                );
            }
            assertGe(effective, 0);
            uint256 vault = assetList[j].balanceOf(address(core));
            uint256 claimsN = (uint256(effective) + handler.ghostDonated(asset)) * d + externalN;
            assertGe(vault * d, claimsN, "vault identity (reserve >= 0)");
            // Exact pooled identity (MATH.md sections 64, 118): the reserve is derived independently from the
            // realized residual counter plus the rounding already embedded in pending finalized deltas.
            assertEq(vault * d, claimsN + core.roundingResidualN(asset) + _pendingResidualN(asset, d), "exact identity");
        }
    }

    /// Rounding residual of finalized-but-unsynced account groups: included in effective cash already.
    function _pendingResidualN(address asset, uint256 d) internal view returns (uint256 r) {
        for (uint256 a = 0; a < actors.length; ++a) {
            for (uint256 gi = 0; gi < groupList.length; ++gi) {
                Group memory g = core.getGroup(groupList[gi]);
                if (g.settlementAsset != asset || !g.finalized) continue;
                if (core.accountGroupSeries(actors[a], groupList[gi]).length == 0) continue;
                (int256 delta, uint256 s, uint256 l) = core.previewSync(actors[a], groupList[gi]);
                if (delta < 0) r += uint256(-delta) * d - (s - l);
                else if (l > s) r += (l - s) - uint256(delta) * d;
            }
        }
    }

    /// INV-CAP-01: wider counters equal the sum of unreleased groups; group = sum of series; series = C*CS*supply.
    function invariant_capCounters() public view {
        uint256[2] memory unreleasedByAsset;
        for (uint256 gi = 0; gi < groupList.length; ++gi) {
            Group memory g = core.getGroup(groupList[gi]);
            uint256 sumSeries;
            for (uint256 i = 0; i < ids.length; ++i) {
                Series memory s = core.getSeries(ids[i]);
                if (s.groupId != groupList[gi]) continue;
                SeriesState memory st = core.getSeriesState(ids[i]);
                assertEq(st.exposureN, PayoffMath.product(s.capWad, s.contractSizeWad, _token(ids[i]).totalSupply()));
                sumSeries += st.exposureN;
            }
            assertEq(g.exposureN, sumSeries, "group = sum series");
            if (!g.released) unreleasedByAsset[gi] += g.exposureN;
            (uint256 pairN, uint256 oracleN, uint256 assetN) =
                core.exposureOf(g.pairId, g.oracleConfigId, g.settlementAsset);
            assertEq(pairN, unreleasedByAsset[gi]);
            assertEq(oracleN, unreleasedByAsset[gi]);
            assertEq(assetN, unreleasedByAsset[gi]);
            assertEq(g.released, g.finalized);
        }
    }

    /// INV-007/008/019: a finalized price never changes.
    function invariant_INV_007_priceImmutable() public view {
        for (uint256 gi = 0; gi < groupList.length; ++gi) {
            if (handler.ghostFinalized(groupList[gi])) {
                assertTrue(core.getGroup(groupList[gi]).finalized);
                assertEq(core.getGroup(groupList[gi]).settlementPriceWad, handler.ghostFinalPrice(groupList[gi]));
            }
        }
    }

    /// INV-016/017: no withdrawal ever succeeds above free collateral.
    function invariant_INV_016_noUnsafeWithdrawal() public view {
        assertFalse(handler.ghostUnsafeWithdrawal());
    }

    /// INV-015: account indexes stay within the configured bounds and match positions.
    function invariant_INV_015_boundedIndexes() public view {
        (uint32 perGroup, uint32 maxGroups, uint32 maxSeries) = config.positionLimits();
        for (uint256 a = 0; a < actors.length; ++a) {
            bytes32[] memory gs = core.accountGroups(actors[a]);
            assertLe(gs.length, maxGroups);
            uint256 total;
            for (uint256 gi = 0; gi < gs.length; ++gi) {
                bytes32[] memory ss = core.accountGroupSeries(actors[a], gs[gi]);
                assertLe(ss.length, perGroup);
                assertGt(ss.length, 0);
                total += ss.length;
                for (uint256 k = 0; k < ss.length; ++k) {
                    Position memory p = core.positionOf(actors[a], ss[k]);
                    assertTrue(p.shortQty > 0 || p.lockedQty > 0);
                }
            }
            assertEq(total, core.accountSeriesCount(actors[a]));
            assertLe(total, maxSeries);
        }
    }

    /// INV-012/013: every asset's ledger is independent; cash total equals the sum of account cash.
    function invariant_INV_012_perAssetLedger() public view {
        for (uint256 j = 0; j < assetList.length; ++j) {
            uint256 sum;
            for (uint256 a = 0; a < actors.length; ++a) {
                sum += core.cashBalance(actors[a], address(assetList[j]));
            }
            assertEq(sum, core.totalCash(address(assetList[j])));
        }
        assertEq(core.totalCash(address(usdc)), 0);
    }

    /// INV-005: every long unit is consumed at most once (close, redemption or hedge settlement), and redemptions
    ///          burn exactly what the redeemers submitted.
    function invariant_INV_005_noDoubleLongConsumption() public view {
        for (uint256 i = 0; i < ids.length; ++i) {
            SeriesState memory st = core.getSeriesState(ids[i]);
            assertEq(st.redeemed, handler.ghostRedeemed(ids[i]), "redeemed == submitted");
            assertEq(st.closed + st.redeemed + st.hedgeConsumed + _token(ids[i]).totalSupply(), st.minted);
            uint256 locked;
            for (uint256 a = 0; a < actors.length; ++a) {
                locked += core.positionOf(actors[a], ids[i]).lockedQty;
            }
            assertLe(locked, _token(ids[i]).totalSupply(), "locked units are live supply");
        }
    }

    /// INV-006: no short is settled twice; open short quantity equals the sum of account shorts.
    function invariant_INV_006_noDoubleShortSettlement() public view {
        assertFalse(handler.ghostDoubleShortSettlement(), "second sync moved cash");
        for (uint256 i = 0; i < ids.length; ++i) {
            SeriesState memory st = core.getSeriesState(ids[i]);
            uint256 open;
            for (uint256 a = 0; a < actors.length; ++a) {
                open += core.positionOf(actors[a], ids[i]).shortQty;
            }
            assertEq(open, st.openShortQty, "open shorts == account shorts");
            assertEq(st.closed + st.shortSynced + st.openShortQty, st.minted);
        }
    }

    /// INV-008: every series of a finalized group is paid from the group's single price.
    function invariant_INV_008_groupSharesSettlementPrice() public view {
        for (uint256 i = 0; i < ids.length; ++i) {
            Series memory s = core.getSeries(ids[i]);
            Group memory g = core.getGroup(s.groupId);
            if (!g.finalized) continue;
            assertEq(
                core.seriesPayoffPerUnderlying(ids[i]),
                PayoffMath.phi(s.optionType, s.strikeWad, s.capWad, g.settlementPriceWad)
            );
        }
    }

    /// INV-011: protocol-owned balance is never negative; in the fee-free MVP it is exactly the unsolicited donations.
    function invariant_INV_011_protocolOwnedNonnegative() public view {
        for (uint256 j = 0; j < assetList.length; ++j) {
            address asset = address(assetList[j]);
            uint256 d = FixedPointMath.nativeDenominator(assetList[j].decimals());
            int256 owned = _protocolOwnedN(asset, actors, ids);
            assertGe(owned, 0, "protocol-owned >= 0");
            assertEq(owned, int256(handler.ghostDonated(asset) * d), "only unsolicited surplus, no fees");
        }
    }

    /// INV-017: no successful unlock ever left an account below its requirement.
    function invariant_INV_017_noUnsafeUnlock() public view {
        assertFalse(handler.ghostUnsafeUnlock());
    }

    /// INV-018: no write ever succeeded at or after expiry.
    function invariant_INV_018_noPostExpiryWrite() public view {
        assertFalse(handler.ghostPostExpiryWrite());
    }

    /// INV-019: no finalized group was ever finalized again.
    function invariant_INV_019_noRefinalization() public view {
        assertFalse(handler.ghostRefinalized());
    }

    /// INV-020: after finalization long supply only falls and nothing is minted again.
    function invariant_INV_020_noSupplyResurrection() public view {
        for (uint256 i = 0; i < ids.length; ++i) {
            if (!core.getGroup(_groupOf(ids[i])).finalized) continue;
            assertLe(_token(ids[i]).totalSupply(), handler.ghostSupplyAtFinal(ids[i]));
            assertEq(core.getSeriesState(ids[i]).minted, handler.ghostMintedAtFinal(ids[i]));
        }
    }

    /// Appends per-run action counts so campaign coverage can be audited across runs (not only the last one).
    function afterInvariant() external {
        string[13] memory names = [
            "deposit",
            "write",
            "lock",
            "unlock",
            "close",
            "cancel",
            "withdraw",
            "finalize",
            "sync",
            "redeem",
            "refinalizeAttempt",
            "lateWriteAttempt",
            "resyncAttempt"
        ];
        string memory line;
        for (uint256 i = 0; i < 13; ++i) {
            line = string.concat(line, names[i], "=", vm.toString(handler.ok(bytes32(bytes(names[i])))), " ");
        }
        vm.writeLine("../deployments/.invariant-stats.log", line);
    }

    function invariant_callSummary() public view {
        string[11] memory names =
            ["deposit", "write", "lock", "unlock", "close", "cancel", "withdraw", "finalize", "sync", "redeem", "x"];
        for (uint256 i = 0; i < 10; ++i) {
            console2.log(names[i], handler.ok(bytes32(bytes(names[i]))));
        }
    }
}
