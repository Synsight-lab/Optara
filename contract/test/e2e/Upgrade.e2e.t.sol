// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {E2EBase} from "./E2EBase.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {ProtocolControl} from "../../src/governance/ProtocolControl.sol";
import {OptionSeriesRegistry} from "../../src/series/OptionSeriesRegistry.sol";
import {ExternalOptionFactory} from "../../src/series/ExternalOptionFactory.sol";
import {SubAccounts} from "../../src/accounts/SubAccounts.sol";
import {LiveSpotOracle} from "../../src/oracle/LiveSpotOracle.sol";
import {VolSurfaceOracle} from "../../src/oracle/VolSurfaceOracle.sol";
import {SettlementOracle} from "../../src/oracle/SettlementOracle.sol";
import {PortfolioRiskManager} from "../../src/risk/PortfolioRiskManager.sol";
import {InsuranceFund} from "../../src/insurance/InsuranceFund.sol";
import {FeeController} from "../../src/fees/FeeController.sol";
import {OptionClearing} from "../../src/clearing/OptionClearing.sol";
import {LiquidationModule} from "../../src/liquidation/LiquidationModule.sol";
import {SettlementWindow} from "../../src/settlement/SettlementWindow.sol";
import {VenueRegistry} from "../../src/venues/VenueRegistry.sol";
import {VenueRouter} from "../../src/venues/VenueRouter.sol";
import {ISettlementWindow} from "../../src/interfaces/ISettlementWindow.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice UPG-003 / INV-34 on the production deployment: with live positions, a finalized group, a fixed ratio and
///         partial redemptions, every one of the 15 proxies is upgraded through the governance timelock. Series
///         terms, wrappers, prices, ratios, redemption records, balances, cash and reserves are identical before and
///         after, and the system keeps working (redemptions, claims, new series, new risk).
contract UpgradeE2ETest is E2EBase {
    uint256 internal a;
    uint256 internal k;

    function setUp() public override {
        super.setUp();
        a = _account(alice);
        k = _account(keeper);
        _deposit(a, alice, 10_000e6);
        _deposit(k, keeper, 10_000e6);
        OracleUpdate memory u = _update();
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c4500, 2e18, carol, type(uint256).max, u);
        OracleUpdate memory u2 = _update();
        vm.prank(keeper);
        d.clearing.mintExternalLong(k, p3500, 1e18, carol, type(uint256).max, u2);
        // expiry at 5,200; finalize, settle, fix the ratio; carol redeems half of her 4500 calls
        vm.warp(EXP30 - 30);
        uint80 inForce = ethFeed.pushRound(5200e8, EXP30 - 30);
        vm.warp(EXP30 + 60);
        uint80 next = ethFeed.pushRound(5200e8, EXP30 + 60);
        vm.warp(EXP30 + 300);
        d.window.finalizeGroup(group30, _proof(inForce, next));
        uint256[] memory accts = new uint256[](2);
        (accts[0], accts[1]) = (a, k);
        d.window.settleAccountsGroup(accts, group30);
        d.window.computeRecoveryRatio(group30);
        vm.prank(carol);
        d.window.redeemWrapper(c4500, 1e18, carol);
    }

    /// @dev Everything INV-34 protects, hashed.
    function _snapshot() internal view returns (bytes32) {
        bytes32[3] memory ids = [c4500, c5000, p3500];
        bytes memory blob;
        for (uint256 i; i < 3; ++i) {
            address w = _wrapper(ids[i]);
            blob = abi.encode(
                blob,
                d.registry.getSeries(ids[i]),
                IERC20(w).totalSupply(),
                IERC20(w).balanceOf(carol),
                d.window.wrapperSupplyAtFinalization(ids[i])
            );
        }
        (uint256 spotWad, uint64 spotTime) = d.spot.spotPrice(eth);
        blob = abi.encode(
            blob,
            d.window.groupAccounting(group30),
            d.window.creditOf(a, group30),
            d.window.creditOf(k, group30),
            d.ledger.cashOf(a),
            d.ledger.cashOf(k),
            d.ledger.participants(group30)
        );
        blob = abi.encode(
            blob,
            d.fees.treasury(address(usdc)),
            d.fees.keeperReserve(address(usdc)),
            d.insurance.balanceOf(address(usdc)),
            d.registry.getProduct(eth),
            d.risk.productRiskSet(eth),
            spotWad,
            spotTime,
            d.surface.header(eth)
        );
        return keccak256(blob);
    }

    function test_UPG003_INV34_upgradeEveryModule() public {
        bytes32 before = _snapshot();
        address[15] memory proxies = [
            address(d.control),
            address(d.registry),
            address(d.factory),
            address(d.ledger),
            address(d.spot),
            address(d.surface),
            address(d.settlementOracle),
            address(d.risk),
            address(d.insurance),
            address(d.fees),
            address(d.clearing),
            address(d.liquidation),
            address(d.window),
            address(d.venues),
            address(d.router)
        ];
        address[15] memory impls = [
            address(new ProtocolControl()),
            address(new OptionSeriesRegistry()),
            address(new ExternalOptionFactory()),
            address(new SubAccounts()),
            address(new LiveSpotOracle()),
            address(new VolSurfaceOracle()),
            address(new SettlementOracle()),
            address(new PortfolioRiskManager()),
            address(new InsuranceFund()),
            address(new FeeController()),
            address(new OptionClearing()),
            address(new LiquidationModule()),
            address(new SettlementWindow()),
            address(new VenueRegistry()),
            address(new VenueRouter())
        ];
        bytes32[15] memory ops;
        vm.startPrank(governance);
        for (uint256 i; i < 15; ++i) {
            d.upgradeAdmin.setImplementationAllowed(impls[i].codehash, true);
            ops[i] = d.upgradeAdmin.scheduleUpgrade(proxies[i], impls[i], "");
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        for (uint256 i; i < 15; ++i) {
            d.upgradeAdmin.executeUpgrade(ops[i]); // anyone, after the delay
            assertEq(_implementationOf(proxies[i]), impls[i], "upgraded");
        }
        assertEq(_snapshot(), before, "INV-34: protected state identical across the upgrade");

        // the upgraded system keeps working: redemptions, the sweep, a new series and new risk
        uint256 rest = IERC20(_wrapper(c4500)).balanceOf(carol);
        uint256 cash = usdc.balanceOf(carol);
        vm.prank(carol);
        d.window.redeemWrapper(c4500, rest, carol);
        assertEq(usdc.balanceOf(carol) - cash, rest * 700 / 1e12);
        uint256 puts = IERC20(_wrapper(p3500)).balanceOf(carol);
        vm.prank(carol);
        d.window.redeemWrapper(p3500, puts, carol);
        d.window.sweepDust(group30);
        assertEq(uint8(d.window.groupState(group30)), uint8(ISettlementWindow.GroupState.REDEEMABLE));

        // keeper rewards drew the keeper reserve below its minimum, which gates new risk (FEES.md §6); ops top it up
        assertFalse(d.fees.reservesHealthy(address(usdc)));
        usdc.mint(address(this), 10e6);
        usdc.approve(address(d.fees), 10e6);
        d.fees.fundKeeperReserve(address(usdc), 10e6);
        assertTrue(d.fees.reservesHealthy(address(usdc)));
        bytes32 c60 = _createSeries(OptionType.CALL, 5500e18, EXP60);
        OracleUpdate memory u = _update();
        vm.prank(alice);
        d.clearing.mintExternalLong(a, c60, 1e18, alice, type(uint256).max, u);
        assertEq(d.ledger.balanceOf(a, c60), -1e18);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
