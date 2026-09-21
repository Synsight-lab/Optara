// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkAnchor} from "../src/libraries/ChainlinkAnchor.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {OracleInvalid, SettlementAnchorInvalid, SettlementAnchorTooStale, InvalidDecimals} from "../src/Errors.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// Exposes the internal library so reverts can be asserted.
contract AnchorHarness {
    function priceAtExpiry(
        IAggregatorV3 feed,
        uint8 feedDecimals,
        uint64 expiry,
        uint32 maxAge,
        uint80 roundId,
        uint80 nextRoundId
    ) external view returns (uint256) {
        return ChainlinkAnchor.priceAtExpiry(feed, feedDecimals, expiry, maxAge, roundId, nextRoundId);
    }

    function tryLatestPrice(IAggregatorV3 feed, uint8 feedDecimals, uint32 maxAge)
        external
        view
        returns (bool, uint256)
    {
        return ChainlinkAnchor.tryLatestPrice(feed, feedDecimals, maxAge);
    }
}

contract ChainlinkAnchorTest is Test {
    AnchorHarness h = new AnchorHarness();
    MockAggregator feed;

    uint64 constant EXPIRY = 1_000_000;
    uint32 constant MAX_AGE = 3600;

    // phase 1 rounds 1..5 around expiry (8 decimals)
    //   1: t = EXPIRY - 3000   answer 100
    //   2: t = EXPIRY - 2000   answer 110
    //   3: t = EXPIRY - 500    answer 120   <- in force at expiry
    //   4: t = EXPIRY + 700    answer 130   <- first after expiry
    //   5: t = EXPIRY + 1500   answer 140
    uint80 r1;
    uint80 r2;
    uint80 r3;
    uint80 r4;
    uint80 r5;

    /// (phase << 64) | aggregatorRound. Internal on purpose: an external call here would consume a
    /// pending vm.expectRevert before the call under test.
    function _id(uint16 phase, uint64 agg) internal pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
    }

    function setUp() public {
        vm.warp(EXPIRY + 5000);
        feed = new MockAggregator(8);
        r1 = _id(1, 1);
        r2 = _id(1, 2);
        r3 = _id(1, 3);
        r4 = _id(1, 4);
        r5 = _id(1, 5);
        feed.push(r1, 100e8, EXPIRY - 3000);
        feed.push(r2, 110e8, EXPIRY - 2000);
        feed.push(r3, 120e8, EXPIRY - 500);
        feed.push(r4, 130e8, EXPIRY + 700);
        feed.push(r5, 140e8, EXPIRY + 1500);
    }

    function _price(uint80 roundId, uint80 nextId) internal view returns (uint256) {
        return h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, roundId, nextId);
    }

    // ------------------------------------------------------------ happy path

    function test_price_isTheRoundInForce_notTheSuccessor() public view {
        // round 3 is in force at expiry; its answer (120), never the successor's (130)
        assertEq(_price(r3, r4), 120e18);
    }

    function test_price_isIdenticalNoMatterWhenItIsCalled() public {
        uint256 first = _price(r3, r4);
        vm.warp(block.timestamp + 90 days);
        assertEq(_price(r3, r4), first);
        // even if the feed moves a lot afterward
        feed.push(_id(1, 6), 999e8, block.timestamp);
        assertEq(_price(r3, r4), first);
    }

    function test_price_ageIsMeasuredAtExpiryNotAtBlockTimestamp() public {
        // round 3 is 500 seconds old at expiry, well inside MAX_AGE. A very late call must not change that.
        vm.warp(block.timestamp + 365 days);
        assertEq(_price(r3, r4), 120e18);
    }

    function test_price_normalizesFeedDecimals() public {
        MockAggregator f18 = new MockAggregator(18);
        f18.push(_id(1, 1), 5.25e18, EXPIRY - 10);
        f18.push(_id(1, 2), 6e18, EXPIRY + 10);
        assertEq(h.priceAtExpiry(f18, 18, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2)), 5.25e18);

        MockAggregator f8 = new MockAggregator(8);
        f8.push(_id(1, 1), 5.25e8, EXPIRY - 10);
        f8.push(_id(1, 2), 6e8, EXPIRY + 10);
        assertEq(h.priceAtExpiry(f8, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2)), 5.25e18);

        MockAggregator f0 = new MockAggregator(0);
        f0.push(_id(1, 1), 5, EXPIRY - 10);
        f0.push(_id(1, 2), 6, EXPIRY + 10);
        assertEq(h.priceAtExpiry(f0, 0, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2)), 5e18);
    }

    function test_price_aRoundPublishedExactlyAtExpiryIsInForce() public {
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 100e8, EXPIRY - 100);
        f.push(_id(1, 2), 111e8, EXPIRY); // updatedAt == expiry: in force at expiry
        f.push(_id(1, 3), 122e8, EXPIRY + 1);
        assertEq(h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 2), _id(1, 3)), 111e18);
        // and the round before it is NOT the one in force: its successor is not after expiry
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2));
    }

    // ------------------------------------------------------------ forged anchors

    function test_reverts_roundNamedAsInForceIsAfterExpiry() public {
        // (4, 5): round 4 is after expiry, so it is not in force at expiry
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r4, r5);
    }

    function test_reverts_earlierRoundWhoseRealSuccessorIsBeforeExpiry() public {
        // (2, 3): round 3 is at or before expiry, so round 2 is not the last round in force
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r2, r3);
    }

    function test_reverts_successorSkipsARound() public {
        // (3, 5): 5 is after expiry but is not the immediate successor of 3
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r3, r5);
        // an older, more favorable round paired with a distant post-expiry round is rejected too
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r1, r4);
    }

    function test_reverts_reversedOrder() public {
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r4, r3);
    }

    function test_reverts_sameRoundTwice() public {
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r3, r3);
    }

    function test_reverts_zeroRoundId() public {
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, 0, r1);
    }

    function test_reverts_nonexistentRounds_proxyStyle() public {
        // reads revert on a missing round: must become SettlementAnchorInvalid
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r3, _id(1, 99));
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, _id(1, 98), _id(1, 99));
    }

    function test_reverts_nonexistentRounds_zeroReturningAggregator() public {
        feed.setZerosForMissing(true);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r3, _id(1, 99));
    }

    function test_reverts_successorDoesNotExistYet() public {
        // a feed that has not yet published after expiry cannot be settled
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 100e8, EXPIRY - 10);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2));
        // ... and becomes settleable, at the same price, once the successor is published
        f.push(_id(1, 2), 200e8, EXPIRY + 400);
        assertEq(h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2)), 100e18);
    }

    function test_reverts_brokenFeed() public {
        feed.setBroken(true);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, MAX_AGE, r3, r4);
    }

    // ------------------------------------------------------------ age at expiry

    function test_reverts_roundInForceWasAlreadyOldAtExpiry() public {
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 100e8, EXPIRY - MAX_AGE - 1); // one second too old at expiry
        f.push(_id(1, 2), 200e8, EXPIRY + 5);
        vm.expectRevert(SettlementAnchorTooStale.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2));
    }

    function test_ageBoundary_exactlyMaxAgeIsAccepted() public {
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 100e8, EXPIRY - MAX_AGE); // exactly MAX_AGE old at expiry
        f.push(_id(1, 2), 200e8, EXPIRY + 5);
        assertEq(h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2)), 100e18);
    }

    /// A slow but healthy feed (an hour between updates) still settles once the successor exists.
    function test_slowHealthyFeedSettles() public {
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 100e8, EXPIRY - 3000); // 50 minutes before expiry
        f.push(_id(1, 2), 130e8, EXPIRY + 3500); // next update almost an hour after expiry
        assertEq(h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2)), 100e18);
    }

    // ------------------------------------------------------------ bad answers

    function test_reverts_answerZeroOrNegative() public {
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 0, EXPIRY - 10);
        f.push(_id(1, 2), 200e8, EXPIRY + 5);
        vm.expectRevert(OracleInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2));

        MockAggregator g = new MockAggregator(8);
        g.push(_id(1, 1), -5, EXPIRY - 10);
        g.push(_id(1, 2), 200e8, EXPIRY + 5);
        vm.expectRevert(OracleInvalid.selector);
        h.priceAtExpiry(g, 8, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2));
    }

    function test_reverts_answerTooLargeToNormalize() public {
        MockAggregator f = new MockAggregator(0);
        f.push(_id(1, 1), type(int256).max, EXPIRY - 10);
        f.push(_id(1, 2), 1, EXPIRY + 5);
        vm.expectRevert(OracleInvalid.selector);
        h.priceAtExpiry(f, 0, EXPIRY, MAX_AGE, _id(1, 1), _id(1, 2));
    }

    function test_reverts_feedDecimalsAbove18() public {
        vm.expectRevert(InvalidDecimals.selector);
        h.priceAtExpiry(feed, 19, EXPIRY, MAX_AGE, r3, r4);
    }

    // ------------------------------------------------------------ phase boundaries

    /// phase 1: aggregator rounds 1..3, phase 2: aggregator rounds 1..2
    function _phaseFeed() internal returns (MockAggregator f) {
        f = new MockAggregator(8);
        f.push(_id(1, 1), 100e8, EXPIRY - 3000);
        f.push(_id(1, 2), 110e8, EXPIRY - 2000);
        f.push(_id(1, 3), 120e8, EXPIRY - 500); // last round of phase 1, in force at expiry
        f.push(_id(2, 1), 130e8, EXPIRY + 700); // first round of phase 2
        f.push(_id(2, 2), 140e8, EXPIRY + 1500);
    }

    function test_phaseBoundary_correctSuccessorSucceeds() public {
        MockAggregator f = _phaseFeed();
        assertEq(h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(2, 1)), 120e18);
    }

    function test_phaseBoundary_derivingSuccessorAsRoundPlusOneFails() public {
        MockAggregator f = _phaseFeed();
        // round + 1 = (1, 4) does not exist
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(1, 4));
    }

    function test_phaseBoundary_skippingTheLastRoundOfThePhaseFails() public {
        MockAggregator f = _phaseFeed();
        // (1,2) -> (2,1) skips round (1,3)
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 2), _id(2, 1));
    }

    function test_phaseBoundary_failsIfPhaseOneHasAnotherRound() public {
        MockAggregator f = _phaseFeed();
        // phase 1 actually continues to round 4 (and it is after expiry), so (1,3) is not its last round
        f.set(_id(1, 4), 125e8, EXPIRY + 100);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(2, 1));
    }

    function test_phaseBoundary_nextRoundMustBeFirstOfNewPhase() public {
        MockAggregator f = _phaseFeed();
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(2, 2));
    }

    function test_phaseBoundary_cannotJumpTwoPhases() public {
        MockAggregator f = _phaseFeed();
        f.push(_id(3, 1), 150e8, EXPIRY + 1600);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(3, 1));
    }

    function test_phaseBoundary_zerosReturningAggregatorStillWorks() public {
        MockAggregator f = _phaseFeed();
        f.setZerosForMissing(true);
        assertEq(h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(2, 1)), 120e18);
    }

    function test_phaseBoundary_roundInForceIsInTheNewPhase() public {
        MockAggregator f = _phaseFeed();
        // expiry falls after (2,1) and before (2,2): the round in force is (2,1)
        uint64 expiry2 = EXPIRY + 1000;
        assertEq(h.priceAtExpiry(f, 8, expiry2, MAX_AGE, _id(2, 1), _id(2, 2)), 130e18);
    }

    function test_sameIdDifferentPhaseIsNotSuccessor() public {
        MockAggregator f = _phaseFeed();
        f.push(_id(2, 3), 145e8, EXPIRY + 1600);
        vm.expectRevert(SettlementAnchorInvalid.selector);
        h.priceAtExpiry(f, 8, EXPIRY, MAX_AGE, _id(1, 3), _id(2, 3));
    }

    // ------------------------------------------------------------ fuzz: exactly one round qualifies

    /// For a feed with strictly increasing update times, exactly one (round, successor) pair passes
    /// for any expiry that lies after the first round.
    function testFuzz_exactlyOneRoundQualifies(uint64 expiryOffset) public {
        MockAggregator f = new MockAggregator(8);
        uint256 n = 8;
        uint64 base = 10_000;
        for (uint64 i = 1; i <= n; i++) {
            f.push(_id(1, i), int256(uint256(i)) * 1e8, base + i * 1000);
        }
        // expiry somewhere from the first round's time to just past the last round
        uint64 expiry = base + 1000 + uint64(bound(expiryOffset, 0, (n - 1) * 1000 - 1));

        uint256 passing;
        uint256 answerOfPassing;
        for (uint64 i = 1; i < n; i++) {
            try h.priceAtExpiry(f, 8, expiry, type(uint32).max, _id(1, i), _id(1, i + 1)) returns (uint256 p) {
                passing++;
                answerOfPassing = p;
            } catch {}
        }
        assertEq(passing, 1);

        // and it is the last round with updatedAt <= expiry
        uint256 expectedIndex = (expiry - base) / 1000; // round i has time base + i*1000
        assertEq(answerOfPassing, expectedIndex * 1e18);
    }

    // ------------------------------------------------------------ reference read

    function test_latest_ok() public {
        feed.setLatest(r5);
        vm.warp(EXPIRY + 1600); // 100 seconds after round 5
        (bool ok, uint256 price) = h.tryLatestPrice(feed, 8, 3600);
        assertTrue(ok);
        assertEq(price, 140e18);
    }

    function test_latest_staleIsRejected() public {
        vm.warp(EXPIRY + 1500 + 3601);
        (bool ok, uint256 price) = h.tryLatestPrice(feed, 8, 3600);
        assertFalse(ok);
        assertEq(price, 0);
        vm.warp(EXPIRY + 1500 + 3600); // exactly maxAge is accepted
        (ok, price) = h.tryLatestPrice(feed, 8, 3600);
        assertTrue(ok);
    }

    function test_latest_neverReverts() public {
        // broken feed
        feed.setBroken(true);
        (bool ok,) = h.tryLatestPrice(feed, 8, 3600);
        assertFalse(ok);
        feed.setBroken(false);

        // non-positive answers
        MockAggregator f = new MockAggregator(8);
        f.push(_id(1, 1), 0, block.timestamp);
        (ok,) = h.tryLatestPrice(f, 8, 3600);
        assertFalse(ok);
        f.push(_id(1, 2), -1, block.timestamp);
        (ok,) = h.tryLatestPrice(f, 8, 3600);
        assertFalse(ok);

        // timestamp zero
        MockAggregator g = new MockAggregator(8);
        g.push(_id(1, 1), 100e8, 0);
        (ok,) = h.tryLatestPrice(g, 8, 3600);
        assertFalse(ok);

        // timestamp in the future
        MockAggregator k = new MockAggregator(8);
        k.push(_id(1, 1), 100e8, block.timestamp + 1);
        (ok,) = h.tryLatestPrice(k, 8, 3600);
        assertFalse(ok);

        // answer too large to normalize
        MockAggregator m = new MockAggregator(0);
        m.push(_id(1, 1), type(int256).max, block.timestamp);
        (ok,) = h.tryLatestPrice(m, 0, 3600);
        assertFalse(ok);

        // no rounds at all
        MockAggregator e = new MockAggregator(8);
        (ok,) = h.tryLatestPrice(e, 8, 3600);
        assertFalse(ok);
    }
}
