// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptaraDirectMarket} from "../../src/venues/OptaraDirectAdapter.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockDependencies.sol";

/// @notice The Optara Direct book on its own: owner quoting, fills against inventory, and getting inventory back.
contract OptaraDirectMarketTest is Test {
    MockERC20 internal option = new MockERC20("Option", "OPT", 18);
    MockERC20 internal usdc = new MockERC20("USD Coin", "USDC", 6);
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal buyer = makeAddr("buyer");
    OptaraDirectMarket internal book;

    function setUp() public {
        // the test contract plays the adapter (the only caller of buy/sell)
        book = new OptaraDirectMarket(
            IERC20(address(option)), IERC20(address(usdc)), 18, 6, 1e6, 1e16, address(this), owner
        );
        option.mint(address(book), 10e18); // 10 options of inventory
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(book), type(uint256).max);
    }

    function test_quotesShowInBestBidAsk() public {
        vm.startPrank(owner);
        book.setAsk(2_600, 5e16); // $0.0026 at 1e6 price precision, 5 options
        book.setBid(2_200, 5e16);
        vm.stopPrank();
        (uint256 bid, uint256 ask) = book.bestBidAsk();
        assertEq(ask, 0.0026e18);
        assertEq(bid, 0.0022e18);
    }

    function test_buyFillsFromInventoryAtTheAsk() public {
        vm.prank(owner);
        book.setAsk(1e6, 5e16); // $1.00, up to 5 options
        uint256 spent = book.buy(3e6, buyer); // $3 buys 3 options
        assertEq(spent, 3e6);
        assertEq(option.balanceOf(buyer), 3e18);
        assertEq(book.askSize(), 2e16);
    }

    function test_onlyOwnerQuotesAndWithdraws() public {
        vm.startPrank(stranger);
        vm.expectRevert(ZeroAddress.selector);
        book.setAsk(1, 1);
        vm.expectRevert(ZeroAddress.selector);
        book.withdraw(IERC20(address(option)), 1e18, stranger);
        vm.stopPrank();
    }

    function test_ownerWithdrawsInventoryAndFunding() public {
        usdc.mint(address(book), 50e6); // bid funding
        vm.startPrank(owner);
        book.withdraw(IERC20(address(option)), 4e18, owner);
        book.withdraw(IERC20(address(usdc)), 50e6, owner);
        vm.expectRevert(ZeroAddress.selector);
        book.withdraw(IERC20(address(usdc)), 0, address(0));
        vm.stopPrank();
        assertEq(option.balanceOf(owner), 4e18);
        assertEq(option.balanceOf(address(book)), 6e18);
        assertEq(usdc.balanceOf(owner), 50e6);
    }

    function test_buyBeyondInventoryReverts() public {
        vm.prank(owner);
        book.setAsk(1e6, 20e16); // asks 20 options but holds 10
        vm.expectRevert();
        book.buy(15e6, buyer);
    }
}
