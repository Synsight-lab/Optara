// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProductConfig, Product, SeriesParams, SeriesTerms, Group} from "../libraries/OptaraTypes.sol";

/// @title IOptionSeriesRegistry
/// @notice Settlement assets, products and write-once series terms (docs/OPTION_SPEC.md, PROTOCOL_SPEC.md §2).
interface IOptionSeriesRegistry {
    event SettlementAssetApproved(address indexed asset, bool approved, uint8 decimals);
    event ProductApproved(
        bytes32 indexed productId, address indexed underlying, address indexed settlementAsset, ProductConfig config
    );
    event ProductEnabled(bytes32 indexed productId, bool enabled);
    event GroupCreated(
        bytes32 indexed groupId,
        address indexed underlying,
        address indexed settlementAsset,
        uint64 expiry,
        bytes32 settlementOracleConfigId
    );
    event SeriesCreated(bytes32 indexed seriesId, bytes32 indexed groupId, address indexed wrapper, SeriesTerms terms);

    // ---- admin ----
    function setSettlementAssetApproved(address asset, bool approved) external;
    function approveProduct(address underlying, address settlementAsset, ProductConfig calldata config)
        external
        returns (bytes32 productId);
    function setProductEnabled(bytes32 productId, bool enabled) external;

    // ---- series ----
    function createSeries(SeriesParams calldata params) external returns (bytes32 seriesId);

    // ---- views ----
    function getSeries(bytes32 seriesId) external view returns (SeriesTerms memory);
    function seriesExists(bytes32 seriesId) external view returns (bool);
    function groupOf(bytes32 seriesId) external view returns (bytes32);
    function productOf(bytes32 seriesId) external view returns (bytes32);
    function seriesInGroup(bytes32 groupId) external view returns (bytes32[] memory);
    function getGroup(bytes32 groupId) external view returns (Group memory);
    function getProduct(bytes32 productId) external view returns (Product memory);
    function isProductEnabled(bytes32 productId) external view returns (bool);
    function isSettlementAssetApproved(address asset) external view returns (bool);
    function settlementAssetDecimals(address asset) external view returns (uint8);

    function seriesDomain() external view returns (bytes32);
    function computeSeriesId(SeriesParams calldata params) external view returns (bytes32);
    function computeGroupId(address underlying, address settlementAsset, uint64 expiry, bytes32 configId)
        external
        pure
        returns (bytes32);
    function computeProductId(address underlying, address settlementAsset) external pure returns (bytes32);
}
