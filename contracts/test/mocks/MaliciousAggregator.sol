// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice A feed that can return data for the WRONG round: a mismatched round id, or an answeredInRound
///         behind what was requested. Used to test the defensive checks in ChainlinkAnchor._tryRound.
///         A well-formed Chainlink aggregator never does this; this mock exists to prove the checks fire.
contract MaliciousAggregator is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool exists;
    }

    uint8 public override decimals;
    mapping(uint80 => Round) public rounds;

    /// If set, every getRoundData call returns this id instead of the one requested.
    bool public forceWrongId;
    uint80 public forcedReturnedId;

    /// If set, every getRoundData call returns this answeredInRound instead of the requested id.
    bool public forceStaleAnsweredInRound;
    uint80 public forcedAnsweredInRound;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function push(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt, true);
    }

    function setForceWrongId(uint80 id) external {
        forcedReturnedId = id;
        forceWrongId = true;
    }

    function setForceStaleAnsweredInRound(uint80 v) external {
        forcedAnsweredInRound = v;
        forceStaleAnsweredInRound = true;
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[roundId];
        require(r.exists, "no data");
        uint80 returnedId = forceWrongId ? forcedReturnedId : roundId;
        uint80 answeredInRound = forceStaleAnsweredInRound ? forcedAnsweredInRound : roundId;
        return (returnedId, r.answer, r.updatedAt, r.updatedAt, answeredInRound);
    }

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("unused");
    }
}
