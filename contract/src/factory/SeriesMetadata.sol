// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OptionType} from "../libraries/OptaraTypes.sol";

/// @notice Deterministic, human-readable token metadata (OPTION_SPEC.md section 20). Display only: integrations
/// identify the economic contract from seriesId and on-chain terms, never from these strings.
///   name:   "Optara MON/USDT 10C Cap5 2026-12-25"
///   symbol: "oMON-USDT-10C-C5-261225"
library SeriesMetadata {
    function name(
        string memory underlyingSymbol,
        string memory assetSymbol,
        OptionType optionType,
        uint256 strikeWad,
        uint256 capWad,
        uint64 expiry
    ) internal pure returns (string memory) {
        (uint256 y, uint256 m, uint256 d) = civilDate(expiry);
        return string.concat(
            "Optara ",
            underlyingSymbol,
            "/",
            assetSymbol,
            " ",
            formatWad(strikeWad),
            optionType == OptionType.CALL ? "C" : "P",
            " Cap",
            formatWad(capWad),
            " ",
            Strings.toString(y),
            "-",
            _pad2(m),
            "-",
            _pad2(d)
        );
    }

    function symbol(
        string memory underlyingSymbol,
        string memory assetSymbol,
        OptionType optionType,
        uint256 strikeWad,
        uint256 capWad,
        uint64 expiry
    ) internal pure returns (string memory) {
        (uint256 y, uint256 m, uint256 d) = civilDate(expiry);
        return string.concat(
            "o",
            underlyingSymbol,
            "-",
            assetSymbol,
            "-",
            formatWad(strikeWad),
            optionType == OptionType.CALL ? "C" : "P",
            "-C",
            formatWad(capWad),
            "-",
            _pad2(y % 100),
            _pad2(m),
            _pad2(d)
        );
    }

    /// @notice WAD value as a decimal string without trailing zeros: 10e18 -> "10", 12.5e18 -> "12.5".
    function formatWad(uint256 value) internal pure returns (string memory) {
        uint256 integerPart = value / 1e18;
        uint256 fraction = value % 1e18;
        if (fraction == 0) return Strings.toString(integerPart);
        uint256 digits = 18;
        while (fraction % 10 == 0) {
            fraction /= 10;
            --digits;
        }
        bytes memory frac = bytes(Strings.toString(fraction));
        bytes memory padded = new bytes(digits);
        uint256 zeros = digits - frac.length;
        for (uint256 i = 0; i < zeros; ++i) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < frac.length; ++i) {
            padded[zeros + i] = frac[i];
        }
        return string.concat(Strings.toString(integerPart), ".", string(padded));
    }

    /// @notice UTC calendar date of a unix timestamp (Howard Hinnant's civil_from_days).
    function civilDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 z = int256(timestamp / 86400) + 719468;
        int256 era = z / 146097;
        int256 doe = z - era * 146097;
        int256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        int256 y = yoe + era * 400;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        int256 mp = (5 * doy + 2) / 153;
        int256 d = doy - (153 * mp + 2) / 5 + 1;
        int256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
        return (uint256(y), uint256(m), uint256(d));
    }

    function _pad2(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", Strings.toString(v)) : Strings.toString(v);
    }
}
