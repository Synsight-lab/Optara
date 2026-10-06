// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";
import {MathHarness} from "../harness/MathHarness.sol";

/// @notice Differential tests: Solidity vs the independent Python reference model (reference/pm_model.py, with
///         math.erfc as the CDF). PRC-001 (CDF ≤ 1e-7), PRC-002 (price ≤ (F + K) × 1e-7, INV-39), VOL-010 (IV).
/// @dev Static vectors come from reference/gen_vectors.py; FFI fuzz tests call reference/ffi.py per run.
contract OptionPricerDiffTest is Test {
    MathHarness internal h;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant CDF_TOL = 1e11; // 1e-7

    function setUp() public {
        h = new MathHarness();
    }

    // ------------------------------------------------------------------ static vectors

    function test_PRC001_cdfVectors() public view {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("../reference/vectors/pricing.json");
        int256[] memory x = vm.parseJsonIntArray(json, ".cdf.x");
        uint256[] memory n = vm.parseJsonUintArray(json, ".cdf.n");
        assertEq(x.length, n.length);
        for (uint256 i; i < x.length; ++i) {
            assertApproxEqAbs(h.normCdf(x[i]), n[i], CDF_TOL, vm.toString(x[i]));
        }
    }

    function test_PRC002_black76Vectors() public view {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("../reference/vectors/pricing.json");
        bool[] memory isCall = vm.parseJsonBoolArray(json, ".black76.isCall");
        uint256[] memory f = vm.parseJsonUintArray(json, ".black76.F");
        uint256[] memory k = vm.parseJsonUintArray(json, ".black76.K");
        uint256[] memory s = vm.parseJsonUintArray(json, ".black76.sigma");
        uint256[] memory t = vm.parseJsonUintArray(json, ".black76.T");
        uint256[] memory p = vm.parseJsonUintArray(json, ".black76.price");
        assertGt(p.length, 600);
        for (uint256 i; i < p.length; ++i) {
            assertApproxEqAbs(h.black76(isCall[i], f[i], k[i], s[i], t[i]), p[i], (f[i] + k[i]) / 1e7, vm.toString(i));
        }
    }

    // ------------------------------------------------------------------ FFI fuzz

    function _ffi(string[] memory args) internal returns (uint256) {
        string[] memory cmd = new string[](args.length + 2);
        cmd[0] = "python3";
        cmd[1] = "../reference/ffi.py";
        for (uint256 i; i < args.length; ++i) {
            cmd[i + 2] = args[i];
        }
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return abi.decode(vm.ffi(cmd), (uint256));
    }

    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_PRC001_cdfMatchesReference(int256 x) public {
        x = bound(x, -40e18, 40e18);
        string[] memory a = new string[](2);
        (a[0], a[1]) = ("cdf", vm.toString(x));
        assertApproxEqAbs(h.normCdf(x), _ffi(a), CDF_TOL);
    }

    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_PRC002_black76MatchesReference(bool isCall, uint256 f, uint256 k, uint256 sigma, uint256 t)
        public
    {
        f = bound(f, 1e15, 1e25);
        k = bound(k, 1e15, 1e25);
        sigma = bound(sigma, 0.01e18, 5e18);
        t = bound(t, WAD / FixedPoint.YEAR, 2 * WAD);
        string[] memory a = new string[](6);
        (a[0], a[1], a[2], a[3], a[4], a[5]) =
        ("black76", isCall ? "1" : "0", vm.toString(f), vm.toString(k), vm.toString(sigma), vm.toString(t));
        assertApproxEqAbs(h.black76(isCall, f, k, sigma, t), _ffi(a), (f + k) / 1e7);
    }

    /// @dev Random 3-tenor × 4-node grid, calendar-consistent (w non-decreasing in tenor). The Solidity side
    ///      selects tenors and nodes with findTenors / findNodes, as the risk manager will.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_VOL010_surfaceIvMatchesReference(uint256 seed, uint256 strike, uint256 spot, uint256 expiryPick)
        public
    {
        uint64 report = 1_800_000_000;
        uint64[4] memory tenors = [report + 1 days, report + 30 days, report + 120 days, 0];
        int256[] memory kNodes = new int256[](4);
        (kNodes[0], kNodes[1], kNodes[2], kNodes[3]) = (-1e18, -0.2e18, 0.3e18, 1e18);

        // w[i][j] = σ_ij² × T_i with σ_ij in [20%, 150%], plus monotone-in-tenor enforcement
        uint256[12] memory w;
        for (uint256 i; i < 3; ++i) {
            uint256 ti = uint256(tenors[i] - report) * WAD / FixedPoint.YEAR;
            for (uint256 j; j < 4; ++j) {
                uint256 sig = 0.2e18 + uint256(keccak256(abi.encode(seed, i, j))) % 1.3e18;
                uint256 v = sig * sig / WAD * ti / WAD;
                if (i > 0 && v < w[(i - 1) * 4 + j]) v = w[(i - 1) * 4 + j];
                w[i * 4 + j] = v;
            }
        }
        spot = bound(spot, 100e18, 100_000e18);
        strike = bound(strike, spot / 4, spot * 4);
        uint64 expiry = uint64(bound(expiryPick, tenors[0], tenors[2]));

        uint256 sol = _solidityIv(strike, spot, expiry, report, tenors, kNodes, w);

        string[] memory a = new string[](10);
        a[0] = "iv";
        a[1] = vm.toString(strike);
        a[2] = vm.toString(spot);
        a[3] = vm.toString(uint256(expiry));
        a[4] = vm.toString(uint256(report));
        a[5] = string.concat(
            vm.toString(uint256(tenors[0])), ",", vm.toString(uint256(tenors[1])), ",", vm.toString(uint256(tenors[2]))
        );
        a[6] = string.concat(
            vm.toString(kNodes[0]),
            ",",
            vm.toString(kNodes[1]),
            ",",
            vm.toString(kNodes[2]),
            ",",
            vm.toString(kNodes[3])
        );
        string memory flat = vm.toString(w[0]);
        for (uint256 i = 1; i < 12; ++i) {
            flat = string.concat(flat, ",", vm.toString(w[i]));
        }
        a[7] = flat;
        a[8] = vm.toString(uint256(0.1e18));
        a[9] = vm.toString(uint256(5e18));
        // IV is computed with lnWad, two linear interpolations and one sqrt: 1e-9 relative is far inside the budget
        assertApproxEqRel(sol, _ffi(a), 1e9);
    }

    function _solidityIv(
        uint256 strike,
        uint256 spot,
        uint64 expiry,
        uint64 report,
        uint64[4] memory tenors,
        int256[] memory kNodes,
        uint256[12] memory w
    ) internal view returns (uint256) {
        (bool ok, uint256 ta, uint256 tb) = h.findTenors(tenors, expiry);
        assertTrue(ok);
        int256 k = h.logMoneyness(strike, spot);
        (uint256 lo, uint256 hi) = h.findNodes(kNodes, k);
        OptionPricer.IvQuery memory q = OptionPricer.IvQuery({
            k: k,
            kLo: kNodes[lo],
            kHi: kNodes[hi],
            wALo: w[ta * 4 + lo],
            wAHi: w[ta * 4 + hi],
            wBLo: w[tb * 4 + lo],
            wBHi: w[tb * 4 + hi],
            tenorA: tenors[ta],
            tenorB: tenors[tb],
            expiry: expiry,
            reportTime: report,
            minIv: 0.1e18,
            maxIv: 5e18
        });
        return h.surfaceIv(q);
    }
}
