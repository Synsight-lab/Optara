// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LedgerSeries, Position} from "../libraries/OptaraTypes.sol";

/// @title ISubAccounts
/// @notice The ledger: subaccount owners and operators, cash, signed option balances, per-series totals, bounded
///         per-account position indexes and the per-group participant counter (docs/PROTOCOL_SPEC.md §1,
///         SETTLEMENT.md §5). Writes come only from OptionClearing, LiquidationModule and SettlementWindow.
interface ISubAccounts {
    event SubAccountCreated(uint256 indexed accountId, address indexed owner, address indexed settlementAsset);
    event OperatorSet(uint256 indexed accountId, address indexed operator, bool approved);
    /// @notice Every cash change, so an indexer can rebuild cash from events alone.
    event CashUpdated(uint256 indexed accountId, int256 delta, uint256 cash);
    /// @notice Every balance change, so an indexer can rebuild positions from events alone.
    event BalanceUpdated(uint256 indexed accountId, bytes32 indexed seriesId, int256 delta, int256 balance);
    event ParticipantsUpdated(bytes32 indexed groupId, uint256 participants);
    event PositionLimitsSet(uint256 maxSeriesPerAccount, uint256 maxBucketsPerAccount);
    event MinPositionQtySet(uint256 minPositionQty);

    // ---- users ----
    function createSubAccount(address settlementAsset) external returns (uint256 accountId);
    function setOperator(uint256 accountId, address operator, bool approved) external;

    // ---- writers (OptionClearing, LiquidationModule, SettlementWindow) ----
    function addCash(uint256 accountId, uint256 amount) external;
    function subCash(uint256 accountId, uint256 amount) external;
    /// @return balance The new signed balance.
    function applyDelta(uint256 accountId, bytes32 seriesId, int256 delta) external returns (int256 balance);

    // ---- governance ----
    function setPositionLimits(uint256 maxSeriesPerAccount, uint256 maxBucketsPerAccount) external;
    function setMinPositionQty(uint256 minPositionQty) external;

    // ---- views ----
    function ownerOf(uint256 accountId) external view returns (address);
    function settlementAssetOf(uint256 accountId) external view returns (address);
    function cashOf(uint256 accountId) external view returns (uint256);
    function balanceOf(uint256 accountId, bytes32 seriesId) external view returns (int256);
    function seriesOf(uint256 accountId) external view returns (bytes32[] memory);
    function bucketsOf(uint256 accountId) external view returns (address[] memory underlyings);
    function isAuthorized(uint256 accountId, address caller) external view returns (bool);
    function isOperator(uint256 accountId, address operator) external view returns (bool);
    function participants(bytes32 groupId) external view returns (uint256);
    function seriesCountInGroup(uint256 accountId, bytes32 groupId) external view returns (uint256);
    function totals(bytes32 seriesId) external view returns (uint256 internalLong, uint256 internalShort);
    /// @notice Every open position of the account with its series data (one call for the risk manager).
    function positionsOf(uint256 accountId) external view returns (Position[] memory);
    /// @notice Cached series data; `cached` is false until the series is first written in the ledger.
    function seriesInfo(bytes32 seriesId) external view returns (LedgerSeries memory info, bool cached);
    /// @notice Σ over the product's series of |total internal short| × contract size, in 1e36 units (q × CS).
    function productShortNotional(bytes32 productId) external view returns (uint256);
    function accountCount() external view returns (uint256);
    function maxSeriesPerAccount() external view returns (uint256);
    function maxBucketsPerAccount() external view returns (uint256);
    function minPositionQty() external view returns (uint256);
}
