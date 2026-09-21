// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SeriesInfo, SettlementProof} from "../Types.sol";

interface IOptionSeriesVault {
    function seriesInfo() external view returns (SeriesInfo memory);

    function mintPaused() external view returns (bool);

    function settled() external view returns (bool);

    function mint(uint256 optionAmount, address receiver)
        external
        returns (uint256 collateralAmount, uint256 feeAmount);

    function settle(SettlementProof calldata proof) external returns (uint256 price);
}
