// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SettlementFixture} from "../utils/SettlementFixture.sol";
import {SettlementOracle} from "../../src/oracle/SettlementOracle.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {OptionType, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {FinalizationTooEarly, InvalidSettlementProof} from "../../src/libraries/Errors.sol";

/// @notice STL-001 / STL-002 / STL-004 end to end: SettlementWindow finalizes through the real SettlementOracle with
///         a round-in-force proof against a Chainlink-style feed.
contract SettlementWindowOracleTest is SettlementFixture {
    SettlementOracle internal so;
    MockAggregator internal feed;
    bytes32 internal cfgId;
    bytes32 internal call4500;
    bytes32 internal group;
    uint80 internal inForce;
    uint80 internal successor;

    function _settlementOracleFor(IProtocolControl c) internal override returns (address) {
        so = SettlementOracle(
            address(new ERC1967Proxy(address(new SettlementOracle()), abi.encodeCall(SettlementOracle.initialize, (c))))
        );
        return address(so);
    }

    function setUp() public {
        _deployClearingMarket();
        address admin = makeAddr("oracleAdmin");
        vm.prank(governance);
        pc.grantRole(Roles.ORACLE_ADMIN, admin);
        feed = new MockAggregator(8);
        feed.pushRound(3900e8, EXP30 - 1 days);
        ISettlementOracle.SettlementOracleConfig memory cfg = ISettlementOracle.SettlementOracleConfig({
            underlying: weth,
            settlementAsset: address(usdc),
            primary: ISettlementOracle.FeedSource({
                kind: ISettlementOracle.FeedKind.DIRECT,
                feed: address(feed),
                feedDecimals: 8,
                quoteFeed: address(0),
                quoteFeedDecimals: 0
            }),
            fallbackSource: ISettlementOracle.FeedSource({
                kind: ISettlementOracle.FeedKind.NONE,
                feed: address(0),
                feedDecimals: 0,
                quoteFeed: address(0),
                quoteFeedDecimals: 0
            }),
            observationStartOffset: -3600,
            observationEndOffset: 0,
            minFinalizationDelay: 300,
            maxFinalizationDelay: 7 days,
            maxLegSkew: 0
        });
        vm.prank(admin);
        cfgId = so.registerConfig(cfg);
        vm.prank(governance);
        so.setConfigApproved(cfgId, true);
        settlementConfigs.set(cfgId, weth, address(usdc), true); // the registry's config check
        SeriesParams memory p = SeriesParams({
            underlying: weth,
            settlementAsset: address(usdc),
            optionType: OptionType.CALL,
            strikeWad: 4500e18,
            contractSizeWad: 1e18,
            expiry: EXP30,
            settlementOracleConfigId: cfgId,
            volSurfaceProductId: ethUsdc,
            riskParameterSetId: RISK_SET
        });
        vm.prank(seriesCreator);
        call4500 = registry.createSeries(p);
        group = registry.groupOf(call4500);
        vm.warp(EXP30 - 120);
        inForce = feed.pushRound(5200e8, EXP30 - 30);
        vm.warp(EXP30 + 60);
        successor = feed.pushRound(5300e8, EXP30 + 60);
    }

    function _proof(uint80 r, uint80 next) internal pure returns (bytes memory) {
        ISettlementOracle.RoundProof[] memory p = new ISettlementOracle.RoundProof[](1);
        p[0] = ISettlementOracle.RoundProof(r, next);
        return abi.encode(ISettlementOracle.SettlementData(0, p, new ISettlementOracle.RoundProof[](0)));
    }

    function test_STL001_finalizeWithRoundInForce() public {
        vm.expectRevert(abi.encodeWithSelector(FinalizationTooEarly.selector, EXP30 + 300));
        window.finalizeGroup(group, _proof(inForce, successor));
        vm.warp(EXP30 + 300);
        vm.expectPartialRevert(InvalidSettlementProof.selector); // the successor was not in force at expiry
        window.finalizeGroup(group, _proof(successor, 0));
        vm.expectEmit(true, true, true, true, address(window));
        emit ISettlementWindow.GroupFinalized(group, 5200e18, EXP30 - 30, 0);
        window.finalizeGroup(group, _proof(inForce, successor));
        assertEq(window.settlementPrice(group), 5200e18);
    }

    function test_STL004_lateFinalizeAfterStall() public {
        vm.warp(EXP30 + 7 days);
        assertEq(uint8(window.groupState(group)), uint8(ISettlementWindow.GroupState.ORACLE_STALLED));
        window.flagOracleStalled(group);
        window.finalizeGroup(group, _proof(inForce, successor)); // the authentic historical round still works
        assertEq(uint8(window.groupState(group)), uint8(ISettlementWindow.GroupState.ALL_SETTLED));
    }
}
