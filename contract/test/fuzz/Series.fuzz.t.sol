// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SeriesFixture} from "../utils/SeriesFixture.sol";
import {SeriesNaming} from "../../src/series/SeriesNaming.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {OptionType, SeriesParams, SeriesTerms} from "../../src/libraries/OptaraTypes.sol";
import {InvalidSeriesParams} from "../../src/libraries/Errors.sol";

/// @notice Fuzz tests for series creation and naming (SER-001, SER-003, SER-006).
contract SeriesFuzzTest is SeriesFixture {
    uint64 internal constant NOW = 1_791_244_800;

    function setUp() public {
        vm.warp(NOW);
        _deploySeries();
    }

    // ------------------------------------------------------------------ naming

    function testFuzz_formatWadRoundTrips(uint256 x) public pure {
        x = bound(x, 0, 1e36);
        assertEq(_parseWad(SeriesNaming.formatWad(x)), x);
    }

    function testFuzz_formatWadHasNoTrailingZeros(uint256 x) public pure {
        x = bound(x, 1, 1e36);
        bytes memory s = bytes(SeriesNaming.formatWad(x));
        bool hasDot;
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == ".") hasDot = true;
        }
        if (hasDot) assertTrue(s[s.length - 1] != "0" && s[s.length - 1] != ".");
    }

    /// @dev The date in the symbol matches an independent days-to-civil conversion (H. Hinnant's algorithm).
    function testFuzz_symbolDate(uint64 expiry) public pure {
        expiry = uint64(bound(expiry, 0, 4_102_444_800)); // up to 2100-01-01
        (uint256 y, uint256 m, uint256 d) = _civil(expiry / 86_400);
        string memory sym = SeriesNaming.symbol("ETH", "USDC", OptionType.PUT, 4500e18, expiry);
        string memory expected = string.concat("oETH-USDC-4500P-", _two(y % 100), _two(m), _two(d));
        assertEq(sym, expected);
    }

    // ------------------------------------------------------------------ creation within / outside bounds

    function testFuzz_SER003_boundsDecideSuccess(uint256 strike, uint256 cs, uint64 dt, bool isCall) public {
        strike = bound(strike, 1, 2_000_000e18);
        cs = bound(cs, 1, 200e18);
        dt = uint64(bound(dt, 0, 500 days));
        SeriesParams memory p = _params(isCall ? OptionType.CALL : OptionType.PUT, strike, NOW + dt);
        p.contractSizeWad = cs;

        uint8 reason;
        if (strike < 100e18 || strike > 1_000_000e18) reason = 1;
        else if (cs < 0.001e18 || cs > 100e18) reason = 2;
        else if (dt < 1 hours || dt > 400 days) reason = 3;

        vm.prank(seriesCreator);
        if (reason != 0) {
            vm.expectRevert(abi.encodeWithSelector(InvalidSeriesParams.selector, reason));
            registry.createSeries(p);
        } else {
            bytes32 id = registry.createSeries(p);
            SeriesTerms memory t = registry.getSeries(id);
            assertEq(t.strikeWad, strike);
            assertEq(t.contractSizeWad, cs);
            assertEq(t.expiry, NOW + dt);
            assertEq(ExternalOptionWrapper(t.wrapper).seriesId(), id);
        }
    }

    function testFuzz_SER006_distinctTermsGiveDistinctIds(
        uint256 strikeA,
        uint256 strikeB,
        uint64 expA,
        uint64 expB,
        bool callA,
        bool callB
    ) public view {
        SeriesParams memory a = _params(callA ? OptionType.CALL : OptionType.PUT, strikeA, expA);
        SeriesParams memory b = _params(callB ? OptionType.CALL : OptionType.PUT, strikeB, expB);
        bool same = strikeA == strikeB && expA == expB && callA == callB;
        assertEq(registry.computeSeriesId(a) == registry.computeSeriesId(b), same);
    }

    // ------------------------------------------------------------------ helpers

    function _parseWad(string memory s) internal pure returns (uint256 v) {
        bytes memory b = bytes(s);
        uint256 frac;
        uint256 fracDigits;
        bool dot;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == ".") {
                dot = true;
                continue;
            }
            uint256 digit = uint8(b[i]) - 48;
            if (dot) {
                frac = frac * 10 + digit;
                ++fracDigits;
            } else {
                v = v * 10 + digit;
            }
        }
        v = v * 1e18 + frac * 10 ** (18 - fracDigits);
    }

    function _civil(uint256 days_) internal pure returns (uint256 y, uint256 m, uint256 d) {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 z = int256(days_) + 719_468; // days_ < 2^64
        int256 era = (z >= 0 ? z : z - 146_096) / 146_097;
        int256 doe = z - era * 146_097;
        int256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        int256 yy = yoe + era * 400;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        int256 mp = (5 * doy + 2) / 153;
        int256 dd = doy - (153 * mp + 2) / 5 + 1;
        int256 mm = mp < 10 ? mp + 3 : mp - 9;
        if (mm <= 2) yy += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(yy), uint256(mm), uint256(dd));
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }
}
