// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SeriesFixture} from "./SeriesFixture.sol";
import {MerkleHelper} from "./MerkleHelper.sol";
import {VolSurfaceOracle} from "../../src/oracle/VolSurfaceOracle.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";

/// @notice Governance + series modules + VolSurfaceOracle (quorum 2) with three publishers: A and C independent,
///         B a market maker. Builds signed reports over a 3-tenor × 5-node smile.
abstract contract SurfaceFixture is SeriesFixture {
    VolSurfaceOracle internal oracle;
    uint64 internal constant T0 = 1_791_244_800;

    address internal pubA;
    uint256 internal keyA;
    address internal pubB; // market maker
    uint256 internal keyB;
    address internal pubC;
    uint256 internal keyC;

    uint256 internal constant N_TENORS = 3;
    uint256 internal constant N_NODES = 5;

    struct Grid {
        uint64[4] tenors;
        int256[] kNodes;
        uint256[] w; // row-major [tenor][node]
    }

    function _deploySurface() internal {
        vm.warp(T0);
        _deployGovernanceCore();
        _deploySeriesModules();
        oracle = VolSurfaceOracle(
            upgradeAdmin.deployProxy(
                address(new VolSurfaceOracle()),
                abi.encodeCall(
                    VolSurfaceOracle.initialize,
                    (IProtocolControl(address(pc)), IOptionSeriesRegistry(address(registry)), 2)
                )
            )
        );
        _handOver();
        _configureSeries();
        (pubA, keyA) = makeAddrAndKey("publisherA");
        (pubB, keyB) = makeAddrAndKey("publisherB");
        (pubC, keyC) = makeAddrAndKey("publisherC");
        vm.startPrank(governance);
        oracle.setSurfaceConfig(ethUsdc, _surfaceConfig());
        oracle.addPublisher(pubA, true);
        oracle.addPublisher(pubB, false);
        oracle.addPublisher(pubC, true);
        vm.stopPrank();
    }

    /// @dev PARAMETERS.md §4 defaults; ETH IV floor 10%, cap 500%.
    function _surfaceConfig() internal pure returns (IVolSurfaceOracle.SurfaceConfig memory) {
        return IVolSurfaceOracle.SurfaceConfig({
            maxReportLifetime: 900,
            maxIvMoveBps: 2000,
            maxConfidenceBps: 1000,
            minIvBps: 1000,
            maxIvBps: 50_000,
            surfaceStaleAfter: 300,
            maxSurfaceStale: 21_600,
            staleIvPenaltyBpsPerHour: 1000,
            maxLongTimeValueStale: 1800
        });
    }

    /// @dev Smile σ(k) = base + 0.2·|k| (WAD), flat across tenors; w = σ²·T measured from `validAfter`.
    function _grid(uint64 validAfter, uint256 baseIv) internal pure returns (Grid memory g) {
        g.tenors = [validAfter + 7 days, validAfter + 30 days, validAfter + 90 days, uint64(0)];
        g.kNodes = new int256[](N_NODES);
        (g.kNodes[0], g.kNodes[1], g.kNodes[2], g.kNodes[3], g.kNodes[4]) = (-1e18, -0.3e18, 0, 0.3e18, 1e18);
        g.w = new uint256[](N_TENORS * N_NODES);
        for (uint256 i; i < N_TENORS; ++i) {
            uint256 t = uint256(g.tenors[i] - validAfter) * 1e18 / FixedPoint.YEAR;
            for (uint256 j; j < N_NODES; ++j) {
                int256 k = g.kNodes[j];
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 sigma = baseIv + 0.2e18 * uint256(k < 0 ? -k : k) / 1e18;
                g.w[i * N_NODES + j] = sigma * sigma / 1e18 * t / 1e18;
            }
        }
    }

    function _leaves(bytes32 productId, uint64 seq, Grid memory g) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](N_TENORS * N_NODES);
        for (uint256 i; i < N_TENORS; ++i) {
            for (uint256 j; j < N_NODES; ++j) {
                // forge-lint: disable-next-line(unsafe-typecast)
                l[i * N_NODES + j] = keccak256(abi.encode(productId, seq, uint8(i), uint8(j), g.w[i * N_NODES + j]));
            }
        }
    }

    function _report(uint64 seq, uint64 validAfter, Grid memory g)
        internal
        view
        returns (IVolSurfaceOracle.SurfaceReport memory r)
    {
        r.chainId = block.chainid;
        r.verifyingContract = address(oracle);
        r.productId = ethUsdc;
        r.underlying = weth;
        r.settlementAsset = address(usdc);
        r.surfaceSeq = seq;
        r.validAfter = validAfter;
        r.expiresAt = validAfter + 900;
        r.spotReferenceId = keccak256("pyth ETH/USD");
        r.surfaceRoot = MerkleHelper.root(_leaves(ethUsdc, seq, g));
        r.tenorTimestamps = g.tenors;
        for (uint256 i; i < N_TENORS; ++i) {
            r.atmTotalVarianceByTenor[i] = g.w[i * N_NODES + 2]; // node 2 is k = 0
        }
        r.kNodes = g.kNodes;
        r.surfaceMinIvBps = 1000;
        r.surfaceMaxIvBps = 30_000;
        r.confidenceBps = 300;
        r.sourceCount = 3;
        r.liquidityScore = 80;
        r.maxBidAskWidthBps = 500;
        r.lastCalibrationTime = validAfter;
        r.riskParameterSetId = RISK_SET;
    }

    function _sign(IVolSurfaceOracle.SurfaceReport memory r, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, oracle.reportDigest(r));
        return abi.encodePacked(rr, s, v);
    }

    /// @dev Signatures from the given keys, sorted by signer address (as the oracle requires).
    function _sigs(IVolSurfaceOracle.SurfaceReport memory r, uint256[] memory keys)
        internal
        view
        returns (bytes[] memory sigs)
    {
        uint256 n = keys.length;
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        sigs = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            sigs[i] = _sign(r, keys[i]);
        }
    }

    function _keysAB() internal view returns (uint256[] memory k) {
        k = new uint256[](2);
        (k[0], k[1]) = (keyA, keyB);
    }

    function _submit(IVolSurfaceOracle.SurfaceReport memory r) internal {
        oracle.submitReport(r, _sigs(r, _keysAB()));
    }

    function _nodeProof(uint64 seq, Grid memory g, uint256 i, uint256 j)
        internal
        view
        returns (IVolSurfaceOracle.NodeProof memory n)
    {
        n.productId = ethUsdc;
        n.surfaceSeq = seq;
        // forge-lint: disable-next-line(unsafe-typecast)
        (n.tenorIndex, n.nodeIndex) = (uint8(i), uint8(j));
        n.totalVarianceWad = g.w[i * N_NODES + j];
        n.proof = MerkleHelper.proof(_leaves(ethUsdc, seq, g), i * N_NODES + j);
    }
}
