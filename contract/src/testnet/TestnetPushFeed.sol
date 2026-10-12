// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title TestnetPushFeed
/// @notice TESTNET ONLY. A Chainlink-compatible price feed whose rounds are pushed by one authorised account (the
///         keeper, relaying Pyth). It stands in where testnet Chainlink has no feed (MON/USD) or updates too rarely
///         for short expiries. Settlement through it trusts the pusher, so it must never back a mainnet listing.
/// @dev Round ids use Chainlink's encoding, (phase << 64) | aggregatorRound, with phase 1 and aggregator rounds 1, 2,
///      3, …, so SettlementOracle's immediate-successor proofs work unchanged. Rounds are append-only and their
///      timestamps strictly increase.
contract TestnetPushFeed is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    uint80 internal constant PHASE = uint80(1) << 64;

    uint8 public immutable override decimals;
    string public description;
    address public owner;
    address public pusher;
    uint64 public latestAggregatorRound;
    mapping(uint64 => Round) internal _rounds;

    event PusherSet(address indexed pusher);
    event OwnerSet(address indexed owner);
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    error NotOwner();
    error NotPusher();
    error BadAnswer();
    error NoDataPresent();

    constructor(uint8 decimals_, string memory description_, address owner_, address pusher_) {
        decimals = decimals_;
        description = description_;
        owner = owner_;
        pusher = pusher_;
        emit OwnerSet(owner_);
        emit PusherSet(pusher_);
    }

    function setPusher(address pusher_) external {
        if (msg.sender != owner) revert NotOwner();
        pusher = pusher_;
        emit PusherSet(pusher_);
    }

    function setOwner(address owner_) external {
        if (msg.sender != owner) revert NotOwner();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    /// @notice Appends a round at the current block time. At most one round per second.
    function push(int256 answer) external returns (uint80 roundId) {
        if (msg.sender != pusher) revert NotPusher();
        if (answer <= 0) revert BadAnswer();
        uint64 n = latestAggregatorRound;
        if (n != 0 && _rounds[n].updatedAt >= block.timestamp) revert BadAnswer();
        n += 1;
        _rounds[n] = Round(answer, uint64(block.timestamp));
        latestAggregatorRound = n;
        roundId = PHASE | uint80(n);
        emit AnswerUpdated(answer, roundId, block.timestamp);
    }

    function getRoundData(uint80 roundId) external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId & ~uint80(type(uint64).max) != PHASE) revert NoDataPresent();
        uint64 n = uint64(roundId);
        if (n == 0 || n > latestAggregatorRound) revert NoDataPresent();
        Round memory r = _rounds[n];
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        uint64 n = latestAggregatorRound;
        if (n == 0) revert NoDataPresent();
        Round memory r = _rounds[n];
        uint80 id = PHASE | uint80(n);
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}
