// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SpotFixture} from "../utils/SpotFixture.sol";
import {LiveSpotOracle} from "../../src/oracle/LiveSpotOracle.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {RefundRejecter} from "../mocks/MockPyth.sol";
import {
    NotAuthorized,
    ZeroAddress,
    StaleSpot,
    InvalidSpotSource,
    InvalidSpotPrice,
    InsufficientProviderFee,
    RefundFailed
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for LiveSpotOracle: SPT-001..SPT-005.
contract LiveSpotOracleTest is SpotFixture {
    function setUp() public {
        _deploySpot();
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ initialization

    function test_initializeChecks() public {
        address impl = address(new LiveSpotOracle()); // create before the prank/expectRevert
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            impl,
            abi.encodeCall(
                LiveSpotOracle.initialize,
                (IProtocolControl(address(pc)), IPyth(address(0)), IOptionSeriesRegistry(address(registry)))
            )
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        spot.initialize(IProtocolControl(address(pc)), IPyth(address(pyth)), IOptionSeriesRegistry(address(registry)));
        assertEq(spot.pyth(), address(pyth));
    }

    // ------------------------------------------------------------------ SPT-005: sources

    function test_SPT005_setSourceGovernanceOnly() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        spot.setSource(ethUsdc, _direct());

        vm.expectEmit(true, true, true, true, address(spot));
        emit ILiveSpotOracle.SpotSourceSet(ethUsdc, _direct());
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct());
        assertEq(spot.sourceOf(ethUsdc).baseFeedId, ETH_USDC);
    }

    function test_SPT005_sourceValidation() public {
        ILiveSpotOracle.SpotSource memory s;
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 1));
        spot.setSource(keccak256("unknown product"), _direct());

        s = _direct();
        s.kind = ILiveSpotOracle.SourceKind.NONE;
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 2));
        spot.setSource(ethUsdc, s);

        s = _direct();
        s.quoteFeedId = USDC_USD; // a direct source has no quote leg
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 3));
        spot.setSource(ethUsdc, s);
        s = _direct();
        s.baseFeedId = 0;
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 3));
        spot.setSource(ethUsdc, s);

        s = _derived();
        s.quoteFeedId = 0; // a USD price is never used as a stablecoin price
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 3));
        spot.setSource(ethUsdc, s);
        s = _derived();
        s.quoteFeedId = s.baseFeedId;
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 3));
        spot.setSource(ethUsdc, s);

        s = _derived();
        s.maxSpotAge = 0;
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 4));
        spot.setSource(ethUsdc, s);
        s.maxSpotAge = 1 days + 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 4));
        spot.setSource(ethUsdc, s);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ SPT-001: accept and normalize

    function test_SPT001_derivedPriceNormalized() public {
        // ETH/USD 4000, USDC/USD 0.9998 → ETH/USDC 4000.8001600320064012...
        bytes[] memory u = _two(_upd(ETH_USD, 4000_00000000, T0 - 5), _upd(USDC_USD, 99_980000, T0 - 2));
        uint256 expected = uint256(4000e18) * 1e18 / 0.9998e18;
        vm.expectEmit(true, true, true, true, address(spot));
        emit ILiveSpotOracle.SpotUpdated(ethUsdc, expected, T0 - 5); // the older leg's time
        _push(u);
        (uint256 p, uint64 t) = spot.spotPrice(ethUsdc);
        assertEq(p, expected);
        assertEq(t, T0 - 5);
        assertEq(spot.requireFreshSpot(ethUsdc), expected);
        assertTrue(spot.isSpotFresh(ethUsdc));
    }

    function test_SPT001_directPrice() public {
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct());
        bytes[] memory u = new bytes[](1);
        u[0] = _upd(ETH_USDC, 4123_45678900, T0);
        _push(u);
        (uint256 p,) = spot.spotPrice(ethUsdc);
        assertEq(p, 4123.456789e18);
    }

    function test_exponentEdges() public {
        vm.prank(governance);
        spot.setSource(ethUsdc, _direct());
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        bytes[] memory u = new bytes[](1);

        u[0] = pyth.encode(ETH_USDC, 4, 0, T0 - 3); // expo 0
        spot.update{value: 1}(u, products);
        (uint256 p,) = spot.spotPrice(ethUsdc);
        assertEq(p, 4e18);

        u[0] = pyth.encode(ETH_USDC, 4_123456789012345678, -18, T0 - 2); // expo −18
        spot.update{value: 1}(u, products);
        (p,) = spot.spotPrice(ethUsdc);
        assertEq(p, 4.123456789012345678e18);

        u[0] = pyth.encode(ETH_USDC, 4_123456789012345678, -20, T0 - 1); // expo −20: divided, rounded down
        spot.update{value: 1}(u, products);
        (p,) = spot.spotPrice(ethUsdc);
        assertEq(p, 0.041234567890123456e18);
    }

    // ------------------------------------------------------------------ SPT-002: never older (INV-18)

    function test_SPT002_olderOrEqualNeverOverwrites() public {
        _push(_two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0)));
        // a refresh with only older data in the provider changes nothing; equal time changes nothing either
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        vm.recordLogs();
        spot.update(new bytes[](0), products);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.warp(T0 + 10);
        _push(_two(_upd(ETH_USD, 4100_00000000, T0 + 10), _upd(USDC_USD, 1_00000000, T0 + 10)));
        (uint256 p, uint64 t) = spot.spotPrice(ethUsdc);
        assertEq(p, 4100e18);
        assertEq(t, T0 + 10);
    }

    // ------------------------------------------------------------------ SPT-003: staleness

    function test_SPT003_stale() public {
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, ethUsdc, T0)); // never updated
        spot.requireFreshSpot(ethUsdc);

        _push(_two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0)));
        vm.warp(T0 + MAX_AGE);
        spot.requireFreshSpot(ethUsdc); // exactly maxSpotAge is fresh
        vm.warp(T0 + MAX_AGE + 1);
        assertFalse(spot.isSpotFresh(ethUsdc));
        vm.expectRevert(abi.encodeWithSelector(StaleSpot.selector, ethUsdc, uint64(MAX_AGE + 1)));
        spot.requireFreshSpot(ethUsdc);
    }

    function test_derivedFreshnessFollowsOlderLeg() public {
        _push(_two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0 - 50)));
        vm.warp(T0 + 11); // ETH leg is 11 s old, USDC leg 61 s
        assertFalse(spot.isSpotFresh(ethUsdc));
    }

    // ------------------------------------------------------------------ SPT-004: fees

    function test_SPT004_feeChargedAndExcessRefunded() public {
        pyth.setFeePerUpdate(0.01 ether);
        bytes[] memory u = _two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0));
        assertEq(spot.updateFee(u), 0.02 ether);
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        uint256 before = address(this).balance;
        uint256 paid = spot.update{value: 1 ether}(u, products);
        assertEq(paid, 0.02 ether);
        assertEq(before - address(this).balance, 0.02 ether, "exact refund");
        assertEq(address(spot).balance, 0, "oracle keeps nothing");
        assertEq(address(pyth).balance, 0.02 ether);
    }

    function test_SPT004_insufficientFeeReverts() public {
        pyth.setFeePerUpdate(0.01 ether);
        bytes[] memory u = _two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0));
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        vm.expectRevert(abi.encodeWithSelector(InsufficientProviderFee.selector, 0.02 ether, 0.02 ether - 1));
        spot.update{value: 0.02 ether - 1}(u, products);
    }

    function test_SPT004_noUpdatesRefundsEverything() public {
        assertEq(spot.updateFee(new bytes[](0)), 0);
        _push(_two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0)));
        uint256 before = address(this).balance;
        spot.update{value: 1 ether}(new bytes[](0), new bytes32[](0));
        assertEq(address(this).balance, before);
    }

    function test_SPT004_refundFailureReverts() public {
        RefundRejecter r = new RefundRejecter();
        vm.deal(address(r), 1 ether);
        bytes[] memory u = _two(_upd(ETH_USD, 4000_00000000, T0), _upd(USDC_USD, 1_00000000, T0));
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        vm.expectRevert(RefundFailed.selector);
        r.forward{value: 3}(address(spot), abi.encodeCall(spot.update, (u, products)));
    }

    // ------------------------------------------------------------------ invalid data

    function test_invalidPricesRevert() public {
        bytes32[] memory products = new bytes32[](1);
        products[0] = ethUsdc;
        bytes[] memory u = _two(_upd(ETH_USD, 0, T0), _upd(USDC_USD, 1_00000000, T0));
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
        spot.update{value: 2}(u, products);

        u = _two(_upd(ETH_USD, -5, T0), _upd(USDC_USD, 1_00000000, T0));
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
        spot.update{value: 2}(u, products);

        u = _two(pyth.encode(ETH_USD, 4, 1, T0), _upd(USDC_USD, 1_00000000, T0)); // positive exponent
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
        spot.update{value: 2}(u, products);

        u = _two(pyth.encode(ETH_USD, 4, -37, T0), _upd(USDC_USD, 1_00000000, T0)); // exponent below −36
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
        spot.update{value: 2}(u, products);

        // above 1e36 WAD after division by a tiny quote
        u = _two(_upd(ETH_USD, type(int64).max, T0), _upd(USDC_USD, 1, T0));
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
        spot.update{value: 2}(u, products);

        // rounds to zero
        u = _two(pyth.encode(ETH_USD, 1, -30, T0), _upd(USDC_USD, 1_00000000, T0));
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotPrice.selector, ethUsdc));
        spot.update{value: 2}(u, products);
    }

    function test_unconfiguredProductReverts() public {
        bytes32[] memory products = new bytes32[](1);
        products[0] = keccak256("BTC/USDC");
        vm.expectRevert(abi.encodeWithSelector(InvalidSpotSource.selector, 2));
        spot.update(new bytes[](0), products);
    }
}
