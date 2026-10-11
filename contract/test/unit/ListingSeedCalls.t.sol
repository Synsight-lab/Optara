// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ListingCalls} from "../../script/ListingCalls.sol";
import {InsuranceFund} from "../../src/insurance/InsuranceFund.sol";
import {FeeController} from "../../src/fees/FeeController.sol";

/// @notice The listing's treasury deposits: a zero minimum (a listing that bootstraps its reserves from fees) has no
///         deposit, since InsuranceFund.deposit and FeeController.fundKeeperReserve reject zero.
contract ListingSeedCallsTest is Test, ListingCalls {
    Deployment internal d;

    function setUp() public {
        d.insurance = InsuranceFund(makeAddr("insurance"));
        d.fees = FeeController(makeAddr("fees"));
    }

    function _p(uint256 seed, uint256 reserve) internal returns (ListingParams memory p) {
        p.asset = makeAddr("usdc");
        p.insuranceSeed = seed;
        p.keeperReserveMin = reserve;
    }

    function test_bothFunded_fourCalls() public {
        Call[] memory c = _seedCalls(d, _p(5_000e6, 300e6));
        assertEq(c.length, 4);
        assertEq(c[1].to, address(d.insurance));
        assertEq(c[3].to, address(d.fees));
    }

    function test_noUsdc_noCalls() public {
        assertEq(_seedCalls(d, _p(0, 0)).length, 0);
    }

    function test_onlyKeeperReserve_twoCalls() public {
        Call[] memory c = _seedCalls(d, _p(0, 100e6));
        assertEq(c.length, 2);
        assertEq(c[1].to, address(d.fees));
        assertEq(c[1].data, abi.encodeCall(FeeController.fundKeeperReserve, (makeAddr("usdc"), 100e6)));
    }

    function test_onlyInsurance_twoCalls() public {
        Call[] memory c = _seedCalls(d, _p(1_000e6, 0));
        assertEq(c.length, 2);
        assertEq(c[1].data, abi.encodeCall(InsuranceFund.deposit, (makeAddr("usdc"), 1_000e6)));
    }
}
