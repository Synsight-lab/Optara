// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {
    OptionType,
    FeeConfig,
    SeriesConfig,
    SettlementProof,
    ADMIN_ROLE,
    PAUSER_ROLE,
    OPTION_DECIMALS,
    MIN_OPTION_AMOUNT
} from "../src/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockFactory} from "./mocks/MockFactory.sol";
import {CloneHelper} from "./base/CloneHelper.sol";

/// @notice Drives random sequences of every vault action from a small set of externally owned actors and keeps
///         ghost totals so the invariant tests can check exact conservation.
contract VaultHandler is Test {
    OptionSeriesVault public vault;
    MockERC20 public collateral;
    MockAggregator public feed;
    MockFactory public factory;

    address[4] public actors;
    address public admin;
    address public pauser;
    address public feeRecipient;
    uint64 public expiry;

    // ghost totals
    uint256 public ghostTokensMinted; // collateral tokens created for the actors (every deposit came from here)
    uint256 public ghostCollateralLocked; // sum of collateral locked by mints
    uint256 public ghostOperations; // mints + redeems + claims + paid accounts: dust is bounded by this
    uint256 public ghostSwept;
    bool public unexpectedRevert; // an exit that must succeed reverted

    // write-once snapshot of the settlement result
    bool public snapshotTaken;
    uint256 public snapPrice;
    uint256 public snapBuyerRate;
    uint256 public snapWriterRate;

    constructor(OptionSeriesVault vault_, MockAggregator feed_, MockFactory factory_, address admin_, address pauser_, address feeRecipient_, uint64 expiry_) {
        vault = vault_;
        feed = feed_;
        factory = factory_;
        admin = admin_;
        pauser = pauser_;
        feeRecipient = feeRecipient_;
        expiry = expiry_;
        collateral = MockERC20(vault_.collateralAsset());
        for (uint256 i; i < 4; i++) {
            actors[i] = address(uint160(0xA000 + i));
        }
    }

    function actorsList() external view returns (address[4] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    // ------------------------------------------------------------------ actions

    function mint(uint256 writerSeed, uint256 receiverSeed, uint256 amountSeed) external {
        if (vault.settled() || block.timestamp >= expiry) return;
        address writer = _actor(writerSeed);
        address receiver = _actor(receiverSeed);
        uint256 amount = bound(amountSeed, MIN_OPTION_AMOUNT, 1e22);

        (uint256 col, uint256 fee) = vault.previewMint(amount);
        collateral.mint(writer, col + fee);
        ghostTokensMinted += col + fee;
        vm.prank(writer);
        collateral.approve(address(vault), type(uint256).max);

        vm.prank(writer);
        try vault.mint(amount, receiver) returns (uint256 c, uint256) {
            ghostCollateralLocked += c;
            ghostOperations++;
        } catch {
            // frozen or capped: acceptable, nothing changed
        }
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(from);
        vault.transfer(to, amount);
    }

    /// Publishes the round in force at expiry and its successor, moves time past expiry and settles. Once.
    function settle(uint256 priceSeed) external {
        if (vault.settled()) return;
        int256 answer = int256(bound(priceSeed, 1e6, 1000e8)); // 0.01 to 1000 at 8 decimals
        feed.push((uint80(1) << 64) | 1, answer, expiry - 100);
        feed.push((uint80(1) << 64) | 2, 1e8, expiry + 100);
        if (block.timestamp < expiry + 200) vm.warp(expiry + 200);
        vault.settle(SettlementProof((uint80(1) << 64) | 1, (uint80(1) << 64) | 2));
        _snapshot();
    }

    function redeem(uint256 holderSeed, uint256 amountSeed) external {
        if (!vault.settled()) return;
        address holder = _actor(holderSeed);
        uint256 bal = vault.balanceOf(holder);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(holder);
        try vault.redeem(amount, holder) {
            ghostOperations++;
        } catch {
            unexpectedRevert = true; // a valid redemption must never revert, frozen or not
        }
    }

    function claim(uint256 writerSeed, uint256 amountSeed) external {
        if (!vault.settled()) return;
        address writer = _actor(writerSeed);
        uint256 short_ = vault.writerShortBalance(writer);
        if (short_ == 0) return;
        uint256 amount = bound(amountSeed, 1, short_);
        vm.prank(writer);
        try vault.claimWriterResidual(amount, writer) {
            ghostOperations++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// A keeper pays every actor in one call.
    function payoutAll() external {
        if (!vault.settled()) return;
        address[] memory list = new address[](5);
        for (uint256 i; i < 4; i++) {
            list[i] = actors[i];
        }
        list[4] = address(0);
        ghostOperations += 8; // at most one redeem and one claim per actor
        vm.prank(makeAddr("keeper"));
        try vault.payout(list) {} catch {
            unexpectedRevert = true;
        }
    }

    function sweep() external {
        if (vault.accruedFees() == 0) return;
        uint256 amount = vault.accruedFees();
        vm.prank(admin);
        try vault.sweepFees() returns (uint256 swept) {
            ghostSwept += swept;
            assertEq(swept, amount);
        } catch {
            unexpectedRevert = true;
        }
    }

    function freeze(bool paused, bool byAdmin) external {
        if (paused) {
            vm.prank(byAdmin ? admin : pauser);
            vault.setMintPaused(true);
        } else {
            vm.prank(admin);
            vault.setMintPaused(false);
        }
    }

    function _snapshot() internal {
        snapshotTaken = true;
        snapPrice = vault.settlementPrice();
        snapBuyerRate = vault.buyerPayoutRate();
        snapWriterRate = vault.writerResidualRate();
    }
}

/// @notice The vault's invariants, checked after every step of a random sequence of actions.
abstract contract VaultInvariantBase is Test {
    VaultHandler internal handler;
    OptionSeriesVault internal vault;
    MockERC20 internal collateral;
    MockFactory internal factory;
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal vaultImplementation; // one implementation, cloned for every series in these tests

    function _deployVault(MockFactory factory_, MockAggregator feed_, uint64 expiry_) internal virtual returns (OptionSeriesVault);

    function setUp() public {
        vm.warp(1_700_000_000);
        uint64 expiry = uint64(block.timestamp + 7 days);
        address admin = makeAddr("admin");
        address pauser = makeAddr("pauser");

        vaultImplementation = CloneHelper.deployImplementation();
        factory = new MockFactory();
        factory.setRole(ADMIN_ROLE, admin, true);
        factory.setRole(PAUSER_ROLE, pauser, true);
        factory.setFeeRecipient(feeRecipient);
        MockAggregator feed = new MockAggregator(8);

        vault = _deployVaultWithExpiry(factory, feed, expiry);
        collateral = MockERC20(vault.collateralAsset());
        handler = new VaultHandler(vault, feed, factory, admin, pauser, feeRecipient, expiry);

        targetContract(address(handler));
    }

    function _deployVaultWithExpiry(MockFactory factory_, MockAggregator feed_, uint64 expiry_)
        internal
        virtual
        returns (OptionSeriesVault);

    function _sumActors(function(address) view returns (uint256) f) internal view returns (uint256 total) {
        address[4] memory a = handler.actorsList();
        for (uint256 i; i < 4; i++) {
            total += f(a[i]);
        }
    }

    function _short(address a) internal view returns (uint256) {
        return vault.writerShortBalance(a);
    }

    function _bal(address a) internal view returns (uint256) {
        return vault.balanceOf(a);
    }

    function _col(address a) internal view returns (uint256) {
        return collateral.balanceOf(a);
    }

    // ------------------------------------------------------------------ the invariants

    /// The vault always holds at least the collateral backing claims plus the accrued fees.
    function invariant_vaultIsAlwaysSolvent() public view {
        assertGe(collateral.balanceOf(address(vault)), vault.collateralLocked() + vault.accruedFees());
    }

    /// Dust is never negative and is bounded by about one unit of collateral per operation.
    function invariant_dustIsNonNegativeAndBounded() public view {
        uint256 bal = collateral.balanceOf(address(vault));
        uint256 dust = bal - (vault.collateralLocked() + vault.accruedFees());
        assertLe(dust, handler.ghostOperations() + 1);
    }

    /// Every unit of collateral that ever entered is either still locked, paid to a claimant, or a fee.
    function invariant_lockedPlusClaimedEqualsEverLocked() public view {
        assertEq(
            vault.totalBuyerPayoutClaimed() + vault.totalWriterResidualClaimed() + vault.collateralLocked(),
            handler.ghostCollateralLocked()
        );
    }

    /// Conservation of tokens: nothing leaks to an address the protocol did not intend.
    function invariant_noCollateralLeaksAnywhere() public view {
        uint256 total = collateral.balanceOf(address(vault)) + collateral.balanceOf(feeRecipient) + _sumActors(_col);
        assertEq(total, handler.ghostTokensMinted());
    }

    /// Before settlement, supply equals short amount, and shorts are fully accounted for.
    function invariant_supplyAndShortsAreConsistent() public view {
        assertLe(vault.totalSupply(), vault.totalShortAmount());
        if (!vault.settled()) {
            assertEq(vault.totalSupply(), vault.totalShortAmount());
        }
        assertEq(_sumActors(_short), vault.totalUnclaimedShortAmount());
        assertLe(vault.totalUnclaimedShortAmount(), vault.totalShortAmount());
        assertEq(_sumActors(_bal), vault.totalSupply());
    }

    /// The residual rate is always the subtraction, so the identity is exact.
    function invariant_settlementIdentityIsExact() public view {
        if (!vault.settled()) return;
        assertEq(vault.buyerPayoutRate() + vault.writerResidualRate(), vault.collateralPerOption());
    }

    /// The settlement result is written once and never changes.
    function invariant_settlementIsWriteOnce() public view {
        if (!handler.snapshotTaken()) {
            assertEq(vault.settlementPrice(), 0);
            assertEq(vault.buyerPayoutRate(), 0);
            return;
        }
        assertEq(vault.settlementPrice(), handler.snapPrice());
        assertEq(vault.buyerPayoutRate(), handler.snapBuyerRate());
        assertEq(vault.writerResidualRate(), handler.snapWriterRate());
    }

    /// A valid exit never reverts, whether or not the series is frozen and whatever else happened.
    function invariant_validExitsNeverRevert() public view {
        assertFalse(handler.unexpectedRevert());
    }

    /// Fees are separate from collateral: what was swept plus what is accrued plus what is locked plus what was
    /// paid out never exceeds what came in.
    function invariant_feesNeverComeOutOfBackingCollateral() public view {
        assertLe(
            vault.collateralLocked() + vault.accruedFees() + handler.ghostSwept(),
            handler.ghostTokensMinted()
        );
    }

    /// Fully paid out, nothing but fees and dust remains in the vault.
    function invariant_whenEveryoneIsPaidOnlyFeesAndDustRemain() public view {
        if (vault.settled() && vault.totalSupply() == 0 && vault.totalUnclaimedShortAmount() == 0) {
            assertEq(vault.collateralLocked() <= handler.ghostOperations() + 1, true);
        }
    }
}

/// A call on WMON (18 dp) against USDC (6 dp), strike 10, with fees.
contract VaultInvariantCall is VaultInvariantBase {
    function _deployVault(MockFactory, MockAggregator, uint64) internal pure override returns (OptionSeriesVault) {
        revert("unused");
    }

    function _deployVaultWithExpiry(MockFactory factory_, MockAggregator feed_, uint64 expiry_)
        internal
        override
        returns (OptionSeriesVault)
    {
        MockERC20 mon = new MockERC20("Wrapped MON", "WMON", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        SeriesConfig memory c = SeriesConfig({
            optionType: OptionType.CALL,
            underlying: address(mon),
            quote: address(usdc),
            strikePrice: 10e18,
            expiry: expiry_,
            contractSize: 1e18,
            optionDecimals: OPTION_DECIMALS,
            minOptionAmount: MIN_OPTION_AMOUNT,
            maxTotalShortAmount: 0,
            chainlinkFeed: address(feed_),
            maxChainlinkAgeAtExpiry: 3600,
            name: "Optara Option",
            symbol: "OPT"
        });
        return CloneHelper.deployVaultClone(vaultImplementation, address(factory_), keccak256("call"), c, FeeConfig(10, 25));
    }
}

/// A put on WBTC (8 dp) against USDC (6 dp), strike 60,000, with fees. Collateralized in USDC.
contract VaultInvariantPut is VaultInvariantBase {
    function _deployVault(MockFactory, MockAggregator, uint64) internal pure override returns (OptionSeriesVault) {
        revert("unused");
    }

    function _deployVaultWithExpiry(MockFactory factory_, MockAggregator feed_, uint64 expiry_)
        internal
        override
        returns (OptionSeriesVault)
    {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        SeriesConfig memory c = SeriesConfig({
            optionType: OptionType.PUT,
            underlying: address(wbtc),
            quote: address(usdc),
            strikePrice: 500e18, // the handler prices 0.01 to 1000, so this put is in the money across the range
            expiry: expiry_,
            contractSize: 1e8,
            optionDecimals: OPTION_DECIMALS,
            minOptionAmount: MIN_OPTION_AMOUNT,
            maxTotalShortAmount: 0,
            chainlinkFeed: address(feed_),
            maxChainlinkAgeAtExpiry: 3600,
            name: "Optara Option",
            symbol: "OPT"
        });
        return CloneHelper.deployVaultClone(vaultImplementation, address(factory_), keccak256("put"), c, FeeConfig(10, 25));
    }
}
