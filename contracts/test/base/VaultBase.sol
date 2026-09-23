// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {OptionSeriesVault} from "../../src/OptionSeriesVault.sol";
import {OptionType, FeeConfig, SeriesConfig, SettlementProof, ADMIN_ROLE, PAUSER_ROLE, OPTION_DECIMALS, MIN_OPTION_AMOUNT} from "../../src/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {CloneHelper} from "./CloneHelper.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Shared setup for vault tests. The default vault is a CALL on WMON (18 dp) against USDC (6 dp) with a
///         strike of 10.00 USDC, a 10 bps mint fee and a 25 bps exercise fee.
abstract contract VaultBase is Test {
    MockERC20 internal mon;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockAggregator internal feed;
    MockFactory internal factory;
    OptionSeriesVault internal vault;
    address internal vaultImplementation; // one implementation, cloned for every series in these tests

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice"); // writer
    address internal bob = makeAddr("bob"); // buyer
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");

    uint64 internal expiry;
    uint32 internal constant MAX_AGE = 3600;
    uint256 internal seriesCounter;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        expiry = uint64(block.timestamp + 7 days);

        mon = new MockERC20("Wrapped MON", "WMON", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        feed = new MockAggregator(8);
        factory = new MockFactory();
        factory.setRole(ADMIN_ROLE, admin, true);
        factory.setRole(PAUSER_ROLE, pauser, true);
        factory.setFeeRecipient(feeRecipient);
        vaultImplementation = CloneHelper.deployImplementation();

        vault = _deploy(OptionType.CALL, address(mon), address(usdc), 10e18, 10, 25, 0);
    }

    // ------------------------------------------------------------------ deployment helpers

    function _config(OptionType t, address u, address q, uint256 strike, uint256 cap)
        internal
        returns (SeriesConfig memory c)
    {
        seriesCounter++;
        c = SeriesConfig({
            optionType: t,
            underlying: u,
            quote: q,
            strikePrice: strike,
            expiry: expiry,
            contractSize: 10 ** uint256(IERC20Metadata(u).decimals()),
            optionDecimals: OPTION_DECIMALS,
            minOptionAmount: MIN_OPTION_AMOUNT,
            maxTotalShortAmount: cap,
            chainlinkFeed: address(feed),
            maxChainlinkAgeAtExpiry: MAX_AGE,
            name: "Optara Option",
            symbol: "OPT"
        });
    }

    function _deployWith(SeriesConfig memory c, uint16 mintFeeBps, uint16 exerciseFeeBps)
        internal
        returns (OptionSeriesVault)
    {
        return CloneHelper.deployVaultClone(
            vaultImplementation,
            address(factory),
            keccak256(abi.encode("series", seriesCounter)),
            c,
            FeeConfig({mintFeeBps: mintFeeBps, exerciseFeeBps: exerciseFeeBps})
        );
    }

    function _deploy(
        OptionType t,
        address u,
        address q,
        uint256 strike,
        uint16 mintFeeBps,
        uint16 exerciseFeeBps,
        uint256 cap
    ) internal returns (OptionSeriesVault) {
        return _deployWith(_config(t, u, q, strike, cap), mintFeeBps, exerciseFeeBps);
    }

    /// Clones first (never reverts), THEN arms `vm.expectRevert(selector)` and calls `initialize` - so the
    /// expectation watches `initialize` itself rather than the clone's own CREATE. See CloneHelper.sol.
    function _expectInitializeRevert(bytes4 selector, SeriesConfig memory c, uint16 mintFeeBps, uint16 exerciseFeeBps)
        internal
    {
        OptionSeriesVault v = CloneHelper.cloneUninitialized(vaultImplementation);
        seriesCounter++;
        vm.expectRevert(selector);
        v.initialize(
            address(factory),
            keccak256(abi.encode("series", seriesCounter)),
            c,
            FeeConfig({mintFeeBps: mintFeeBps, exerciseFeeBps: exerciseFeeBps})
        );
    }

    // ------------------------------------------------------------------ actions

    /// Gives `who` enough collateral asset for `amount` options plus the fee, and approves the vault.
    function _fund(OptionSeriesVault v, address who, uint256 amount) internal {
        (uint256 col, uint256 fee) = v.previewMint(amount);
        address asset = v.collateralAsset(); // read BEFORE vm.prank: an external call would consume the prank
        IMintable(asset).mint(who, col + fee);
        vm.prank(who);
        IERC20(asset).approve(address(v), type(uint256).max);
    }

    /// `writer` mints `amount` options and the tokens go to `receiver`.
    function _mint(OptionSeriesVault v, address writer, address receiver, uint256 amount) internal {
        _fund(v, writer, amount);
        vm.prank(writer);
        v.mint(amount, receiver);
    }

    /// Publishes a round in force at expiry with `price18` (a multiple of 1e10) and a successor after expiry,
    /// moves time past expiry and settles. Returns the settlement price.
    function _settle(OptionSeriesVault v, uint256 price18) internal returns (uint256) {
        feed.push(_id(1, 1), int256(price18 / 1e10), expiry - 100);
        feed.push(_id(1, 2), int256(1e8), expiry + 100);
        vm.warp(expiry + 200);
        return v.settle(SettlementProof({chainlinkRoundId: _id(1, 1), chainlinkNextRoundId: _id(1, 2)}));
    }

    function _id(uint16 phase, uint64 agg) internal pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }

    /// The solvency relation that must hold at every moment.
    function _assertVaultSolvent(OptionSeriesVault v) internal view {
        assertGe(_bal(v.collateralAsset(), address(v)), v.collateralLocked() + v.accruedFees(), "vault under-collateralized");
    }
}
