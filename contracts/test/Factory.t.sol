// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OptionSeriesFactory} from "../src/OptionSeriesFactory.sol";
import {OptionSeriesVault} from "../src/OptionSeriesVault.sol";
import {VaultDeployer, AlreadyBound} from "../src/VaultDeployer.sol";
import {IVaultDeployer} from "../src/interfaces/IVaultDeployer.sol";
import {
    OptionType,
    CreateSeriesParams,
    PairConfig,
    FeeConfig,
    SeriesInfo,
    SeriesConfig,
    SettlementProof,
    MAX_MINT_FEE_BPS,
    MAX_EXERCISE_FEE_BPS,
    MAX_EXPIRY_DELAY,
    MIN_OPTION_AMOUNT,
    EXPIRY_SLOT_OFFSET,
    ADMIN_ROLE,
    PAUSER_ROLE
} from "../src/Types.sol";
import "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {NoSymbolToken} from "./mocks/HostileTokens.sol";

interface IMint {
    function mint(address to, uint256 amount) external;
}

/// The factory: permissionless creation within fixed limits, the ADMIN-approved feed per pair, generated names,
/// duplicates revert, and the two roles.
contract FactoryTest is Test {
    OptionSeriesFactory internal factory;
    VaultDeployer internal deployer;

    MockERC20 internal mon; // 18 dp
    MockERC20 internal usdc; // 6 dp
    MockERC20 internal wbtc; // 8 dp
    MockAggregator internal monFeed;
    MockAggregator internal btcFeed;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MON_STEP = 0.5e18;
    uint256 internal constant BTC_STEP = 100e18;
    uint32 internal constant MAX_AGE = 3600;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        mon = new MockERC20("Wrapped MON", "WMON", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        monFeed = new MockAggregator(8);
        btcFeed = new MockAggregator(8);
        monFeed.push(_id(1, 1), 10e8, block.timestamp);
        btcFeed.push(_id(1, 1), 60000e8, block.timestamp);

        deployer = new VaultDeployer();
        factory = new OptionSeriesFactory(admin, IVaultDeployer(address(deployer)));

        vm.startPrank(admin);
        factory.setAllowedAsset(address(mon), true);
        factory.setAllowedAsset(address(usdc), true);
        factory.setAllowedAsset(address(wbtc), true);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(monFeed), MAX_AGE, MON_STEP));
        factory.setPairConfig(address(wbtc), address(usdc), PairConfig(address(btcFeed), MAX_AGE, BTC_STEP));
        factory.setDefaultFeeConfig(FeeConfig(10, 25));
        factory.setFeeRecipient(feeRecipient);
        factory.grantRole(PAUSER_ROLE, pauser);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _id(uint16 phase, uint64 agg) internal pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
    }

    /// The 08:00 UTC slot `daysAhead` days after the next UTC midnight. Always at least 8 hours away.
    function _slot(uint256 daysAhead) internal view returns (uint64) {
        return uint64(((block.timestamp / 1 days) + 1 + daysAhead) * 1 days + EXPIRY_SLOT_OFFSET);
    }

    function _monCall(uint256 strike, uint64 expiry) internal view returns (CreateSeriesParams memory) {
        return CreateSeriesParams({
            optionType: OptionType.CALL,
            underlying: address(mon),
            quote: address(usdc),
            strikePrice: strike,
            expiry: expiry,
            chainlinkFeed: address(monFeed)
        });
    }

    function _create(CreateSeriesParams memory p) internal returns (OptionSeriesVault v, bytes32 id) {
        vm.prank(alice);
        (bytes32 seriesId, address vault) = factory.createSeries(p);
        return (OptionSeriesVault(vault), seriesId);
    }

    // ================================================================== deployment and wiring

    function test_deployment_wiring() public view {
        assertEq(address(factory.deployer()), address(deployer));
        assertEq(deployer.factory(), address(factory));
        assertTrue(factory.hasRole(ADMIN_ROLE, admin));
        assertFalse(factory.hasRole(ADMIN_ROLE, address(this))); // the deployer keeps nothing
        assertEq(factory.seriesCount(), 0);
        assertFalse(factory.creationPaused());
    }

    function test_deployment_rejectsZeroAddresses() public {
        VaultDeployer d = new VaultDeployer();
        vm.expectRevert(ZeroAddress.selector);
        new OptionSeriesFactory(address(0), IVaultDeployer(address(d)));
        vm.expectRevert(ZeroAddress.selector);
        new OptionSeriesFactory(admin, IVaultDeployer(address(0)));
    }

    function test_deployer_canBeBoundOnlyOnce() public {
        VaultDeployer d = new VaultDeployer();
        new OptionSeriesFactory(admin, IVaultDeployer(address(d)));
        // a second factory cannot take over a deployer that is already bound
        vm.expectRevert(AlreadyBound.selector);
        new OptionSeriesFactory(admin, IVaultDeployer(address(d)));
    }

    function test_deployer_frontRunBindMakesFactoryDeploymentRevert() public {
        VaultDeployer d = new VaultDeployer();
        vm.prank(stranger);
        d.bind(); // an attacker binds it first
        vm.expectRevert(AlreadyBound.selector);
        new OptionSeriesFactory(admin, IVaultDeployer(address(d)));
    }

    function test_deployer_onlyTheFactoryCanDeploy() public {
        SeriesConfig memory c;
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        deployer.deploy(bytes32(uint256(1)), c, FeeConfig(0, 0));
    }

    function test_deployment_factoryFitsTheContractSizeLimit() public view {
        assertLt(address(factory).code.length, 24_576);
        assertLt(address(deployer).code.length, 24_576);
    }

    // ================================================================== anyone can create

    function test_create_anyoneWithNoRoleCanCreateASeries() public {
        assertFalse(factory.hasRole(ADMIN_ROLE, stranger));
        assertFalse(factory.hasRole(PAUSER_ROLE, stranger));
        vm.prank(stranger);
        (bytes32 id, address vault) = factory.createSeries(_monCall(10e18, _slot(2)));
        assertTrue(vault != address(0));
        assertEq(factory.vaultOf(id), vault);
    }

    function test_create_registersAndFixesEverythingTheFactoryControls() public {
        vm.prank(admin);
        factory.setMaxShortAmount(address(mon), 1000e18);
        uint64 expiry = _slot(3);

        vm.recordLogs();
        (OptionSeriesVault v, bytes32 id) = _create(_monCall(12e18, expiry));

        // registry, both directions
        assertEq(factory.vaultOf(id), address(v));
        assertEq(factory.seriesIdOf(address(v)), id);
        assertTrue(factory.isOptionToken(address(v)));
        assertEq(factory.seriesCount(), 1);
        assertEq(v.seriesId(), id);

        // what the user chose
        SeriesInfo memory i = v.seriesInfo();
        assertEq(uint8(i.optionType), uint8(OptionType.CALL));
        assertEq(i.underlying, address(mon));
        assertEq(i.quote, address(usdc));
        assertEq(i.strikePrice, 12e18);
        assertEq(i.expiry, expiry);
        assertEq(i.chainlinkFeed, address(monFeed));

        // what the factory fixed
        assertEq(i.contractSize, 1e18); // one whole underlying
        assertEq(i.optionDecimals, 18);
        assertEq(i.minOptionAmount, MIN_OPTION_AMOUNT);
        assertEq(i.maxTotalShortAmount, 1000e18); // the underlying's cap, snapshotted
        assertEq(i.maxChainlinkAgeAtExpiry, MAX_AGE); // the pair's value, snapshotted
        assertEq(i.mintFeeBps, 10);
        assertEq(i.exerciseFeeBps, 25);
        assertEq(address(v.factory()), address(factory));

        // generated names: nothing a user typed reaches the metadata, and the REAL pair is always in them
        assertEq(v.name(), "Optara WMON/USDC Call #1");
        assertEq(v.symbol(), "OPT-WMON-USDC-C-1");
        assertEq(v.decimals(), 18);

        // the event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 k; k < logs.length; k++) {
            if (logs[k].emitter == address(factory) && logs[k].topics[0] == OptionSeriesFactory.SeriesCreated.selector) {
                found = true;
                assertEq(logs[k].topics[1], id);
                assertEq(address(uint160(uint256(logs[k].topics[2]))), address(v));
                assertEq(address(uint160(uint256(logs[k].topics[3]))), alice); // the creator
            }
        }
        assertTrue(found);
    }

    function test_create_lowDecimalUnderlyingGetsItsOwnContractSize() public {
        CreateSeriesParams memory p = CreateSeriesParams({
            optionType: OptionType.PUT,
            underlying: address(wbtc),
            quote: address(usdc),
            strikePrice: 60000e18,
            expiry: _slot(2),
            chainlinkFeed: address(btcFeed)
        });
        (OptionSeriesVault v,) = _create(p);
        assertEq(v.contractSize(), 1e8); // one whole BTC
        assertEq(v.collateralAsset(), address(usdc)); // a put is collateralized in the quote
        assertEq(v.collateralPerOption(), 6e10); // Vector 6
        assertEq(v.maxTotalShortAmount(), 0); // no cap set for WBTC
    }

    function test_create_namesIncreaseByOne() public {
        (OptionSeriesVault a,) = _create(_monCall(10e18, _slot(2)));
        (OptionSeriesVault b,) = _create(_monCall(11e18, _slot(2)));
        (OptionSeriesVault c,) = _create(_monCall(10e18, _slot(3)));
        assertEq(a.name(), "Optara WMON/USDC Call #1");
        assertEq(b.name(), "Optara WMON/USDC Call #2");
        assertEq(c.symbol(), "OPT-WMON-USDC-C-3");
        assertEq(factory.seriesCount(), 3);
    }

    /// The name and symbol always carry the pair the series actually uses, read from the tokens themselves.
    function test_names_alwaysCarryTheRealPairAndOptionType() public {
        (OptionSeriesVault call,) = _create(_monCall(10e18, _slot(2)));
        CreateSeriesParams memory put = _monCall(10e18, _slot(2));
        put.optionType = OptionType.PUT;
        (OptionSeriesVault asPut,) = _create(put);
        (OptionSeriesVault btc,) = _create(
            CreateSeriesParams({
                optionType: OptionType.PUT,
                underlying: address(wbtc),
                quote: address(usdc),
                strikePrice: 60000e18,
                expiry: _slot(2),
                chainlinkFeed: address(btcFeed)
            })
        );

        assertEq(call.name(), "Optara WMON/USDC Call #1");
        assertEq(call.symbol(), "OPT-WMON-USDC-C-1");
        assertEq(asPut.name(), "Optara WMON/USDC Put #2");
        assertEq(asPut.symbol(), "OPT-WMON-USDC-P-2");
        assertEq(btc.name(), "Optara WBTC/USDC Put #3");
        assertEq(btc.symbol(), "OPT-WBTC-USDC-P-3");

        // the pair in the name is the pair of the actual assets, read from them
        assertEq(MockERC20(call.underlying()).symbol(), "WMON");
        assertEq(MockERC20(call.quote()).symbol(), "USDC");
        assertEq(MockERC20(btc.underlying()).symbol(), "WBTC");
    }

    /// If a token has no symbol() creation still works, and the name says so instead of guessing.
    function test_names_aTokenWithoutASymbolFallsBackToAQuestionMark() public {
        NoSymbolToken bare = new NoSymbolToken();
        vm.startPrank(admin);
        factory.setAllowedAsset(address(bare), true);
        factory.setPairConfig(address(bare), address(usdc), PairConfig(address(monFeed), MAX_AGE, MON_STEP));
        vm.stopPrank();
        CreateSeriesParams memory p = _monCall(10e18, _slot(2));
        p.underlying = address(bare);
        (OptionSeriesVault v,) = _create(p);
        assertEq(v.name(), "Optara ?/USDC Call #1");
        assertEq(v.symbol(), "OPT-?-USDC-C-1");
    }

    /// Nothing a creator supplies can change the metadata: two creators of otherwise different series get names
    /// that differ only by the running number and the option type.
    function test_names_areIndependentOfWhoCreatesTheSeries() public {
        vm.prank(alice);
        (, address a) = factory.createSeries(_monCall(10e18, _slot(2)));
        vm.prank(bob);
        (, address b) = factory.createSeries(_monCall(11e18, _slot(2)));
        assertEq(OptionSeriesVault(a).name(), "Optara WMON/USDC Call #1");
        assertEq(OptionSeriesVault(b).name(), "Optara WMON/USDC Call #2");
    }

    function test_computeSeriesId_matchesTheIdCreateSeriesAssigns() public {
        CreateSeriesParams memory p = _monCall(10e18, _slot(2));
        bytes32 predicted = factory.computeSeriesId(p);
        (, bytes32 actual) = _create(p);
        assertEq(predicted, actual);
    }

    function test_isOptionToken_falseForLookalikes() public {
        (OptionSeriesVault v,) = _create(_monCall(10e18, _slot(2)));
        // a token with the very same name and symbol is not official
        MockERC20 fake = new MockERC20(v.name(), v.symbol(), 18);
        assertFalse(factory.isOptionToken(address(fake)));
        assertFalse(factory.isOptionToken(address(0)));
        assertFalse(factory.isOptionToken(address(mon)));
        assertTrue(factory.isOptionToken(address(v)));
    }

    // ================================================================== duplicates

    function test_duplicate_alwaysReverts() public {
        CreateSeriesParams memory p = _monCall(10e18, _slot(2));
        (, bytes32 id) = _create(p);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DuplicateSeries.selector, id));
        factory.createSeries(p); // the same caller

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DuplicateSeries.selector, id));
        factory.createSeries(p); // anyone else

        assertEq(factory.seriesCount(), 1); // nothing was created
    }

    function test_duplicate_anyDifferenceIsADifferentSeries() public {
        (OptionSeriesVault base,) = _create(_monCall(10e18, _slot(2)));
        (OptionSeriesVault otherStrike,) = _create(_monCall(10.5e18, _slot(2)));
        (OptionSeriesVault otherExpiry,) = _create(_monCall(10e18, _slot(3)));
        CreateSeriesParams memory put = _monCall(10e18, _slot(2));
        put.optionType = OptionType.PUT;
        (OptionSeriesVault asPut,) = _create(put);

        address[4] memory vaults = [address(base), address(otherStrike), address(otherExpiry), address(asPut)];
        for (uint256 i; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(vaults[i] != vaults[j]);
            }
        }
        assertEq(asPut.collateralAsset(), address(usdc));
        assertEq(base.collateralAsset(), address(mon));
    }

    // ================================================================== creation limits

    function test_create_feedMustBeTheApprovedOne() public {
        MockAggregator other = new MockAggregator(8);
        other.push(_id(1, 1), 10e8, block.timestamp);
        CreateSeriesParams memory p = _monCall(10e18, _slot(2));

        p.chainlinkFeed = address(other); // a real-looking feed, but not the approved one
        vm.expectRevert(FeedNotApproved.selector);
        factory.createSeries(p);

        p.chainlinkFeed = address(btcFeed); // the approved feed of a DIFFERENT pair
        vm.expectRevert(FeedNotApproved.selector);
        factory.createSeries(p);

        p.chainlinkFeed = address(0);
        vm.expectRevert(FeedNotApproved.selector);
        factory.createSeries(p);
    }

    function test_create_pairWithNoApprovedFeedIsDisabled() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(admin);
        factory.setAllowedAsset(address(other), true);
        CreateSeriesParams memory p = _monCall(10e18, _slot(2));
        p.underlying = address(other);
        vm.expectRevert(FeedNotApproved.selector);
        factory.createSeries(p);
    }

    function test_create_assetChecks() public {
        CreateSeriesParams memory p = _monCall(10e18, _slot(2));

        p.underlying = address(0);
        vm.expectRevert(ZeroAddress.selector);
        factory.createSeries(p);

        p = _monCall(10e18, _slot(2));
        p.quote = address(0);
        vm.expectRevert(ZeroAddress.selector);
        factory.createSeries(p);

        p = _monCall(10e18, _slot(2));
        p.quote = p.underlying; // same asset on both sides
        vm.expectRevert(AssetNotAllowed.selector);
        factory.createSeries(p);

        MockERC20 notListed = new MockERC20("Not Listed", "NL", 18);
        p = _monCall(10e18, _slot(2));
        p.underlying = address(notListed);
        vm.expectRevert(AssetNotAllowed.selector);
        factory.createSeries(p);

        p = _monCall(10e18, _slot(2));
        p.quote = address(notListed);
        vm.expectRevert(AssetNotAllowed.selector);
        factory.createSeries(p);
    }

    function test_create_assetThatLosesItsAllowlistCannotBeUsed() public {
        vm.prank(admin);
        factory.setAllowedAsset(address(mon), false);
        vm.expectRevert(AssetNotAllowed.selector);
        factory.createSeries(_monCall(10e18, _slot(2)));
    }

    function test_create_strikeMustBeAMultipleOfTheStep() public {
        vm.expectRevert(InvalidStrike.selector);
        factory.createSeries(_monCall(0, _slot(2)));
        vm.expectRevert(InvalidStrike.selector);
        factory.createSeries(_monCall(10.01e18, _slot(2))); // not on the 0.50 grid
        vm.expectRevert(InvalidStrike.selector);
        factory.createSeries(_monCall(MON_STEP - 1, _slot(2)));
        factory.createSeries(_monCall(MON_STEP, _slot(2))); // the smallest valid strike
        factory.createSeries(_monCall(10.5e18, _slot(2)));
    }

    function test_create_expiryLimits() public {
        // in the past
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, uint64(block.timestamp - 1)));

        // on the slot but too far away: 30 days is the maximum
        uint64 farSlot = _slot(31);
        assertGt(farSlot, block.timestamp + MAX_EXPIRY_DELAY);
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, farSlot));

        // the last slot inside 30 days is fine
        uint64 lastOk = _slot(28);
        assertLe(lastOk, block.timestamp + MAX_EXPIRY_DELAY);
        factory.createSeries(_monCall(10e18, lastOk));
    }

    function test_create_expiryMustBeOnTheDailySlot() public {
        uint64 slot = _slot(2);
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, slot + 1)); // one second off the slot
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, slot - 1));
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, slot + 1 hours)); // 09:00 UTC
        factory.createSeries(_monCall(10e18, slot)); // 08:00 UTC
    }

    function test_create_expiryMustBeAtLeastAnHourAway() public {
        // move to 07:30 UTC: today's 08:00 slot is only 30 minutes away
        uint256 midnight = (block.timestamp / 1 days) * 1 days;
        vm.warp(midnight + 7.5 hours);
        uint64 todaySlot = uint64(midnight + EXPIRY_SLOT_OFFSET);
        assertEq(todaySlot, block.timestamp + 30 minutes);
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, todaySlot));

        // at 06:30 UTC the 08:00 slot is 90 minutes away: valid
        vm.warp(midnight + 6.5 hours);
        factory.createSeries(_monCall(10e18, todaySlot));
    }

    // ================================================================== freeze creation

    function test_creationPause_pauserAndAdminCanFreeze_onlyAdminCanUnfreeze() public {
        vm.prank(pauser);
        factory.setCreationPaused(true);
        assertTrue(factory.creationPaused());

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, ADMIN_ROLE)
        );
        factory.setCreationPaused(false); // a compromised pauser cannot undo it

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        factory.setCreationPaused(false);

        vm.prank(admin);
        factory.setCreationPaused(false);
        assertFalse(factory.creationPaused());

        vm.prank(admin);
        factory.setCreationPaused(true); // admin can freeze too
        assertTrue(factory.creationPaused());
    }

    function test_creationPause_strangersCannotFreeze() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER_ROLE)
        );
        factory.setCreationPaused(true);
    }

    function test_creationPause_blocksCreationButNotExistingSeries() public {
        (OptionSeriesVault v,) = _create(_monCall(10e18, _slot(2)));
        vm.prank(pauser);
        factory.setCreationPaused(true);

        vm.expectRevert(CreationPaused.selector);
        factory.createSeries(_monCall(11e18, _slot(2)));

        // the existing series is completely unaffected
        mon.mint(alice, 100e18);
        vm.startPrank(alice);
        mon.approve(address(v), type(uint256).max);
        v.mint(1e18, alice);
        vm.stopPrank();
        assertEq(v.totalSupply(), 1e18);
    }

    // ================================================================== ADMIN settings

    function test_admin_onlyAdminCanChangeSettings() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, ADMIN_ROLE);
        vm.startPrank(pauser); // the pauser is not an admin
        vm.expectRevert(unauthorized);
        factory.setAllowedAsset(address(mon), false);
        vm.expectRevert(unauthorized);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(monFeed), MAX_AGE, MON_STEP));
        vm.expectRevert(unauthorized);
        factory.setMaxShortAmount(address(mon), 1);
        vm.expectRevert(unauthorized);
        factory.setDefaultFeeConfig(FeeConfig(1, 1));
        vm.expectRevert(unauthorized);
        factory.setFeeRecipient(pauser);
        vm.expectRevert(unauthorized);
        factory.setKuruMarket(bytes32(uint256(1)), pauser);
        vm.expectRevert(unauthorized);
        factory.grantRole(PAUSER_ROLE, pauser);
        vm.stopPrank();

        // and nobody without a role can either
        vm.prank(stranger);
        vm.expectRevert();
        factory.setFeeRecipient(stranger);
    }

    function test_admin_onlyTwoRolesExist() public view {
        // the pauser role is administered by the admin, and there is no other role
        assertEq(factory.getRoleAdmin(PAUSER_ROLE), ADMIN_ROLE);
        assertEq(factory.getRoleAdmin(ADMIN_ROLE), ADMIN_ROLE);
        assertEq(PAUSER_ROLE, keccak256("PAUSER_ROLE"));
        assertEq(ADMIN_ROLE, bytes32(0));
        assertFalse(factory.hasRole(keccak256("CREATOR_ROLE"), admin));
        assertFalse(factory.hasRole(keccak256("CREATOR_ROLE"), address(this)));
    }

    function test_admin_adminCanGrantAndRevokeThePauser() public {
        address newPauser = makeAddr("newPauser");
        vm.startPrank(admin);
        factory.grantRole(PAUSER_ROLE, newPauser);
        assertTrue(factory.hasRole(PAUSER_ROLE, newPauser));
        factory.revokeRole(PAUSER_ROLE, newPauser);
        assertFalse(factory.hasRole(PAUSER_ROLE, newPauser));
        vm.stopPrank();
    }

    function test_allowAsset_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(ZeroAddress.selector);
        factory.setAllowedAsset(address(0), true);

        vm.expectRevert(InvalidDecimals.selector);
        factory.setAllowedAsset(makeAddr("notAContract"), true); // no code

        MockERC20 tooManyDecimals = new MockERC20("Big", "BIG", 19);
        vm.expectRevert(InvalidDecimals.selector);
        factory.setAllowedAsset(address(tooManyDecimals), true);

        // an address that has code but no decimals()
        vm.expectRevert(InvalidDecimals.selector);
        factory.setAllowedAsset(address(factory), true);
        vm.stopPrank();
    }

    function test_defaultFees_capsAndSnapshot() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeExceedsCap.selector);
        factory.setDefaultFeeConfig(FeeConfig(MAX_MINT_FEE_BPS + 1, 0));
        vm.expectRevert(FeeExceedsCap.selector);
        factory.setDefaultFeeConfig(FeeConfig(0, MAX_EXERCISE_FEE_BPS + 1));
        factory.setDefaultFeeConfig(FeeConfig(MAX_MINT_FEE_BPS, MAX_EXERCISE_FEE_BPS)); // exactly the caps
        factory.setDefaultFeeConfig(FeeConfig(10, 25));
        vm.stopPrank();

        (OptionSeriesVault before_,) = _create(_monCall(10e18, _slot(2)));
        assertEq(before_.mintFeeBps(), 10);

        vm.prank(admin);
        factory.setDefaultFeeConfig(FeeConfig(40, 60));
        (OptionSeriesVault after_,) = _create(_monCall(11e18, _slot(2)));

        // the earlier series keeps its rates for ever; only the later one gets the new ones
        assertEq(before_.mintFeeBps(), 10);
        assertEq(before_.exerciseFeeBps(), 25);
        assertEq(after_.mintFeeBps(), 40);
        assertEq(after_.exerciseFeeBps(), 60);
    }

    function test_maxShortAmount_snapshotPerUnderlying() public {
        vm.prank(admin);
        factory.setMaxShortAmount(address(mon), 50e18);
        (OptionSeriesVault a,) = _create(_monCall(10e18, _slot(2)));
        assertEq(a.maxTotalShortAmount(), 50e18);

        vm.prank(admin);
        factory.setMaxShortAmount(address(mon), 500e18); // raising the default...
        (OptionSeriesVault b,) = _create(_monCall(11e18, _slot(2)));
        assertEq(b.maxTotalShortAmount(), 500e18);
        assertEq(a.maxTotalShortAmount(), 50e18); // ...never raises a live series' cap

        // and the cap is enforced by the vault
        mon.mint(alice, 100e18);
        vm.startPrank(alice);
        mon.approve(address(a), type(uint256).max);
        a.mint(50e18, alice);
        vm.expectRevert(OpenInterestCapExceeded.selector);
        a.mint(1e16, alice);
        vm.stopPrank();
    }

    function test_feeRecipient_validationAndRotation() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        factory.setFeeRecipient(address(0));

        (OptionSeriesVault v,) = _create(_monCall(10e18, _slot(2)));
        mon.mint(alice, 100e18);
        vm.startPrank(alice);
        mon.approve(address(v), type(uint256).max);
        v.mint(10e18, alice);
        vm.stopPrank();

        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        factory.setFeeRecipient(newTreasury);
        vm.prank(admin);
        v.sweepFees();
        assertEq(mon.balanceOf(newTreasury), 1e16); // 10 bps of 10 MON, rotated recipient receives it
        assertEq(mon.balanceOf(feeRecipient), 0);
    }

    // ================================================================== pair config

    function test_pairConfig_validation() public {
        vm.startPrank(admin);
        MockAggregator good = new MockAggregator(8);
        good.push(_id(1, 1), 10e8, block.timestamp);

        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(good), 0, MON_STEP)); // zero age
        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(good), MAX_AGE, 0)); // zero step

        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(makeAddr("noCode"), MAX_AGE, MON_STEP));

        MockAggregator bigDecimals = new MockAggregator(19);
        bigDecimals.push(_id(1, 1), 10e8, block.timestamp);
        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(bigDecimals), MAX_AGE, MON_STEP));

        MockAggregator negative = new MockAggregator(8);
        negative.push(_id(1, 1), -1, block.timestamp);
        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(negative), MAX_AGE, MON_STEP));

        MockAggregator zeroAnswer = new MockAggregator(8);
        zeroAnswer.push(_id(1, 1), 0, block.timestamp);
        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(zeroAnswer), MAX_AGE, MON_STEP));

        MockAggregator empty = new MockAggregator(8); // no rounds at all
        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(empty), MAX_AGE, MON_STEP));

        MockAggregator broken = new MockAggregator(8);
        broken.push(_id(1, 1), 10e8, block.timestamp);
        broken.setBroken(true);
        vm.expectRevert(InvalidOracleConfig.selector);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(broken), MAX_AGE, MON_STEP));

        // both assets must be allowlisted to approve a feed for them
        MockERC20 notListed = new MockERC20("NL", "NL", 18);
        vm.expectRevert(AssetNotAllowed.selector);
        factory.setPairConfig(address(notListed), address(usdc), PairConfig(address(good), MAX_AGE, MON_STEP));
        vm.stopPrank();
    }

    function test_pairConfig_changesAffectOnlyNewSeries() public {
        (OptionSeriesVault old,) = _create(_monCall(10e18, _slot(2)));

        MockAggregator newFeed = new MockAggregator(18);
        newFeed.push(_id(1, 1), 10e18, block.timestamp);
        vm.prank(admin);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(newFeed), 7200, 1e18));

        // the old series keeps its feed and window for ever
        assertEq(old.chainlinkFeed(), address(monFeed));
        assertEq(old.maxChainlinkAgeAtExpiry(), MAX_AGE);
        assertEq(old.feedDecimals(), 8);

        // the old feed can no longer be used for new series
        vm.expectRevert(FeedNotApproved.selector);
        factory.createSeries(_monCall(11e18, _slot(2)));

        // the new one can, with the new step (1.0) and window
        CreateSeriesParams memory p = _monCall(11e18, _slot(2));
        p.chainlinkFeed = address(newFeed);
        CreateSeriesParams memory offGrid = _monCall(11.5e18, _slot(2)); // separate struct: no memory aliasing
        offGrid.chainlinkFeed = address(newFeed);
        vm.expectRevert(InvalidStrike.selector); // valid under the old 0.5 step, invalid under the new 1.0 step
        factory.createSeries(offGrid);
        vm.prank(alice);
        (, address vault) = factory.createSeries(p);
        assertEq(OptionSeriesVault(vault).chainlinkFeed(), address(newFeed));
        assertEq(OptionSeriesVault(vault).maxChainlinkAgeAtExpiry(), 7200);
        assertEq(OptionSeriesVault(vault).feedDecimals(), 18);
    }

    function test_pairConfig_disablingAPair() public {
        (OptionSeriesVault old,) = _create(_monCall(10e18, _slot(2)));
        vm.prank(admin);
        factory.setPairConfig(address(mon), address(usdc), PairConfig(address(0), 0, 0)); // disable

        vm.expectRevert(FeedNotApproved.selector);
        factory.createSeries(_monCall(11e18, _slot(2)));

        // an existing series is untouched
        assertEq(old.chainlinkFeed(), address(monFeed));
        (address feedAfter,,) = factory.pairConfig(factory.pairKey(address(mon), address(usdc)));
        assertEq(feedAfter, address(0));
    }

    // ================================================================== Kuru pointer

    function test_kuruMarket_writeOnceAdminOnly() public {
        (, bytes32 id) = _create(_monCall(10e18, _slot(2)));
        address market = makeAddr("kuruMarket");

        vm.startPrank(admin);
        vm.expectRevert(SeriesNotFound.selector);
        factory.setKuruMarket(bytes32(uint256(999)), market);
        vm.expectRevert(ZeroAddress.selector);
        factory.setKuruMarket(id, address(0));

        factory.setKuruMarket(id, market);
        assertEq(factory.kuruMarketOf(id), market);

        vm.expectRevert(KuruMarketAlreadySet.selector);
        factory.setKuruMarket(id, makeAddr("otherMarket")); // write-once
        vm.stopPrank();
        assertEq(factory.kuruMarketOf(id), market);
    }

    // ================================================================== full lifecycle through the factory

    function test_lifecycle_createMintSettleRedeemClaimSweep() public {
        uint64 expiry = _slot(2);
        (OptionSeriesVault v,) = _create(_monCall(10e18, expiry));

        // alice writes 5 options and sells them to bob
        mon.mint(alice, 5.005e18);
        vm.startPrank(alice);
        mon.approve(address(v), type(uint256).max);
        v.mint(5e18, bob);
        vm.stopPrank();
        assertEq(v.balanceOf(bob), 5e18);

        // the price at expiry is 12.50
        monFeed.push(_id(1, 2), 12.5e8, expiry - 100);
        monFeed.push(_id(1, 3), 13e8, expiry + 100);
        vm.warp(expiry + 1 hours);
        vm.prank(stranger);
        v.settle(SettlementProof(_id(1, 2), _id(1, 3)));
        assertEq(v.buyerPayoutRate(), 2e17);

        // a keeper pays everyone
        address[] memory list = new address[](2);
        list[0] = bob;
        list[1] = alice;
        vm.prank(stranger);
        v.payout(list);
        assertEq(mon.balanceOf(bob), 9.975e17);
        assertEq(mon.balanceOf(alice), 4e18);

        // the admin sweeps the fees to the recipient set on the factory
        vm.prank(admin);
        v.sweepFees();
        assertEq(mon.balanceOf(feeRecipient), 7.5e15);
        assertEq(mon.balanceOf(address(v)), 0);
    }

    function test_lifecycle_pauserFreezeStopsMintingButNotPayouts() public {
        uint64 expiry = _slot(2);
        (OptionSeriesVault v,) = _create(_monCall(10e18, expiry));
        mon.mint(alice, 10e18);
        vm.startPrank(alice);
        mon.approve(address(v), type(uint256).max);
        v.mint(1e18, alice);
        vm.stopPrank();

        vm.prank(pauser); // roles live on the factory and the vault reads them from there
        v.setMintPaused(true);

        vm.prank(alice);
        vm.expectRevert(MintPaused.selector);
        v.mint(1e18, alice);

        monFeed.push(_id(1, 2), 12e8, expiry - 100);
        monFeed.push(_id(1, 3), 12e8, expiry + 100);
        vm.warp(expiry + 1 hours);
        v.settle(SettlementProof(_id(1, 2), _id(1, 3)));
        vm.prank(alice);
        v.redeem(1e18, alice); // still works while frozen
        vm.prank(alice);
        v.claimWriterResidual(1e18, alice);
    }

    function test_lifecycle_rolesRevokedOnTheFactoryApplyToEveryVault() public {
        (OptionSeriesVault v,) = _create(_monCall(10e18, _slot(2)));
        vm.prank(admin);
        factory.revokeRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        vm.expectRevert(Unauthorized.selector);
        v.setMintPaused(true); // the revoked pauser no longer works on any vault
    }

    // ================================================================== fuzz

    /// Any strike on the grid and any slot inside 30 days creates a series whose fixed values are right.
    function testFuzz_create_validInputsAlwaysWork(uint256 strikeSteps, uint256 daysAhead, bool isPut) public {
        strikeSteps = bound(strikeSteps, 1, 1_000_000);
        daysAhead = bound(daysAhead, 0, 28);
        uint256 strike = strikeSteps * MON_STEP;
        uint64 expiry = _slot(daysAhead);

        CreateSeriesParams memory p = _monCall(strike, expiry);
        p.optionType = isPut ? OptionType.PUT : OptionType.CALL;
        (OptionSeriesVault v, bytes32 id) = _create(p);

        assertEq(factory.vaultOf(id), address(v));
        assertEq(v.strikePrice(), strike);
        assertEq(v.expiry(), expiry);
        assertEq(v.contractSize(), 1e18);
        assertEq(v.collateralAsset(), isPut ? address(usdc) : address(mon));
        assertGe(v.collateralPerOption(), 1);
    }

    /// Any strike off the grid is rejected.
    function testFuzz_create_offGridStrikeAlwaysReverts(uint256 strike) public {
        strike = bound(strike, 1, 1e30);
        vm.assume(strike % MON_STEP != 0);
        vm.expectRevert(InvalidStrike.selector);
        factory.createSeries(_monCall(strike, _slot(2)));
    }

    /// Any expiry off the 08:00 UTC slot is rejected.
    function testFuzz_create_offSlotExpiryAlwaysReverts(uint64 expiry) public {
        expiry = uint64(bound(expiry, block.timestamp + 2 hours, block.timestamp + 29 days));
        vm.assume(expiry % 1 days != EXPIRY_SLOT_OFFSET);
        vm.expectRevert(InvalidExpiry.selector);
        factory.createSeries(_monCall(10e18, expiry));
    }
}
