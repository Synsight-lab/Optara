// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {MerkleHelper} from "../../test/utils/MerkleHelper.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {MockPyth} from "../../test/mocks/MockPyth.sol";

/// @title LocalMarketData
/// @notice What the spot updater and the surface publishers do (INDEXER_AND_KEEPERS.md §4–§5), done in-script for the
///         local stack: a Pyth blob plus a flat-IV surface report over fixed strike nodes, signed by two publishers,
///         with proofs for every leaf, packed as one OracleUpdate.
abstract contract LocalMarketData is Script {
    struct Market {
        address pyth; // MockPyth locally (spot blobs are built here); the real Pyth on a fork (blobs come from Hermes)
        IVolSurfaceOracle surface;
        bytes32 productId;
        address underlying;
        address asset;
        bytes32 pythFeed;
        uint256 keyA; // publisher A (independent)
        uint256 keyB; // publisher B
    }

    /// @dev Strike nodes as fractions of spot: at 4,000 these are 2,500 / 3,500 / 4,000 / 4,500 / 5,000 / 6,500.
    function _nodeRatios() internal pure returns (uint256[6] memory) {
        return [uint256(0.625e18), 0.875e18, 1e18, 1.125e18, 1.25e18, 1.625e18];
    }

    /// @dev Two weekly expiries: Fridays 08:00 UTC, the first more than a day out.
    function _weeklyExpiries() internal view returns (uint64[] memory e) {
        uint256 day = (block.timestamp + 2 days) / 1 days;
        uint256 dow = (day + 4) % 7; // 0 = Sunday (1970-01-01 was a Thursday)
        uint256 friday = (day + (12 - dow) % 7) * 1 days + 8 hours;
        e = new uint64[](2);
        // forge-lint: disable-next-line(unsafe-typecast)
        e[0] = uint64(friday); // a timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        e[1] = uint64(friday + 7 days);
    }

    /// @dev A MockPyth blob at `price` plus a signed flat-`iv` surface.
    function _oracleUpdate(Market memory m, uint256 price, uint256 iv, uint64[] memory tenors, uint64 seq)
        internal
        view
        returns (OracleUpdate memory u)
    {
        bytes[] memory spot = new bytes[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        spot[0] = MockPyth(m.pyth).encode(m.pythFeed, int64(int256(price / 1e10)), -8, block.timestamp);
        u = _surfaceUpdate(m, spot, price, iv, tenors, seq);
    }

    /// @dev `spotUpdates` (possibly empty) for `m.productId` plus a signed flat-`iv` surface centered on `price`.
    function _surfaceUpdate(
        Market memory m,
        bytes[] memory spotUpdates,
        uint256 price,
        uint256 iv,
        uint64[] memory tenors,
        uint64 seq
    ) internal view returns (OracleUpdate memory u) {
        u.spotUpdates = spotUpdates;
        u.spotProductIds = new bytes32[](spotUpdates.length == 0 ? 0 : 1);
        if (spotUpdates.length != 0) u.spotProductIds[0] = m.productId;
        u.reports = new IVolSurfaceOracle.SurfaceReport[](1);
        u.reportSignatures = new bytes[][](1);
        bytes32[] memory leaves;
        uint256[] memory w;
        (u.reports[0], leaves, w) = _report(m, price, iv, tenors, seq);
        u.reportSignatures[0] = _sign(m, u.reports[0]);
        u.nodes = _proofs(m.productId, seq, w, leaves);
    }

    function _report(Market memory m, uint256 price, uint256 iv, uint64[] memory tenors, uint64 seq)
        internal
        view
        returns (IVolSurfaceOracle.SurfaceReport memory r, bytes32[] memory leaves, uint256[] memory w)
    {
        uint256[6] memory ratios = _nodeRatios();
        r.chainId = block.chainid;
        r.verifyingContract = address(m.surface);
        r.productId = m.productId;
        r.underlying = m.underlying;
        r.settlementAsset = m.asset;
        r.surfaceSeq = seq;
        r.validAfter = uint64(block.timestamp);
        r.expiresAt = r.validAfter + 900;
        r.kNodes = new int256[](6);
        for (uint256 j; j < 6; ++j) {
            r.kNodes[j] = OptionPricer.logMoneyness(price * ratios[j] / 1e18, price);
        }
        leaves = new bytes32[](tenors.length * 6);
        w = new uint256[](tenors.length * 6);
        for (uint256 i; i < tenors.length; ++i) {
            r.tenorTimestamps[i] = tenors[i];
            uint256 t = uint256(tenors[i] - r.validAfter) * 1e18 / FixedPoint.YEAR;
            uint256 v = iv * iv / 1e18 * t / 1e18;
            r.atmTotalVarianceByTenor[i] = v;
            for (uint256 j; j < 6; ++j) {
                w[i * 6 + j] = v;
                // forge-lint: disable-next-line(unsafe-typecast)
                leaves[i * 6 + j] = keccak256(abi.encode(m.productId, seq, uint8(i), uint8(j), v));
            }
        }
        r.surfaceMinIvBps = 1000;
        r.surfaceMaxIvBps = 50_000;
        r.confidenceBps = 100;
        r.sourceCount = 3;
        r.surfaceRoot = MerkleHelper.root(leaves);
    }

    function _sign(Market memory m, IVolSurfaceOracle.SurfaceReport memory r)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = m.surface.reportDigest(r);
        (uint8 va, bytes32 ra, bytes32 sa) = vm.sign(m.keyA, digest);
        (uint8 vb, bytes32 rb, bytes32 sb) = vm.sign(m.keyB, digest);
        (bytes memory a, bytes memory b) = (abi.encodePacked(ra, sa, va), abi.encodePacked(rb, sb, vb));
        sigs = new bytes[](2);
        (sigs[0], sigs[1]) = vm.addr(m.keyA) < vm.addr(m.keyB) ? (a, b) : (b, a);
    }

    function _proofs(bytes32 productId, uint64 seq, uint256[] memory w, bytes32[] memory leaves)
        internal
        pure
        returns (IVolSurfaceOracle.NodeProof[] memory n)
    {
        n = new IVolSurfaceOracle.NodeProof[](w.length);
        for (uint256 i; i < w.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 tenorIndex = uint8(i / 6); // < 4 tenors
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 nodeIndex = uint8(i % 6); // 6 nodes
            n[i] =
                IVolSurfaceOracle.NodeProof(productId, seq, tenorIndex, nodeIndex, w[i], MerkleHelper.proof(leaves, i));
        }
    }
}
