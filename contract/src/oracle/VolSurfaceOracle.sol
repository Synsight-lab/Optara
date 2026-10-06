// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IVolSurfaceOracle} from "../interfaces/IVolSurfaceOracle.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {OptionPricer} from "../risk/OptionPricer.sol";
import {Product, ProductStatus} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    InvalidSurfaceReport,
    InvalidSignatures,
    InvalidSurfaceConfig,
    InvalidPublisher
} from "../libraries/Errors.sol";

/// @title VolSurfaceOracle
/// @notice Accepts implied-volatility surface reports signed by a quorum of publishers (EIP-712), stores the header
///         and the Merkle root, and verifies and caches grid leaves on demand (docs/ORACLES.md §3).
/// @dev Acceptance checks (InvalidSurfaceReport reasons):
///      1 domain (chainId, contract)       2 product (unknown, pair mismatch, not configured)
///      3 sequence / time going backwards  4 validity window or lifetime
///      5 tenors (count, order, ATM variance calendar sanity, ATM IV within the report bounds)
///      6 kNodes (1–32, strictly increasing)  7 IV bounds vs the product's floor/cap
///      8 ATM IV moved more than maxIvMoveBps (waived in emergency mode)
///      9 a proven leaf's IV outside the report bounds   10 bad Merkle proof or leaf index
///      Low confidence does not revert: the report is stored and flagged, and the risk manager treats the product as
///      close-only until a confident report arrives.
contract VolSurfaceOracle is OptaraModule, EIP712Upgradeable, IVolSurfaceOracle {
    uint256 internal constant MAX_K_NODES = 32;
    uint256 internal constant BPS_TO_WAD = 1e14; // 1 bps of IV = 1e14 in WAD

    uint8 internal constant R_DOMAIN = 1;
    uint8 internal constant R_PRODUCT = 2;
    uint8 internal constant R_SEQUENCE = 3;
    uint8 internal constant R_TIME = 4;
    uint8 internal constant R_TENORS = 5;
    uint8 internal constant R_KNODES = 6;
    uint8 internal constant R_IV_BOUNDS = 7;
    uint8 internal constant R_IV_MOVE = 8;
    uint8 internal constant R_NODE_IV = 9;
    uint8 internal constant R_PROOF = 10;

    bytes32 internal constant REPORT_TYPEHASH = keccak256(
        "SurfaceReport(uint256 chainId,address verifyingContract,bytes32 productId,address underlying,"
        "address settlementAsset,uint64 surfaceSeq,uint64 validAfter,uint64 expiresAt,bytes32 spotReferenceId,"
        "bytes32 surfaceRoot,uint64[4] tenorTimestamps,uint256[4] atmTotalVarianceByTenor,int256[] kNodes,"
        "uint32 surfaceMinIvBps,uint32 surfaceMaxIvBps,uint32 confidenceBps,uint16 sourceCount,uint32 liquidityScore,"
        "uint32 maxBidAskWidthBps,uint64 lastCalibrationTime,bytes32 riskParameterSetId)"
    );

    struct Publisher {
        bool active;
        bool independent;
    }

    /// @custom:storage-location erc7201:optara.storage.VolSurfaceOracle
    struct SurfaceStorage {
        IOptionSeriesRegistry registry;
        uint256 quorum;
        mapping(address => Publisher) publishers;
        mapping(bytes32 productId => SurfaceConfig) configs;
        mapping(bytes32 productId => SurfaceHeader) headers;
        mapping(bytes32 productId => int256[]) kNodes;
        mapping(bytes32 productId => bool) emergency;
        mapping(bytes32 leafKey => uint256) nodes; // keccak(productId, seq, tenor, node) → totalVariance (0 = unproven)
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.VolSurfaceOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xcc8b6681bf4021c78c378ea4a0f35b828218f453985ac2bf2d908b133e204c00;

    function initialize(IProtocolControl control_, IOptionSeriesRegistry registry_, uint256 quorum_)
        external
        initializer
    {
        __OptaraModule_init(control_);
        __EIP712_init("Optara VolSurfaceOracle", "1");
        if (address(registry_) == address(0)) revert ZeroAddress();
        if (quorum_ == 0) revert InvalidSurfaceConfig(10);
        _s().registry = registry_;
        _s().quorum = quorum_;
        emit QuorumSet(quorum_);
    }

    // ------------------------------------------------------------------------------------------------- reports

    /// @inheritdoc IVolSurfaceOracle
    function submitReport(SurfaceReport calldata r, bytes[] calldata signatures) external nonReentrant {
        SurfaceStorage storage $ = _s();
        if (r.chainId != block.chainid || r.verifyingContract != address(this)) revert InvalidSurfaceReport(R_DOMAIN);
        SurfaceConfig storage cfg = $.configs[r.productId];
        _checkProduct(r, cfg);

        SurfaceHeader storage h = $.headers[r.productId];
        if (r.surfaceSeq <= h.surfaceSeq || r.validAfter < h.validAfter) revert InvalidSurfaceReport(R_SEQUENCE);
        if (
            r.validAfter > block.timestamp || block.timestamp >= r.expiresAt
                || r.expiresAt - r.validAfter > cfg.maxReportLifetime
        ) revert InvalidSurfaceReport(R_TIME);

        _checkSignatures(_hashTypedDataV4(_structHash(r)), signatures);
        _checkGrid(r, cfg);
        if (h.surfaceSeq != 0 && !$.emergency[r.productId]) _checkIvMove(r, h, cfg.maxIvMoveBps);

        bool lowConfidence = r.confidenceBps > cfg.maxConfidenceBps;
        bytes32 kHash = keccak256(abi.encodePacked(r.kNodes));
        if (kHash != h.kNodesHash) $.kNodes[r.productId] = r.kNodes; // grids rarely change: store only on change
        h.surfaceSeq = r.surfaceSeq;
        h.validAfter = r.validAfter;
        h.expiresAt = r.expiresAt;
        h.surfaceMinIvBps = r.surfaceMinIvBps;
        h.surfaceMaxIvBps = r.surfaceMaxIvBps;
        h.confidenceBps = r.confidenceBps;
        h.lowConfidence = lowConfidence;
        h.surfaceRoot = r.surfaceRoot;
        h.kNodesHash = kHash;
        h.tenorTimestamps = r.tenorTimestamps;
        h.atmTotalVarianceByTenor = r.atmTotalVarianceByTenor;
        emit SurfaceAccepted(
            r.productId, r.surfaceSeq, r.surfaceRoot, r.validAfter, r.expiresAt, r.confidenceBps, lowConfidence
        );
    }

    /// @inheritdoc IVolSurfaceOracle
    /// @dev Only leaves of each product's current report can be proved. Already-proven leaves are skipped.
    function proveNodes(NodeProof[] calldata nodes) external nonReentrant {
        SurfaceStorage storage $ = _s();
        for (uint256 i; i < nodes.length; ++i) {
            NodeProof calldata n = nodes[i];
            SurfaceHeader storage h = $.headers[n.productId];
            bytes32 key = _leafKey(n.productId, n.surfaceSeq, n.tenorIndex, n.nodeIndex);
            if ($.nodes[key] != 0) continue;
            if (
                n.surfaceSeq == 0 || n.surfaceSeq != h.surfaceSeq || n.tenorIndex >= 4
                    || h.tenorTimestamps[n.tenorIndex] == 0 || n.nodeIndex >= $.kNodes[n.productId].length
            ) revert InvalidSurfaceReport(R_PROOF);
            bytes32 leaf =
                keccak256(abi.encode(n.productId, n.surfaceSeq, n.tenorIndex, n.nodeIndex, n.totalVarianceWad));
            if (!MerkleProof.verifyCalldata(n.proof, h.surfaceRoot, leaf)) revert InvalidSurfaceReport(R_PROOF);
            uint256 iv = _iv(n.totalVarianceWad, h.tenorTimestamps[n.tenorIndex], h.validAfter);
            if (iv < h.surfaceMinIvBps * BPS_TO_WAD || iv > h.surfaceMaxIvBps * BPS_TO_WAD) {
                revert InvalidSurfaceReport(R_NODE_IV);
            }
            $.nodes[key] = n.totalVarianceWad; // > 0 because iv ≥ surfaceMinIv > 0
            emit NodeProven(n.productId, n.surfaceSeq, n.tenorIndex, n.nodeIndex, n.totalVarianceWad);
        }
    }

    // ------------------------------------------------------------------------------------------------- admin

    /// @notice Governance (publisher-set changes are timelocked through governance).
    function addPublisher(address publisher, bool independent) external onlyRole(Roles.GOVERNANCE) {
        if (publisher == address(0) || _s().publishers[publisher].active) revert InvalidPublisher(publisher);
        _s().publishers[publisher] = Publisher({active: true, independent: independent});
        emit PublisherAdded(publisher, independent);
    }

    /// @notice Governance or guardian (removing a publisher only reduces trust).
    function removePublisher(address publisher) external {
        if (!_hasRole(Roles.GOVERNANCE, msg.sender) && !_hasRole(Roles.GUARDIAN, msg.sender)) {
            revert NotAuthorized(msg.sender);
        }
        if (!_s().publishers[publisher].active) revert InvalidPublisher(publisher);
        delete _s().publishers[publisher];
        emit PublisherRemoved(publisher);
    }

    function setQuorum(uint256 quorum_) external onlyRole(Roles.GOVERNANCE) {
        if (quorum_ == 0) revert InvalidSurfaceConfig(10);
        _s().quorum = quorum_;
        emit QuorumSet(quorum_);
    }

    /// @notice Governance. The product must exist in the registry.
    function setSurfaceConfig(bytes32 productId, SurfaceConfig calldata c) external onlyRole(Roles.GOVERNANCE) {
        if (_s().registry.getProduct(productId).status == ProductStatus.NONE) revert InvalidSurfaceConfig(1);
        if (c.maxReportLifetime == 0 || c.maxReportLifetime > 1 days) revert InvalidSurfaceConfig(2);
        if (c.maxIvMoveBps == 0 || c.maxConfidenceBps > 10_000) revert InvalidSurfaceConfig(3);
        if (c.minIvBps == 0 || c.minIvBps >= c.maxIvBps || c.maxIvBps > 100_000) revert InvalidSurfaceConfig(4);
        if (
            c.surfaceStaleAfter == 0 || c.maxSurfaceStale < c.surfaceStaleAfter
                || c.maxLongTimeValueStale < c.surfaceStaleAfter || c.maxLongTimeValueStale > c.maxSurfaceStale
        ) revert InvalidSurfaceConfig(5);
        if (c.staleIvPenaltyBpsPerHour > 100_000) revert InvalidSurfaceConfig(6);
        _s().configs[productId] = c;
        emit SurfaceConfigSet(productId, c);
    }

    /// @notice Guardian or governance enables; only governance disables. Emergency mode waives maxIvMoveBps so a
    ///         genuine sharp move can be accepted; the risk manager treats the product as close-only while it is on.
    function setEmergencyMode(bytes32 productId, bool enabled) external {
        if (!_hasRole(Roles.GOVERNANCE, msg.sender) && (!enabled || !_hasRole(Roles.GUARDIAN, msg.sender))) {
            revert NotAuthorized(msg.sender);
        }
        _s().emergency[productId] = enabled;
        emit EmergencyModeSet(productId, enabled);
    }

    // ------------------------------------------------------------------------------------------------- views

    function header(bytes32 productId) external view returns (SurfaceHeader memory) {
        return _s().headers[productId];
    }

    function kNodes(bytes32 productId) external view returns (int256[] memory) {
        return _s().kNodes[productId];
    }

    function nodeValue(bytes32 productId, uint8 tenorIndex, uint8 nodeIndex)
        external
        view
        returns (bool proven, uint256 totalVarianceWad)
    {
        SurfaceStorage storage $ = _s();
        totalVarianceWad = $.nodes[_leafKey(productId, $.headers[productId].surfaceSeq, tenorIndex, nodeIndex)];
        proven = totalVarianceWad != 0;
    }

    /// @inheritdoc IVolSurfaceOracle
    function surfaceStatus(bytes32 productId) external view returns (SurfaceStatus status, uint64 staleSeconds) {
        SurfaceStorage storage $ = _s();
        SurfaceHeader storage h = $.headers[productId];
        if (h.surfaceSeq == 0) return (SurfaceStatus.NONE, 0);
        SurfaceConfig storage c = $.configs[productId];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 age = uint64(block.timestamp) - h.validAfter; // validAfter ≤ acceptance time ≤ now
        if (age > c.surfaceStaleAfter) staleSeconds = age - c.surfaceStaleAfter;
        if (age > c.maxSurfaceStale) return (SurfaceStatus.EXPIRED_DATA, staleSeconds);
        if (age <= c.surfaceStaleAfter && block.timestamp < h.expiresAt) return (SurfaceStatus.FRESH, 0);
        return (SurfaceStatus.STALE, staleSeconds);
    }

    function isEmergency(bytes32 productId) external view returns (bool) {
        return _s().emergency[productId];
    }

    function surfaceConfig(bytes32 productId) external view returns (SurfaceConfig memory) {
        return _s().configs[productId];
    }

    function reportDigest(SurfaceReport calldata r) external view returns (bytes32) {
        return _hashTypedDataV4(_structHash(r));
    }

    function isPublisher(address account) external view returns (bool active, bool independent) {
        Publisher storage p = _s().publishers[account];
        return (p.active, p.independent);
    }

    function quorum() external view returns (uint256) {
        return _s().quorum;
    }

    function registry() external view returns (address) {
        return address(_s().registry);
    }

    // ------------------------------------------------------------------------------------------------- internal

    function _checkProduct(SurfaceReport calldata r, SurfaceConfig storage cfg) private view {
        Product memory p = _s().registry.getProduct(r.productId);
        if (
            p.status == ProductStatus.NONE || p.underlying != r.underlying || p.settlementAsset != r.settlementAsset
                || cfg.maxReportLifetime == 0
        ) revert InvalidSurfaceReport(R_PRODUCT);
    }

    /// @dev Signatures sorted by signer (strictly increasing, so no duplicates), every signer an active publisher,
    ///      at least `quorum` of them, and at least one from the independent group.
    function _checkSignatures(bytes32 digest, bytes[] calldata signatures) private view {
        SurfaceStorage storage $ = _s();
        if (signatures.length < $.quorum) revert InvalidSignatures();
        address previous;
        bool independent;
        for (uint256 i; i < signatures.length; ++i) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError || signer <= previous) revert InvalidSignatures();
            Publisher storage p = $.publishers[signer];
            if (!p.active) revert InvalidSignatures();
            if (p.independent) independent = true;
            previous = signer;
        }
        if (!independent) revert InvalidSignatures();
    }

    function _checkGrid(SurfaceReport calldata r, SurfaceConfig storage cfg) private view {
        // tenors: n ≥ 1 increasing after validAfter, trailing zeros; ATM total variance > 0 and non-decreasing
        uint256 n;
        while (n < 4 && r.tenorTimestamps[n] != 0) ++n;
        if (n == 0 || r.tenorTimestamps[0] <= r.validAfter) revert InvalidSurfaceReport(R_TENORS);
        for (uint256 i; i < 4; ++i) {
            if (i < n) {
                if (r.atmTotalVarianceByTenor[i] == 0) revert InvalidSurfaceReport(R_TENORS);
                if (i > 0) {
                    if (r.tenorTimestamps[i] <= r.tenorTimestamps[i - 1]) revert InvalidSurfaceReport(R_TENORS);
                    if (r.atmTotalVarianceByTenor[i] < r.atmTotalVarianceByTenor[i - 1]) {
                        revert InvalidSurfaceReport(R_TENORS);
                    }
                }
            } else if (r.tenorTimestamps[i] != 0 || r.atmTotalVarianceByTenor[i] != 0) {
                revert InvalidSurfaceReport(R_TENORS);
            }
        }
        // kNodes
        uint256 m = r.kNodes.length;
        if (m == 0 || m > MAX_K_NODES) revert InvalidSurfaceReport(R_KNODES);
        for (uint256 j = 1; j < m; ++j) {
            if (r.kNodes[j] <= r.kNodes[j - 1]) revert InvalidSurfaceReport(R_KNODES);
        }
        // IV bounds vs the product, and every ATM IV inside the report's own bounds
        if (
            r.surfaceMinIvBps < cfg.minIvBps || r.surfaceMaxIvBps > cfg.maxIvBps
                || r.surfaceMinIvBps > r.surfaceMaxIvBps
        ) revert InvalidSurfaceReport(R_IV_BOUNDS);
        for (uint256 i; i < n; ++i) {
            uint256 iv = _iv(r.atmTotalVarianceByTenor[i], r.tenorTimestamps[i], r.validAfter);
            if (iv < r.surfaceMinIvBps * BPS_TO_WAD || iv > r.surfaceMaxIvBps * BPS_TO_WAD) {
                revert InvalidSurfaceReport(R_TENORS);
            }
        }
    }

    /// @dev For each new tenor, compare its ATM IV with the stored surface's ATM IV at the same expiry (linear in
    ///      total variance between stored tenors, the nearest stored tenor's IV outside them).
    function _checkIvMove(SurfaceReport calldata r, SurfaceHeader storage h, uint256 maxMoveBps) private view {
        uint64[4] memory oldTenors = h.tenorTimestamps;
        for (uint256 i; i < 4 && r.tenorTimestamps[i] != 0; ++i) {
            uint64 t = r.tenorTimestamps[i];
            uint256 ivNew = _iv(r.atmTotalVarianceByTenor[i], t, r.validAfter);
            uint256 ivOld = _oldAtmIv(h, oldTenors, t);
            uint256 diff = ivNew > ivOld ? ivNew - ivOld : ivOld - ivNew;
            if (diff * 10_000 > maxMoveBps * ivOld) revert InvalidSurfaceReport(R_IV_MOVE);
        }
    }

    function _oldAtmIv(SurfaceHeader storage h, uint64[4] memory oldTenors, uint64 t) private view returns (uint256) {
        (bool inside, uint256 a, uint256 b) = OptionPricer.findTenors(oldTenors, t);
        if (!inside) {
            uint256 last;
            while (last < 3 && oldTenors[last + 1] != 0) ++last;
            uint256 idx = t < oldTenors[0] ? 0 : last;
            return _iv(h.atmTotalVarianceByTenor[idx], oldTenors[idx], h.validAfter);
        }
        uint256 w = OptionPricer.interpolateTenors(
            h.atmTotalVarianceByTenor[a], h.atmTotalVarianceByTenor[b], oldTenors[a], oldTenors[b], t
        );
        return _iv(w, t, h.validAfter);
    }

    /// @dev Unclamped σ = sqrt(w / T), T from `from` to `tenor`.
    function _iv(uint256 w, uint64 tenor, uint64 from) private pure returns (uint256) {
        return OptionPricer.ivFromTotalVariance(w, tenor, from, 0, type(uint256).max);
    }

    /// @dev EIP-712 struct hash. All members encode to 32-byte words (arrays as the hash of their elements), so the
    ///      encoding is built in three chunks to stay within the stack limit.
    function _structHash(SurfaceReport calldata r) private pure returns (bytes32) {
        bytes memory a = abi.encode(
            REPORT_TYPEHASH,
            r.chainId,
            r.verifyingContract,
            r.productId,
            r.underlying,
            r.settlementAsset,
            r.surfaceSeq,
            r.validAfter
        );
        bytes memory b = abi.encode(
            r.expiresAt,
            r.spotReferenceId,
            r.surfaceRoot,
            keccak256(abi.encode(r.tenorTimestamps)),
            keccak256(abi.encode(r.atmTotalVarianceByTenor)),
            keccak256(abi.encodePacked(r.kNodes)),
            r.surfaceMinIvBps
        );
        bytes memory c = abi.encode(
            r.surfaceMaxIvBps,
            r.confidenceBps,
            r.sourceCount,
            r.liquidityScore,
            r.maxBidAskWidthBps,
            r.lastCalibrationTime,
            r.riskParameterSetId
        );
        return keccak256(bytes.concat(a, b, c));
    }

    function _leafKey(bytes32 productId, uint64 seq, uint8 tenor, uint8 node) private pure returns (bytes32) {
        return keccak256(abi.encode(productId, seq, tenor, node));
    }

    function _s() private pure returns (SurfaceStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
