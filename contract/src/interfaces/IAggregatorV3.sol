// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Chainlink AggregatorV3Interface subset used by the settlement adapter.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
