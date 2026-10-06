// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice Random trades, risk-reducing actions, deposits, spot moves and time across three accounts. Every
///         risk-reducing action measures health before and after at the same instant (INV-13).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: ci.invariant.runs = 128
/// forge-config: ci.invariant.depth = 100
contract PortfolioRiskManagerInvariantTest is RiskFixture {
    bytes32[] internal universe;
    uint256[] internal accounts;
    uint256 public reductions;
    uint256 public healthDrops;
    uint256 internal spotNow = 4000e18;

    uint256 internal constant ROUNDING = 1e3;

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        uint256[4] memory strikes = [uint256(3500e18), 4000e18, 4500e18, 5000e18];
        for (uint256 k; k < 4; ++k) {
            universe.push(_series(ethUsdc, OptionType.CALL, strikes[k], EXP30));
            universe.push(_series(ethUsdc, OptionType.PUT, strikes[k], EXP30));
        }
        for (uint256 i; i < 3; ++i) {
            accounts.push(_account(alice));
        }
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = this.h_trade.selector;
        sel[1] = this.h_reduce.selector;
        sel[2] = this.h_deposit.selector;
        sel[3] = this.h_spot.selector;
        sel[4] = this.h_warp.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    function _h(uint256 a) internal view returns (int256, int256) {
        IPortfolioRiskManager.Risk memory r = risk.riskOf(a);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (r.equity - int256(r.initialMargin), r.equity - int256(r.maintenanceMargin));
    }

    function h_trade(uint256 ai, uint256 si, int256 units) external {
        uint256 a = accounts[ai % accounts.length];
        bytes32 s = universe[si % universe.length];
        int256 q = bound(units, -300, 300) * 1e16;
        if (q == 0 || ledger.balanceOf(a, s) + q == 0) return;
        _hold(a, s, q);
    }

    /// @dev Receive a long: either adds a long or closes part of a short. Both are risk-reducing.
    function h_reduce(uint256 ai, uint256 si, uint256 units) external {
        uint256 a = accounts[ai % accounts.length];
        bytes32 s = universe[si % universe.length];
        int256 q = int256(bound(units, 1, 300)) * 1e16;
        if (ledger.balanceOf(a, s) + q == 0) return;
        (int256 h0, int256 m0) = _h(a);
        _hold(a, s, q);
        (int256 h1, int256 m1) = _h(a);
        if (h1 + int256(ROUNDING) < h0 || m1 + int256(ROUNDING) < m0) healthDrops++;
        reductions++;
    }

    function h_deposit(uint256 ai, uint64 amount) external {
        uint256 a = accounts[ai % accounts.length];
        (int256 h0,) = _h(a);
        _fund(a, amount);
        (int256 h1,) = _h(a);
        if (h1 - h0 != int256(uint256(amount)) * 1e12) healthDrops++;
        reductions++;
    }

    function h_spot(int256 moveBps) external {
        moveBps = bound(moveBps, -1000, 1000);
        // forge-lint: disable-next-line(unsafe-typecast)
        spotNow = spotNow * uint256(10_000 + moveBps) / 10_000;
        _setSpot(ethUsdc, spotNow);
    }

    function h_warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3600));
        _setSpot(ethUsdc, spotNow); // keep spot fresh; the surface may go stale (VIEW applies penalties)
    }

    // ------------------------------------------------------------------ invariants

    function invariant_INV14_mmNeverAboveIm() public view {
        for (uint256 i; i < accounts.length; ++i) {
            IPortfolioRiskManager.Risk memory r = risk.riskOf(accounts[i]);
            assertLe(r.maintenanceMargin, r.initialMargin);
        }
    }

    function invariant_INV13_riskReducingNeverLowersHealth() public view {
        assertEq(healthDrops, 0);
    }

    function invariant_healthStateMatchesNumbers() public view {
        for (uint256 i; i < accounts.length; ++i) {
            (IPortfolioRiskManager.HealthState st, int256 eq, uint256 im, uint256 mm,) = risk.healthOf(accounts[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            bool coversIm = eq >= 0 && uint256(eq) >= im;
            // forge-lint: disable-next-line(unsafe-typecast)
            bool coversMm = eq >= 0 && uint256(eq) >= mm;
            if (coversIm) {
                assertEq(uint8(st), uint8(IPortfolioRiskManager.HealthState.HEALTHY));
            } else if (coversMm) {
                assertEq(uint8(st), uint8(IPortfolioRiskManager.HealthState.CLOSE_ONLY));
            } else {
                assertTrue(
                    st == IPortfolioRiskManager.HealthState.LIQUIDATABLE
                        || st == IPortfolioRiskManager.HealthState.INSOLVENT
                );
            }
        }
    }

    function test_handlerPathsReachable() public {
        this.h_trade(0, 0, -100);
        this.h_trade(0, 3, 50);
        this.h_reduce(0, 0, 40);
        this.h_deposit(0, 1000e6);
        this.h_spot(500);
        this.h_warp(1200);
        this.h_reduce(0, 2, 10);
        assertEq(reductions, 3);
        invariant_INV13_riskReducingNeverLowersHealth();
        invariant_INV14_mmNeverAboveIm();
        invariant_healthStateMatchesNumbers();
    }
}
