// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurfaceFixture} from "../utils/SurfaceFixture.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";

/// @notice The EIP-712 encoding of SurfaceReport is checked against an independent implementation: the report is
///         written as JSON typed data and signed by `cast wallet sign --data` (alloy). The oracle must accept those
///         signatures, which only happens if its digest equals alloy's (VOL-001, VOL-005).
contract VolSurfaceOracleDiffTest is SurfaceFixture {
    function setUp() public {
        _deploySurface();
    }

    function test_VOL001_castSignedReportAccepted() public {
        Grid memory g = _grid(T0, 0.6e18);
        IVolSurfaceOracle.SurfaceReport memory r = _report(1, T0, g);
        bytes[] memory sigs = new bytes[](2);
        (bytes memory sa, bytes memory sb) = (_castSign(r, keyA), _castSign(r, keyB));
        (sigs[0], sigs[1]) = pubA < pubB ? (sa, sb) : (sb, sa);
        oracle.submitReport(r, sigs);
        assertEq(oracle.header(ethUsdc).surfaceSeq, 1);
    }

    function test_VOL001_digestMatchesCast() public {
        Grid memory g = _grid(T0, 0.6e18);
        g.kNodes[0] = -1.5e18; // negative WAD node, encoded as a signed integer
        IVolSurfaceOracle.SurfaceReport memory r = _report(7, T0, g);
        bytes memory sig = _castSign(r, keyC);
        (bytes32 rr, bytes32 s, uint8 v) = _split(sig);
        assertEq(ecrecover(oracle.reportDigest(r), v, rr, s), pubC);
    }

    // ------------------------------------------------------------------ JSON typed data

    function _castSign(IVolSurfaceOracle.SurfaceReport memory r, uint256 key) internal returns (bytes memory) {
        string[] memory cmd = new string[](7);
        cmd[0] = "cast";
        cmd[1] = "wallet";
        cmd[2] = "sign";
        cmd[3] = "--private-key";
        cmd[4] = vm.toString(bytes32(key));
        cmd[5] = "--data";
        cmd[6] = _json(r);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.ffi(cmd);
    }

    function _json(IVolSurfaceOracle.SurfaceReport memory r) internal view returns (string memory) {
        string memory types = string.concat(
            '{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"SurfaceReport":[{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"},',
            '{"name":"productId","type":"bytes32"},{"name":"underlying","type":"address"},',
            '{"name":"settlementAsset","type":"address"},{"name":"surfaceSeq","type":"uint64"},',
            '{"name":"validAfter","type":"uint64"},{"name":"expiresAt","type":"uint64"},',
            '{"name":"spotReferenceId","type":"bytes32"},{"name":"surfaceRoot","type":"bytes32"},',
            '{"name":"tenorTimestamps","type":"uint64[4]"},{"name":"atmTotalVarianceByTenor","type":"uint256[4]"},',
            '{"name":"kNodes","type":"int256[]"},{"name":"surfaceMinIvBps","type":"uint32"},',
            '{"name":"surfaceMaxIvBps","type":"uint32"},{"name":"confidenceBps","type":"uint32"},',
            '{"name":"sourceCount","type":"uint16"},{"name":"liquidityScore","type":"uint32"},',
            '{"name":"maxBidAskWidthBps","type":"uint32"},{"name":"lastCalibrationTime","type":"uint64"},',
            '{"name":"riskParameterSetId","type":"bytes32"}]}'
        );
        string memory domain = string.concat(
            '{"name":"Optara VolSurfaceOracle","version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(oracle)),
            '"}'
        );
        return string.concat(
            '{"types":', types, ',"primaryType":"SurfaceReport","domain":', domain, ',"message":', _message(r), "}"
        );
    }

    function _message(IVolSurfaceOracle.SurfaceReport memory r) internal pure returns (string memory) {
        string memory a = string.concat(
            '{"chainId":"',
            vm.toString(r.chainId),
            '","verifyingContract":"',
            vm.toString(r.verifyingContract),
            '","productId":"',
            vm.toString(r.productId),
            '","underlying":"',
            vm.toString(r.underlying),
            '","settlementAsset":"',
            vm.toString(r.settlementAsset),
            '","surfaceSeq":"',
            vm.toString(uint256(r.surfaceSeq)),
            '","validAfter":"',
            vm.toString(uint256(r.validAfter)),
            '","expiresAt":"',
            vm.toString(uint256(r.expiresAt))
        );
        string memory b = string.concat(
            '","spotReferenceId":"',
            vm.toString(r.spotReferenceId),
            '","surfaceRoot":"',
            vm.toString(r.surfaceRoot),
            '","tenorTimestamps":',
            _arr4(r.tenorTimestamps),
            ',"atmTotalVarianceByTenor":',
            _arr4u(r.atmTotalVarianceByTenor),
            ',"kNodes":',
            _arrInt(r.kNodes)
        );
        string memory c = string.concat(
            ',"surfaceMinIvBps":"',
            vm.toString(uint256(r.surfaceMinIvBps)),
            '","surfaceMaxIvBps":"',
            vm.toString(uint256(r.surfaceMaxIvBps)),
            '","confidenceBps":"',
            vm.toString(uint256(r.confidenceBps)),
            '","sourceCount":"',
            vm.toString(uint256(r.sourceCount)),
            '","liquidityScore":"',
            vm.toString(uint256(r.liquidityScore)),
            '","maxBidAskWidthBps":"',
            vm.toString(uint256(r.maxBidAskWidthBps)),
            '","lastCalibrationTime":"',
            vm.toString(uint256(r.lastCalibrationTime)),
            '","riskParameterSetId":"',
            vm.toString(r.riskParameterSetId),
            '"}'
        );
        return string.concat(a, b, c);
    }

    function _arr4(uint64[4] memory x) internal pure returns (string memory) {
        return string.concat(
            '["',
            vm.toString(uint256(x[0])),
            '","',
            vm.toString(uint256(x[1])),
            '","',
            vm.toString(uint256(x[2])),
            '","',
            vm.toString(uint256(x[3])),
            '"]'
        );
    }

    function _arr4u(uint256[4] memory x) internal pure returns (string memory) {
        return string.concat(
            '["', vm.toString(x[0]), '","', vm.toString(x[1]), '","', vm.toString(x[2]), '","', vm.toString(x[3]), '"]'
        );
    }

    function _arrInt(int256[] memory x) internal pure returns (string memory s) {
        s = "[";
        for (uint256 i; i < x.length; ++i) {
            s = string.concat(s, i == 0 ? '"' : ',"', vm.toString(x[i]), '"');
        }
        s = string.concat(s, "]");
    }

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}
