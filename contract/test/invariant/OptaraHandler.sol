// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OptaraCore} from "../../src/core/OptaraCore.sol";
import {IOptionToken} from "../../src/interfaces/IOptionToken.sol";
import {ChainlinkSettlementAdapter} from "../../src/oracle/ChainlinkSettlementAdapter.sol";
import {Series, Group, Position, CloseSource} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice Random-action handler for the stateful invariant campaign (TESTING.md sections 110-114).
/// Every action is a valid user/keeper action or a bounded attempt; reverts are expected and ignored.
contract OptaraHandler is Test {
    OptaraCore public core;
    address[] public actors;
    bytes32[] public seriesIds;
    MockERC20[] public assets;
    mapping(bytes32 => MockAggregator) public feedOf; // group -> feed
    bytes32[] public groups;

    // ghost state
    mapping(bytes32 => uint256) public ghostFinalPrice;
    mapping(bytes32 => bool) public ghostFinalized;
    mapping(address => uint256) public ghostDonated;
    uint256 public callCount;
    bool public ghostUnsafeWithdrawal;
    mapping(bytes32 => uint256) public ok; // successful actions by name
    mapping(bytes32 => uint256) public ghostRedeemed; // series -> quantity burned by successful redemptions
    mapping(bytes32 => uint256) public ghostSupplyAtFinal; // series -> long supply when its group finalized
    mapping(bytes32 => uint256) public ghostMintedAtFinal; // series -> cumulative minted when its group finalized
    bool public ghostUnsafeUnlock; // INV-017
    bool public ghostPostExpiryWrite; // INV-018
    bool public ghostRefinalized; // INV-019
    bool public ghostDoubleShortSettlement; // INV-006

    constructor(
        OptaraCore core_,
        address[] memory actors_,
        bytes32[] memory seriesIds_,
        MockERC20[] memory assets_,
        bytes32[] memory groups_,
        MockAggregator[] memory feeds_
    ) {
        core = core_;
        actors = actors_;
        seriesIds = seriesIds_;
        assets = assets_;
        groups = groups_;
        for (uint256 i = 0; i < groups_.length; ++i) {
            feedOf[groups_[i]] = feeds_[i];
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function seriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function groupCount() external view returns (uint256) {
        return groups.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _series(uint256 s) internal view returns (bytes32) {
        return seriesIds[s % seriesIds.length];
    }

    function _unit(address asset) internal view returns (uint256) {
        return 10 ** uint256(MockERC20(asset).decimals());
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint256 a, uint256 which, uint256 amount) external {
        callCount++;
        address actor = _actor(a);
        MockERC20 asset = assets[which % assets.length];
        amount = bound(amount, 1, 50 * _unit(address(asset)));
        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(core), amount);
        try core.deposit(address(asset), amount) {
            ok["deposit"]++;
        } catch {}
        vm.stopPrank();
    }

    /// Writes, usually after funding exactly the additional collateral the preview asks for; sometimes unfunded
    /// (which must revert unless free collateral already covers it).
    function write(uint256 a, uint256 s, uint256 qty, uint256 r, bool fund) external {
        callCount++;
        address actor = _actor(a);
        bytes32 id = _series(s);
        qty = bound(qty, 1, 3e18);
        address recipient = _actor(r);
        Series memory ser = core.getSeries(id);
        if (block.timestamp >= ser.expiry) return;
        if (fund) {
            uint256 need = core.additionalCollateralForWrite(actor, id, qty);
            if (need > 0) {
                MockERC20(ser.settlementAsset).mint(actor, need);
                vm.startPrank(actor);
                MockERC20(ser.settlementAsset).approve(address(core), need);
                try core.deposit(ser.settlementAsset, need) {} catch {}
                vm.stopPrank();
            }
        }
        vm.prank(actor);
        try core.write(id, qty, recipient) {
            ok["write"]++;
        } catch {}
    }

    function transferLong(uint256 a, uint256 b, uint256 s, uint256 qty) external {
        callCount++;
        address from = _actor(a);
        IOptionToken t = IOptionToken(core.getSeries(_series(s)).optionToken);
        uint256 bal = t.balanceOf(from);
        if (bal == 0) return;
        qty = bound(qty, 1, bal);
        vm.prank(from);
        t.transfer(_actor(b), qty);
    }

    function lock(uint256 a, uint256 s, uint256 qty) external {
        callCount++;
        address actor = _actor(a);
        bytes32 id = _series(s);
        IOptionToken t = IOptionToken(core.getSeries(id).optionToken);
        uint256 bal = t.balanceOf(actor);
        if (bal == 0) return;
        qty = bound(qty, 1, bal);
        vm.startPrank(actor);
        t.approve(address(core), qty);
        try core.lockLong(id, qty) {
            ok["lock"]++;
        } catch {}
        vm.stopPrank();
    }

    function unlock(uint256 a, uint256 s, uint256 qty) external {
        callCount++;
        address actor = _actor(a);
        bytes32 id = _series(s);
        uint256 locked = core.positionOf(actor, id).lockedQty;
        if (locked == 0) return;
        qty = bound(qty, 1, locked);
        vm.prank(actor);
        try core.unlockLong(id, qty, actor) {
            ok["unlock"]++;
            // INV-017: a successful unlock never leaves the account below its requirement
            if (core.deficit(actor, core.getSeries(id).settlementAsset) != 0) ghostUnsafeUnlock = true;
        } catch {}
    }

    function close(uint256 a, uint256 s, uint256 qty, bool fromLocked) external {
        callCount++;
        address actor = _actor(a);
        bytes32 id = _series(s);
        Position memory p = core.positionOf(actor, id);
        if (p.shortQty == 0) return;
        qty = bound(qty, 1, p.shortQty);
        CloseSource src = fromLocked ? CloseSource.LOCKED : CloseSource.EXTERNAL;
        vm.startPrank(actor);
        try core.closeShort(id, qty, src) {
            ok["close"]++;
        } catch {}
        try core.cancelUnfinalizedShort(id, qty, src) {
            ok["cancel"]++;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 a, uint256 which, uint256 amount) external {
        callCount++;
        address actor = _actor(a);
        address asset = address(assets[which % assets.length]);
        uint256 free = core.freeCollateral(actor, asset);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(actor);
        try core.withdraw(asset, amount, actor) {
            ok["withdraw"]++;
        } catch {}
    }

    function warp(uint256 dt) external {
        callCount++;
        dt = bound(dt, 1 hours, 2 days);
        vm.warp(block.timestamp + dt);
    }

    /// Finalizes a group with a fresh in-force round at `price`, when timing allows.
    function finalize(uint256 g, uint256 priceSeed) external {
        callCount++;
        bytes32 gid = groups[g % groups.length];
        Group memory grp = core.getGroup(gid);
        if (grp.finalized || block.timestamp < uint256(grp.expiry) + 5 minutes) return;
        MockAggregator feed = feedOf[gid];
        uint256 priceWad = bound(priceSeed, 0, 40e18);
        // The historical round in force at expiry and its successor (a keeper finds these on chain).
        int256 answer = int256(priceWad / 10 ** (18 - uint256(feed.decimals()))) + 1;
        uint80 r = feed.pushRound(answer, grp.expiry - 1);
        uint80 n = feed.pushRound(answer, grp.expiry + 1);
        ChainlinkSettlementAdapter.RoundProof[] memory p = new ChainlinkSettlementAdapter.RoundProof[](1);
        p[0] = ChainlinkSettlementAdapter.RoundProof(r, n);
        bytes memory data =
            abi.encode(ChainlinkSettlementAdapter.SettlementData(0, p, new ChainlinkSettlementAdapter.RoundProof[](0)));
        try core.finalizeRiskGroup(gid, data) returns (uint256 price) {
            ghostFinalized[gid] = true;
            ghostFinalPrice[gid] = price;
            ok["finalize"]++;
            for (uint256 i = 0; i < seriesIds.length; ++i) {
                Series memory s = core.getSeries(seriesIds[i]);
                if (s.groupId != gid) continue;
                ghostSupplyAtFinal[seriesIds[i]] = IOptionToken(s.optionToken).totalSupply();
                ghostMintedAtFinal[seriesIds[i]] = core.getSeriesState(seriesIds[i]).minted;
            }
        } catch {}
    }

    /// INV-019: attempt to finalize an already-finalized group again with a different, well-formed proof.
    function refinalize(uint256 g, uint256 priceSeed) external {
        callCount++;
        bytes32 gid = groups[g % groups.length];
        Group memory grp = core.getGroup(gid);
        if (!grp.finalized) return;
        MockAggregator feed = feedOf[gid];
        int256 answer = int256(bound(priceSeed, 1, 40e8));
        uint80 r = feed.pushRound(answer, block.timestamp);
        ChainlinkSettlementAdapter.RoundProof[] memory p = new ChainlinkSettlementAdapter.RoundProof[](1);
        p[0] = ChainlinkSettlementAdapter.RoundProof(r, 0);
        bytes memory data =
            abi.encode(ChainlinkSettlementAdapter.SettlementData(0, p, new ChainlinkSettlementAdapter.RoundProof[](0)));
        ok["refinalizeAttempt"]++;
        try core.finalizeRiskGroup(gid, data) {
            ghostRefinalized = true;
        } catch {}
    }

    /// INV-018: attempt a write on an expired series (funded, so only the expiry rule can stop it).
    function writeAfterExpiry(uint256 a, uint256 s, uint256 qty) external {
        callCount++;
        address actor = _actor(a);
        bytes32 id = _series(s);
        Series memory ser = core.getSeries(id);
        if (block.timestamp < ser.expiry) return;
        qty = bound(qty, 1, 1e18);
        MockERC20(ser.settlementAsset).mint(actor, 10 * _unit(ser.settlementAsset));
        vm.startPrank(actor);
        MockERC20(ser.settlementAsset).approve(address(core), type(uint256).max);
        try core.deposit(ser.settlementAsset, 10 * _unit(ser.settlementAsset)) {} catch {}
        ok["lateWriteAttempt"]++;
        try core.write(id, qty, actor) {
            ghostPostExpiryWrite = true;
        } catch {}
        vm.stopPrank();
    }

    function sync(uint256 a, uint256 g) external {
        callCount++;
        address actor = _actor(a);
        bytes32 gid = groups[g % groups.length];
        try core.syncRiskGroup(actor, gid) returns (bool done) {
            if (done) {
                ok["sync"]++;
                // INV-006: an immediate second synchronization is a no-op that moves no cash
                address asset = core.getGroup(gid).settlementAsset;
                uint256 cash = core.cashBalance(actor, asset);
                ok["resyncAttempt"]++;
                bool again = core.syncRiskGroup(actor, gid);
                if (again || core.cashBalance(actor, asset) != cash) ghostDoubleShortSettlement = true;
            }
        } catch {}
    }

    function redeem(uint256 a, uint256 s, uint256 qty) external {
        callCount++;
        address actor = _actor(a);
        bytes32 id = _series(s);
        IOptionToken t = IOptionToken(core.getSeries(id).optionToken);
        uint256 bal = t.balanceOf(actor);
        if (bal == 0) return;
        qty = bound(qty, 1, bal);
        vm.prank(actor);
        try core.redeem(id, qty, actor) {
            ok["redeem"]++;
            ghostRedeemed[id] += qty;
        } catch {}
    }

    /// Direct donation: surplus only (DON-001/002).
    function donate(uint256 which, uint256 amount) external {
        callCount++;
        MockERC20 asset = assets[which % assets.length];
        amount = bound(amount, 1, 5 * _unit(address(asset)));
        asset.mint(address(core), amount);
        ghostDonated[address(asset)] += amount;
    }

    /// Attempt an unsafe withdrawal; it must never succeed beyond free collateral.
    function withdrawTooMuch(uint256 a, uint256 which) external {
        callCount++;
        address actor = _actor(a);
        address asset = address(assets[which % assets.length]);
        uint256 free = core.freeCollateral(actor, asset);
        uint256 cash = core.cashBalance(actor, asset);
        if (cash == 0) return;
        vm.prank(actor);
        try core.withdraw(asset, free + 1, actor) {
            ghostUnsafeWithdrawal = true; // must never happen (INV-016)
        } catch {}
    }
}
