// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibString} from "solady/utils/LibString.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {OptionType} from "../libraries/OptaraTypes.sol";

/// @title SeriesNaming
/// @notice Display name and symbol of a wrapper (docs/OPTION_SPEC.md §7):
///         name   "Optara ETH/USDC 4500C 2026-12-25"
///         symbol "oETH-USDC-4500C-261225"
///         Display only: integrations identify a series by `seriesId`, never by name or symbol.
library SeriesNaming {
    using LibString for uint256;

    function name(
        string memory underlyingSymbol,
        string memory assetSymbol,
        OptionType optionType,
        uint256 strikeWad,
        uint64 expiry
    ) internal pure returns (string memory) {
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.timestampToDate(expiry);
        return string.concat(
            "Optara ",
            underlyingSymbol,
            "/",
            assetSymbol,
            " ",
            formatWad(strikeWad),
            optionType == OptionType.CALL ? "C" : "P",
            " ",
            y.toString(),
            "-",
            _two(m),
            "-",
            _two(d)
        );
    }

    function symbol(
        string memory underlyingSymbol,
        string memory assetSymbol,
        OptionType optionType,
        uint256 strikeWad,
        uint64 expiry
    ) internal pure returns (string memory) {
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.timestampToDate(expiry);
        return string.concat(
            "o",
            underlyingSymbol,
            "-",
            assetSymbol,
            "-",
            formatWad(strikeWad),
            optionType == OptionType.CALL ? "C" : "P",
            "-",
            _two(y % 100),
            _two(m),
            _two(d)
        );
    }

    /// @notice WAD as a decimal string without trailing zeros: 4500e18 → "4500", 0.25e18 → "0.25".
    function formatWad(uint256 x) internal pure returns (string memory) {
        uint256 whole = x / 1e18;
        uint256 frac = x % 1e18;
        if (frac == 0) return whole.toString();
        uint256 digits = 18;
        while (frac % 10 == 0) {
            frac /= 10;
            --digits;
        }
        string memory f = frac.toString();
        // left-pad the fraction to `digits` characters
        while (bytes(f).length < digits) {
            f = string.concat("0", f);
        }
        return string.concat(whole.toString(), ".", f);
    }

    function _two(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", v.toString()) : v.toString();
    }
}
