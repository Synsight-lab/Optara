// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VenueFixture} from "../utils/VenueFixture.sol";
import {KuruAdapter} from "../../src/venues/kuru/KuruAdapter.sol";
import {InvalidMarket} from "../../src/libraries/Errors.sol";

/// @dev Kuru's maker side and market deployment (fork tests only; Optara never calls these).
interface IKuruRouterAdmin {
    function deployProxy(
        uint8 _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) external returns (address proxy);
    function owner() external view returns (address);
}

interface IKuruMaker {
    function addBuyOrder(uint32 _price, uint96 size, bool _postOnly) external;
    function addSellOrder(uint32 _price, uint96 _size, bool _postOnly) external;
}

interface IKuruMarginAccount {
    function deposit(address _user, address _token, uint256 _amount) external payable;
}

/// @notice VEN-008: the full Optara stack against REAL Kuru on a Monad mainnet fork. Only Kuru is real; Optara and
///         its mocks are deployed fresh on the fork. The market uses pricePrecision 1e4 (≠ 10^6 quote decimals) and
///         sizePrecision 1e16 (≠ 10^18 wrapper decimals), so the adapter's unit conversions are exercised.
/// @dev Run: FOUNDRY_PROFILE=fork forge test --match-contract KuruAdapterForkTest (RPC: FORK_RPC_URL, default
///      https://rpc.monad.xyz). Market deployment on Kuru is owner-gated, so the test impersonates Kuru's router owner.
contract KuruAdapterForkTest is VenueFixture {
    address internal constant KURU_ROUTER = 0xd651346d7c789536ebf06dc72aE3C8502cd695CC;
    address internal constant KURU_MARGIN_ACCOUNT = 0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5;
    uint32 internal constant PRICE_PRECISION = 1e4;
    uint96 internal constant SIZE_PRECISION = 1e16;

    KuruAdapter internal adapter;
    address internal market;
    address internal maker = makeAddr("kuruMaker");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_URL", string("https://rpc.monad.xyz")));
        _deployClearingMarket();
        _grantVenueAdmin();
        adapter = _installKuru(KURU_ROUTER);

        // the maker writes 10 wrappers (its ask inventory) and holds USDC for bids
        uint256 makerAcct = _account(maker);
        _deposit(makerAcct, maker, 40_000e6);
        vm.prank(maker);
        clearingModule.mintExternalLong(makerAcct, c4500, 10e18, maker, type(uint256).max, _empty());
        usdc.mint(maker, 1000e6);

        // every external read happens before the prank (a prank applies to the next call only)
        address kuruOwner = IKuruRouterAdmin(KURU_ROUTER).owner();
        address wrapper = _wrapper(c4500);
        vm.prank(kuruOwner);
        market = IKuruRouterAdmin(KURU_ROUTER)
            .deployProxy(0, wrapper, address(usdc), SIZE_PRECISION, PRICE_PRECISION, 100, 1e14, 1e20, 30, 10, 100);
        vm.prank(venueAdmin);
        venues.registerMarket(KURU, market, c4500, "");

        // resting liquidity: ask 5 wrappers at 110, bid 5 wrappers at 100 (prices in 1e4 units)
        vm.startPrank(maker);
        IERC20(wrapper).approve(KURU_MARGIN_ACCOUNT, type(uint256).max);
        usdc.approve(KURU_MARGIN_ACCOUNT, type(uint256).max);
        IKuruMarginAccount(KURU_MARGIN_ACCOUNT).deposit(maker, wrapper, 5e18);
        IKuruMarginAccount(KURU_MARGIN_ACCOUNT).deposit(maker, address(usdc), 500e6);
        IKuruMaker(market).addSellOrder(1_100_000, 5e16, false);
        IKuruMaker(market).addBuyOrder(1_000_000, 5e16, false);
        vm.stopPrank();
    }

    function test_VEN008_registryReadsKuru() public {
        (address base, address quote) = adapter.marketTokens(market);
        assertEq(base, _wrapper(c4500));
        assertEq(quote, address(usdc));
        // a contract Kuru's router did not deploy is unknown to it: registration fails on the base check
        bytes32 c5000Id = c5000;
        vm.prank(venueAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMarket.selector, 1));
        venues.registerMarket(KURU, address(this), c5000Id, "");
    }

    /// @dev 330 USDC at 110 buys exactly 3 wrappers; Kuru keeps 0.3% of them; Optara's buyer fee is 3% of 330.
    function test_VEN008_buyThroughRealKuru() public {
        usdc.mint(buyer, 1000e6);
        vm.startPrank(buyer);
        usdc.approve(address(venueRouter), type(uint256).max);
        (uint256 qty, uint256 spent, uint256 buyerFee, uint256 venueFee) =
            venueRouter.buyThroughVenue(_buyOrder(c4500, 330e6, 2.99e18, buyer), "");
        vm.stopPrank();
        assertEq(spent, 330e6, "the whole budget fills at 110");
        assertEq(qty, 3e18 - 9e15, "3 wrappers less Kuru's 0.3% taker fee (in base)");
        assertEq(IERC20(_wrapper(c4500)).balanceOf(buyer), qty);
        assertEq(buyerFee, 9.9e6, "3% of the premium spent");
        assertEq(venueFee, 990_000, "Kuru's fee, valued in quote");
        assertEq(usdc.balanceOf(buyer), 1000e6 - 330e6 - 9.9e6);
        _assertNothingLeft();
    }

    /// @dev 1,000 USDC against 550 of asks: the rest comes back; the fee is charged on 550 only.
    function test_VEN008_partialFillRefunds() public {
        usdc.mint(buyer, 2000e6);
        vm.startPrank(buyer);
        usdc.approve(address(venueRouter), type(uint256).max);
        (uint256 qty, uint256 spent, uint256 buyerFee,) =
            venueRouter.buyThroughVenue(_buyOrder(c4500, 1000e6, 0, buyer), "");
        vm.stopPrank();
        // FINDING (real Kuru): on a partial fill Kuru works out the unspent quote in price-precision units rounded
        // down, so it keeps up to one price unit (here 1e-4 USDC = 100 raw) beyond 550
        assertGe(spent, 550e6);
        assertLe(spent, 550e6 + 100, "at most one price-precision unit of Kuru rounding");
        assertEq(qty, 5e18 - 15e15, "all 5 asks, less the 0.3% fee in base");
        assertEq(buyerFee, (spent * 300 + 9999) / 10_000, "3% of what was actually spent, rounded up");
        assertEq(usdc.balanceOf(buyer), 2000e6 - spent - buyerFee, "exact refund of the rest");
        _assertNothingLeft();
    }

    /// @dev Selling 2 wrappers into the 100 bid: 200 gross, Kuru keeps 0.3% of the quote; no Optara fee.
    function test_VEN008_sellThroughRealKuru() public {
        IERC20 w = IERC20(_wrapper(c4500));
        vm.prank(maker);
        assertTrue(w.transfer(buyer, 2e18));
        vm.startPrank(buyer);
        w.approve(address(venueRouter), type(uint256).max);
        (uint256 sold, uint256 proceeds,) = venueRouter.sellThroughVenue(_sellOrder(c4500, 2e18, 199e6, buyer), "");
        vm.stopPrank();
        assertEq(sold, 2e18);
        assertEq(proceeds, 200e6 - 600_000);
        assertEq(usdc.balanceOf(buyer), proceeds);
        _assertNothingLeft();
    }

    function _assertNothingLeft() internal view {
        IERC20 w = IERC20(_wrapper(c4500));
        assertEq(w.balanceOf(address(venueRouter)) + w.balanceOf(address(adapter)), 0, "INV-50: wrappers");
        assertEq(usdc.balanceOf(address(venueRouter)) + usdc.balanceOf(address(adapter)), 0, "INV-50: quote");
    }
}
