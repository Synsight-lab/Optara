// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpotFixture} from "../utils/SpotFixture.sol";
import {InvalidSpotPrice} from "../../src/libraries/Errors.sol";

/// @notice Fuzz tests for LiveSpotOracle: exact normalization (SPT-001), derived price and freshness, INV-18.
contract LiveSpotOracleFuzzTest is SpotFixture {
    bytes32[] internal products;

    function setUp() public {
        _deploySpot();
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct());
        products.push(ethUsdc);
        vm.deal(address(this), 100 ether);
    }

    function testFuzz_SPT001_normalizationIsExact(int64 price, int32 expo) public {
        price = int64(bound(price, 1, type(int64).max));
        expo = int32(bound(expo, -36, 0));
        bytes[] memory u = new bytes[](1);
        u[0] = pyth.encode(ETH_USDC, price, expo, T0);
        int256 shift = 18 + int256(expo);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(uint64(price));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 expected = shift >= 0 ? raw * 10 ** uint256(shift) : raw / 10 ** uint256(-shift);
        if (expected == 0 || expected > 1e36) {
            vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
            spot.update{value: 1}(u, products);
        } else {
            spot.update{value: 1}(u, products);
            (uint256 p,) = spot.spotPrice(ethUsdc);
            assertEq(p, expected);
        }
    }

    function testFuzz_derivedPriceAndOlderLegTime(uint64 base8, uint64 quote8, uint32 tb, uint32 tq) public {
        vm.prank(governance);
        spot.setSource(ethUsdc, _derived());
        base8 = uint64(bound(base8, 1e6, 1e16)); // 0.01 to 1e8 USD
        quote8 = uint64(bound(quote8, 0.5e8, 1.5e8)); // stablecoin 0.5 to 1.5 USD
        tb = uint32(bound(tb, 1, 1000));
        tq = uint32(bound(tq, 1, 1000));
        // forge-lint: disable-next-line(unsafe-typecast)
        _push(_two(_upd(ETH_USD, int64(base8), T0 - tb), _upd(USDC_USD, int64(quote8), T0 - tq)));
        (uint256 p, uint64 t) = spot.spotPrice(ethUsdc);
        assertEq(p, (uint256(base8) * 1e10) * 1e18 / (uint256(quote8) * 1e10));
        assertEq(t, T0 - (tb > tq ? tb : tq));
        assertEq(spot.isSpotFresh(ethUsdc), (tb > tq ? tb : tq) <= MAX_AGE);
    }

    /// @dev INV-18: whatever order updates arrive in, the stored price is the one with the latest publish time.
    function testFuzz_INV18_latestWins(uint32[5] memory times) public {
        uint256 latest;
        int64 latestPrice;
        for (uint256 i; i < 5; ++i) {
            uint256 t = T0 - bound(times[i], 0, 10_000);
            // forge-lint: disable-next-line(unsafe-typecast)
            int64 price = int64(int256(4000_00000000 + i * 1_00000000));
            bytes[] memory u = new bytes[](1);
            u[0] = pyth.encode(ETH_USDC, price, -8, t);
            spot.update{value: 1}(u, products);
            if (t > latest) (latest, latestPrice) = (t, price);
            (uint256 p, uint64 stored) = spot.spotPrice(ethUsdc);
            assertEq(stored, latest);
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(p, uint256(uint64(latestPrice)) * 1e10);
        }
    }
}
