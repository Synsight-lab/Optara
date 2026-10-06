// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Types shared across Optara PM modules (docs/OPTION_SPEC.md).

enum OptionType {
    CALL,
    PUT
}

enum ProductStatus {
    NONE,
    ENABLED,
    DISABLED
}

/// @notice Bounds for series of one product (underlying × settlement asset) and display symbols for wrapper names.
/// @dev Hard caps (OptionSeriesRegistry) keep every settlement numerator inside int256 (docs/MATH.md §14).
struct ProductConfig {
    uint256 minStrikeWad;
    uint256 maxStrikeWad;
    uint256 minContractSizeWad;
    uint256 maxContractSizeWad;
    uint64 minTimeToExpiry; // seconds
    uint64 maxTimeToExpiry; // seconds
    /// @dev Settlement prices are clamped to this (SettlementOracle); bounds every payoff.
    uint256 maxSettlementPriceWad;
    string underlyingSymbol; // display only, e.g. "ETH"
    string assetSymbol; // display only, e.g. "USDC"
}

struct Product {
    address underlying;
    address settlementAsset;
    ProductStatus status;
    ProductConfig config;
}

/// @notice What a series creator submits.
struct SeriesParams {
    address underlying;
    address settlementAsset;
    OptionType optionType;
    uint256 strikeWad;
    uint256 contractSizeWad;
    uint64 expiry;
    bytes32 settlementOracleConfigId;
    bytes32 volSurfaceProductId;
    bytes32 riskParameterSetId;
}

/// @notice Stored terms of a series. Written once, never changed (protected storage, ACCESS_CONTROL.md §5).
struct SeriesTerms {
    address underlying;
    address settlementAsset;
    OptionType optionType;
    uint256 strikeWad;
    uint256 contractSizeWad;
    uint64 expiry;
    bytes32 settlementOracleConfigId;
    bytes32 volSurfaceProductId;
    bytes32 riskParameterSetId;
    address wrapper;
}

/// @notice All series sharing underlying, settlement asset, expiry and settlement oracle config settle together.
struct Group {
    address underlying;
    address settlementAsset;
    uint64 expiry;
    bytes32 settlementOracleConfigId;
}
