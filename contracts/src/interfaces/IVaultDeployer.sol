// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SeriesConfig, FeeConfig} from "../Types.sol";

interface IVaultDeployer {
    function factory() external view returns (address);

    function bind() external;

    function deploy(bytes32 seriesId, SeriesConfig calldata c, FeeConfig calldata fees) external returns (address);
}
