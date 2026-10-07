// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockKuruFixture} from "../utils/MockKuruFixture.sol";
import {VenueRegistry} from "../../src/venues/VenueRegistry.sol";
import {IVenueRegistry} from "../../src/interfaces/IVenueRegistry.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {MockKuruOrderBook, MockVenueAdapter} from "../mocks/MockVenues.sol";
import {MockERC20} from "../mocks/MockDependencies.sol";
import {
    NotAuthorized,
    ZeroAddress,
    InvalidMarket,
    InvalidAdapter,
    AdapterDisabled,
    MarketNotVerified,
    UnknownSeries
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for VenueRegistry: VEN-001, VEN-009, VEN-010.
contract VenueRegistryTest is MockKuruFixture {
    function setUp() public {
        _deployVenueMarket();
    }

    function test_initialize() public {
        IProtocolControl c = IProtocolControl(address(pc));
        address impl = address(new VenueRegistry());
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(impl, abi.encodeCall(VenueRegistry.initialize, (c, IOptionSeriesRegistry(address(0)))));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        venues.initialize(c, IOptionSeriesRegistry(address(registry)));
    }

    // ------------------------------------------------------------------ VEN-001: market verification

    function test_VEN001_registerMarket() public {
        IVenueRegistry.VenueMarket memory m = venues.getMarket(KURU, c4500);
        assertEq(m.venueId, KURU);
        assertEq(m.market, address(book));
        assertEq(m.seriesId, c4500);
        assertEq(m.base, _wrapper(c4500));
        assertEq(m.quote, address(usdc));
        assertEq(m.chainId, block.chainid);
        assertEq(uint8(m.status), uint8(IVenueRegistry.MarketStatus.ACTIVE));
        assertEq(m.metadata, "tick=100");

        MockKuruOrderBook b = _book(c5000);
        vm.expectEmit(true, true, true, true, address(venues));
        emit IVenueRegistry.MarketRegistered(KURU, c5000, address(b));
        vm.prank(venueAdmin);
        venues.registerMarket(KURU, address(b), c5000, "");
    }

    function test_VEN001_INV51_wrongMarketsRejected() public {
        // base: the C4500 book offered for C5000
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 1));
        venues.registerMarket(KURU, address(book), c5000, "");
        // quote: a C5000 book quoted in another token
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        MockKuruOrderBook b =
            new MockKuruOrderBook(IERC20(_wrapper(c5000)), IERC20(address(other)), 18, 6, 1e4, 1e16, 30);
        kuruRouter.setMarket(address(b), _params(_wrapper(c5000), address(other)));
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 2));
        venues.registerMarket(KURU, address(b), c5000, "");
        // a contract the venue does not know (Kuru's router has no record): zero base
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 1));
        venues.registerMarket(KURU, address(this), c5000, "");
        // one market per (venue, series)
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 3));
        venues.registerMarket(KURU, address(book), c4500, "");
    }

    function test_VEN001_registrationChecks() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        venues.registerMarket(KURU, address(book), c5000, "");
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidAdapter.selector, 1));
        venues.registerMarket(keccak256("NOPE"), address(book), c5000, "");
        bytes32 bogus = keccak256("series");
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(UnknownSeries.selector, bogus));
        venues.registerMarket(KURU, address(book), bogus, "");
        MockKuruOrderBook b = _book(c5000);
        vm.warp(EXP30);
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 4));
        venues.registerMarket(KURU, address(b), c5000, "");
    }

    // ------------------------------------------------------------------ VEN-009: status

    function test_VEN009_status() public {
        vm.expectRevert(MarketNotVerified.selector);
        venues.tradableMarket(KURU, c5000); // never registered
        (address a, address m) = venues.tradableMarket(KURU, c4500);
        assertEq(a, address(adapter));
        assertEq(m, address(book));

        vm.expectEmit(true, true, true, true, address(venues));
        emit IVenueRegistry.MarketStatusSet(KURU, c4500, IVenueRegistry.MarketStatus.INACTIVE);
        vm.prank(venueAdmin);
        venues.setMarketStatus(KURU, c4500, IVenueRegistry.MarketStatus.INACTIVE);
        vm.expectRevert(MarketNotVerified.selector);
        venues.tradableMarket(KURU, c4500);
        vm.prank(venueAdmin);
        venues.setMarketStatus(KURU, c4500, IVenueRegistry.MarketStatus.ACTIVE);
        venues.tradableMarket(KURU, c4500);

        vm.startPrank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 5));
        venues.setMarketStatus(KURU, c4500, IVenueRegistry.MarketStatus.EXPIRED); // follows from expiry only
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 5));
        venues.setMarketStatus(KURU, c5000, IVenueRegistry.MarketStatus.ACTIVE); // unknown market
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        venues.setMarketStatus(KURU, c4500, IVenueRegistry.MarketStatus.INACTIVE);

        vm.warp(EXP30); // the series expires: the market reads EXPIRED and is no longer tradable
        assertEq(uint8(venues.getMarket(KURU, c4500).status), uint8(IVenueRegistry.MarketStatus.EXPIRED));
        vm.expectRevert(MarketNotVerified.selector);
        venues.tradableMarket(KURU, c4500);
    }

    // ------------------------------------------------------------------ VEN-010: adapters

    function test_VEN010_registerAdapter() public {
        bytes32 mockId = keccak256("MOCK");
        MockVenueAdapter mock =
            new MockVenueAdapter(mockId, IERC20(_wrapper(c4500)), IERC20(address(usdc)), makeAddr("mockVenue"));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        venues.registerAdapter(mockId, address(mock)); // governance (timelocked) only
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidAdapter.selector, 1));
        venues.registerAdapter(keccak256("OTHER"), address(mock)); // venue id mismatch
        vm.expectRevert(abi.encodeWithSelector(InvalidAdapter.selector, 1));
        venues.registerAdapter(mockId, address(0));
        vm.expectEmit(true, true, true, true, address(venues));
        emit IVenueRegistry.AdapterRegistered(mockId, address(mock));
        vm.expectEmit(true, true, true, true, address(venues));
        emit IVenueRegistry.AdapterEnabled(mockId, false);
        venues.registerAdapter(mockId, address(mock));
        vm.expectRevert(abi.encodeWithSelector(InvalidAdapter.selector, 2));
        venues.registerAdapter(mockId, address(mock));
        vm.stopPrank();
        (address a, bool enabled) = venues.adapterOf(mockId);
        assertEq(a, address(mock));
        assertFalse(enabled, "registered disabled");
    }

    function test_VEN010_enableAndDisable() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        venues.setAdapterEnabled(KURU, true); // enabling needs governance
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        venues.setAdapterEnabled(KURU, false);

        vm.expectEmit(true, true, true, true, address(venues));
        emit IVenueRegistry.AdapterEnabled(KURU, false);
        vm.prank(guardian); // instant
        venues.setAdapterEnabled(KURU, false);
        vm.expectRevert(abi.encodeWithSelector(AdapterDisabled.selector, KURU));
        venues.tradableMarket(KURU, c4500);
        vm.prank(governance);
        venues.setAdapterEnabled(KURU, true);
        vm.prank(venueAdmin);
        venues.setAdapterEnabled(KURU, false);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidAdapter.selector, 1));
        venues.setAdapterEnabled(keccak256("NOPE"), true);
    }
}
