// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {GovernanceFixture} from "../utils/GovernanceFixture.sol";
import {UpgradeAdmin} from "../../src/governance/UpgradeAdmin.sol";
import {IUpgradeAdmin} from "../../src/interfaces/IUpgradeAdmin.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {MockModuleV1, MockModuleV2, MockCreatingModule} from "../mocks/MockModule.sol";
import {
    NotAuthorized,
    ZeroAddress,
    NotAContract,
    InvalidDelay,
    UnknownProxy,
    ImplementationNotAllowed,
    UnknownUpgrade,
    UpgradeNotPending,
    UpgradeNotReady,
    CodeHashMismatch
} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for UpgradeAdmin (ACCESS_CONTROL.md §2–§4): UPG-002, UPG-003, UPG-004, UPG-005..UPG-009.
contract UpgradeAdminTest is GovernanceFixture {
    function setUp() public {
        _deployGovernance();
    }

    function _allow(address impl) internal {
        vm.prank(governance);
        upgradeAdmin.setImplementationAllowed(impl.codehash, true);
    }

    function _scheduleV2(bytes memory data) internal returns (bytes32 id) {
        _allow(address(moduleImplV2));
        vm.prank(governance);
        id = upgradeAdmin.scheduleUpgrade(address(module), address(moduleImplV2), data);
    }

    // ------------------------------------------------------------------ constructor (UPG-008)

    function test_UPG008_constructorBounds() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidDelay.selector, 2 days - 1));
        new UpgradeAdmin(governance, council, deployer, 2 days - 1, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(InvalidDelay.selector, 365 days + 1));
        new UpgradeAdmin(governance, council, deployer, 365 days + 1, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(InvalidDelay.selector, 1 hours - 1));
        new UpgradeAdmin(governance, council, deployer, 7 days, 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidDelay.selector, 365 days + 1));
        new UpgradeAdmin(governance, council, deployer, 7 days, 365 days + 1);
        vm.expectRevert(ZeroAddress.selector);
        new UpgradeAdmin(address(0), council, deployer, 7 days, 1 days);
        vm.expectRevert(ZeroAddress.selector);
        new UpgradeAdmin(governance, address(0), deployer, 7 days, 1 days);
    }

    function test_constructorState() public {
        vm.expectEmit(true, true, true, true);
        emit IUpgradeAdmin.GovernanceTransferred(address(0), governance);
        vm.expectEmit(true, true, true, true);
        emit IUpgradeAdmin.EmergencyCouncilSet(council);
        UpgradeAdmin ua = new UpgradeAdmin(governance, council, deployer, 7 days, 1 days);
        assertEq(ua.upgradeDelay(), 7 days);
        assertEq(ua.emergencyDelay(), 1 days);
        assertEq(ua.governance(), governance);
        assertEq(ua.emergencyCouncil(), council);
        assertEq(ua.deployer(), deployer);
    }

    // ------------------------------------------------------------------ proxies (UPG-005)

    function test_UPG005_deployProxyOwnedAndInitialized() public view {
        address admin = upgradeAdmin.proxyAdminOf(address(module));
        assertTrue(admin != address(0));
        assertEq(ProxyAdmin(admin).owner(), address(upgradeAdmin));
        assertEq(module.value(), 42, "initialized in the deploy transaction");
        assertEq(address(module.control()), address(pc));
        assertEq(_implementationOf(address(module)), address(moduleImplV1));
    }

    function test_UPG005_deployProxyEmitsEvent() public {
        MockModuleV1 impl = new MockModuleV1();
        vm.recordLogs();
        vm.prank(governance);
        address proxy = upgradeAdmin.deployProxy(
            address(impl), abi.encodeCall(MockModuleV1.initialize, (IProtocolControl(address(pc)), 1))
        );
        // last log is ProxyDeployed (earlier ones come from the proxy constructor)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], IUpgradeAdmin.ProxyDeployed.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(proxy))));
        assertEq(last.topics[2], bytes32(uint256(uint160(upgradeAdmin.proxyAdminOf(proxy)))));
        assertEq(last.topics[3], bytes32(uint256(uint160(address(impl)))));
        assertEq(abi.decode(last.data, (bytes32)), address(impl).codehash);
        assertEq(MockModuleV1(proxy).value(), 1);
    }

    function test_UPG005_deployProxyAccess() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.deployProxy(address(moduleImplV1), "");
        // the deployer renounced in the fixture
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, deployer));
        upgradeAdmin.deployProxy(address(moduleImplV1), "");
    }

    function test_UPG009_deployProxyRejectsInitializerThatDeploys() public {
        MockCreatingModule impl = new MockCreatingModule();
        // the proxy would be created at UpgradeAdmin's next nonce; its admin then sits at proxy nonce 2, not 1
        address expectedProxy = vm.computeCreateAddress(address(upgradeAdmin), vm.getNonce(address(upgradeAdmin)));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UnknownProxy.selector, expectedProxy));
        upgradeAdmin.deployProxy(address(impl), abi.encodeCall(MockCreatingModule.initialize, ()));
    }

    function test_UPG009_deployProxyRequiresContract() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, stranger));
        upgradeAdmin.deployProxy(stranger, "");
    }

    // ------------------------------------------------------------------ normal upgrade (UPG-002, UPG-003)

    function test_UPG002_scheduleAndExecuteAfterDelay() public {
        bytes memory data = abi.encodeCall(MockModuleV2.migrate, (7));
        _allow(address(moduleImplV2));
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(upgradeAdmin), uint256(0)));
        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.UpgradeScheduled(
            expectedId,
            address(module),
            address(moduleImplV2),
            address(moduleImplV2).codehash,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64(block.timestamp + UPGRADE_DELAY),
            false
        );
        vm.prank(governance);
        bytes32 id = upgradeAdmin.scheduleUpgrade(address(module), address(moduleImplV2), data);
        assertEq(id, expectedId);

        IUpgradeAdmin.Operation memory op = upgradeAdmin.getOperation(id);
        assertEq(op.eta, block.timestamp + UPGRADE_DELAY);
        assertEq(op.codeHash, address(moduleImplV2).codehash);
        assertEq(uint8(op.state), uint8(IUpgradeAdmin.OperationState.PENDING));
        assertFalse(op.emergency);

        vm.warp(op.eta - 1);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotReady.selector, op.eta));
        upgradeAdmin.executeUpgrade(id);

        vm.warp(op.eta);
        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.UpgradeExecuted(id, address(module), address(moduleImplV2), address(moduleImplV2).codehash);
        vm.prank(stranger); // anyone may execute
        upgradeAdmin.executeUpgrade(id);

        MockModuleV2 v2 = MockModuleV2(address(module));
        assertEq(v2.version(), 2);
        assertEq(v2.extra(), 7, "migration ran");
        assertEq(v2.value(), 42, "storage preserved");
        assertEq(_implementationOf(address(module)), address(moduleImplV2));
        assertEq(uint8(upgradeAdmin.getOperation(id).state), uint8(IUpgradeAdmin.OperationState.EXECUTED));

        vm.expectRevert(abi.encodeWithSelector(UpgradeNotPending.selector, id));
        upgradeAdmin.executeUpgrade(id);
    }

    function test_UPG003_protectedValueSurvivesUpgrade() public {
        vm.prank(governance);
        module.setProtectedOnce(keccak256("terms"));
        bytes32 id = _scheduleV2("");
        vm.warp(block.timestamp + UPGRADE_DELAY);
        upgradeAdmin.executeUpgrade(id);
        assertEq(MockModuleV2(address(module)).protectedTerm(), keccak256("terms"));
    }

    function test_UPG002_scheduleRequiresGovernanceAllowlistKnownProxy() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.scheduleUpgrade(address(module), address(moduleImplV2), "");

        bytes32 h = address(moduleImplV2).codehash;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ImplementationNotAllowed.selector, h));
        upgradeAdmin.scheduleUpgrade(address(module), address(moduleImplV2), "");

        _allow(address(moduleImplV2));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UnknownProxy.selector, stranger));
        upgradeAdmin.scheduleUpgrade(stranger, address(moduleImplV2), "");

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, stranger));
        upgradeAdmin.scheduleUpgrade(address(module), stranger, "");
    }

    function test_setImplementationAllowedAccessAndEvent() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.setImplementationAllowed(bytes32(uint256(1)), true);

        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.ImplementationAllowed(bytes32(uint256(1)), true);
        vm.prank(governance);
        upgradeAdmin.setImplementationAllowed(bytes32(uint256(1)), true);
        assertTrue(upgradeAdmin.implementationAllowed(bytes32(uint256(1))));
    }

    function test_UPG007_disallowingBlocksScheduledUpgrade() public {
        bytes32 id = _scheduleV2("");
        vm.prank(governance);
        upgradeAdmin.setImplementationAllowed(address(moduleImplV2).codehash, false);
        vm.warp(block.timestamp + UPGRADE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ImplementationNotAllowed.selector, address(moduleImplV2).codehash));
        upgradeAdmin.executeUpgrade(id);
    }

    function test_UPG007_codeChangeBlocksExecution() public {
        bytes32 id = _scheduleV2("");
        bytes32 expected = address(moduleImplV2).codehash;
        vm.etch(address(moduleImplV2), address(moduleImplV1).code); // implementation code swapped
        vm.warp(block.timestamp + UPGRADE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(CodeHashMismatch.selector, expected, address(moduleImplV1).codehash));
        upgradeAdmin.executeUpgrade(id);
    }

    function test_UPG009_unknownOperation() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownUpgrade.selector, bytes32(uint256(5))));
        upgradeAdmin.executeUpgrade(bytes32(uint256(5)));
        vm.expectRevert(abi.encodeWithSelector(UnknownUpgrade.selector, bytes32(uint256(5))));
        upgradeAdmin.cancelUpgrade(bytes32(uint256(5)));
    }

    function test_operationIdsAreUnique() public {
        bytes32 a = _scheduleV2("");
        vm.prank(governance);
        bytes32 b = upgradeAdmin.scheduleUpgrade(address(module), address(moduleImplV2), "");
        assertTrue(a != b);
        assertEq(upgradeAdmin.operationNonce(), 2);
    }

    // ------------------------------------------------------------------ cancel (UPG-006)

    function test_UPG006_governanceCancels() public {
        bytes32 id = _scheduleV2("");
        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.UpgradeCancelled(id, governance);
        vm.prank(governance);
        upgradeAdmin.cancelUpgrade(id);
        vm.warp(block.timestamp + UPGRADE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotPending.selector, id));
        upgradeAdmin.executeUpgrade(id);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotPending.selector, id));
        upgradeAdmin.cancelUpgrade(id);
    }

    function test_UPG006_councilCannotCancelNormalUpgrade() public {
        bytes32 id = _scheduleV2("");
        vm.prank(council);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, council));
        upgradeAdmin.cancelUpgrade(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.cancelUpgrade(id);
    }

    // ------------------------------------------------------------------ emergency (UPG-004)

    function test_UPG004_emergencyUpgradeSetsCloseOnlyAndUsesShortDelay() public {
        bytes32[] memory products = new bytes32[](2);
        (products[0], products[1]) = (PRODUCT, keccak256("BTC/USDC"));

        vm.expectEmit(true, true, true, true, address(pc));
        emit IProtocolControl.ProductCloseOnlySet(PRODUCT, true, address(upgradeAdmin));
        vm.prank(council);
        bytes32 id = upgradeAdmin.scheduleEmergencyUpgrade(address(module), address(moduleImplV2), "", products);

        assertTrue(pc.isProductCloseOnly(PRODUCT));
        assertTrue(pc.isProductCloseOnly(products[1]));
        IUpgradeAdmin.Operation memory op = upgradeAdmin.getOperation(id);
        assertTrue(op.emergency);
        assertEq(op.eta, block.timestamp + EMERGENCY_DELAY);

        vm.warp(op.eta);
        upgradeAdmin.executeUpgrade(id); // no allowlist needed on the emergency path
        assertEq(MockModuleV2(address(module)).version(), 2);
        assertTrue(pc.isProductCloseOnly(PRODUCT), "close-only stays until governance clears it");
    }

    function test_UPG004_onlyCouncilSchedulesEmergency() public {
        bytes32[] memory none = new bytes32[](0);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, governance));
        upgradeAdmin.scheduleEmergencyUpgrade(address(module), address(moduleImplV2), "", none);
    }

    function test_UPG004_emergencyNeedsProtocolControlForProducts() public {
        UpgradeAdmin ua = new UpgradeAdmin(governance, council, deployer, 7 days, 1 days);
        address proxy = ua.deployProxy(
            address(moduleImplV1), abi.encodeCall(MockModuleV1.initialize, (IProtocolControl(address(pc)), 1))
        );
        bytes32[] memory products = new bytes32[](1);
        products[0] = PRODUCT;
        vm.prank(council);
        vm.expectRevert(ZeroAddress.selector);
        ua.scheduleEmergencyUpgrade(proxy, address(moduleImplV2), "", products);
    }

    function test_UPG006_councilAndGovernanceCanCancelEmergency() public {
        bytes32[] memory none = new bytes32[](0);
        vm.startPrank(council);
        bytes32 a = upgradeAdmin.scheduleEmergencyUpgrade(address(module), address(moduleImplV2), "", none);
        bytes32 b = upgradeAdmin.scheduleEmergencyUpgrade(address(module), address(moduleImplV2), "", none);
        upgradeAdmin.cancelUpgrade(a);
        vm.stopPrank();
        vm.prank(governance);
        upgradeAdmin.cancelUpgrade(b);
        assertEq(uint8(upgradeAdmin.getOperation(a).state), uint8(IUpgradeAdmin.OperationState.CANCELLED));
        assertEq(uint8(upgradeAdmin.getOperation(b).state), uint8(IUpgradeAdmin.OperationState.CANCELLED));
    }

    // ------------------------------------------------------------------ admin (UPG-008)

    function test_UPG008_governanceTransferIsTwoStep() public {
        address next = makeAddr("nextGovernance");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.transferGovernance(next);

        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.GovernanceTransferStarted(governance, next);
        vm.prank(governance);
        upgradeAdmin.transferGovernance(next);
        assertEq(upgradeAdmin.governance(), governance, "not yet transferred");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.acceptGovernance();

        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.GovernanceTransferred(governance, next);
        vm.prank(next);
        upgradeAdmin.acceptGovernance();
        assertEq(upgradeAdmin.governance(), next);
        assertEq(upgradeAdmin.pendingGovernance(), address(0));

        vm.prank(governance); // the old governance lost its powers
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, governance));
        upgradeAdmin.transferGovernance(next);
        vm.prank(next);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.transferGovernance(address(0));
    }

    function test_UPG008_setEmergencyCouncil() public {
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.setEmergencyCouncil(address(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        upgradeAdmin.setEmergencyCouncil(stranger);
        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.EmergencyCouncilSet(stranger);
        vm.prank(governance);
        upgradeAdmin.setEmergencyCouncil(stranger);
        assertEq(upgradeAdmin.emergencyCouncil(), stranger);
    }

    function test_UPG008_setProtocolControl() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, stranger));
        upgradeAdmin.setProtocolControl(IProtocolControl(stranger));
        vm.expectEmit(true, true, true, true, address(upgradeAdmin));
        emit IUpgradeAdmin.ProtocolControlSet(address(pc));
        vm.prank(governance);
        upgradeAdmin.setProtocolControl(IProtocolControl(address(pc)));
    }

    function test_UPG008_deployerRenounce() public {
        UpgradeAdmin ua = new UpgradeAdmin(governance, council, deployer, 7 days, 1 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        ua.renounceDeployer();
        vm.expectEmit(true, true, true, true, address(ua));
        emit IUpgradeAdmin.DeployerRenounced(deployer);
        ua.renounceDeployer();
        assertEq(ua.deployer(), address(0));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, deployer));
        ua.renounceDeployer();
    }
}
