// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkAnchor} from "../src/libraries/ChainlinkAnchor.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {
    OracleInvalid,
    SettlementAnchorRoundUnavailable,
    SettlementAnchorTooStale
} from "../src/Errors.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MaliciousAggregator} from "./mocks/MaliciousAggregator.sol";

/// Exposes ChainlinkAnchor.isImmediateSuccessor directly, since it is a library-internal function usable from
/// any importing contract (the same way OptionMath's functions are).
contract SuccessorHarness {
    function isImmediateSuccessor(IAggregatorV3 feed, uint80 round, uint80 next) external view returns (bool) {
        return ChainlinkAnchor.isImmediateSuccessor(feed, round, next);
    }
}

/// @notice `isImmediateSuccessor` is the single function the whole settlement design leans on: it is what turns
/// "a caller-supplied pair of round ids" into "the ONE unique round in force at expiry, proven". If it accepts a
/// pair it should not, a caller can settle at a wrong, more favorable price. This file tests it directly and
/// exhaustively, on top of the indirect coverage already in ChainlinkAnchor.t.sol (which exercises it only
/// through `priceAtExpiry`).
contract ChainlinkAnchorSuccessorTest is Test {
    SuccessorHarness internal h = new SuccessorHarness();
    MockAggregator internal feed;

    function setUp() public {
        feed = new MockAggregator(8);
    }

    function _id(uint16 phase, uint64 agg) internal pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
    }

    // ================================================================== 1. same-phase branch

    function test_samePhase_exactSuccessorIsAccepted() public view {
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 11)));
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 1), _id(1, 2)));
        assertTrue(h.isImmediateSuccessor(feed, _id(7, 999), _id(7, 1000)));
    }

    /// The exact case named in the concern: round 10 -> round 12 must be rejected, not just round 10 -> 13.
    function test_samePhase_skippedRoundsAreRejected() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 12))); // skip one
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 13))); // skip two
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 1000))); // skip many
    }

    function test_samePhase_reversedOrderIsRejected() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 11), _id(1, 10))); // one step back
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 11), _id(1, 5))); // many steps back
    }

    function test_samePhase_sameRoundTwiceIsRejected() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 10)));
        assertFalse(h.isImmediateSuccessor(feed, _id(0, 0), _id(0, 0))); // including round zero
    }

    /// The same-phase branch never reads the feed at all: prove it by using a feed that reverts on everything.
    function test_samePhase_neverCallsTheFeed() public {
        feed.setBroken(true);
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 11)));
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 12)));
    }

    // ================================================================== 2. phase-boundary branch

    function test_phaseBoundary_correctTransition_lastRoundReverts() public {
        // proxy-style aggregator: querying round+1 (which does not exist) reverts
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 3), _id(2, 1)));
    }

    function test_phaseBoundary_correctTransition_lastRoundReturnsZero() public {
        feed.setZerosForMissing(true);
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 3), _id(2, 1)));
    }

    /// The exact scenario that makes the round+1 probe necessary: the supplied "round" is NOT actually the
    /// last round of its phase — a later round in the SAME phase exists — so this must be rejected even
    /// though the phase/aggregator arithmetic alone would look fine.
    function test_phaseBoundary_rejectedWhenOldPhaseHasMoreRounds() public {
        feed.set(_id(1, 4), 1, 1); // round 4 of phase 1 exists: round 3 was not the last
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 3), _id(2, 1)));
    }

    /// Same case, but the gap is further out: round 4 is missing but round 5 exists. Real Chainlink round ids
    /// never have gaps, so this is a defense-in-depth case rather than an expected real scenario — and the
    /// function correctly still rejects it, because round 4 (round+1) genuinely does not exist.
    function test_phaseBoundary_gapPastRoundPlusOneStillPasses_documentingTheTrustAssumption() public {
        feed.set(_id(1, 5), 1, 1); // round 4 absent, round 5 present: a gap Chainlink should never produce
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 3), _id(2, 1)));
        // this is exactly the trust assumption documented on isImmediateSuccessor: gapless round ids within
        // a phase. It is a property of the feed, not something this function can independently verify.
    }

    function test_phaseBoundary_nextMustBeAggregatorRoundOne() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(2, 2)));
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(2, 0)));
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(2, 999)));
    }

    function test_phaseBoundary_cannotJumpMoreThanOnePhase() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(3, 1)));
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(5, 1)));
    }

    function test_phaseBoundary_cannotGoBackwardsAPhase() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(2, 1), _id(1, 10)));
        assertFalse(h.isImmediateSuccessor(feed, _id(2, 1), _id(1, 1)));
    }

    /// The exact overflow guard: round+1 would overflow uint80 and revert Solidity's own arithmetic check
    /// (uint80(round) + 1 with round already at the type's max). The function must return false, not revert,
    /// for every possible `next`, including one shaped like a valid phase-boundary successor.
    function test_phaseBoundary_maxRoundIdNeverReverts() public view {
        uint80 maxRound = type(uint80).max; // phase 65535, aggregator round 2^64-1
        assertFalse(h.isImmediateSuccessor(feed, maxRound, _id(1, 1))); // arbitrary next
        assertFalse(h.isImmediateSuccessor(feed, maxRound, maxRound)); // same round twice, at the max
        assertFalse(h.isImmediateSuccessor(feed, maxRound, 0));
    }

    /// A large AGGREGATOR round (but not the type max) at a phase boundary must not misbehave either: the
    /// same-phase branch correctly finds no possible successor (aggRound + 1 cannot be represented within the
    /// masked 64 bits, so no aggNext can ever match), all computed in uint256 with no overflow anywhere.
    function test_samePhase_maxAggregatorRoundHasNoValidSuccessor() public view {
        uint80 round = _id(1, type(uint64).max);
        assertFalse(h.isImmediateSuccessor(feed, round, _id(1, 0)));
        assertFalse(h.isImmediateSuccessor(feed, round, _id(1, type(uint64).max)));
    }

    function test_phaseBoundary_brokenFeedDuringTheProbeIsTreatedAsNotExisting() public {
        // documents the known limitation: a feed that reverts on the round+1 query for ANY reason is
        // indistinguishable from one where round+1 genuinely does not exist. This is why feed approval,
        // not this function, is the security-critical control (see oracle.md).
        feed.setBroken(true);
        assertTrue(h.isImmediateSuccessor(feed, _id(1, 3), _id(2, 1)));
    }

    // ================================================================== 3. every other jump is rejected

    function test_everyOtherShapeIsRejected() public view {
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(3, 1))); // phase 1 -> phase 3
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(2, 2))); // phase 1 -> phase 2, wrong agg
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 12))); // same phase, skip
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 11), _id(1, 10))); // reversed, same phase
        assertFalse(h.isImmediateSuccessor(feed, _id(2, 1), _id(1, 10))); // reversed, across phases
        assertFalse(h.isImmediateSuccessor(feed, _id(1, 10), _id(1, 10))); // same round twice
        assertFalse(h.isImmediateSuccessor(feed, 0, 0)); // zero round twice
    }

    /// Zero is not special-cased inside this function: (0, 1) is structurally a same-phase successor. The
    /// outer `priceAtExpiry` is what rejects roundId == 0 (tested in ChainlinkAnchor.t.sol); documented here
    /// so the split of responsibility is explicit and covered on both sides.
    function test_zeroRoundStructurallyLooksLikeASuccessorPair_guardedByTheCaller() public view {
        assertTrue(h.isImmediateSuccessor(feed, 0, _id(0, 1)));
    }

    // ================================================================== exhaustive equivalence fuzz

    /// An independent reference implementation of the same rule, taking "does round+1 exist" as a plain
    /// boolean input instead of querying a feed. If the library and this reference ever disagree, the library
    /// has a bug: this is checked across the full random space of round ids, not just the named cases above.
    function _reference(uint80 round, uint80 next, bool roundPlusOneExists) internal pure returns (bool) {
        if (round == type(uint80).max) return false;
        uint256 phaseRound = uint256(round) >> 64;
        uint256 phaseNext = uint256(next) >> 64;
        uint256 aggRound = uint256(round) & type(uint64).max;
        uint256 aggNext = uint256(next) & type(uint64).max;
        if (phaseNext == phaseRound) return aggNext == aggRound + 1;
        if (phaseNext == phaseRound + 1) return aggNext == 1 && !roundPlusOneExists;
        return false;
    }

    function testFuzz_matchesTheIndependentReference_acrossRandomRoundsAndExistence(
        uint80 round,
        uint80 next,
        bool roundPlusOneExists
    ) public {
        MockAggregator f = new MockAggregator(8);
        if (round != type(uint80).max) {
            if (roundPlusOneExists) {
                f.set(round + 1, 1, 1);
            }
            // else: leave it unset, so getRoundData(round+1) reverts (the proxy-style "does not exist")
        }
        bool expected = _reference(round, next, roundPlusOneExists);
        assertEq(h.isImmediateSuccessor(f, round, next), expected);
    }

    /// Same fuzz, but the "missing" case is the zero-returning style aggregator instead of a revert, so both
    /// ways a feed can say "no data" are covered by the same exhaustive check.
    function testFuzz_matchesTheIndependentReference_zerosReturningStyle(
        uint80 round,
        uint80 next,
        bool roundPlusOneExists
    ) public {
        MockAggregator f = new MockAggregator(8);
        f.setZerosForMissing(true);
        if (round != type(uint80).max && roundPlusOneExists) {
            f.set(round + 1, 1, 1);
        }
        bool expected = _reference(round, next, roundPlusOneExists);
        assertEq(h.isImmediateSuccessor(f, round, next), expected);
    }

    /// Fuzzed but biased into the "interesting" region (small phases and aggregator rounds, so collisions and
    /// boundary conditions are hit often instead of almost always landing in the trivial all-false region that
    /// pure-random uint80 values mostly produce).
    function testFuzz_matchesReference_nearBoundaries(
        uint16 phaseRound,
        uint64 aggRound,
        uint16 phaseNext,
        uint64 aggNext,
        bool roundPlusOneExists
    ) public {
        phaseRound = uint16(bound(phaseRound, 0, 4));
        aggRound = uint64(bound(aggRound, 0, 6));
        phaseNext = uint16(bound(phaseNext, 0, 4));
        aggNext = uint64(bound(aggNext, 0, 6));
        uint80 round = (uint80(phaseRound) << 64) | aggRound;
        uint80 next = (uint80(phaseNext) << 64) | aggNext;

        MockAggregator f = new MockAggregator(8);
        if (roundPlusOneExists) f.set(round + 1, 1, 1);

        assertEq(h.isImmediateSuccessor(f, round, next), _reference(round, next, roundPlusOneExists));
    }

    // ================================================================== through priceAtExpiry: end to end

    /// The whole exhaustive-successor guarantee is only useful if `priceAtExpiry` actually uses it to admit
    /// exactly one round for a given expiry. This repeats that top-level guarantee here as a fuzz test over a
    /// feed that spans a phase boundary, complementing the single-phase version in ChainlinkAnchor.t.sol.
    PriceHarness internal priceHarness = new PriceHarness();

    function testFuzz_priceAtExpiry_exactlyOneRoundQualifies_acrossAPhaseBoundary(uint64 expiryOffset) public {
        MockAggregator f = new MockAggregator(8);
        // phase 1: rounds 1..4 at t = 1000, 2000, 3000, 4000; phase 2: rounds 1..4 at t = 5000..8000
        uint64 base = 1000;
        uint80[8] memory ids;
        uint256 k;
        for (uint64 i = 1; i <= 4; i++) {
            ids[k++] = _id(1, i);
            f.push(_id(1, i), int256(uint256(k)) * 1e8, base * i);
        }
        for (uint64 i = 1; i <= 4; i++) {
            ids[k++] = _id(2, i);
            f.push(_id(2, i), int256(uint256(k)) * 1e8, base * (4 + i));
        }

        uint64 expiry = uint64(bound(expiryOffset, base, base * 8 - 1));

        uint256 passing;
        for (uint256 i; i < ids.length; i++) {
            for (uint256 j; j < ids.length; j++) {
                if (i == j) continue;
                (bool ok,) = _tryPrice(f, ids[i], ids[j], expiry);
                if (ok) passing++;
            }
        }
        assertEq(passing, 1);
    }

    function _tryPrice(MockAggregator f, uint80 r, uint80 n, uint64 expiry) internal view returns (bool ok, uint256 price) {
        try priceHarness.priceAtExpiry(f, 8, expiry, type(uint32).max, r, n) returns (uint256 p) {
            return (true, p);
        } catch {
            return (false, 0);
        }
    }
}

