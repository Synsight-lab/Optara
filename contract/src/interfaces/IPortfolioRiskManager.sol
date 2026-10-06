// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRiskSets} from "./IExternalDependencies.sol";

/// @title IPortfolioRiskManager
/// @notice Equity, initial and maintenance margin, health and product close-only (docs/MATH.md §5–§9,
///         MARGIN_AND_RISK.md). All values are WAD of the account's settlement asset.
interface IPortfolioRiskManager is IRiskSets {
    /// @notice A stress scenario (MATH.md §9). timeMode: 0 now, 1 near-expiry floor, 2 shift by timeShiftSeconds.
    struct Scenario {
        int32 spotShockBps; // ≥ −10_000
        int32 volShockBps; // ≥ −10_000, relative to the leg's IV
        uint8 timeMode;
        uint32 timeShiftSeconds;
    }

    /// @notice One risk parameter set (PARAMETERS.md §2–§3). IVs are WAD.
    struct RiskParams {
        uint16 imBufferBps; // of the current mark of all shorts, ≤ 5000
        uint256 minIv;
        uint256 maxIv;
        uint32 nearExpiryFloorSeconds;
        uint256 maxOpenInterestPerSeries; // total internal short per series, quantity (1e18), ≤ 1e24
        Scenario[] initialSet; // IM uses initialSet ∪ maintenanceSet
        Scenario[] maintenanceSet;
    }

    enum HealthState {
        HEALTHY,
        CLOSE_ONLY,
        LIQUIDATABLE,
        INSOLVENT
    }

    struct Risk {
        int256 equity;
        uint256 initialMargin;
        uint256 maintenanceMargin;
        bool fresh; // every product's spot and surface were fresh
    }

    event RiskSetCreated(bytes32 indexed riskParameterSetId, RiskParams params);
    event RiskSetUpdated(bytes32 indexed riskParameterSetId, RiskParams params);
    event RiskSetEnabled(bytes32 indexed riskParameterSetId, bool enabled);
    event ProductRiskSetAssigned(bytes32 indexed productId, bytes32 indexed riskParameterSetId);
    event ProductShortCapSet(bytes32 indexed productId, uint256 maxShortUnderlyingWad);

    // ---- governance / risk admin ----
    function createRiskSet(bytes32 id, RiskParams calldata params) external;
    function updateRiskSet(bytes32 id, RiskParams calldata params) external;
    function raiseImBuffer(bytes32 id, uint16 imBufferBps) external;
    function raiseMinIv(bytes32 id, uint256 minIv) external;
    function addScenarios(bytes32 id, Scenario[] calldata initialAdd, Scenario[] calldata maintenanceAdd) external;
    function setOpenInterestCap(bytes32 id, uint256 maxOpenInterestPerSeries) external;
    function setRiskSetEnabled(bytes32 id, bool enabled) external;
    function assignProductRiskSet(bytes32 productId, bytes32 id) external;
    function setProductShortCap(bytes32 productId, uint256 maxShortUnderlyingWad) external;

    // ---- checks used by other modules ----
    /// @notice Reverts unless the account is healthy with fresh data for every product it holds (STRICT).
    function requireHealthy(uint256 accountId) external view returns (Risk memory);
    /// @notice Reverts unless new risk may be opened on the series: active (`SeriesNotActive`), product not
    ///         close-only (`ProductCloseOnly`) and, when `checkCaps` (mints, which add shorts), open-interest caps
    ///         respected after the ledger write (`OpenInterestCap`, INV-42).
    function checkOpenRisk(bytes32 seriesId, bool checkCaps) external view;
    /// @notice Margins for liquidation: fresh spot; surface fresh or stale up to maxSurfaceStale (INV-45).
    function riskForLiquidation(uint256 accountId) external view returns (Risk memory);

    // ---- views ----
    function riskOf(uint256 accountId) external view returns (Risk memory);
    function healthOf(uint256 accountId)
        external
        view
        returns (HealthState state, int256 equity, uint256 initialMargin, uint256 maintenanceMargin, bool fresh);
    function equityOf(uint256 accountId) external view returns (int256);
    function marginOf(uint256 accountId) external view returns (uint256 initialMargin, uint256 maintenanceMargin);
    /// @notice Risk after hypothetically changing one balance and the cash (no state change).
    function previewWithDelta(uint256 accountId, bytes32 seriesId, int256 qtyDelta, int256 cashDeltaNative)
        external
        view
        returns (Risk memory);
    /// @notice Risk after hypothetically changing several balances and the cash (no state change); used by
    ///         `LiquidationModule.previewSlice`. Reverts `LengthMismatch` if the arrays differ in length.
    function previewWithDeltas(
        uint256 accountId,
        bytes32[] calldata seriesIds,
        int256[] calldata qtyDeltas,
        int256 cashDeltaNative
    ) external view returns (Risk memory);
    function previewWrap(uint256 accountId, bytes32 seriesId, uint256 qty)
        external
        view
        returns (int256 equityAfter, uint256 imAfter, bool ok);
    function previewWithdraw(uint256 accountId, uint256 amount)
        external
        view
        returns (int256 equityAfter, uint256 imAfter, bool ok);
    function maxWithdrawable(uint256 accountId) external view returns (uint256 native);
    /// @notice Per-option prices (WAD): mid, short (stale-adjusted up), long (stale-adjusted down).
    function priceOf(bytes32 seriesId) external view returns (uint256 mid, uint256 shortPrice, uint256 longPrice);
    function ivOf(bytes32 seriesId) external view returns (uint256 sigma, uint256 sigmaShort, uint256 sigmaLong);
    function isProductCloseOnly(bytes32 productId) external view returns (bool);
    function getRiskSet(bytes32 id) external view returns (RiskParams memory params, bool enabled);
    function productRiskSet(bytes32 productId) external view returns (bytes32);
    function productShortCap(bytes32 productId) external view returns (uint256);
}
