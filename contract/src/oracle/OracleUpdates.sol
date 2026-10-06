// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILiveSpotOracle} from "../interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../interfaces/IVolSurfaceOracle.sol";
import {InsufficientProviderFee, InvalidOracleUpdate} from "../libraries/Errors.sol";

/// @notice Market data submitted with a risk-increasing or liquidation call (docs/ORACLES.md §4). Every field may be
///         empty when the cached data is fresh.
/// @param spotUpdates     Pyth price update blobs (the provider fee is paid from `msg.value`).
/// @param spotProductIds  Products whose stored spot price is refreshed from Pyth after the blobs are applied.
/// @param reports         Signed surface reports; a report at or below the product's current sequence is skipped.
/// @param reportSignatures One signature list per report.
/// @param nodes           Merkle proofs for surface leaves not yet cached (already-cached leaves are skipped).
struct OracleUpdate {
    bytes[] spotUpdates;
    bytes32[] spotProductIds;
    IVolSurfaceOracle.SurfaceReport[] reports;
    bytes[][] reportSignatures;
    IVolSurfaceOracle.NodeProof[] nodes;
}

/// @title OracleUpdates
/// @notice Applies an `OracleUpdate` before an action (used by OptionClearing and LiquidationModule).
/// @dev Skipping already-accepted reports (DD-30) means two users submitting the same report in one block both
///      succeed instead of the second reverting on its sequence number. The spot oracle receives exactly its fee,
///      so it refunds nothing; the calling module refunds `msg.value − feePaid` to its caller.
library OracleUpdates {
    /// @return feePaid The provider fee forwarded to the spot oracle (≤ msg.value).
    function applyUpdate(OracleUpdate calldata u, ILiveSpotOracle spot, IVolSurfaceOracle surface)
        internal
        returns (uint256 feePaid)
    {
        if (u.spotUpdates.length != 0 || u.spotProductIds.length != 0) {
            feePaid = spot.updateFee(u.spotUpdates);
            if (msg.value < feePaid) revert InsufficientProviderFee(feePaid, msg.value);
            spot.update{value: feePaid}(u.spotUpdates, u.spotProductIds);
        }
        uint256 n = u.reports.length;
        if (n != u.reportSignatures.length) revert InvalidOracleUpdate();
        for (uint256 i; i < n; ++i) {
            IVolSurfaceOracle.SurfaceReport calldata r = u.reports[i];
            if (r.surfaceSeq > surface.header(r.productId).surfaceSeq) surface.submitReport(r, u.reportSignatures[i]);
        }
        if (u.nodes.length != 0) surface.proveNodes(u.nodes);
    }
}
