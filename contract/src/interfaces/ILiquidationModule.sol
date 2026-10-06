// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleUpdate} from "../oracle/OracleUpdates.sol";

/// @title ILiquidationModule
/// @notice Permissionless Dutch-auction liquidation per risk bucket (one account × one underlying), by portfolio slice
///         or by wrapper burn (docs/LIQUIDATION.md, MATH.md §12, PROTOCOL_SPEC.md §6).
/// @dev Units: `sliceMark`, `sliceMM` and `discount` are WAD of the settlement asset; `penalty` and
///      `cashToLiquidator` are native units actually moved (positive = account → liquidator).
interface ILiquidationModule {
    struct LiquidationParams {
        uint16 startBonusBps; // bonus (bps of slice MM) when the auction starts
        uint16 maxBonusBps; // reached linearly after auctionDuration
        uint32 auctionDuration; // seconds; afterwards whole-bucket mode allows slices up to 10,000 bps
        uint16 minSliceBps;
        uint16 maxSliceBps;
        uint16 targetHealthBufferBps; // the auction ends at equity ≥ IM × (1 + buffer)
        uint16 liquidationPenaltyBps; // bps of slice MM, to insurance
    }

    struct Modules {
        address ledger;
        address registry;
        address risk;
        address insurance;
        address clearing;
        address spot;
        address surface;
    }

    event AuctionStarted(
        uint256 indexed accountId,
        address indexed underlying,
        int256 equity,
        uint256 maintenanceMargin,
        uint64 startTime
    );
    event SliceLiquidated(
        uint256 indexed accountId,
        address indexed underlying,
        uint256 indexed liquidatorAccountId,
        uint16 sliceBps,
        int256 sliceMark,
        uint256 sliceMM,
        uint256 discount,
        uint256 penalty,
        int256 cashToLiquidator
    );
    event WrapperLiquidated(
        uint256 indexed accountId,
        bytes32 indexed seriesId,
        uint256 qty,
        uint256 indexed liquidatorAccountId,
        uint256 cashToLiquidator,
        uint256 penalty
    );
    event BadDebtCovered(uint256 indexed accountId, address indexed asset, uint256 insuranceAmount, uint256 unpaid);
    /// @param reason 0 = the account reached its target health, 1 = the bucket has no unexpired positions left.
    event AuctionEnded(uint256 indexed accountId, address indexed underlying, uint8 reason);
    event LiquidationParamsSet(LiquidationParams params);
    event MaxInsurancePerLiquidationSet(address indexed asset, uint256 amount);

    /// @notice Anyone. Requires equity < MM (LIQUIDATION mode), unexpired positions in the bucket, no active auction.
    function startAuction(uint256 accountId, address underlying, OracleUpdate calldata u) external payable;
    /// @notice Moves `sliceBps` of every unexpired leg of the bucket to `liquidatorAccountId` at mark value, with the
    ///         auction's current discount; the account pays the penalty to insurance (LIQUIDATION.md §3).
    function liquidateSlice(
        uint256 accountId,
        address underlying,
        uint256 liquidatorAccountId,
        uint16 sliceBps,
        uint256 minCashToLiquidator,
        uint256 maxCashFromLiquidator,
        OracleUpdate calldata u
    ) external payable;
    /// @notice Burns the caller's wrappers of a series the account is short (LIQUIDATION.md §4). Requires equity < MM.
    function liquidateWithWrapper(
        uint256 accountId,
        bytes32 seriesId,
        uint256 qty,
        uint256 liquidatorAccountId,
        uint256 minCashToLiquidator,
        OracleUpdate calldata u
    ) external payable;
    /// @notice Anyone, once equity ≥ IM × (1 + targetHealthBufferBps) or the bucket has no unexpired positions.
    function endAuction(uint256 accountId, address underlying, OracleUpdate calldata u) external payable;

    function setLiquidationParams(LiquidationParams calldata params) external;
    function setMaxInsurancePerLiquidation(address asset, uint256 amount) external;

    /// @notice What `liquidateSlice` would do now (VIEW-mode risk; never reverts on staleness).
    function previewSlice(uint256 accountId, address underlying, uint16 sliceBps)
        external
        view
        returns (int256 sliceMark, uint256 sliceMM, uint256 discount, uint256 penalty, int256 cashToLiquidator);
    /// @return startTime 0 if no auction is active.
    function auctionStart(uint256 accountId, address underlying) external view returns (uint64 startTime);
    /// @return bonusBps The current bonus (startBonusBps if no auction). @return wholeBucket True after auctionDuration.
    function currentBonus(uint256 accountId, address underlying)
        external
        view
        returns (uint256 bonusBps, bool wholeBucket);
    function liquidationParams() external view returns (LiquidationParams memory);
    function maxInsurancePerLiquidation(address asset) external view returns (uint256);
    function modules() external view returns (Modules memory);
}
