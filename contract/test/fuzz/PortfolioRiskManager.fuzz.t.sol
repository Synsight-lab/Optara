// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice Margin properties over random portfolios: INV-13 (risk-reducing actions never lower health), INV-14
///         (MM ≤ IM), INV-41 (homogeneity), withdrawal limit.
contract PortfolioRiskManagerFuzzTest is RiskFixture {
    bytes32[] internal universe;
    uint256 internal acct;
    /// @dev Position values round toward −∞ once per leg per scenario, so exact identities hold to a few wei.
    uint256 internal constant ROUNDING = 1e3;

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        uint256[6] memory strikes = [uint256(3000e18), 3500e18, 4000e18, 4500e18, 5000e18, 6000e18];
        uint64[2] memory expiries = [EXP30, T0 + 45 days];
        for (uint256 e; e < 2; ++e) {
            for (uint256 k; k < 6; ++k) {
                universe.push(_series(ethUsdc, OptionType.CALL, strikes[k], expiries[e]));
                universe.push(_series(ethUsdc, OptionType.PUT, strikes[k], expiries[e]));
            }
        }
        acct = _account(alice);
    }

    function _randomPortfolio(uint256 account, uint256 seed, uint256 legs, int256 scale) internal {
        for (uint256 i; i < legs; ++i) {
            bytes32 sid = universe[uint256(keccak256(abi.encode(seed, i))) % universe.length];
            int256 units = int256(uint256(keccak256(abi.encode(seed, i, "q"))) % 600) - 300;
            int256 next = ledger.balanceOf(account, sid) + units * 1e16 * scale;
            if (units != 0 && next != 0) _hold(account, sid, units * 1e16 * scale);
        }
    }

    function _health(IPortfolioRiskManager.Risk memory r) internal pure returns (int256 im, int256 mm) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return (r.equity - int256(r.initialMargin), r.equity - int256(r.maintenanceMargin));
    }

    // ------------------------------------------------------------------ INV-13

    function testFuzz_INV13_receivingALongNeverLowersHealth(uint256 seed, uint8 legs, uint256 pick, uint256 units)
        public
    {
        _randomPortfolio(acct, seed, bound(legs, 1, 6), 1);
        bytes32 sid = universe[pick % universe.length];
        int256 q = int256(bound(units, 1, 300)) * 1e16;
        (int256 h0, int256 m0) = _health(risk.riskOf(acct));
        (int256 h1, int256 m1) = _health(risk.previewWithDelta(acct, sid, q, 0));
        assertGe(h1 + int256(ROUNDING), h0, "equity - IM fell");
        assertGe(m1 + int256(ROUNDING), m0, "equity - MM fell");
    }

    function testFuzz_INV13_closingAShortNeverLowersHealth(uint256 seed, uint8 legs, uint256 pick, uint256 frac)
        public
    {
        _randomPortfolio(acct, seed, bound(legs, 1, 6), 1);
        bytes32[] memory held = ledger.seriesOf(acct);
        bytes32 sid;
        if (held.length != 0) pick %= held.length;
        for (uint256 i; i < held.length; ++i) {
            if (ledger.balanceOf(acct, held[(pick + i) % held.length]) < 0) {
                sid = held[(pick + i) % held.length];
                break;
            }
        }
        vm.assume(sid != 0);
        int256 shortQty = -ledger.balanceOf(acct, sid);
        int256 q = shortQty * int256(bound(frac, 1, 100)) / 100 / 1e16 * 1e16; // part of the short, min-qty units
        vm.assume(q > 0);
        (int256 h0, int256 m0) = _health(risk.riskOf(acct));
        (int256 h1, int256 m1) = _health(risk.previewWithDelta(acct, sid, q, 0));
        assertGe(h1 + int256(ROUNDING), h0);
        assertGe(m1 + int256(ROUNDING), m0);
    }

    function testFuzz_INV13_depositRaisesHealthOneForOne(uint256 seed, uint8 legs, uint64 amount) public {
        _randomPortfolio(acct, seed, bound(legs, 1, 6), 1);
        (int256 h0,) = _health(risk.riskOf(acct));
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 h1,) = _health(risk.previewWithDelta(acct, 0, 0, int256(uint256(amount))));
        assertEq(h1 - h0, int256(uint256(amount)) * 1e12);
    }

    // ------------------------------------------------------------------ INV-14

    function testFuzz_INV14_mmNeverAboveIm(uint256 seed, uint8 legs) public {
        _randomPortfolio(acct, seed, bound(legs, 1, 8), 1);
        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        assertLe(r.maintenanceMargin, r.initialMargin);
    }

    // ------------------------------------------------------------------ INV-41

    function testFuzz_INV41_marginIsHomogeneous(uint256 seed, uint8 legs) public {
        uint256 twice = _account(alice);
        legs = uint8(bound(legs, 1, 6));
        _randomPortfolio(acct, seed, legs, 1);
        _randomPortfolio(twice, seed, legs, 2);
        IPortfolioRiskManager.Risk memory one = risk.riskOf(acct);
        IPortfolioRiskManager.Risk memory two = risk.riskOf(twice);
        assertApproxEqAbs(two.maintenanceMargin, 2 * one.maintenanceMargin, ROUNDING, "MM");
        assertApproxEqAbs(two.initialMargin, 2 * one.initialMargin, ROUNDING, "IM (loss and short-mark buffer)");
        assertApproxEqAbs(two.equity, 2 * one.equity, ROUNDING, "equity");
    }

    // ------------------------------------------------------------------ withdrawal limit

    function testFuzz_maxWithdrawableIsTheHealthyLimit(uint256 seed, uint8 legs, uint64 cash) public {
        _randomPortfolio(acct, seed, bound(legs, 1, 6), 1);
        _fund(acct, bound(cash, 0, 1e11));
        uint256 max = risk.maxWithdrawable(acct);
        (,, bool ok) = risk.previewWithdraw(acct, max);
        if (max > 0) assertTrue(ok, "the max itself is withdrawable");
        if (max < ledger.cashOf(acct)) {
            (,, bool more) = risk.previewWithdraw(acct, max + 1);
            assertFalse(more, "one unit more is not");
        }
    }
}
