// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UpgradeAdmin} from "../../src/governance/UpgradeAdmin.sol";
import {ProtocolControl} from "../../src/governance/ProtocolControl.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {MockModuleV1, MockModuleV2} from "../mocks/MockModule.sol";

/// @notice Deploys governance the way DEPLOYMENT.md §2 does: UpgradeAdmin first, then ProtocolControl behind a proxy
///         initialized in the same transaction, roles granted, deployer roles renounced.
abstract contract GovernanceFixture is Test {
    address internal governance = makeAddr("governance"); // the governance timelock
    address internal guardian = makeAddr("guardian");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal council = makeAddr("emergencyCouncil");
    address internal stranger = makeAddr("stranger");
    address internal deployer = address(this);

    uint256 internal constant UPGRADE_DELAY = 7 days;
    uint256 internal constant EMERGENCY_DELAY = 24 hours;

    UpgradeAdmin internal upgradeAdmin;
    ProtocolControl internal pc;
    MockModuleV1 internal module; // proxy
    MockModuleV1 internal moduleImplV1;
    MockModuleV2 internal moduleImplV2;

    bytes32 internal constant PRODUCT = keccak256("ETH/USDC");
    address internal constant USDC = address(0xC0FFEE);

    /// @dev Governance plus the mock module, then the hand-over.
    function _deployGovernance() internal {
        _deployGovernanceCore();
        _deployMockModule();
        _handOver();
    }

    /// @dev UpgradeAdmin + ProtocolControl with roles granted; the deployer still holds GOVERNANCE and the
    ///      UpgradeAdmin deployer seat so more proxies can be deployed before `_handOver`.
    function _deployGovernanceCore() internal {
        upgradeAdmin = new UpgradeAdmin(governance, council, deployer, UPGRADE_DELAY, EMERGENCY_DELAY);
        ProtocolControl impl = new ProtocolControl();
        pc = ProtocolControl(
            upgradeAdmin.deployProxy(
                address(impl), abi.encodeCall(ProtocolControl.initialize, (deployer, address(upgradeAdmin)))
            )
        );
        upgradeAdmin.setProtocolControl(IProtocolControl(address(pc)));

        pc.grantRole(Roles.GOVERNANCE, governance);
        pc.grantRole(Roles.GUARDIAN, guardian);
        pc.grantRole(Roles.RISK_ADMIN, riskAdmin);
    }

    function _deployMockModule() internal {
        moduleImplV1 = new MockModuleV1();
        moduleImplV2 = new MockModuleV2();
        module = MockModuleV1(
            upgradeAdmin.deployProxy(
                address(moduleImplV1), abi.encodeCall(MockModuleV1.initialize, (IProtocolControl(address(pc)), 42))
            )
        );
    }

    /// @dev The deployer keeps nothing (DEPLOYMENT.md §2 step 5).
    function _handOver() internal {
        pc.renounceRole(Roles.GOVERNANCE, deployer);
        upgradeAdmin.renounceDeployer();
    }

    /// @dev Address of the next proxy UpgradeAdmin.deployProxy creates (one CREATE per proxy), `ahead` proxies later.
    function _nextProxy(uint256 ahead) internal view returns (address) {
        return vm.computeCreateAddress(address(upgradeAdmin), vm.getNonce(address(upgradeAdmin)) + ahead);
    }

    /// @dev ERC-1967 implementation slot of a proxy.
    function _implementationOf(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
