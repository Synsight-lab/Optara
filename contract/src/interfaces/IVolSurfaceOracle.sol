// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVolSurfaceOracle
/// @notice Signed implied-volatility surfaces per product (docs/ORACLES.md §3). A report carries a header (stored)
///         and a Merkle root over total-variance grid leaves (proved on demand and cached).
interface IVolSurfaceOracle {
    /// @notice Signed by a quorum of publishers (EIP-712, domain "Optara VolSurfaceOracle" version "1").
    struct SurfaceReport {
        uint256 chainId;
        address verifyingContract;
        bytes32 productId;
        address underlying;
        address settlementAsset;
        uint64 surfaceSeq; // strictly increasing per product
        uint64 validAfter; // = report time
        uint64 expiresAt;
        bytes32 spotReferenceId; // audit only
        bytes32 surfaceRoot; // sorted-pair Merkle root of the grid leaves
        uint64[4] tenorTimestamps; // increasing; unused trailing entries 0
        uint256[4] atmTotalVarianceByTenor; // WAD; 0 for unused tenors
        int256[] kNodes; // log-moneyness grid, WAD, strictly increasing, 1–32 nodes
        uint32 surfaceMinIvBps;
        uint32 surfaceMaxIvBps;
        uint32 confidenceBps;
        uint16 sourceCount;
        uint32 liquidityScore;
        uint32 maxBidAskWidthBps;
        uint64 lastCalibrationTime;
        bytes32 riskParameterSetId;
    }

    /// @notice leaf = keccak256(abi.encode(productId, surfaceSeq, tenorIndex, nodeIndex, totalVarianceWad)).
    struct NodeProof {
        bytes32 productId;
        uint64 surfaceSeq;
        uint8 tenorIndex;
        uint8 nodeIndex;
        uint256 totalVarianceWad;
        bytes32[] proof;
    }

    /// @notice Stored per product (everything in the report except the leaves; kNodes stored separately).
    struct SurfaceHeader {
        uint64 surfaceSeq;
        uint64 validAfter;
        uint64 expiresAt;
        uint32 surfaceMinIvBps;
        uint32 surfaceMaxIvBps;
        uint32 confidenceBps;
        bool lowConfidence; // confidenceBps > maxConfidenceBps: stored, but the product is close-only
        bytes32 surfaceRoot;
        bytes32 kNodesHash;
        uint64[4] tenorTimestamps;
        uint256[4] atmTotalVarianceByTenor;
    }

    /// @notice Per-product oracle settings (docs/PARAMETERS.md §4). IV bounds in bps of IV (10_000 = 100%).
    struct SurfaceConfig {
        uint32 maxReportLifetime; // expiresAt − validAfter limit
        uint32 maxIvMoveBps; // relative ATM IV change per update (waived in emergency mode)
        uint32 maxConfidenceBps; // above → stored but close-only
        uint32 minIvBps; // product IV floor: surfaceMinIvBps must be ≥ this
        uint32 maxIvBps; // product IV cap: surfaceMaxIvBps must be ≤ this
        uint32 surfaceStaleAfter; // FRESH while age ≤ this (and before expiresAt)
        uint32 maxSurfaceStale; // EXPIRED_DATA beyond this
        uint32 staleIvPenaltyBpsPerHour;
        uint32 maxLongTimeValueStale; // longs at intrinsic after this age
    }

    enum SurfaceStatus {
        NONE,
        FRESH,
        STALE,
        EXPIRED_DATA
    }

    event SurfaceAccepted(
        bytes32 indexed productId,
        uint64 indexed surfaceSeq,
        bytes32 surfaceRoot,
        uint64 validAfter,
        uint64 expiresAt,
        uint32 confidenceBps,
        bool lowConfidence
    );
    event NodeProven(
        bytes32 indexed productId,
        uint64 indexed surfaceSeq,
        uint8 tenorIndex,
        uint8 nodeIndex,
        uint256 totalVarianceWad
    );
    event PublisherAdded(address indexed publisher, bool independent);
    event PublisherRemoved(address indexed publisher);
    event QuorumSet(uint256 quorum);
    event EmergencyModeSet(bytes32 indexed productId, bool enabled);
    event SurfaceConfigSet(bytes32 indexed productId, SurfaceConfig config);

    function submitReport(SurfaceReport calldata report, bytes[] calldata signatures) external;
    function proveNodes(NodeProof[] calldata nodes) external;

    function addPublisher(address publisher, bool independent) external;
    function removePublisher(address publisher) external;
    function setQuorum(uint256 quorum) external;
    function setSurfaceConfig(bytes32 productId, SurfaceConfig calldata config) external;
    function setEmergencyMode(bytes32 productId, bool enabled) external;

    function header(bytes32 productId) external view returns (SurfaceHeader memory);
    function kNodes(bytes32 productId) external view returns (int256[] memory);
    /// @return proven True if the leaf of the current report was proved. @return totalVarianceWad Its value.
    function nodeValue(bytes32 productId, uint8 tenorIndex, uint8 nodeIndex)
        external
        view
        returns (bool proven, uint256 totalVarianceWad);
    /// @return status FRESH / STALE / EXPIRED_DATA. @return staleSeconds Seconds beyond surfaceStaleAfter.
    function surfaceStatus(bytes32 productId) external view returns (SurfaceStatus status, uint64 staleSeconds);
    function isEmergency(bytes32 productId) external view returns (bool);
    function surfaceConfig(bytes32 productId) external view returns (SurfaceConfig memory);
    function reportDigest(SurfaceReport calldata report) external view returns (bytes32);
    function isPublisher(address account) external view returns (bool active, bool independent);
    function quorum() external view returns (uint256);
}
