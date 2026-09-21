// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice A configurable Chainlink feed for tests. Supports several rounds with chosen answer and
///         updatedAt, chosen decimals, phase-encoded round ids, and reverting (or zero-returning) reads
///         for rounds that do not exist.
contract MockAggregator is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool exists;
    }

    uint8 public override decimals;
    mapping(uint80 => Round) public rounds;
    uint80 public latestId;

    /// If true, a missing round returns zeros (like an old aggregator) instead of reverting (like a proxy).
    bool public zerosForMissing;
    /// If true, every read reverts.
    bool public broken;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    /// (phase << 64) | aggregatorRound
    function id(uint16 phase, uint64 agg) public pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
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

    /// Adds a round and makes it the latest.
    function push(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt, true);
        latestId = roundId;
    }

    /// Adds a round WITHOUT changing which round is latest.
    function set(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt, true);
    }

    function setLatest(uint80 roundId) external {
        latestId = roundId;
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(!broken, "broken");
        Round memory r = rounds[roundId];
        if (!r.exists) {
            if (zerosForMissing) return (roundId, 0, 0, 0, 0);
            revert("No data present");
        }
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken");
        Round memory r = rounds[latestId];
        if (!r.exists) revert("No data present");
        return (latestId, r.answer, r.updatedAt, r.updatedAt, latestId);
    }
}
