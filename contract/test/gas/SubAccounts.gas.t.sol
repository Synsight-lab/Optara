// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";

/// @notice Gas of ledger writes (TESTING.md §6). Opening a position touches the series list, bucket, group count,
///         participants, totals and (first time only) the series cache; changing an open position touches only the
///         balance and totals.
contract SubAccountsGasTest is LedgerFixture {
    uint256 internal a;

    function setUp() public {
        _deployLedger();
        a = _newAccount(alice, address(usdc));
    }

    function _measure(bytes32 s, int256 d) internal returns (uint256 used) {
        vm.prank(clearing);
        uint256 g = gasleft();
        ledger.applyDelta(a, s, d);
        used = g - gasleft();
    }

    function test_gas_applyDelta() public {
        uint256 open = _measure(ethC4500, 1e18); // first position ever in this series (cache miss)
        uint256 change = _measure(ethC4500, 1e18); // existing position
        uint256 close = _measure(ethC4500, -2e18); // back to zero
        uint256 reopen = _measure(ethC4500, -1e18); // series cached
        console.log("open (cold cache)", open);
        console.log("change existing", change);
        console.log("close", close);
        console.log("reopen (cached)", reopen);
        assertLt(change, 30_000);
        assertLt(reopen, open);
    }
}
