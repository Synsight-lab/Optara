// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {RiskFixture} from "../utils/RiskFixture.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice GAS-001 (TESTING.md §6): a margin check at the maximum position count (16 legs, two underlyings,
///         24 + 12 scenarios) must fit `maxRiskCheckGas` (8,000,000).
contract PortfolioRiskManagerGasTest is RiskFixture {
    uint256 internal acct;

    function setUp() public {
        _deployRisk();
        _workedExampleMarket();
        _setSpot(btcUsdc, 90_000e18);
        uint256[] memory k = new uint256[](3);
        uint256[] memory iv = new uint256[](3);
        (k[0], k[1], k[2]) = (80_000e18, 90_000e18, 100_000e18);
        (iv[0], iv[1], iv[2]) = (0.55e18, 0.5e18, 0.52e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        _setSurface(btcUsdc, 90_000e18, k, iv, tenors);

        acct = _account(alice);
        _fund(acct, 10_000_000e6);
        uint256[4] memory ethStrikes = [uint256(3500e18), 4000e18, 4500e18, 5000e18];
        uint256[4] memory btcStrikes = [uint256(80_000e18), 90_000e18, 95_000e18, 100_000e18];
        for (uint256 i; i < 4; ++i) {
            _hold(
                acct, _series(ethUsdc, OptionType.CALL, ethStrikes[i], EXP30), i % 2 == 0 ? int256(-1e18) : int256(1e18)
            );
            _hold(acct, _series(ethUsdc, OptionType.PUT, ethStrikes[i], T0 + 45 days), -1e18);
            _hold(acct, _series(btcUsdc, OptionType.CALL, btcStrikes[i], EXP30), -0.5e18);
            _hold(acct, _series(btcUsdc, OptionType.PUT, btcStrikes[i], T0 + 45 days), 0.5e18);
        }
        assertEq(ledger.seriesOf(acct).length, 16);
    }

    function test_GAS001_riskCheckAtMaxPositions() public view {
        uint256 g = gasleft();
        risk.requireHealthy(acct);
        uint256 used = g - gasleft();
        console.log("requireHealthy, 16 legs x 36 scenarios:", used);
        assertLt(used, 8_000_000);
    }

    function test_gas_riskOfSingleLeg() public {
        uint256 one = _account(alice);
        _hold(one, _series(ethUsdc, OptionType.CALL, 4500e18, EXP30), -1e18);
        uint256 g = gasleft();
        risk.riskOf(one);
        console.log("riskOf, 1 leg x 36 scenarios:", g - gasleft());
    }
}
