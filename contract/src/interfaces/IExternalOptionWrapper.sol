// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IExternalOptionWrapper
/// @notice ERC-20 long claim on one series (docs/OPTION_SPEC.md §7). 18 decimals, EIP-2612 permit, no hooks, no
///         pausing, not upgradeable. Integrations must identify the series by `seriesId()`, never by name or symbol.
interface IExternalOptionWrapper is IERC20Metadata, IERC20Permit {
    function seriesId() external view returns (bytes32);
    /// @notice The only address that may mint (OptionClearing).
    function minter() external view returns (address);
    /// @notice True for OptionClearing, SettlementWindow and LiquidationModule.
    function isBurner(address account) external view returns (bool);

    /// @dev Minter only.
    function mint(address to, uint256 amount) external;
    /// @dev Burners only. Burners burn only from the account whose own call asked for it.
    function burn(address from, uint256 amount) external;
}
