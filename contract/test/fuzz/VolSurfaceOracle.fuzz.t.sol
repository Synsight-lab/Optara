// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurfaceFixture} from "../utils/SurfaceFixture.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {InvalidSurfaceReport} from "../../src/libraries/Errors.sol";

/// @notice Fuzz tests for VolSurfaceOracle: the signature covers every field (VOL-005), leaves prove and cache
///         exactly (VOL-009, INV-19), the IV-move limit decides acceptance (VOL-007).
contract VolSurfaceOracleFuzzTest is SurfaceFixture {
    function setUp() public {
        _deploySurface();
    }

    /// @dev Changing any one of the 21 signed fields changes the EIP-712 digest.
    function testFuzz_VOL005_everyFieldIsSigned(uint8 field, uint256 noise) public view {
        field = uint8(bound(field, 0, 20));
        noise = bound(noise, 1, type(uint32).max);
        IVolSurfaceOracle.SurfaceReport memory r = _report(1, T0, _grid(T0, 0.6e18));
        bytes32 before = oracle.reportDigest(r);
        _tamper(r, field, noise);
        assertTrue(oracle.reportDigest(r) != before);
    }

    function _tamper(IVolSurfaceOracle.SurfaceReport memory r, uint8 f, uint256 x) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        if (f == 0) r.chainId += x;
        else if (f == 1) r.verifyingContract = address(uint160(r.verifyingContract) ^ uint160(x));
        else if (f == 2) r.productId ^= bytes32(x);
        else if (f == 3) r.underlying = address(uint160(r.underlying) ^ uint160(x));
        else if (f == 4) r.settlementAsset = address(uint160(r.settlementAsset) ^ uint160(x));
        else if (f == 5) r.surfaceSeq += uint64(x);
        else if (f == 6) r.validAfter += uint64(x);
        else if (f == 7) r.expiresAt += uint64(x);
        else if (f == 8) r.spotReferenceId ^= bytes32(x);
        else if (f == 9) r.surfaceRoot ^= bytes32(x);
        else if (f == 10) r.tenorTimestamps[x % 4] += uint64(x);
        else if (f == 11) r.atmTotalVarianceByTenor[x % 4] += x;
        else if (f == 12) r.kNodes[x % r.kNodes.length] += int256(x);
        else if (f == 13) r.surfaceMinIvBps ^= uint32(x);
        else if (f == 14) r.surfaceMaxIvBps ^= uint32(x);
        else if (f == 15) r.confidenceBps ^= uint32(x);
        else if (f == 16) r.sourceCount ^= uint16(x % 65_535 + 1);
        else if (f == 17) r.liquidityScore ^= uint32(x);
        else if (f == 18) r.maxBidAskWidthBps ^= uint32(x);
        else if (f == 19) r.lastCalibrationTime += uint64(x);
        else r.riskParameterSetId ^= bytes32(x);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev INV-19: any leaf of an accepted report proves and caches exactly its value; a different value fails.
    function testFuzz_INV19_leavesProveExactly(uint256 baseIv, uint8 i, uint8 j, uint256 delta) public {
        baseIv = bound(baseIv, 0.15e18, 1.5e18);
        i = uint8(bound(i, 0, N_TENORS - 1));
        j = uint8(bound(j, 0, N_NODES - 1));
        Grid memory g = _grid(T0, baseIv);
        _submit(_report(1, T0, g));

        IVolSurfaceOracle.NodeProof[] memory n = new IVolSurfaceOracle.NodeProof[](1);
        n[0] = _nodeProof(1, g, i, j);
        n[0].totalVarianceWad += bound(delta, 1, 1e18);
        vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 10));
        oracle.proveNodes(n);

        n[0] = _nodeProof(1, g, i, j);
        oracle.proveNodes(n);
        (bool proven, uint256 w) = oracle.nodeValue(ethUsdc, i, j);
        assertTrue(proven);
        assertEq(w, g.w[uint256(i) * N_NODES + j]);
    }

    /// @dev VOL-007: a same-shape surface scaled by `factor` is accepted iff the ATM IV moved ≤ 20%.
    function testFuzz_VOL007_ivMoveBoundary(uint256 newIv) public {
        uint256 oldIv = 0.6e18;
        newIv = bound(newIv, 0.3e18, 0.9e18);
        _submit(_report(1, T0, _grid(T0, oldIv)));
        IVolSurfaceOracle.SurfaceReport memory r = _report(2, T0, _grid(T0, newIv));
        bytes[] memory sigs = _sigs(r, _keysAB());
        uint256 diff = newIv > oldIv ? newIv - oldIv : oldIv - newIv;
        // ATM node has k = 0, so ATM IV == base IV up to fixed-point rounding (well below 1 bps)
        bool clearlyInside = diff * 10_000 < 1999 * oldIv;
        bool clearlyOutside = diff * 10_000 > 2001 * oldIv;
        if (clearlyOutside) vm.expectRevert(abi.encodeWithSelector(InvalidSurfaceReport.selector, 8));
        if (clearlyInside || clearlyOutside) oracle.submitReport(r, sigs);
        if (clearlyInside) assertEq(oracle.header(ethUsdc).surfaceSeq, 2);
    }
}
