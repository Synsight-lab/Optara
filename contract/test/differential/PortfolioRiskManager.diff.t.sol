// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskFixture} from "../utils/RiskFixture.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice MRG-010: equity, IM and MM of random portfolios equal the Python reference model (pm_model.account_risk
///         with the same NR CDF), up to fixed-point rounding. Each leg's IV is the on-chain surface IV (ivOf), so
///         this isolates the margin engine (scenarios, buckets, buffer, rounding) from IV interpolation (VOL-010).
contract PortfolioRiskManagerDiffTest is RiskFixture {
    bytes32[] internal universe;
    uint256 internal acct;

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

    /// forge-config: default.fuzz.runs = 100
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_MRG010_marginMatchesReference(uint256 seed, uint8 nLegs, uint64 cash) public {
        nLegs = uint8(bound(nLegs, 1, 6));
        _fund(acct, bound(cash, 0, 1e12)); // up to 1,000,000 USDC
        string memory legs;
        uint256 notional;
        for (uint256 i; i < nLegs; ++i) {
            bytes32 sid = universe[uint256(keccak256(abi.encode(seed, i))) % universe.length];
            if (ledger.balanceOf(acct, sid) != 0) continue;
            int256 units = int256(uint256(keccak256(abi.encode(seed, i, "q"))) % 600) - 300; // −3.00 to +2.99
            if (units == 0) continue;
            int256 q = units * 1e16;
            _hold(acct, sid, q);
            (,, uint256 sigLong) = risk.ivOf(sid);
            (, uint256 sigShort,) = risk.ivOf(sid);
            legs = string.concat(legs, _leg(sid, q, q < 0 ? sigShort : sigLong), ";");
            // forge-lint: disable-next-line(unsafe-typecast)
            notional += uint256(q < 0 ? -q : q) * (4000e18 + registry.getSeries(sid).strikeWad) / 1e18;
        }
        vm.assume(bytes(legs).length != 0);

        IPortfolioRiskManager.Risk memory r = risk.riskOf(acct);
        (int256 eq, uint256 im, uint256 mm) = _reference(legs);
        uint256 tol = notional / 1e9 + 1e6; // 1e-9 of notional: far above fixed-point error, far below any bug
        assertApproxEqAbs(r.equity, eq, tol, "equity");
        assertApproxEqAbs(r.initialMargin, im, tol, "IM");
        assertApproxEqAbs(r.maintenanceMargin, mm, tol, "MM");
        assertGe(r.initialMargin + tol, im, "never below the reference beyond rounding");
    }

    function _leg(bytes32 sid, int256 q, uint256 sigma) internal view returns (string memory) {
        (bool isCall, uint256 k, uint256 cs, uint64 e) = _terms(sid);
        return string.concat(
            isCall ? "1:" : "0:",
            vm.toString(k),
            ":",
            vm.toString(cs),
            ":",
            vm.toString(uint256(e)),
            ":",
            vm.toString(q),
            ":",
            vm.toString(sigma)
        );
    }

    function _terms(bytes32 sid) internal view returns (bool, uint256, uint256, uint64) {
        (bool isCall, uint256 k, uint256 cs, uint64 e) = (
            registry.getSeries(sid).optionType == OptionType.CALL,
            registry.getSeries(sid).strikeWad,
            registry.getSeries(sid).contractSizeWad,
            registry.getSeries(sid).expiry
        );
        return (isCall, k, cs, e);
    }

    function _reference(string memory legs) internal returns (int256 eq, uint256 im, uint256 mm) {
        string[] memory cmd = new string[](7);
        (cmd[0], cmd[1], cmd[2]) = ("python3", "../reference/ffi.py", "risk");
        cmd[3] = vm.toString(ledger.cashOf(acct) * 1e12);
        cmd[4] = vm.toString(uint256(4000e18));
        cmd[5] = vm.toString(block.timestamp);
        cmd[6] = legs;
        // forge-lint: disable-next-line(unsafe-cheatcode)
        (eq, im, mm) = abi.decode(vm.ffi(cmd), (int256, uint256, uint256));
    }
}
