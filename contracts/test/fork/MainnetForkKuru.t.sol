// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {OptionSeriesFactory} from "../../src/OptionSeriesFactory.sol";
import {OptionSeriesVault} from "../../src/OptionSeriesVault.sol";
import {VaultDeployer} from "../../src/VaultDeployer.sol";
import {PremiumExecutionGuard} from "../../src/PremiumExecutionGuard.sol";
import {IVaultDeployer} from "../../src/interfaces/IVaultDeployer.sol";
import {IOptionSeriesFactory} from "../../src/interfaces/IOptionSeriesFactory.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ChainlinkAnchor} from "../../src/libraries/ChainlinkAnchor.sol";
import {
    OptionType,
    CreateSeriesParams,
    PairConfig,
    FeeConfig,
    SettlementProof,
    EXPIRY_SLOT_OFFSET,
    ADMIN_ROLE,
    PAUSER_ROLE
} from "../../src/Types.sol";
import "../../src/Errors.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {IKuruRouter, IKuruOrderBook, IKuruMarginAccount} from "./interfaces/IKuru.sol";

/// Exposes ChainlinkAnchor.priceAtExpiry so it can be called directly against REAL historical round data,
/// bypassing the vault's own "expiry must be in the future" business rule (see the long comment above
/// PART A below for why that bypass is exactly the right way to test this).
contract AnchorHarness {
    function priceAtExpiry(
        IAggregatorV3 feed,
        uint8 feedDecimals,
        uint64 expiry,
        uint32 maxAge,
        uint80 roundId,
        uint80 nextRoundId
    ) external view returns (uint256) {
        return ChainlinkAnchor.priceAtExpiry(feed, feedDecimals, expiry, maxAge, roundId, nextRoundId);
    }
}

