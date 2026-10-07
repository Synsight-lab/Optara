// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SeriesFixture} from "./SeriesFixture.sol";
import {LiveSpotOracle} from "../../src/oracle/LiveSpotOracle.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {MockPyth} from "../mocks/MockPyth.sol";

/// @notice Governance + series modules + LiveSpotOracle with a mock Pyth. ETH/USDC uses a derived source
///         (ETH/USD ÷ USDC/USD), as on Monad, where Pyth quotes in USD.
abstract contract SpotFixture is SeriesFixture {
    LiveSpotOracle internal spot;
    MockPyth internal pyth;

    bytes32 internal constant ETH_USD = keccak256("pyth ETH/USD");
    bytes32 internal constant USDC_USD = keccak256("pyth USDC/USD");
    bytes32 internal constant ETH_USDC = keccak256("pyth ETH/USDC");
    uint32 internal constant MAX_AGE = 60;
    uint64 internal constant T0 = 1_791_244_800;

    function _deploySpot() internal {
        vm.warp(T0);
        pyth = new MockPyth();
        _deployGovernanceCore();
        _deploySeriesModules();
        spot = LiveSpotOracle(
            upgradeAdmin.deployProxy(
                address(new LiveSpotOracle()),
                abi.encodeCall(
                    LiveSpotOracle.initialize,
                    (IProtocolControl(address(pc)), IPyth(address(pyth)), IOptionSeriesRegistry(address(registry)))
                )
            )
        );
        _handOver();
        _configureSeries();
        vm.prank(governance);
        spot.setSource(ethUsdc, _derived());
    }

    function _derived() internal pure returns (ILiveSpotOracle.SpotSource memory) {
        return ILiveSpotOracle.SpotSource({
            kind: ILiveSpotOracle.SourceKind.PYTH_DERIVED,
            baseFeedId: ETH_USD,
            quoteFeedId: USDC_USD,
            maxSpotAge: MAX_AGE,
            maxConfidenceBps: 100
        });
    }

    function _direct() internal pure returns (ILiveSpotOracle.SpotSource memory) {
        return ILiveSpotOracle.SpotSource({
            kind: ILiveSpotOracle.SourceKind.PYTH_DIRECT,
            baseFeedId: ETH_USDC,
            quoteFeedId: 0,
            maxSpotAge: MAX_AGE,
            maxConfidenceBps: 100
        });
    }

    /// @dev Pyth-style update: price with expo −8.
    function _upd(bytes32 id, int64 price8, uint256 publishTime) internal view returns (bytes memory) {
        return pyth.encode(id, price8, -8, publishTime);
    }

    function _push(bytes[] memory updates) internal returns (uint256 fee) {
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        fee = updates.length * pyth.feePerUpdate();
        spot.update{value: fee}(updates, products);
    }

    function _two(bytes memory a, bytes memory b) internal pure returns (bytes[] memory u) {
        u = new bytes[](2);
        (u[0], u[1]) = (a, b);
    }
}
