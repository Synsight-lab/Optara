// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpotFixture} from "../utils/SpotFixture.sol";
import {LiveSpotOracle} from "../../src/oracle/LiveSpotOracle.sol";
import {MockPyth} from "../mocks/MockPyth.sol";

/// @notice Random Pyth updates (any order, any publish time, sometimes invalid) and time warps.
contract SpotHandler is Test {
    LiveSpotOracle internal spot;
    MockPyth internal pyth;
    bytes32 internal productId;
    bytes32 internal feed;

    uint64 public ghostLatest; // latest accepted publish time
    uint256 public ghostPrice; // price of that update
    uint256 public accepted;

    constructor(LiveSpotOracle s, MockPyth p, bytes32 product, bytes32 feed_) {
        (spot, pyth, productId, feed) = (s, p, product, feed_);
        vm.deal(address(this), 1000 ether);
    }

    receive() external payable {}

    function push(int64 price, uint32 back, uint256 extraValue) external {
        price = int64(bound(price, -10, 1e15));
        uint64 t = uint64(block.timestamp) - uint64(bound(back, 0, 3600));
        bytes[] memory u = new bytes[](1);
        u[0] = pyth.encode(feed, price, -8, t);
        bytes32[] memory ps = new bytes32[](1);
        ps[0] = productId;
        uint256 balBefore = address(this).balance;
        uint256 value = 1 + bound(extraValue, 0, 1 ether);
        try spot.update{value: value}(u, ps) returns (uint256 fee) {
            assertEq(balBefore - address(this).balance, fee, "caller pays exactly the fee");
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 wad = uint256(uint64(price)) * 1e10;
            if (t > ghostLatest && t > _pythTimeBefore) {
                (ghostLatest, ghostPrice) = (t, wad);
                accepted++;
            }
        } catch {
            assertLe(price, 0, "only non-positive prices may fail");
        }
        _pythTimeBefore = _pythTime();
    }

    uint256 internal _pythTimeBefore;

    function _pythTime() internal view returns (uint256) {
        try pyth.getPriceUnsafe(feed) returns (MockPyth.Price memory p) {
            return p.publishTime;
        } catch {
            return 0;
        }
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 600));
    }
}

contract LiveSpotOracleInvariantTest is SpotFixture {
    SpotHandler internal handler;

    function setUp() public {
        _deploySpot();
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct());
        handler = new SpotHandler(spot, pyth, ethUsdc, ETH_USDC);
        targetContract(address(handler));
    }

    /// @dev INV-18: the stored price is the latest-published valid price ever pushed; it never goes back in time.
    function invariant_INV18_storedIsLatest() public view {
        (uint256 p, uint64 t) = spot.spotPrice(ethUsdc);
        assertEq(t, handler.ghostLatest());
        assertEq(p, handler.ghostPrice());
    }

    /// @dev The oracle never keeps native value (fees go to the provider, the rest is refunded).
    function invariant_noValueKept() public view {
        assertEq(address(spot).balance, 0);
    }

    function test_handlerPathsReachable() public {
        handler.push(4000_00000000, 10, 5);
        handler.warp(30);
        handler.push(4100_00000000, 0, 0);
        handler.push(3900_00000000, 100, 0); // older: ignored
        handler.push(-1, 0, 0); // invalid: reverts inside the handler's try
        assertEq(handler.accepted(), 2);
        invariant_INV18_storedIsLatest();
    }
}
