// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";

/// @notice TESTING.md §6: `submitReport` at quorum 2 with 32 nodes × 4 tenors (128 leaves), and proving the 4 leaves a
///         typical mint needs (Merkle depth 7). Recorded, with a sanity ceiling.
contract VolSurfaceOracleGasTest is RiskFixture {
    IVolSurfaceOracle.SurfaceReport internal report;
    bytes[] internal sigs;
    IVolSurfaceOracle.NodeProof[] internal proofs;

    function setUp() public {
        _deployRisk();
        _setSpot(ethUsdc, 4000e18);
        uint256[] memory k = new uint256[](32);
        uint256[] memory iv = new uint256[](32);
        for (uint256 j; j < 32; ++j) {
            k[j] = 2000e18 + j * 200e18; // 2,000 .. 8,200
            iv[j] = 0.5e18 + j * 0.005e18;
        }
        uint64[] memory tenors = new uint64[](4);
        (tenors[0], tenors[1], tenors[2], tenors[3]) = (T0 + 7 days, EXP30, T0 + 60 days, T0 + 90 days);
        (IVolSurfaceOracle.SurfaceReport memory r, bytes[] memory s, IVolSurfaceOracle.NodeProof[] memory n) =
            _buildSurface(ethUsdc, 4000e18, k, iv, tenors);
        report = r;
        for (uint256 i; i < s.length; ++i) {
            sigs.push(s[i]);
        }
        // the four leaves around a 4,500 strike at the 30- and 60-day tenors
        uint256[4] memory pick = [uint256(32 + 12), 32 + 13, 64 + 12, 64 + 13];
        for (uint256 i; i < 4; ++i) {
            proofs.push(n[pick[i]]);
        }
    }

    function test_gas_submitReport32x4() public {
        uint256 g = gasleft();
        surface.submitReport(report, sigs);
        uint256 used = g - gasleft();
        console.log("submitReport, quorum 2, 32 nodes x 4 tenors:", used);
        assertLt(used, 2_000_000);

        g = gasleft();
        surface.proveNodes(proofs);
        used = g - gasleft();
        console.log("proveNodes, 4 leaves of 128:", used);
        assertLt(used, 1_000_000);
    }
}
