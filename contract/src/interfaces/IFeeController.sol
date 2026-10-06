// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IReserveStatus} from "./IExternalDependencies.sol";

/// @title IFeeController
/// @notice Fee formulas, caps and split; treasury and keeper reserve; keeper rewards; reserve minimums
///         (docs/FEES.md, MATH.md §11). Holds the treasury and keeper-reserve tokens.
interface IFeeController is IReserveStatus {
    struct Split {
        uint16 insuranceBps;
        uint16 treasuryBps;
        uint16 keeperBps;
    }

    struct AssetConfig {
        uint256 minSellerFeeNative;
        uint256 minimumInsuranceSeed;
        uint256 minimumKeeperReserve;
        uint256 finalizeRewardNative;
        uint256 settleRewardNative;
    }

    event FeeRatesSet(uint16 sellerOpenFeeBps, uint16 buyerTradeFeeBps);
    event SplitSet(uint16 insuranceBps, uint16 treasuryBps, uint16 keeperBps);
    event MinSellerFeeSet(address indexed asset, uint256 minSellerFeeNative);
    event MinimumsSet(address indexed asset, uint256 minimumInsuranceSeed, uint256 minimumKeeperReserve);
    event RewardsSet(address indexed asset, uint256 finalizeRewardNative, uint256 settleRewardNative);
    event SellerFeeCharged(uint256 indexed accountId, bytes32 indexed seriesId, address indexed asset, uint256 fee);
    event BuyerFeeCharged(address indexed buyer, bytes32 indexed seriesId, address indexed asset, uint256 fee);
    event FeeSplit(address indexed asset, uint256 fee, uint256 toInsurance, uint256 toTreasury, uint256 toKeeper);
    event KeeperReserveFunded(address indexed asset, address indexed from, uint256 amount);
    event KeeperRewardPaid(address indexed asset, address indexed keeper, uint256 amount, bool finalize);
    event TreasuryWithdrawn(address indexed asset, uint256 amount, address indexed to);

    // ---- fee collection (OptionClearing / VenueRouter push the tokens first) ----
    function notifySellerFee(uint256 accountId, bytes32 seriesId, address asset, uint256 fee) external;
    function notifyBuyerFee(address buyer, bytes32 seriesId, address asset, uint256 fee) external;

    // ---- keeper reserve and rewards ----
    function fundKeeperReserve(address asset, uint256 amount) external;
    function payFinalizeReward(address asset, address keeper) external returns (uint256 paid);
    function paySettleReward(address asset, address keeper, uint64 finalizedAt) external returns (uint256 paid);

    // ---- governance ----
    function setFeeRates(uint16 sellerOpenFeeBps, uint16 buyerTradeFeeBps) external;
    function setSplit(uint16 insuranceBps, uint16 treasuryBps, uint16 keeperBps) external;
    function setMinSellerFee(address asset, uint256 minSellerFeeNative) external;
    function setMinimums(address asset, uint256 minimumInsuranceSeed, uint256 minimumKeeperReserve) external;
    function setRewards(address asset, uint256 finalizeRewardNative, uint256 settleRewardNative) external;
    function withdrawTreasury(address asset, uint256 amount, address to) external;

    // ---- views ----
    /// @notice max(ceil(mark(qty) × sellerOpenFeeBps / 10_000) in native, minSellerFeeNative).
    function previewSellerFee(bytes32 seriesId, uint256 qty) external view returns (uint256);
    /// @notice ceil(premiumNative × buyerTradeFeeBps / 10_000).
    function previewBuyerFee(uint256 premiumNative) external view returns (uint256);
    /// @notice The settle reward now for a group finalized at `finalizedAt` (+25% of base per hour, capped at 4×).
    function settleRewardAt(address asset, uint64 finalizedAt) external view returns (uint256);
    function treasury(address asset) external view returns (uint256);
    function keeperReserve(address asset) external view returns (uint256);
    function insuranceBalance(address asset) external view returns (uint256);
    function feeRates() external view returns (uint16 sellerOpenFeeBps, uint16 buyerTradeFeeBps);
    function split() external view returns (Split memory);
    function assetConfig(address asset) external view returns (AssetConfig memory);
}
