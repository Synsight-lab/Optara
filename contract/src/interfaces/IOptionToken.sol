// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOptionToken is IERC20 {
    function seriesId() external view returns (bytes32);
    function core() external view returns (address);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
