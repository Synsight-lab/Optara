// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {GovernanceFixture} from "../utils/GovernanceFixture.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {MockModuleV1} from "../mocks/MockModule.sol";
import {NotAuthorized, ZeroAddress, ActionPaused} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for the OptaraModule base: initializer lock-down, role checks through ProtocolControl, scoped
///         pause checks, reentrancy guard, ERC-7201 slot.
contract OptaraModuleTest is GovernanceFixture {
    function setUp() public {
        _deployGovernance();
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        moduleImplV1.initialize(IProtocolControl(address(pc)), 1);
    }

    function test_proxyCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        module.initialize(IProtocolControl(address(pc)), 1);
    }

    function test_initRejectsZeroControl() public {
        MockModuleV1 impl = new MockModuleV1();
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            address(impl), abi.encodeCall(MockModuleV1.initialize, (IProtocolControl(address(0)), 1))
        );
    }

    function test_onlyRoleReadsProtocolControl() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        module.setValue(1);

        vm.prank(riskAdmin);
        module.setValue(9);
        assertEq(module.value(), 9);

        // revoking the role in ProtocolControl takes effect in every module at once
        vm.prank(governance);
        pc.revokeRole(keccak256("optara.role.RISK_ADMIN"), riskAdmin);
        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, riskAdmin));
        module.setValue(1);
    }

    function test_hasRoleReadsProtocolControl() public view {
        assertTrue(module.isGuardianOrGovernance(guardian));
        assertTrue(module.isGuardianOrGovernance(governance));
        assertFalse(module.isGuardianOrGovernance(stranger));
    }

    function test_pauseScopesApplyToModules() public {
        assertTrue(module.mintLike(USDC, PRODUCT));
        vm.prank(guardian);
        pc.pause(IProtocolControl.Scope.ASSET, bytes32(uint256(uint160(USDC))), uint256(1) << PauseBits.MINT);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.MINT));
        module.mintLike(USDC, PRODUCT);
        assertTrue(module.mintLike(address(0xBEEF), PRODUCT), "other asset unaffected");
    }

    function test_nonReentrant() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        module.reenter();
    }

    function test_storageSlotMatchesErc7201() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("optara.storage.OptaraModule")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, 0xde0b22c4fea5bfbfa5981692ca05b7ede90474910f477f8232f271db7a585b00);
        bytes32 pcSlot =
            keccak256(abi.encode(uint256(keccak256("optara.storage.ProtocolControl")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(pcSlot, 0x6c38be8bf973fb881542bc2e4a5457541646e342eb50eaf5aac96ae556b93f00);
    }

    function test_controlStoredInNamespacedSlot() public view {
        bytes32 slot = 0xde0b22c4fea5bfbfa5981692ca05b7ede90474910f477f8232f271db7a585b00;
        assertEq(address(uint160(uint256(vm.load(address(module), slot)))), address(pc));
    }
}
