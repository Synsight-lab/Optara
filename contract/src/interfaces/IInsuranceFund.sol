// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IInsuranceFund
/// @notice Insurance balance per settlement asset (docs/FEES.md §3, §6; LIQUIDATION.md §5; SETTLEMENT.md §7).
///         Holds its tokens; pays bad-debt coverage only into OptionClearing custody.
interface IInsuranceFund {
    event InsuranceDeposited(address indexed asset, address indexed from, uint256 amount);
    event InsurancePaid(address indexed asset, address indexed caller, uint256 amount);

    /// @notice Anyone: seed or recapitalize. Pulls exactly `amount` (fee-on-transfer tokens revert). Credits no
    ///         account.
    function deposit(address asset, uint256 amount) external;
    /// @notice FeeController or OptionClearing, after transferring `amount` here (fee share, liquidation penalty,
    ///         swept dust). Reverts `TokensNotReceived` if the tokens are not here.
    function notifyDeposit(address asset, uint256 amount) external;
    /// @notice LiquidationModule or SettlementWindow: pay up to `amount` of bad-debt coverage into OptionClearing.
    /// @return paid min(amount, balance).
    function cover(address asset, uint256 amount) external returns (uint256 paid);

    function balanceOf(address asset) external view returns (uint256);
}
