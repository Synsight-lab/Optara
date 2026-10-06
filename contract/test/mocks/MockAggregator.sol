// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Configurable Chainlink proxy mock: phase-encoded round ids, chosen answers/timestamps, reverting
///         (proxy-like) or zero-returning reads for missing rounds, and a fully broken mode.
contract MockAggregator is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool exists;
    }

    uint8 public override decimals;
    mapping(uint80 => Round) public rounds;
    uint80 public latestId;
    uint16 public phase = 1;
    uint64 public aggRound;
    bool public zerosForMissing;
    bool public broken;
    /// If set, getRoundData returns a different round id than requested (malicious/buggy adapter).
    bool public returnWrongId;
    /// If set, only latestRoundData reverts (round history still readable).
    bool public latestBroken;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function id(uint16 phase_, uint64 agg) public pure returns (uint80) {
        return (uint80(phase_) << 64) | uint80(agg);
    }

    /// @notice Append the next round in the current phase and make it latest. Returns its id.
    function pushRound(int256 answer, uint256 updatedAt) external returns (uint80 roundId) {
        aggRound += 1;
        roundId = id(phase, aggRound);
        rounds[roundId] = Round(answer, updatedAt, true);
        latestId = roundId;
    }

    /// @notice Start a new phase (aggregator upgrade); the next pushRound gets aggregator round 1.
    function startNewPhase() external {
        phase += 1;
        aggRound = 0;
    }

    function set(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt, true);
    }

    function setLatest(uint80 roundId) external {
        latestId = roundId;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setZerosForMissing(bool v) external {
        zerosForMissing = v;
    }

    function setBroken(bool v) external {
        broken = v;
    }

    function setLatestBroken(bool v) external {
        latestBroken = v;
    }

    function setReturnWrongId(bool v) external {
        returnWrongId = v;
    }

    function getRoundData(uint80 roundId) external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken");
        Round memory r = rounds[roundId];
        if (!r.exists) {
            if (zerosForMissing) return (roundId, 0, 0, 0, 0);
            revert("No data present");
        }
        uint80 rid = returnWrongId ? roundId + 1 : roundId;
        return (rid, r.answer, r.updatedAt, r.updatedAt, rid);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken && !latestBroken, "broken");
        Round memory r = rounds[latestId];
        if (!r.exists) revert("No data present");
        return (latestId, r.answer, r.updatedAt, r.updatedAt, latestId);
    }
}
