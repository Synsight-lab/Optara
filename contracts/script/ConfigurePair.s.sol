// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OptionSeriesFactory} from "../src/OptionSeriesFactory.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PairConfig} from "../src/Types.sol";

/// @notice Step 2: allowlist a pair's assets, approve its ONE Chainlink feed, and set the open-interest cap.
///
/// APPROVING A FEED IS THE MOST SECURITY-CRITICAL ACTION IN THE SYSTEM. A series can never be corrected once it
/// is created with a feed. Two people must confirm that FEED is a DIRECT Chainlink feed for exactly
/// UNDERLYING/QUOTE (not a composed price) before this runs. The script prints what the feed reports so the
/// reviewers can check it against Chainlink's feed page. Set MAX_AGE to the feed's heartbeat plus a buffer.
///
/// Required env: FACTORY, UNDERLYING, QUOTE, FEED, MAX_AGE (seconds), STRIKE_STEP (1e18 units)
/// Optional env: MAX_SHORT (option raw units for the underlying's open-interest cap, 0 = uncapped; default 0)
contract ConfigurePair is Script {
    function run() external {
        OptionSeriesFactory factory = OptionSeriesFactory(vm.envAddress("FACTORY"));
        address underlying = vm.envAddress("UNDERLYING");
        address quote = vm.envAddress("QUOTE");
        address feed = vm.envAddress("FEED");
        uint32 maxAge = uint32(vm.envUint("MAX_AGE"));
        uint256 strikeStep = vm.envUint("STRIKE_STEP");
        uint256 maxShort = vm.envOr("MAX_SHORT", uint256(0));

        // What the reviewers must compare against the Chainlink feed page for this exact pair
        console.log("underlying          ", IERC20Metadata(underlying).symbol(), IERC20Metadata(underlying).decimals());
        console.log("quote               ", IERC20Metadata(quote).symbol(), IERC20Metadata(quote).decimals());
        console.log("feed                ", feed);
        console.log("feed decimals       ", IAggregatorV3(feed).decimals());
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        console.log("latest answer (raw) ", uint256(answer));
        console.log("latest updatedAt    ", updatedAt);
        console.log("maxChainlinkAgeAtExpiry", maxAge);
        console.log("strikeStep          ", strikeStep);
        console.log("open-interest cap   ", maxShort);

        vm.startBroadcast();
        if (!factory.allowedAsset(underlying)) factory.setAllowedAsset(underlying, true);
        if (!factory.allowedAsset(quote)) factory.setAllowedAsset(quote, true);
        factory.setPairConfig(
            underlying, quote, PairConfig({feed: feed, maxChainlinkAgeAtExpiry: maxAge, strikeStep: strikeStep})
        );
        factory.setMaxShortAmount(underlying, maxShort);
        vm.stopBroadcast();
    }
}
