// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceFixture} from "../utils/GovernanceFixture.sol";
import {UpgradeAdmin} from "../../src/governance/UpgradeAdmin.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IUpgradeAdmin} from "../../src/interfaces/IUpgradeAdmin.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {MockModuleV1} from "../mocks/MockModule.sol";
import {NotAuthorized, UpgradeNotReady, InvalidDelay} from "../../src/libraries/Errors.sol";

/// @notice Fuzz tests for ProtocolControl and UpgradeAdmin: pause masks combine exactly per scope (PAU-001/002),
///         unauthorized callers never succeed (ACL-001), upgrades never execute before their eta (UPG-002).
contract GovernanceFuzzTest is GovernanceFixture {
    function setUp() public {
        _deployGovernance();
    }

    function testFuzz_PAU001_isPausedEqualsUnionOfScopes(
        uint256 globalBits,
        uint256 assetBits,
        uint256 productBits,
        uint8 bit,
        bool queryAsset,
        bool queryProduct
    ) public {
        globalBits = bound(globalBits, 0, PauseBits.ALL);
        assetBits = bound(assetBits, 0, PauseBits.ALL);
        productBits = bound(productBits, 0, PauseBits.ALL);
        bit = uint8(bound(bit, 0, PauseBits.COUNT - 1));
        vm.startPrank(guardian);
        if (globalBits != 0) pc.pause(IProtocolControl.Scope.GLOBAL, 0, globalBits);
        if (assetBits != 0) pc.pause(IProtocolControl.Scope.ASSET, bytes32(uint256(uint160(USDC))), assetBits);
        if (productBits != 0) pc.pause(IProtocolControl.Scope.PRODUCT, PRODUCT, productBits);
        vm.stopPrank();

        uint256 mask = globalBits | (queryAsset ? assetBits : 0) | (queryProduct ? productBits : 0);
        bool expected = mask & (uint256(1) << bit) != 0;
        assertEq(pc.isPaused(bit, queryAsset ? USDC : address(0), queryProduct ? PRODUCT : bytes32(0)), expected);
    }

    function testFuzz_PAU001_unpauseClearsOnlyGivenBits(uint256 paused, uint256 cleared) public {
        paused = bound(paused, 1, PauseBits.ALL);
        cleared = bound(cleared, 1, PauseBits.ALL);
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.GLOBAL, 0, paused);
        vm.prank(governance);
        pc.unpause(IProtocolControl.Scope.GLOBAL, 0, cleared);
        assertEq(pc.pausedBits(IProtocolControl.Scope.GLOBAL, 0), paused & ~cleared);
    }

    function testFuzz_ACL001_strangersCannotChangeAnything(address caller, uint256 bits) public {
        vm.assume(caller != governance && caller != guardian && caller != address(upgradeAdmin));
        vm.assume(caller != council);
        // a proxy's own ProxyAdmin is also denied, by the proxy itself (ProxyDeniedAdminAccess): see ProtocolControlTest
        vm.assume(caller != upgradeAdmin.proxyAdminOf(address(pc)));
        vm.assume(caller != upgradeAdmin.proxyAdminOf(address(module)));
        bits = bound(bits, 1, PauseBits.ALL);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        pc.pause(IProtocolControl.Scope.GLOBAL, 0, bits);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        pc.unpause(IProtocolControl.Scope.GLOBAL, 0, bits);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        pc.setProductCloseOnly(PRODUCT, true);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        upgradeAdmin.setImplementationAllowed(bytes32(bits), true);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        upgradeAdmin.scheduleUpgrade(address(module), address(moduleImplV2), "");
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        upgradeAdmin.scheduleEmergencyUpgrade(address(module), address(moduleImplV2), "", new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, caller));
        upgradeAdmin.deployProxy(address(moduleImplV1), "");
        vm.stopPrank();
    }

    function testFuzz_UPG002_neverExecutesBeforeEta(uint256 delay, uint256 wait) public {
        delay = bound(delay, 2 days, 365 days);
        UpgradeAdmin ua = new UpgradeAdmin(governance, council, deployer, delay, 1 hours);
        address proxy = ua.deployProxy(
            address(moduleImplV1), abi.encodeCall(MockModuleV1.initialize, (IProtocolControl(address(pc)), 5))
        );
        vm.startPrank(governance);
        ua.setImplementationAllowed(address(moduleImplV2).codehash, true);
        bytes32 id = ua.scheduleUpgrade(proxy, address(moduleImplV2), "");
        vm.stopPrank();
        uint64 eta = ua.getOperation(id).eta;
        assertEq(eta, block.timestamp + delay);

        wait = bound(wait, 0, 2 * delay);
        vm.warp(block.timestamp + wait);
        if (block.timestamp < eta) {
            vm.expectRevert(abi.encodeWithSelector(UpgradeNotReady.selector, eta));
            ua.executeUpgrade(id);
            assertEq(_implementationOf(proxy), address(moduleImplV1));
        } else {
            ua.executeUpgrade(id);
            assertEq(_implementationOf(proxy), address(moduleImplV2));
            assertEq(uint8(ua.getOperation(id).state), uint8(IUpgradeAdmin.OperationState.EXECUTED));
        }
    }

    function testFuzz_UPG008_delayBounds(uint256 upgradeDelay, uint256 emergencyDelay) public {
        bool upOk = upgradeDelay >= 2 days && upgradeDelay <= 365 days;
        bool emOk = emergencyDelay >= 1 hours && emergencyDelay <= 365 days;
        if (!upOk) {
            vm.expectRevert(abi.encodeWithSelector(InvalidDelay.selector, upgradeDelay));
        } else if (!emOk) {
            vm.expectRevert(abi.encodeWithSelector(InvalidDelay.selector, emergencyDelay));
        }
        UpgradeAdmin ua = new UpgradeAdmin(governance, council, deployer, upgradeDelay, emergencyDelay);
        if (upOk && emOk) {
            assertEq(ua.upgradeDelay(), upgradeDelay);
            assertEq(ua.emergencyDelay(), emergencyDelay);
        }
    }
}
