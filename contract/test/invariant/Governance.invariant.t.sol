// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernanceFixture} from "../utils/GovernanceFixture.sol";
import {UpgradeAdmin} from "../../src/governance/UpgradeAdmin.sol";
import {ProtocolControl} from "../../src/governance/ProtocolControl.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IUpgradeAdmin} from "../../src/interfaces/IUpgradeAdmin.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";
import {MockModuleV1} from "../mocks/MockModule.sol";

/// @notice Random governance actions by random actors. Ghost state is updated only when a call succeeds, so the
///         invariants check that the contracts did exactly what the model allows (INV-53, INV-34).
contract GovernanceHandler is Test {
    ProtocolControl internal pc;
    UpgradeAdmin internal ua;
    address internal module;
    address internal implV1;
    address internal implV2;
    address[4] internal actors; // governance, guardian, council, stranger

    bytes32[3] internal scopeIds;
    IProtocolControl.Scope[3] internal scopes;
    bytes32[2] internal products;

    // ghost model
    mapping(uint256 => uint256) public ghostPaused; // by scope index
    mapping(bytes32 => bool) public ghostCloseOnly;
    address public ghostImplementation;
    uint256 public earlyExecutions;
    uint256 public unauthorizedPauses;
    uint256 public unauthorizedUnpauses;
    uint256 public unauthorizedClears;
    uint256 public executions;
    bytes32[] internal ops;

    constructor(ProtocolControl pc_, UpgradeAdmin ua_, address module_, address v1, address v2, address[4] memory a) {
        (pc, ua, module, implV1, implV2, actors) = (pc_, ua_, module_, v1, v2, a);
        ghostImplementation = v1;
        scopes = [IProtocolControl.Scope.GLOBAL, IProtocolControl.Scope.ASSET, IProtocolControl.Scope.PRODUCT];
        scopeIds = [bytes32(0), bytes32(uint256(uint160(address(0xC0FFEE)))), keccak256("ETH/USDC")];
        products = [keccak256("ETH/USDC"), keccak256("BTC/USDC")];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function pause(uint256 actorSeed, uint256 scopeSeed, uint256 bits) external {
        address a = _actor(actorSeed);
        uint256 s = scopeSeed % 3;
        bits = bound(bits, 1, PauseBits.ALL);
        vm.prank(a);
        try pc.pause(scopes[s], scopeIds[s], bits) {
            if (a != actors[0] && a != actors[1]) unauthorizedPauses++;
            ghostPaused[s] |= bits;
        } catch {}
    }

    function unpause(uint256 actorSeed, uint256 scopeSeed, uint256 bits) external {
        address a = _actor(actorSeed);
        uint256 s = scopeSeed % 3;
        bits = bound(bits, 1, PauseBits.ALL);
        vm.prank(a);
        try pc.unpause(scopes[s], scopeIds[s], bits) {
            if (a != actors[0]) unauthorizedUnpauses++;
            ghostPaused[s] &= ~bits;
        } catch {}
    }

    function setCloseOnly(uint256 actorSeed, uint256 productSeed, bool on) external {
        address a = _actor(actorSeed);
        bytes32 p = products[productSeed % 2];
        vm.prank(a);
        try pc.setProductCloseOnly(p, on) {
            if (!on && a != actors[0]) unauthorizedClears++;
            ghostCloseOnly[p] = on;
        } catch {}
    }

    function schedule(bool toV2) external {
        address impl = toV2 ? implV2 : implV1;
        vm.startPrank(actors[0]);
        ua.setImplementationAllowed(impl.codehash, true);
        ops.push(ua.scheduleUpgrade(module, impl, ""));
        vm.stopPrank();
    }

    function scheduleEmergency(bool toV2, uint256 productSeed) external {
        bytes32[] memory affected = new bytes32[](1);
        affected[0] = products[productSeed % 2];
        vm.prank(actors[2]);
        ops.push(ua.scheduleEmergencyUpgrade(module, toV2 ? implV2 : implV1, "", affected));
        ghostCloseOnly[affected[0]] = true;
    }

    function execute(uint256 idx) external {
        if (ops.length == 0) return;
        bytes32 id = ops[idx % ops.length];
        IUpgradeAdmin.Operation memory op = ua.getOperation(id);
        try ua.executeUpgrade(id) {
            if (block.timestamp < op.eta) earlyExecutions++;
            ghostImplementation = op.implementation;
            executions++;
        } catch {}
    }

    function cancel(uint256 idx, uint256 actorSeed) external {
        if (ops.length == 0) return;
        vm.prank(_actor(actorSeed));
        try ua.cancelUpgrade(ops[idx % ops.length]) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }
}

contract GovernanceInvariantTest is GovernanceFixture {
    GovernanceHandler internal handler;

    function setUp() public {
        _deployGovernance();
        handler = new GovernanceHandler(
            pc,
            upgradeAdmin,
            address(module),
            address(moduleImplV1),
            address(moduleImplV2),
            [governance, guardian, council, stranger]
        );
        targetContract(address(handler));
    }

    /// @dev Pause masks are exactly what authorized calls produced; only governance ever cleared a bit.
    function invariant_pauseMasksMatchModel() public view {
        assertEq(pc.pausedBits(IProtocolControl.Scope.GLOBAL, 0), handler.ghostPaused(0));
        assertEq(pc.pausedBits(IProtocolControl.Scope.ASSET, bytes32(uint256(uint160(USDC)))), handler.ghostPaused(1));
        assertEq(pc.pausedBits(IProtocolControl.Scope.PRODUCT, PRODUCT), handler.ghostPaused(2));
    }

    function invariant_closeOnlyMatchesModel() public view {
        assertEq(pc.isProductCloseOnly(PRODUCT), handler.ghostCloseOnly(PRODUCT));
        assertEq(pc.isProductCloseOnly(keccak256("BTC/USDC")), handler.ghostCloseOnly(keccak256("BTC/USDC")));
    }

    /// @dev INV-53: guardians and strangers never unpause, clear close-only or pause without a role.
    function invariant_INV53_onlyGovernanceRelaxes() public view {
        assertEq(handler.unauthorizedUnpauses(), 0);
        assertEq(handler.unauthorizedClears(), 0);
        assertEq(handler.unauthorizedPauses(), 0);
    }

    /// @dev The implementation changes only through executed operations, never before their eta.
    function invariant_upgradesOnlyAfterEta() public view {
        assertEq(handler.earlyExecutions(), 0);
        assertEq(_implementationOf(address(module)), handler.ghostImplementation());
    }

    /// @dev Proves the handler's success paths are reachable (so the invariants above are not vacuous).
    function test_handlerPathsReachable() public {
        handler.schedule(true);
        handler.pause(1, 0, 1); // guardian, global
        handler.setCloseOnly(1, 0, true); // guardian
        handler.warp(3 days);
        handler.warp(3 days);
        handler.execute(0);
        assertEq(handler.executions(), 0, "not before eta");
        handler.warp(1 days);
        handler.execute(0);
        assertEq(handler.executions(), 1);
        assertEq(_implementationOf(address(module)), address(moduleImplV2));
        assertEq(handler.ghostPaused(0), 1);
        assertTrue(handler.ghostCloseOnly(PRODUCT));
        handler.unpause(0, 0, 1); // governance
        assertEq(handler.ghostPaused(0), 0);
        invariant_pauseMasksMatchModel();
        invariant_upgradesOnlyAfterEta();
    }

    /// @dev INV-34 (pattern): module storage survives any sequence of upgrades.
    function invariant_INV34_storagePreservedAcrossUpgrades() public view {
        assertEq(MockModuleV1(address(module)).value(), 42);
        assertEq(address(MockModuleV1(address(module)).control()), address(pc));
    }
}