/// Tiny separate harness so `_tryPrice` above can use try/catch on an external call.
contract PriceHarness {
    function priceAtExpiry(IAggregatorV3 feed, uint8 feedDecimals, uint64 expiry, uint32 maxAge, uint80 r, uint80 n)
        external
        view
        returns (uint256)
    {
        return ChainlinkAnchor.priceAtExpiry(feed, feedDecimals, expiry, maxAge, r, n);
    }
}

/// Direct tests for the `_tryRound` hardening: a feed returning data for the WRONG round must never be trusted.
contract ChainlinkAnchorTryRoundHardeningTest is Test {
    PriceHarness internal h = new PriceHarness();
    MaliciousAggregator internal feed;
    uint64 constant EXPIRY = 1_000_000;

    function setUp() public {
        feed = new MaliciousAggregator(8);
        feed.push(1, 100e8, EXPIRY - 100); // in force at expiry
        feed.push(2, 200e8, EXPIRY + 100); // its successor
    }

    function test_reverts_whenReturnedRoundIdDoesNotMatchTheRequestedOne() public {
        feed.setForceWrongId(999);
        // roundId (1) is checked before nextRoundId, and its own lookup already returns the wrong id
        vm.expectRevert(SettlementAnchorRoundUnavailable.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, 3600, 1, 2);
    }

    function test_reverts_whenAnsweredInRoundIsBehindTheRequestedRound() public {
        feed.setForceStaleAnsweredInRound(0);
        vm.expectRevert(SettlementAnchorRoundUnavailable.selector);
        h.priceAtExpiry(feed, 8, EXPIRY, 3600, 1, 2);
    }

    function test_passes_whenRoundIdAndAnsweredInRoundAreConsistent() public view {
        // a well-formed feed: returnedId == requested, answeredInRound == requested, both rounds present.
        // The price is round 1's answer (100), never round 2's (200).
        assertEq(h.priceAtExpiry(feed, 8, EXPIRY, 3600, 1, 2), 100e18);
    }
}
