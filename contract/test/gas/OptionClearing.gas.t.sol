// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {ClearingFixture} from "../utils/ClearingFixture.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice GAS-003 for OptionClearing: a mint that takes an account to the maximum position count (16 legs, two
///         underlyings), carrying a full ETH oracle update (spot, report, 6 leaf proofs), stays under 10,000,000 gas
///         (the 8,000,000 risk check plus the update, ledger write, fee split and wrapper mint).
contract OptionClearingGasTest is ClearingFixture {
    uint256 internal acct;
    bytes32 internal last;

    function setUp() public {
        _deployClearingMarket();
        _setSpot(btcUsdc, 90_000e18);
        uint256[] memory k = new uint256[](3);
        uint256[] memory iv = new uint256[](3);
        (k[0], k[1], k[2]) = (80_000e18, 90_000e18, 100_000e18);
        (iv[0], iv[1], iv[2]) = (0.55e18, 0.5e18, 0.52e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        _setSurface(btcUsdc, 90_000e18, k, iv, tenors);

        acct = _account(alice);
        _deposit(acct, alice, 10_000_000e6);
        uint256[4] memory ethStrikes = [uint256(3500e18), 4000e18, 4500e18, 5000e18];
        uint256[4] memory btcStrikes = [uint256(80_000e18), 90_000e18, 95_000e18, 100_000e18];
        for (uint256 i; i < 4; ++i) {
            _hold(
                acct, _series(ethUsdc, OptionType.CALL, ethStrikes[i], EXP30), i % 2 == 0 ? int256(-1e18) : int256(1e18)
            );
            if (i < 3) _hold(acct, _series(ethUsdc, OptionType.PUT, ethStrikes[i], T0 + 45 days), -1e18);
            _hold(acct, _series(btcUsdc, OptionType.CALL, btcStrikes[i], EXP30), -0.5e18);
            _hold(acct, _series(btcUsdc, OptionType.PUT, btcStrikes[i], T0 + 45 days), 0.5e18);
        }
        last = _series(ethUsdc, OptionType.PUT, 5000e18, T0 + 45 days);
        assertEq(ledger.seriesOf(acct).length, 15);
    }

    function test_GAS003_mintToMaxPositionsWithFullUpdate() public {
        OracleUpdate memory u = _marketUpdate(4000e18);
        vm.prank(alice);
        uint256 g = gasleft();
        clearingModule.mintExternalLong(acct, last, 1e18, alice, type(uint256).max, u);
        uint256 used = g - gasleft();
        console.log("mintExternalLong to 16 legs, full ETH update:", used);
        assertEq(ledger.seriesOf(acct).length, 16);
        assertLt(used, 10_000_000);
    }

    function test_gas_mintSingleLeg() public {
        uint256 one = _account(bob);
        _deposit(one, bob, 10_000e6);
        vm.prank(bob);
        uint256 g = gasleft();
        clearingModule.mintExternalLong(one, c4500, 1e18, bob, type(uint256).max, _empty());
        console.log("mintExternalLong, 1 leg, cached data:", g - gasleft());
    }
}
