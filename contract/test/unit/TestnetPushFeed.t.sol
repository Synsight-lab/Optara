// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettlementOracleFixture} from "../utils/SettlementOracleFixture.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {TestnetPushFeed} from "../../src/testnet/TestnetPushFeed.sol";

/// @notice The testnet settlement feed: pusher-only, append-only rounds in Chainlink's id encoding, accepted by
///         SettlementOracle exactly like a Chainlink feed (in-force round and immediate-successor proofs).
contract TestnetPushFeedTest is SettlementOracleFixture {
    TestnetPushFeed internal feed;
    address internal keeper = makeAddr("keeper");
    address internal feedOwner = makeAddr("feedOwner");
    uint80 internal constant P1 = uint80(1) << 64;

    function setUp() public {
        _deploySettlementOracle();
        feed = new TestnetPushFeed(8, "MON / USD (testnet push)", feedOwner, keeper);
    }

    function test_onlyPusherPushesPositiveAnswersOncePerSecond() public {
        vm.expectRevert(TestnetPushFeed.NotPusher.selector);
        feed.push(1e8);
        vm.startPrank(keeper);
        vm.expectRevert(TestnetPushFeed.BadAnswer.selector);
        feed.push(0);
        assertEq(feed.push(2e8), P1 | 1);
        vm.expectRevert(TestnetPushFeed.BadAnswer.selector); // same second
        feed.push(3e8);
        vm.warp(block.timestamp + 1);
        assertEq(feed.push(3e8), P1 | 2);
        vm.stopPrank();
    }

    function test_roundsReadLikeChainlink() public {
        vm.expectRevert(TestnetPushFeed.NoDataPresent.selector);
        feed.latestRoundData();
        vm.prank(keeper);
        feed.push(2e8);
        uint256 t1 = block.timestamp;
        vm.warp(t1 + 60);
        vm.prank(keeper);
        feed.push(3e8);

        (uint80 id, int256 a, uint256 s, uint256 u, uint80 ans) = feed.latestRoundData();
        assertEq(id, P1 | 2);
        assertEq(a, 3e8);
        assertEq(s, t1 + 60);
        assertEq(u, t1 + 60);
        assertEq(ans, id);
        (, a,, u,) = feed.getRoundData(P1 | 1);
        assertEq(a, 2e8);
        assertEq(u, t1);
        vm.expectRevert(TestnetPushFeed.NoDataPresent.selector);
        feed.getRoundData(P1 | 3);
        vm.expectRevert(TestnetPushFeed.NoDataPresent.selector);
        feed.getRoundData(2); // phase 0
        assertTrue(so.isImmediateSuccessor(address(feed), P1 | 1, P1 | 2));
    }

    function test_ownerRotatesPusher() public {
        address next = makeAddr("next");
        vm.expectRevert(TestnetPushFeed.NotOwner.selector);
        feed.setPusher(next);
        vm.prank(feedOwner);
        feed.setPusher(next);
        vm.prank(keeper);
        vm.expectRevert(TestnetPushFeed.NotPusher.selector);
        feed.push(1e8);
        vm.prank(next);
        feed.push(1e8);
    }

    /// The settlement oracle settles from it: the round in force at expiry, proved by its immediate successor.
    function test_settlementOracleVerifiesThroughIt() public {
        vm.prank(keeper);
        feed.push(1e8); // live at registration
        bytes32 id = _register(
            _cfg(
                ISettlementOracle.FeedSource({
                    kind: ISettlementOracle.FeedKind.DIRECT,
                    feed: address(feed),
                    feedDecimals: 8,
                    quoteFeed: address(0),
                    quoteFeedDecimals: 0
                }),
                _none(),
                0
            )
        );
        vm.warp(EXPIRY - 120);
        vm.prank(keeper);
        uint80 inForce = feed.push(0.0261e8);
        vm.warp(EXPIRY + 180);
        vm.prank(keeper);
        uint80 next = feed.push(0.0263e8);
        vm.warp(EXPIRY + 600);
        (uint256 price, uint64 t,) = so.verify(id, EXPIRY, _data(0, _proof(inForce, next), new ISettlementOracle.RoundProof[](0)));
        assertEq(price, 0.0261e18);
        assertEq(t, EXPIRY - 120);
    }
}
