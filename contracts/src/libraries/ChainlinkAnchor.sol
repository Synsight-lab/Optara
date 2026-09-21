// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {OracleInvalid, SettlementAnchorInvalid, SettlementAnchorTooStale, InvalidDecimals} from "../Errors.sol";

/// @notice Reads the one Chainlink feed named in a series. See simple-workflow/oracle.md.
///
/// SETTLEMENT (`priceAtExpiry`): the price is the answer of the round IN FORCE at expiry, that is the
/// last round with updatedAt <= expiry, proven by its immediate successor having updatedAt > expiry.
/// The caller supplies both round ids. Exactly one round can satisfy every check, so the result is a
/// fixed function of the feed's history and is identical no matter who settles or when.
///
/// REFERENCE (`tryLatestPrice`): the latest price with a now-relative freshness check. Used only by the
/// premium guard. Never used for settlement, and it never reverts.
library ChainlinkAnchor {
    /// @notice Settlement price at `expiry`, normalized to PRICE_SCALE (1e18).
    /// @param feedDecimals the feed's decimals, read once at series creation (at most 18)
    /// @param maxAgeAtExpiry max age of the round in force, measured at `expiry` and never at block.timestamp
    /// @param roundId the round in force at expiry: updatedAt <= expiry
    /// @param nextRoundId its immediate successor: updatedAt > expiry
    function priceAtExpiry(
        IAggregatorV3 feed,
        uint8 feedDecimals,
        uint64 expiry,
        uint32 maxAgeAtExpiry,
        uint80 roundId,
        uint80 nextRoundId
    ) internal view returns (uint256 price) {
        if (roundId == 0 || nextRoundId == roundId) revert SettlementAnchorInvalid();

        // A round that does not exist reverts on a proxy (or reports updatedAt == 0 on some
        // aggregators). Both must become SettlementAnchorInvalid, never an unexplained revert.
        (bool okRound, int256 answer, uint256 updatedAtRound) = _tryRound(feed, roundId);
        (bool okNext,, uint256 updatedAtNext) = _tryRound(feed, nextRoundId);
        if (!okRound || !okNext) revert SettlementAnchorInvalid();

        // The successor must be the IMMEDIATE successor. Without this a caller could pair an older round
        // with a distant post-expiry round and settle at the older, more favorable price.
        if (!_isImmediateSuccessor(feed, roundId, nextRoundId)) revert SettlementAnchorInvalid();

        // In force at expiry, and nothing newer by expiry. Exactly one round satisfies both.
        if (updatedAtRound > expiry) revert SettlementAnchorInvalid();
        if (updatedAtNext <= expiry) revert SettlementAnchorInvalid();

        // The feed was not already dead at expiry. Measured against expiry, never block.timestamp.
        if (expiry - updatedAtRound > maxAgeAtExpiry) revert SettlementAnchorTooStale();

        (bool okPrice, uint256 normalized) = _normalize(answer, feedDecimals);
        if (!okPrice) revert OracleInvalid();
        return normalized;
    }

    /// @notice Latest price for the premium guard. Never reverts.
    /// @return ok false if the feed reverts, the answer is not positive, the timestamp is zero or in the
    ///         future, or the price is older than `maxAge` seconds
    function tryLatestPrice(IAggregatorV3 feed, uint8 feedDecimals, uint32 maxAge)
        internal
        view
        returns (bool ok, uint256 price)
    {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (updatedAt == 0 || updatedAt > block.timestamp) return (false, 0);
            if (block.timestamp - updatedAt > maxAge) return (false, 0);
            return _normalize(answer, feedDecimals);
        } catch {
            return (false, 0);
        }
    }

    /// @dev answer * 10 ** (18 - feedDecimals), or (false, 0) if the answer is not positive or the
    ///      product does not fit in 256 bits.
    function _normalize(int256 answer, uint8 feedDecimals) private pure returns (bool ok, uint256 price) {
        if (feedDecimals > 18) revert InvalidDecimals();
        if (answer <= 0) return (false, 0);
        // casting to uint256 is safe: answer > 0 was checked above, so it is non-negative
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool fits, uint256 result) = Math.tryMul(uint256(answer), uint256(10) ** (18 - feedDecimals));
        if (!fits) return (false, 0);
        return (true, result);
    }

    /// @dev Reads one round. `ok` is false if the call reverts or the round reports updatedAt == 0.
    function _tryRound(IAggregatorV3 feed, uint80 id)
        private
        view
        returns (bool ok, int256 answer, uint256 updatedAt)
    {
        try feed.getRoundData(id) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            if (u == 0) return (false, 0, 0);
            return (true, a, u);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Chainlink proxy round ids are phase-encoded: id = (phaseId << 64) | aggregatorRound.
    ///      `next` is the immediate successor of `round` if either
    ///        same phase:        aggregatorRound(next) == aggregatorRound(round) + 1
    ///        phase boundary:    phase(next) == phase(round) + 1, aggregatorRound(next) == 1, and
    ///                           round + 1 does not exist (so `round` was the last round of its phase).
    ///      The successor is NEVER derived by adding one to the round id and trusting the result.
    function _isImmediateSuccessor(IAggregatorV3 feed, uint80 round, uint80 next) private view returns (bool) {
        uint256 phaseRound = uint256(round) >> 64;
        uint256 phaseNext = uint256(next) >> 64;
        uint256 aggRound = uint256(round) & type(uint64).max;
        uint256 aggNext = uint256(next) & type(uint64).max;

        if (phaseNext == phaseRound) {
            return aggNext == aggRound + 1;
        }

        if (phaseNext == phaseRound + 1) {
            if (aggNext != 1) return false;
            if (round == type(uint80).max) return false;
            // `round` must be the last valid round of its phase: round + 1 must not exist.
            try feed.getRoundData(round + 1) returns (uint80, int256, uint256, uint256 u, uint80) {
                return u == 0;
            } catch {
                return true;
            }
        }

        return false;
    }
}
