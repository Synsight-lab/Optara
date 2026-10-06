// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The subset of the Pyth pull-oracle interface Optara uses (https://docs.pyth.network/price-feeds).
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    /// @dev Latest stored price regardless of age; reverts if the feed has never been updated.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
}
