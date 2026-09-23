// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {VaultDeployer, AlreadyBound} from "../src/VaultDeployer.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {OptionType, FeeConfig, SeriesConfig, OPTION_DECIMALS, MIN_OPTION_AMOUNT} from "../src/Types.sol";
import {Unauthorized} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockFactory} from "./mocks/MockFactory.sol";

/// @notice Every series vault is now an EIP-1167 minimal proxy clone of ONE implementation, initialized
///         instead of constructed. That pattern has its own well-known bug classes - an uninitialized
///         implementation contract that anyone can take over, double-initialization, and state accidentally
///         shared between clones - none of which existed when the vault was a plain deployment. This file
///         tests exactly those, on top of the ordinary mint/settle coverage every clone already gets by
///         being exercised through VaultBase in every other test file.
contract VaultDeployerTest is Test {
    VaultDeployer internal deployer;
    MockERC20 internal mon;
    MockERC20 internal usdc;
    MockAggregator internal feed;
    MockFactory internal factory;
    uint64 internal expiry;

    function setUp() public {
        vm.warp(1_700_000_000);
        expiry = uint64(block.timestamp + 7 days);
        deployer = new VaultDeployer();
        mon = new MockERC20("Wrapped MON", "WMON", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new MockAggregator(8);
        factory = new MockFactory();
        factory.setFeeRecipient(makeAddr("feeRecipient"));
    }

    function _config() internal view returns (SeriesConfig memory) {
        return SeriesConfig({
            optionType: OptionType.CALL,
            underlying: address(mon),
            quote: address(usdc),
            strikePrice: 10e18,
            expiry: expiry,
            contractSize: 1e18,
            optionDecimals: OPTION_DECIMALS,
            minOptionAmount: MIN_OPTION_AMOUNT,
            maxTotalShortAmount: 0,
            chainlinkFeed: address(feed),
            maxChainlinkAgeAtExpiry: 3600,
            name: "Optara Option",
            symbol: "OPT"
        });
    }

    // ================================================================== the implementation itself

    /// The implementation VaultDeployer deploys must never be usable as a real series: its constructor calls
    /// `_disableInitializers()`, so `initialize` on it must always revert, for any caller, forever.
    function test_implementation_canNeverBeInitialized() public {
        address impl = deployer.implementation();
        assertGt(impl.code.length, 45, "implementation must be the real contract, not a clone");

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        OptionSeriesVault(impl).initialize(address(factory), keccak256("x"), _config(), FeeConfig(0, 0));
    }

    /// Same property, from a completely unrelated caller: disabling initializers is not an access-control
    /// check that a particular address bypasses, it is unconditional.
    function test_implementation_canNeverBeInitialized_byAnyone() public {
        address impl = deployer.implementation();
        vm.prank(makeAddr("randomAttacker"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        OptionSeriesVault(impl).initialize(address(factory), keccak256("y"), _config(), FeeConfig(0, 0));
    }

    // ================================================================== double initialization

    /// A real clone, once initialized by `deploy`, can never be initialized again by anyone - not with the
    /// same parameters, not with different ones (which would otherwise let an attacker hijack a live series'
    /// factory pointer, fee rates, or collateral asset after the fact).
    function test_clone_cannotBeInitializedTwice() public {
        deployer.bind();
        address vault = deployer.deploy(keccak256("series-1"), _config(), FeeConfig(10, 25));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        OptionSeriesVault(vault).initialize(address(factory), keccak256("series-1"), _config(), FeeConfig(10, 25));

        // Not even with a completely different, otherwise-valid config and a different caller.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        OptionSeriesVault(vault).initialize(makeAddr("fakeFactory"), keccak256("series-2"), _config(), FeeConfig(5, 5));
    }

    // ================================================================== storage isolation between clones

    /// Two clones of the SAME implementation must never share state. This is the core risk this migration
    /// introduces relative to the old plain-deployment vault: if delegatecall or storage layout were wrong,
    /// writing to one series could corrupt another. Mint into two independently-deployed series and confirm
    /// each vault's accounting reflects only its own activity.
    function test_twoClones_haveCompletelyIndependentStorage() public {
        deployer.bind();
        SeriesConfig memory cA = _config();
        SeriesConfig memory cB = _config();
        cB.strikePrice = 20e18; // a different series, different identity

        OptionSeriesVault vaultA = OptionSeriesVault(deployer.deploy(keccak256("A"), cA, FeeConfig(10, 25)));
        OptionSeriesVault vaultB = OptionSeriesVault(deployer.deploy(keccak256("B"), cB, FeeConfig(10, 25)));

        assertTrue(vaultA != vaultB, "clones must be distinct addresses");
        assertEq(vaultA.strikePrice(), 10e18);
        assertEq(vaultB.strikePrice(), 20e18);

        address writer = makeAddr("writer");
        (uint256 col, uint256 fee) = vaultA.previewMint(5e18);
        mon.mint(writer, col + fee);
        vm.prank(writer);
        mon.approve(address(vaultA), type(uint256).max);
        vm.prank(writer);
        vaultA.mint(5e18, writer);

        // Only A moved. B's storage - collateralLocked, totalShortAmount, the writer's short balance, and
        // its own token balance - must be completely untouched by A's mint.
        assertEq(vaultA.collateralLocked(), 5e18);
        assertEq(vaultB.collateralLocked(), 0, "mint on clone A leaked into clone B's collateralLocked");
        assertEq(vaultA.totalShortAmount(), 5e18);
        assertEq(vaultB.totalShortAmount(), 0, "mint on clone A leaked into clone B's totalShortAmount");
        assertEq(vaultA.balanceOf(writer), 5e18);
        assertEq(vaultB.balanceOf(writer), 0, "mint on clone A leaked into clone B's token balance");
        assertEq(vaultA.writerShortBalance(writer), 5e18);
        assertEq(vaultB.writerShortBalance(writer), 0, "mint on clone A leaked into clone B's short balance");
    }

    // ================================================================== deploy() mechanics

    function test_deploy_producesARealMinimalProxy() public {
        deployer.bind();
        address vault = deployer.deploy(keccak256("series"), _config(), FeeConfig(10, 25));

        // EIP-1167: exactly 45 bytes, dramatically smaller than the real implementation.
        assertEq(vault.code.length, 45, "clone must be the standard EIP-1167 minimal proxy size");
        assertGt(deployer.implementation().code.length, 45);
        assertTrue(vault != deployer.implementation());
    }

    function test_deploy_onlyBoundFactory() public {
        deployer.bind(); // this test contract becomes "factory"
        vm.prank(makeAddr("notTheFactory"));
        vm.expectRevert(Unauthorized.selector);
        deployer.deploy(keccak256("series"), _config(), FeeConfig(10, 25));
    }

    function test_bind_onlyOnce() public {
        deployer.bind();
        vm.expectRevert(AlreadyBound.selector);
        deployer.bind();
    }
}