/// @notice Tests the full stack against REAL Kuru contracts on a Monad MAINNET fork: real Router, real
/// OrderBook, real WMON/USDC, and a real Chainlink MON/USD feed. Nothing here is broadcast to the real
/// chain — `vm.createSelectFork` takes a snapshot and every transaction after that runs purely locally.
///
/// Addresses were independently confirmed live before this file was written (not just trusted from a
/// pasted link): the feed's decimals()/description()/latestRoundData() were called directly, and the
/// Router's verifiedMarket/orderBookImplementation/kuruAmmVaultImplementation/owner were all called and
/// returned sane, real-looking values. See the PR/commit message for the raw output.
///
/// Run with: forge test --match-contract MainnetForkKuruTest -vvv
/// Override the RPC with: FORK_RPC_URL=<url> forge test --match-contract MainnetForkKuruTest -vvv
contract MainnetForkKuruTest is Test {
    // Confirmed live on Monad mainnet (chain id 143) before writing this test.
    address constant MON_USD_FEED = 0xBcD78f76005B7515837af6b50c7C52BCf73822fb;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant KURU_ROUTER = 0xd651346d7c789536ebf06dc72aE3C8502cd695CC;

    // Not exposed by any Router/OrderBook getter this interface calls - read off a recorded initialize()
    // trace during market deployment, then confirmed live as a real, already-deployed proxy on Monad
    // mainnet (owner() returns the same address that owns the Router). See IKuruMarginAccount's doc comment.
    address constant KURU_MARGIN_ACCOUNT = 0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5;

    // Observed empirically: this feed updates roughly every 30-60 seconds and has only ever been on
    // phase 1 (round ~576,467 at the time this was written). No real phase boundary exists to test
    // against for THIS feed; the phase-boundary logic itself is exhaustively covered against synthetic
    // data in ChainlinkAnchorSuccessor.t.sol. A generous but still tight age window, given the real cadence:
    uint32 constant MAX_CHAINLINK_AGE = 5 minutes;

    OptionSeriesFactory factory;
    PremiumExecutionGuard guard;
    AnchorHarness anchorHarness;

    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address feeRecipient = makeAddr("feeRecipient");
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");
    address keeper = makeAddr("keeper");

    /// The enum ordinal for IOrderBook.OrderBookType.NO_NATIVE is not published anywhere reachable in
    /// Kuru's docs. Confirmed empirically on the fork: 0 succeeds for a WMON/USDC (ERC20/ERC20) pair, 1 and
    /// 2 revert on native-asset-slot validation (unsurprising for NATIVE_IN_BASE/NATIVE_IN_QUOTE against two
    /// plain ERC-20s). See _discoverNoNativeOrderBookType, which re-derives this on the fork rather than
    /// hardcoding the magic number, so a wrong assumption fails loudly instead of silently.
    uint8 kuruNoNativeType;

    /// FINDING: Router.deployProxy is access-restricted, not permissionless. Calling it as an arbitrary
    /// address reverts with the custom error Unauthorized() (selector 0x82b42900) regardless of the
    /// OrderBookType argument - confirmed by calling it as an unrelated address BEFORE ordinal discovery
    /// even began. This contradicts the assumption in kuru-integration-spec.md / architectural.md that
    /// anyone can create the Kuru market for a series. It only succeeds when called as the Router's real
    /// owner() (0x8B736DCe2071783Fd9DB0a423dad17cc8ed5788b at the time this was written). To keep testing
    /// the REST of the integration, this test impersonates that real owner via vm.prank - which is exactly
    /// what fork impersonation is for - but this is flagged here as a real production finding, not quietly
    /// worked around: a real deployment needs either Kuru's own permission/cooperation to deploy markets,
    /// or a different, actually-permissionless path that was not found in the public docs.
    address constant KURU_ROUTER_OWNER = 0x8B736DCe2071783Fd9DB0a423dad17cc8ed5788b;

    // Carried between the steps of the big lifecycle test, in storage, to avoid one huge stack frame.
    bytes32 seriesId;
    OptionSeriesVault vault;
    address market;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string("https://rpc.monad.xyz"));
        vm.createSelectFork(rpc);
        require(block.chainid == 143, "not Monad mainnet");

        _verifyRealAddressesAreWhatWeThinkTheyAre();
        _deployOurStack();
        _confirmDeployProxyIsOwnerGated();
        kuruNoNativeType = _discoverNoNativeOrderBookType();
    }

    /// Confirms the Unauthorized() finding explicitly, as its own check, so a future change in Kuru's access
    /// control (opening deployProxy up, or gating it differently) is caught here rather than silently
    /// invalidating the owner-impersonation used below.
    function _confirmDeployProxyIsOwnerGated() internal {
        vm.expectRevert(); // Unauthorized() from an address that is not the Router's owner
        IKuruRouter(KURU_ROUTER).deployProxy(0, WMON, USDC, 1e15, 1e6, 1, 1e15, 1e24, 30, 10, 100);
        assertEq(IKuruRouter(KURU_ROUTER).owner(), KURU_ROUTER_OWNER, "cached Router owner is stale");
    }

    // ================================================================== diligence

    /// Re-verifies every external address behaves as expected, ON THE FORK, rather than trusting the
    /// snapshot silently matches what was checked live earlier. If Kuru or the feed ever change shape,
    /// this fails loudly here instead of producing confusing failures deeper in the test.
    function _verifyRealAddressesAreWhatWeThinkTheyAre() internal view {
        IAggregatorV3 feed = IAggregatorV3(MON_USD_FEED);
        assertEq(feed.decimals(), 8, "feed decimals changed");
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(answer, 0, "feed answer not positive");
        assertGt(updatedAt, 0, "feed never updated");
        assertLe(updatedAt, block.timestamp, "feed updatedAt in the future");

        assertGt(WMON.code.length, 0, "WMON has no code");
        assertGt(USDC.code.length, 0, "USDC has no code");
        assertEq(IERC20Metadata(WMON).decimals(), 18, "WMON decimals changed");
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC decimals changed");

        IKuruRouter router = IKuruRouter(KURU_ROUTER);
        assertGt(router.orderBookImplementation().code.length, 0, "Router has no OrderBook implementation");
        assertGt(router.kuruAmmVaultImplementation().code.length, 0, "Router has no AMM vault implementation");
        assertTrue(router.owner() != address(0), "Router has no owner");
    }

    function _deployOurStack() internal {
        VaultDeployer d = new VaultDeployer();
        factory = new OptionSeriesFactory(admin, IVaultDeployer(address(d)));
        guard = new PremiumExecutionGuard(IOptionSeriesFactory(address(factory)), 100, MAX_CHAINLINK_AGE, 100);
        anchorHarness = new AnchorHarness();

        vm.startPrank(admin);
        factory.setAllowedAsset(WMON, true);
        factory.setAllowedAsset(USDC, true);
        factory.setPairConfig(WMON, USDC, PairConfig(MON_USD_FEED, MAX_CHAINLINK_AGE, 0.001e18));
        factory.setDefaultFeeConfig(FeeConfig(10, 25));
        factory.setFeeRecipient(feeRecipient);
        factory.grantRole(PAUSER_ROLE, pauser);
        vm.stopPrank();
    }

    /// Tries the smallest plausible ordinals for OrderBookType against the REAL Router with real WMON/USDC,
    /// on the fork, and keeps whichever one succeeds. This costs nothing on a fork and is more trustworthy
    /// than trusting an undocumented guess.
    function _discoverNoNativeOrderBookType() internal returns (uint8) {
        for (uint8 t; t < 3; t++) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(KURU_ROUTER_OWNER); // deployProxy is owner-gated; see the finding documented above
            try IKuruRouter(KURU_ROUTER).deployProxy(
                t, WMON, USDC, 1e15, 1e6, 1, 1e15, 1e24, 30, 10, 100
            ) returns (address proxy) {
                bool ok = proxy.code.length > 0;
                vm.revertToState(snapshot);
                if (ok) {
                    console.log("OrderBookType.NO_NATIVE discovered as ordinal", t);
                    return t;
                }
            } catch {
                vm.revertToState(snapshot);
            }
        }
        revert("could not discover a working OrderBookType ordinal for a WMON/USDC (ERC20/ERC20) market");
    }

    // ================================================================== helpers

    function _slot(uint256 daysAhead) internal view returns (uint64) {
        return uint64(((block.timestamp / 1 days) + 1 + daysAhead) * 1 days + EXPIRY_SLOT_OFFSET);
    }

    /// Gives `who` real WMON on the fork by wrapping real native MON, which exercises WMON's actual
    /// deposit() logic rather than guessing its storage layout the way the `deal` cheatcode would have to.
    function _giveWmon(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        (bool ok,) = WMON.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(ok, "WMON.deposit() failed - is it really WETH9-style?");
        assertEq(IERC20(WMON).balanceOf(who), amount, "WMON balance did not land as expected");
    }

    /// Real USDC has no public mint the test controls; use `deal` (Foundry's storage-slot heuristic) and
    /// assert it actually worked rather than silently trusting it.
    function _giveUsdc(address who, uint256 amount) internal {
        deal(USDC, who, amount);
        assertEq(IERC20(USDC).balanceOf(who), amount, "deal() could not set a real USDC balance for this proxy");
    }

    // ================================================================== the test

    function test_fullLifecycle_onRealKuru_withRealFeedAndRealRoundHistory() public {
        _step1_createSeries();
        _step2_writerMints();
        _step3_deployRealKuruMarket();
        _step4_tradeOnRealKuru();
        _step5_guardAgainstRealBookData();

        // ================================================================== PART A: round process against
        // REAL historical data
        //
        // A static fork cannot be used to test "settle() correctly waits for and finds a genuinely NEW
        // Chainlink round" for a NEWLY CREATED series: createSeries requires expiry to be in our future
        // relative to the fork's snapshot time, and no real oracle node reports to a forked, locally-mined
        // chain after the fork point (our local clock can be warped forward for free, but doing so does not
        // cause the real world's Chainlink transmitters to produce data for a time that has not actually
        // happened yet). That specific behavior can only be exercised against a genuinely live chain, and
        // for THIS feed specifically (30-60s real cadence) that wait would be short (see the accompanying
        // write-up).
        //
        // What a fork DOES give us, for free, is complete real historical round data. So instead of waiting,
        // this calls ChainlinkAnchor.priceAtExpiry DIRECTLY (bypassing the vault's future-expiry rule, which
        // is a vault-level business rule, not a property of the anchoring library itself) against a real past
        // expiry and the REAL round ids around it. This is a stronger test of the round-finding logic than our
        // synthetic mocks: it runs against the feed's actual, possibly irregular, real update history.
        _testRoundProcessAgainstRealHistory();

        // ================================================================== PART B: full settlement
        // lifecycle, via a controlled feed, to prove the REST of the stack (redeem/claim/payout/fees) works
        // correctly when driven by trading that happened on REAL Kuru
        _settleRedeemClaimAndSweep_usingAControlledFeedForTimingOnly();
    }

    function _step1_createSeries() internal {
        uint64 expiry = _slot(1);
        CreateSeriesParams memory p = CreateSeriesParams({
            optionType: OptionType.CALL,
            underlying: WMON,
            quote: USDC,
            strikePrice: 0.02e18, // near the real observed MON/USD price (~$0.025) at write time
            expiry: expiry,
            chainlinkFeed: MON_USD_FEED
        });
        address vaultAddr;
        (seriesId, vaultAddr) = factory.createSeries(p);
        vault = OptionSeriesVault(vaultAddr);
        assertTrue(factory.isOptionToken(vaultAddr));
        console.log("series vault", vaultAddr);
    }

    function _step2_writerMints() internal {
        (uint256 collateralNeeded, uint256 fee) = vault.previewMint(50e18);
        _giveWmon(writer, collateralNeeded + fee);
        vm.prank(writer);
        IERC20(WMON).approve(address(vault), type(uint256).max);
        vm.prank(writer);
        vault.mint(50e18, writer);
        assertEq(vault.collateralLocked(), collateralNeeded);
        assertGe(IERC20(WMON).balanceOf(address(vault)), vault.collateralLocked() + vault.accruedFees());
        console.log("minted 50 options, collateral locked (WMON raw)", vault.collateralLocked());
    }

    function _step3_deployRealKuruMarket() internal {
        address vaultAddr = address(vault);
        vm.recordLogs();
        vm.prank(KURU_ROUTER_OWNER); // owner-gated on the real Router; see the finding documented above
        market = IKuruRouter(KURU_ROUTER).deployProxy(
            kuruNoNativeType,
            vaultAddr,
            USDC,
            1e15, // sizePrecision: 0.001 option
            1e6, // pricePrecision
            1, // tickSize
            1e15, // minSize
            1e24, // maxSize
            30, // takerFeeBps
            10, // makerFeeBps
            100 // kuruAmmSpread
        );
        assertGt(market.code.length, 0, "Kuru did not deploy a real market");

        // Router.verifiedMarket() and OrderBook.getMarketParams() are confirmed byte-identical (see
        // IKuru.sol). Neither includes kuruAmmSpread or the market's own address, so those are instead read
        // from the Router's own market-creation event, whose 12-word layout was decoded the same way (see
        // the finding above): baseAsset, quoteAsset, market, ammVault, pricePrecision, sizePrecision,
        // tickSize, minSize, maxSize, takerFeeBps, makerFeeBps, kuruAmmSpread.
        IKuruRouter.MarketParams memory verified = IKuruRouter(KURU_ROUTER).verifiedMarket(market);
        assertEq(verified.baseAssetAddress, vaultAddr, "verifiedMarket: wrong base asset");
        assertEq(verified.quoteAssetAddress, USDC, "verifiedMarket: wrong quote asset");
        assertEq(verified.baseAssetDecimals, 18, "verifiedMarket: wrong base decimals");
        assertEq(verified.quoteAssetDecimals, 6, "verifiedMarket: wrong quote decimals");
        assertEq(verified.pricePrecision, 1e6, "verifiedMarket: wrong pricePrecision");
        assertEq(verified.sizePrecision, 1e15, "verifiedMarket: wrong sizePrecision");
        assertEq(verified.takerFeeBps, 30, "verifiedMarket: wrong takerFeeBps");
        assertEq(verified.makerFeeBps, 10, "verifiedMarket: wrong makerFeeBps");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != KURU_ROUTER || logs[i].data.length != 12 * 32) continue;
            (
                address evBase,
                address evQuote,
                address evMarket,
                address evAmmVault,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 evAmmSpread
            ) = abi.decode(
                logs[i].data, (address, address, address, address, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
            );
            if (evMarket != market) continue;
            foundEvent = true;
            assertEq(evBase, vaultAddr, "event: wrong base asset");
            assertEq(evQuote, USDC, "event: wrong quote asset");
            assertEq(evAmmSpread, 100, "event: wrong kuruAmmSpread");
            console.log("real Kuru market deployed at", market);
            console.log("its AMM vault deployed at", evAmmVault);
        }
        assertTrue(foundEvent, "Router did not emit the expected market-creation event for this market");

        vm.prank(admin);
        factory.setKuruMarket(seriesId, market);
    }

    function _step4_tradeOnRealKuru() internal {
        address vaultAddr = address(vault);
        IKuruOrderBook book = IKuruOrderBook(market);
        IKuruMarginAccount margin = IKuruMarginAccount(KURU_MARGIN_ACCOUNT);

        // REAL FINDING: addSellOrder is a resting limit order that debits the trader's MarginAccount
        // balance, not their wallet - a bare approve() on the order book is not enough. The first attempt
        // without this deposit reverted with MarginAccount's own InsufficientBalance() (0xf4d678b8, decoded
        // via `cast 4byte`). See IKuruMarginAccount's doc comment for how this was confirmed.
        vm.startPrank(writer);
        IERC20(vaultAddr).approve(KURU_MARGIN_ACCOUNT, type(uint256).max);
        margin.deposit(writer, vaultAddr, 10e18);
        assertEq(margin.getBalance(writer, vaultAddr), 10e18, "MarginAccount deposit did not land");
        vm.stopPrank();

        vm.prank(writer);
        // price units are the book's own tick-scaled integer; 1e6 tick scale, ask a bit above intrinsic
        book.addSellOrder(500_000, 10e15, false); // ask at 0.50 (tick units), 10 option-units of size

        _giveUsdc(buyer, 1_000e6);
        vm.prank(buyer);
        IERC20(USDC).approve(market, type(uint256).max);

        uint256 vaultCollateralBefore = vault.collateralLocked();
        uint256 vaultTotalShortBefore = vault.totalShortAmount();
        uint256 buyerOptionsBefore = IERC20(vaultAddr).balanceOf(buyer);

        // REAL FINDING: the first attempt here declared `_minAmountOut` as uint96, matching the naming
        // convention of every other size/price param in this ABI. It is actually uint256 (confirmed against
        // Kuru's own public source, Kuru-Labs/Kuru-contracts-dex-public). A uint96 vs uint256 parameter
        // changes the function selector entirely, so every call landed on "no matching function" in the real
        // proxy and reverted with 0 bytes of data at ~927 gas regardless of the other arguments - cheap
        // enough to look like a rejected value rather than a routing miss. See IKuruOrderBook's doc comment.
        vm.prank(buyer);
        uint256 amountOut = book.placeAndExecuteMarketBuy(50_000_000, 0, false, false); // spend up to 50 USDC
        console.log("placeAndExecuteMarketBuy: amountOut (option raw units)", amountOut);

        // Invariant 4 / 4A, empirically, against REAL Kuru: trading changed WHO holds the token, never what
        // the vault owes.
        assertEq(vault.collateralLocked(), vaultCollateralBefore, "Kuru trade changed collateralLocked");
        assertEq(vault.totalShortAmount(), vaultTotalShortBefore, "Kuru trade changed totalShortAmount");
        assertGt(IERC20(vaultAddr).balanceOf(buyer), buyerOptionsBefore, "buyer received no option tokens");
        console.log("buyer now holds (option raw units)", IERC20(vaultAddr).balanceOf(buyer));
    }

    function _step5_guardAgainstRealBookData() internal {
        IKuruOrderBook book = IKuruOrderBook(market);
        (uint256 bestBid, uint256 bestAsk) = book.bestBidAsk();
        console.log("real book bestBid", bestBid);
        console.log("real book bestAsk", bestAsk);
        PremiumExecutionGuard.CheckResult memory r = guard.checkBuy(
            PremiumExecutionGuard.BuyCheck({
                seriesId: seriesId,
                market: market,
                optionAmount: 1e15,
                grossPremium: uint256(bestAsk), // illustrative; see write-up on real price scaling
                takerFeeBps: 30,
                buyerMaxTotalPremium: type(uint256).max,
                deadline: block.timestamp + 1 hours
            })
        );
        console.log("guard.checkBuy valid", r.valid);
        console.log("guard.checkBuy reason", uint8(r.reason));
    }

    /// @dev Walks real MON/USD history backward from the latest round to find the real round in force at a
    /// real past expiry, and its real immediate successor, then: (1) asserts the correct pair is accepted and
    /// returns the correct real price, and (2) asserts its two immediate neighbors are each rejected — proving
    /// "exactly one round qualifies" against real data, not just synthetic vectors.
    function _testRoundProcessAgainstRealHistory() internal {
        IAggregatorV3 feed = IAggregatorV3(MON_USD_FEED);
        (uint80 latestId,,, uint256 latestUpdatedAt,) = feed.latestRoundData();

        uint64 pastExpiry = uint64(latestUpdatedAt - 20 minutes);

        // Linear walk backward through REAL rounds (bounded; ~30-60s real cadence means 20 minutes is a
        // few dozen rounds, comfortably inside this bound).
        uint80 id = latestId;
        uint256 updatedAt = latestUpdatedAt;
        uint80 successorId = latestId;
        bool found;
        for (uint256 i; i < 200; i++) {
            if (updatedAt <= pastExpiry) {
                found = true;
                break;
            }
            successorId = id;
            id -= 1;
            (, , , updatedAt, ) = feed.getRoundData(id);
        }
        require(found, "did not find the real round in force within the search bound - widen it");

        uint256 price = anchorHarness.priceAtExpiry(feed, 8, pastExpiry, MAX_CHAINLINK_AGE, id, successorId);
        (, int256 rawAnswer,,,) = feed.getRoundData(id);
        assertEq(price, uint256(rawAnswer) * 1e10, "wrong real price returned");
        console.log("real round in force", id);
        console.log("real successor", successorId);
        console.log("price (1e18)", price);

        // exactly one pair qualifies: the round BEFORE the real one-in-force must be rejected as "round"
        vm.expectRevert(SettlementAnchorRoundAfterExpiry.selector);
        anchorHarness.priceAtExpiry(feed, 8, pastExpiry, MAX_CHAINLINK_AGE, successorId, successorId + 1);

        // and the round AFTER the real successor must be rejected as "not the immediate successor" when
        // paired with the same round-in-force
        vm.expectRevert(SettlementAnchorNotImmediateSuccessor.selector);
        anchorHarness.priceAtExpiry(feed, 8, pastExpiry, MAX_CHAINLINK_AGE, id, successorId + 1);

        // settling "later" against the same real anchor gives the identical price, exactly as it must
        uint256 priceAgain = anchorHarness.priceAtExpiry(feed, 8, pastExpiry, MAX_CHAINLINK_AGE, id, successorId);
        assertEq(priceAgain, price);
    }

    /// @dev A fork cannot produce a genuinely new REAL round after a future expiry (see the long comment
    /// above). To exercise settle -> redeem -> claim -> payout -> sweepFees end to end on top of the REAL
    /// Kuru trade that already happened, this creates a SEPARATE series against our OWN MockAggregator
    /// (never the real feed) purely so its timing is under our control. Everything Kuru-related has already
    /// been exercised against the real Router/OrderBook above; this half only proves the vault's own
    /// lifecycle completes correctly on top of that.
    function _settleRedeemClaimAndSweep_usingAControlledFeedForTimingOnly() internal {
        MockAggregator mock = new MockAggregator(8);
        mock.push(_id(1, 1), 2_500_000, block.timestamp - 10); // matches the real feed's observed scale/price
        vm.startPrank(admin);
        factory.setPairConfig(WMON, USDC, PairConfig(address(mock), 3600, 0.001e18));
        vm.stopPrank();

        uint64 expiry2 = _slot(1);
        (, address vault2Addr) = factory.createSeries(
            CreateSeriesParams({
                optionType: OptionType.CALL,
                underlying: WMON,
                quote: USDC,
                strikePrice: 0.02e18,
                expiry: expiry2,
                chainlinkFeed: address(mock)
            })
        );
        OptionSeriesVault vault2 = OptionSeriesVault(vault2Addr);

        _giveWmon(writer, 6e18);
        vm.prank(writer);
        IERC20(WMON).approve(vault2Addr, type(uint256).max);
        vm.prank(writer);
        vault2.mint(5e18, buyer); // buyer holds them directly, skipping a second real Kuru trade

        mock.push(_id(1, 1), 2_500_000, expiry2 - 10);
        mock.push(_id(1, 2), 2_500_000, expiry2 + 10);
        vm.warp(expiry2 + 20);
        vm.prank(keeper);
        vault2.settle(SettlementProof(_id(1, 1), _id(1, 2)));
        assertTrue(vault2.settled());

        address[] memory accounts = new address[](2);
        accounts[0] = buyer;
        accounts[1] = writer;
        vm.prank(keeper);
        vault2.payout(accounts);
        assertEq(vault2.totalSupply(), 0);
        assertEq(vault2.collateralLocked(), 0);

        vm.prank(admin);
        uint256 swept = vault2.sweepFees();
        assertGt(swept, 0);
        assertGe(IERC20(WMON).balanceOf(vault2Addr), vault2.collateralLocked() + vault2.accruedFees());
        console.log("controlled-feed series settled, paid out, and swept OK");
    }

    function _id(uint16 phase, uint64 agg) internal pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
    }
}
