// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {LocalMarketData} from "./LocalMarketData.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {IOptionClearing} from "../../src/interfaces/IOptionClearing.sol";
import {IVenueRouter} from "../../src/interfaces/IVenueRouter.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../test/mocks/MockDependencies.sol";
import {MockPyth} from "../../test/mocks/MockPyth.sol";
import {MockKuruOrderBook} from "../../test/mocks/MockVenues.sol";

/// @title Smoke
/// @notice Exercises a freshly deployed local stack (`LocalStack.s.sol`) through real transactions: a writer opens an
///         account, deposits, mints one ETH 4500 call with a fresh spot + surface update in the same transaction and
///         sells it through the router to the Kuru book; a buyer then buys it back through the router. Reverts if any
///         balance or the writer's health is not as expected.
/// @dev `forge script script/local/Smoke.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`. Run once per fresh stack:
///      it uses account 5 as the writer and account 6 as the buyer.
contract Smoke is LocalMarketData {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    uint256 internal constant SERIES = 4; // 4500 call, first expiry (LocalStack._listSeries)

    error SmokeFailed(string what);

    struct Stack {
        IOptionClearing clearing;
        IVenueRouter router;
        ISubAccounts ledger;
        IPortfolioRiskManager risk;
        MockERC20 usdc;
        bytes32 kuru;
        bytes32 seriesId;
        IERC20 wrapper;
        MockKuruOrderBook book;
        uint64[] expiries;
    }

    function run() external {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/local.json"));
        (Stack memory s, Market memory m) = _load(json);
        uint256 mm = vm.deriveKey(MNEMONIC, 0);

        // A market maker bids $100 for one contract.
        vm.startBroadcast(mm);
        s.usdc.mint(address(s.book), 100e6);
        s.book.setBid(1_000_000, 1e16);
        vm.stopBroadcast();
        (uint256 a, uint256 proceeds) = _writeAndSell(s, m, vm.deriveKey(MNEMONIC, 5));

        // The market maker offers it at $110.
        vm.broadcast(mm);
        s.book.setAsk(1_100_000, 1e16);
        (uint256 qty, uint256 spent, uint256 buyerFee) = _buy(s, vm.deriveKey(MNEMONIC, 6));

        console.log("smoke ok: account %s short 1e18; proceeds %s", a, proceeds);
        console.log("buyer got %s wrappers for %s premium + %s fee", qty, spent, buyerFee);
    }

    /// @dev Account, deposit, mint with a fresh update in the same transaction, sell through the router.
    function _writeAndSell(Stack memory s, Market memory m, uint256 key)
        internal
        returns (uint256 a, uint256 proceeds)
    {
        address writer = vm.addr(key);
        OracleUpdate memory u = _oracleUpdate(m, 4000e18, 0.6e18, s.expiries, uint64(block.timestamp));
        uint256 fee = MockPyth(m.pyth).getUpdateFee(u.spotUpdates);
        uint256 usdcBefore = s.usdc.balanceOf(writer);
        IVenueRouter.SellOrder memory o =
            IVenueRouter.SellOrder(s.kuru, s.seriesId, 1e18, 99e6, type(uint256).max, writer, _deadline());
        vm.startBroadcast(key);
        a = s.ledger.createSubAccount(address(s.usdc));
        s.usdc.approve(address(s.clearing), 5_000e6);
        s.clearing.depositCollateral(a, 5_000e6);
        s.clearing.mintExternalLong{value: fee}(a, s.seriesId, 1e18, writer, type(uint256).max, u);
        s.wrapper.approve(address(s.router), 1e18);
        uint256 sold;
        (sold, proceeds,) = s.router.sellThroughVenue(o, "");
        vm.stopBroadcast();
        _check("writer short 1", s.ledger.balanceOf(a, s.seriesId) == -1e18);
        _check("sold 1", sold == 1e18 && s.wrapper.balanceOf(writer) == 0);
        _check("proceeds paid", s.usdc.balanceOf(writer) == usdcBefore - 5_000e6 + proceeds);
        IPortfolioRiskManager.Risk memory r = s.risk.riskOf(a);
        _check("writer above initial margin", r.fresh && r.equity >= int256(r.initialMargin));
    }

    function _buy(Stack memory s, uint256 key) internal returns (uint256 qty, uint256 spent, uint256 buyerFee) {
        address buyer = vm.addr(key);
        IVenueRouter.BuyOrder memory o = IVenueRouter.BuyOrder(
            s.kuru, s.seriesId, 110e6, 0.99e18, type(uint256).max, type(uint256).max, buyer, _deadline()
        );
        vm.startBroadcast(key);
        s.usdc.approve(address(s.router), type(uint256).max);
        (qty, spent, buyerFee,) = s.router.buyThroughVenue(o, "");
        vm.stopBroadcast();
        _check("buyer filled", qty >= 0.99e18 && s.wrapper.balanceOf(buyer) == qty);
    }

    function _load(string memory json) internal view returns (Stack memory s, Market memory m) {
        s.clearing = IOptionClearing(vm.parseJsonAddress(json, ".proxies.OptionClearing.proxy"));
        s.router = IVenueRouter(vm.parseJsonAddress(json, ".proxies.VenueRouter.proxy"));
        s.ledger = ISubAccounts(vm.parseJsonAddress(json, ".proxies.SubAccounts.proxy"));
        s.risk = IPortfolioRiskManager(vm.parseJsonAddress(json, ".proxies.PortfolioRiskManager.proxy"));
        s.usdc = MockERC20(vm.parseJsonAddress(json, ".extra.usdc"));
        s.kuru = keccak256("KURU");
        s.seriesId = vm.parseJsonBytes32Array(json, ".extra.seriesIds")[SERIES];
        s.book = MockKuruOrderBook(vm.parseJsonAddressArray(json, ".extra.kuruBooks")[SERIES]);
        s.wrapper = s.book.base();
        uint256[] memory e = vm.parseJsonUintArray(json, ".extra.expiries");
        s.expiries = new uint64[](e.length);
        for (uint256 i; i < e.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            s.expiries[i] = uint64(e[i]); // timestamps
        }
        m = Market({
            pyth: vm.parseJsonAddress(json, ".extra.pyth"),
            surface: IVolSurfaceOracle(vm.parseJsonAddress(json, ".proxies.VolSurfaceOracle.proxy")),
            productId: vm.parseJsonBytes32(json, ".extra.ethUsdcProductId"),
            underlying: vm.parseJsonAddress(json, ".extra.weth"),
            asset: address(s.usdc),
            pythFeed: vm.parseJsonBytes32(json, ".extra.ethUsdcPythFeedId"),
            keyA: vm.deriveKey(MNEMONIC, 2),
            keyB: vm.deriveKey(MNEMONIC, 3)
        });
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 10 minutes);
    }

    function _check(string memory what, bool ok) internal pure {
        if (!ok) revert SmokeFailed(what);
    }
}
