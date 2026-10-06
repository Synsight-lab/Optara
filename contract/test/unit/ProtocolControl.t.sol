// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GovernanceFixture} from "../utils/GovernanceFixture.sol";
import {ProtocolControl} from "../../src/governance/ProtocolControl.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {NotAuthorized, ZeroAddress, ActionPaused, InvalidScope, InvalidPauseBits} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for ProtocolControl: roles (ACL-*), pause bits (PAU-*), manual close-only (ACL-005).
contract ProtocolControlTest is GovernanceFixture {
    IProtocolControl.Scope internal constant S_GLOBAL = IProtocolControl.Scope.GLOBAL;
    IProtocolControl.Scope internal constant S_ASSET = IProtocolControl.Scope.ASSET;
    IProtocolControl.Scope internal constant S_PRODUCT = IProtocolControl.Scope.PRODUCT;

    uint256 internal constant MINT_BIT = uint256(1) << PauseBits.MINT;
    uint256 internal constant CLOSE_BIT = uint256(1) << PauseBits.CLOSE;

    function setUp() public {
        _deployGovernance();
    }

    function _asset(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // ------------------------------------------------------------------ initialization and roles (ACL-006)

    function test_initialState() public view {
        assertTrue(pc.hasRole(Roles.GOVERNANCE, governance));
        assertTrue(pc.hasRole(Roles.GUARDIAN, guardian));
        assertFalse(pc.hasRole(Roles.GOVERNANCE, deployer), "deployer kept governance");
        assertEq(pc.upgradeAdmin(), address(upgradeAdmin));
        assertEq(Roles.GOVERNANCE, pc.DEFAULT_ADMIN_ROLE());
        assertEq(pc.getRoleAdmin(Roles.GUARDIAN), Roles.GOVERNANCE);
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pc.initialize(stranger, stranger);
    }

    function test_implementationCannotBeInitialized() public {
        ProtocolControl impl = new ProtocolControl();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(stranger, stranger);
    }

    function test_initialize_rejectsZeroAddresses() public {
        ProtocolControl impl = new ProtocolControl();
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(address(impl), abi.encodeCall(ProtocolControl.initialize, (address(0), stranger)));
        vm.prank(governance);
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(address(impl), abi.encodeCall(ProtocolControl.initialize, (stranger, address(0))));
    }

    function test_ACL006_onlyGovernanceGrantsRoles() public {
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, Roles.GOVERNANCE)
        );
        pc.grantRole(Roles.SERIES_CREATOR, stranger);

        vm.expectEmit(true, true, true, true, address(pc));
        emit IAccessControl.RoleGranted(Roles.SERIES_CREATOR, stranger, governance);
        vm.prank(governance);
        pc.grantRole(Roles.SERIES_CREATOR, stranger);
        assertTrue(pc.hasRole(Roles.SERIES_CREATOR, stranger));

        vm.expectEmit(true, true, true, true, address(pc));
        emit IAccessControl.RoleRevoked(Roles.SERIES_CREATOR, stranger, governance);
        vm.prank(governance);
        pc.revokeRole(Roles.SERIES_CREATOR, stranger);
        assertFalse(pc.hasRole(Roles.SERIES_CREATOR, stranger));
    }

    // ------------------------------------------------------------------ pause / unpause (PAU-001, ACL-002)

    function test_PAU001_guardianPausesGovernanceUnpauses() public {
        vm.expectEmit(true, true, true, true, address(pc));
        emit IProtocolControl.Paused(S_GLOBAL, 0, MINT_BIT, guardian);
        vm.prank(guardian);
        pc.pause(S_GLOBAL, 0, MINT_BIT);
        assertTrue(pc.isPaused(PauseBits.MINT, address(0), 0));

        vm.expectEmit(true, true, true, true, address(pc));
        emit IProtocolControl.Unpaused(S_GLOBAL, 0, MINT_BIT, governance);
        vm.prank(governance);
        pc.unpause(S_GLOBAL, 0, MINT_BIT);
        assertFalse(pc.isPaused(PauseBits.MINT, address(0), 0));
    }

    function test_governanceCanPause() public {
        vm.prank(governance);
        pc.pause(S_GLOBAL, 0, MINT_BIT);
        assertTrue(pc.isPaused(PauseBits.MINT, address(0), 0));
    }

    function test_ACL002_guardianCannotUnpause() public {
        vm.prank(guardian);
        pc.pause(S_GLOBAL, 0, MINT_BIT);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        pc.unpause(S_GLOBAL, 0, MINT_BIT);
    }

    function test_strangerCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        pc.pause(S_GLOBAL, 0, MINT_BIT);
    }

    function test_PAU001_scopes() public {
        vm.startPrank(guardian);
        pc.pause(S_ASSET, _asset(USDC), MINT_BIT);
        pc.pause(S_PRODUCT, PRODUCT, CLOSE_BIT);
        vm.stopPrank();

        assertTrue(pc.isPaused(PauseBits.MINT, USDC, 0), "asset scope");
        assertFalse(pc.isPaused(PauseBits.MINT, address(0xBEEF), 0), "other asset");
        assertFalse(pc.isPaused(PauseBits.MINT, address(0), PRODUCT), "asset not given");
        assertTrue(pc.isPaused(PauseBits.CLOSE, address(0), PRODUCT), "product scope");
        assertFalse(pc.isPaused(PauseBits.CLOSE, USDC, keccak256("BTC/USDC")), "other product");
        assertEq(pc.pausedBits(S_ASSET, _asset(USDC)), MINT_BIT);
        assertEq(pc.pausedBits(S_PRODUCT, PRODUCT), CLOSE_BIT);
        assertEq(pc.pausedBits(S_GLOBAL, 0), 0);
    }

    function test_PAU002_pausingOneBitLeavesOthers() public {
        vm.prank(guardian);
        pc.pause(S_GLOBAL, 0, MINT_BIT);
        for (uint8 b; b < PauseBits.COUNT; ++b) {
            assertEq(pc.isPaused(b, USDC, PRODUCT), b == PauseBits.MINT);
        }
    }

    function test_requireNotPaused() public {
        pc.requireNotPaused(PauseBits.MINT, USDC, PRODUCT); // nothing paused
        vm.prank(guardian);
        pc.pause(S_PRODUCT, PRODUCT, MINT_BIT);
        vm.expectRevert(abi.encodeWithSelector(ActionPaused.selector, PauseBits.MINT));
        pc.requireNotPaused(PauseBits.MINT, USDC, PRODUCT);
    }

    function test_PAU003_invalidScopeIds() public {
        vm.startPrank(guardian);
        vm.expectRevert(InvalidScope.selector);
        pc.pause(S_GLOBAL, bytes32(uint256(1)), MINT_BIT);
        vm.expectRevert(InvalidScope.selector);
        pc.pause(S_ASSET, 0, MINT_BIT);
        vm.expectRevert(InvalidScope.selector);
        pc.pause(S_ASSET, bytes32(uint256(1) << 160), MINT_BIT); // not an address
        vm.expectRevert(InvalidScope.selector);
        pc.pause(S_PRODUCT, 0, MINT_BIT);
        vm.stopPrank();
    }

    function test_PAU003_invalidBits() public {
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(InvalidPauseBits.selector, 0));
        pc.pause(S_GLOBAL, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidPauseBits.selector, uint256(1) << PauseBits.COUNT));
        pc.pause(S_GLOBAL, 0, uint256(1) << PauseBits.COUNT);
        vm.stopPrank();
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidPauseBits.selector, 0));
        pc.unpause(S_GLOBAL, 0, 0);
    }

    // ------------------------------------------------------------------ close-only (ACL-005)

    function test_ACL005_guardianSetsGovernanceClears() public {
        vm.expectEmit(true, true, true, true, address(pc));
        emit IProtocolControl.ProductCloseOnlySet(PRODUCT, true, guardian);
        vm.prank(guardian);
        pc.setProductCloseOnly(PRODUCT, true);
        assertTrue(pc.isProductCloseOnly(PRODUCT));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, guardian));
        pc.setProductCloseOnly(PRODUCT, false);

        vm.prank(governance);
        pc.setProductCloseOnly(PRODUCT, false);
        assertFalse(pc.isProductCloseOnly(PRODUCT));
    }

    function test_ACL005_upgradeAdminMaySetButNotClear() public {
        vm.prank(address(upgradeAdmin));
        pc.setProductCloseOnly(PRODUCT, true);
        assertTrue(pc.isProductCloseOnly(PRODUCT));
        vm.prank(address(upgradeAdmin));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, address(upgradeAdmin)));
        pc.setProductCloseOnly(PRODUCT, false);
    }

    function test_proxyAdminCannotCallProtocolControl() public {
        address admin = upgradeAdmin.proxyAdminOf(address(pc));
        vm.prank(admin);
        vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        pc.pause(S_GLOBAL, 0, MINT_BIT);
    }

    function test_strangerCannotSetCloseOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        pc.setProductCloseOnly(PRODUCT, true);
    }
}
