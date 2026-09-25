// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/OptaraTestBase.sol";

contract SmokeTest is OptaraTestBase {
    function test_smoke_lifecycle() public {
        bytes32 id = _monCall(10 * WAD, 5 * WAD);
        _deposit(alice, usdt, _usdt(5));
        _write(alice, id, WAD);
        assertEq(core.requiredMargin(alice, address(usdt)), _usdt(5));
        IOptionToken token = _token(id);
        vm.prank(alice);
        token.transfer(bob, WAD);
        _finalizeMon(id, 13 * WAD);
        vm.prank(bob);
        uint256 paid = core.redeem(id, WAD, bob);
        assertEq(paid, _usdt(3));
        core.syncRiskGroup(alice, _groupOf(id));
        assertEq(core.cashBalance(alice, address(usdt)), _usdt(2));
        vm.prank(alice);
        core.withdraw(address(usdt), _usdt(2), alice);
        assertEq(usdt.balanceOf(address(core)), 0);
    }
}
