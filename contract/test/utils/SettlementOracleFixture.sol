// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceFixture} from "./GovernanceFixture.sol";
import {SettlementOracle} from "../../src/oracle/SettlementOracle.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice Governance + SettlementOracle with mock Chainlink feeds (8 decimals): ETH/USDC (direct), ETH/USD and
///         USDC/USD (derived), and a second ETH/USDC feed used as fallback.
abstract contract SettlementOracleFixture is GovernanceFixture {
    SettlementOracle internal so;
    MockAggregator internal ethUsdcFeed;
    MockAggregator internal ethUsdcFallback;
    MockAggregator internal ethUsdFeed;
    MockAggregator internal usdcUsdFeed;
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal weth = makeAddr("WETH");
    address internal usdcToken = makeAddr("USDC");

    uint64 internal constant EXPIRY = 1_798_185_600; // 2026-12-25 08:00 UTC

    function _deploySettlementOracle() internal {
        vm.warp(EXPIRY - 1 days);
        _deployGovernanceCore();
        so = SettlementOracle(
            upgradeAdmin.deployProxy(
                address(new SettlementOracle()),
                abi.encodeCall(SettlementOracle.initialize, (IProtocolControl(address(pc))))
            )
        );
        pc.grantRole(Roles.ORACLE_ADMIN, oracleAdmin);
        _handOver();
        ethUsdcFeed = _feed(4000e8);
        ethUsdcFallback = _feed(4000e8);
        ethUsdFeed = _feed(4000e8);
        usdcUsdFeed = _feed(1e8);
    }

    /// @dev A live feed with one round a day before expiry.
    function _feed(int256 answer) internal returns (MockAggregator f) {
        f = new MockAggregator(8);
        f.pushRound(answer, EXPIRY - 1 days);
    }

    function _direct(MockAggregator f) internal pure returns (ISettlementOracle.FeedSource memory) {
        return ISettlementOracle.FeedSource({
            kind: ISettlementOracle.FeedKind.DIRECT,
            feed: address(f),
            feedDecimals: 8,
            quoteFeed: address(0),
            quoteFeedDecimals: 0
        });
    }

    function _derived() internal view returns (ISettlementOracle.FeedSource memory) {
        return ISettlementOracle.FeedSource({
            kind: ISettlementOracle.FeedKind.DERIVED,
            feed: address(ethUsdFeed),
            feedDecimals: 8,
            quoteFeed: address(usdcUsdFeed),
            quoteFeedDecimals: 8
        });
    }

    function _none() internal pure returns (ISettlementOracle.FeedSource memory s) {}

    /// @dev Observation window [expiry − 1 h, expiry]; finalize from expiry + 5 min; stalled after 7 days.
    function _cfg(ISettlementOracle.FeedSource memory primary, ISettlementOracle.FeedSource memory fb, uint32 skew)
        internal
        view
        returns (ISettlementOracle.SettlementOracleConfig memory)
    {
        return ISettlementOracle.SettlementOracleConfig({
            underlying: weth,
            settlementAsset: usdcToken,
            primary: primary,
            fallbackSource: fb,
            observationStartOffset: -3600,
            observationEndOffset: 0,
            minFinalizationDelay: 300,
            maxFinalizationDelay: 7 days,
            maxLegSkew: skew
        });
    }

    function _register(ISettlementOracle.SettlementOracleConfig memory c) internal returns (bytes32) {
        vm.prank(oracleAdmin);
        return so.registerConfig(c);
    }

    function _proof(uint80 r, uint80 next) internal pure returns (ISettlementOracle.RoundProof[] memory p) {
        p = new ISettlementOracle.RoundProof[](1);
        p[0] = ISettlementOracle.RoundProof(r, next);
    }

    function _data(uint8 idx, ISettlementOracle.RoundProof[] memory primary, ISettlementOracle.RoundProof[] memory fb)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(ISettlementOracle.SettlementData(idx, primary, fb));
    }
}
