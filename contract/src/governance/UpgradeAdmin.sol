// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IUpgradeAdmin} from "../interfaces/IUpgradeAdmin.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
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
} from "../libraries/Errors.sol";

/// @title UpgradeAdmin
/// @notice Owns the ProxyAdmin of every module proxy. Not upgradeable.
///         Normal path: governance allowlists a code hash, schedules, and anyone executes after `upgradeDelay`.
///         Emergency path: the emergency council (higher multisig threshold) schedules any implementation with the
///         shorter `emergencyDelay`; the affected products are set close-only immediately (ACCESS_CONTROL.md §4).
///         Governance may cancel any pending upgrade; the council may cancel its own emergency upgrades.
/// @dev `governance` is the governance timelock, so a normal upgrade is announced at least parameterTimelock before
///      it is scheduled here, then waits `upgradeDelay`. Delays are immutable and bounded below.
contract UpgradeAdmin is IUpgradeAdmin {
    uint256 public constant MIN_UPGRADE_DELAY = 2 days;
    uint256 public constant MIN_EMERGENCY_DELAY = 1 hours;
    /// @dev Upper bound for both delays, so `block.timestamp + delay` always fits the uint64 eta.
    uint256 public constant MAX_DELAY = 365 days;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable upgradeDelay;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable emergencyDelay;

    address public governance;
    address public pendingGovernance;
    address public emergencyCouncil;
    /// @notice Bootstrap account that may deploy proxies and wire ProtocolControl; renounced after deployment.
    address public deployer;
    IProtocolControl public protocolControl;

    mapping(bytes32 codeHash => bool) public implementationAllowed;
    mapping(address proxy => address) public proxyAdminOf;
    mapping(bytes32 id => Operation) private _operations;
    uint256 public operationNonce;

    modifier onlyGovernance() {
        _onlyGovernance();
        _;
    }

    modifier onlyGovernanceOrDeployer() {
        _onlyGovernanceOrDeployer();
        _;
    }

    constructor(
        address governance_,
        address emergencyCouncil_,
        address deployer_,
        uint256 upgradeDelay_,
        uint256 emergencyDelay_
    ) {
        if (governance_ == address(0) || emergencyCouncil_ == address(0)) revert ZeroAddress();
        if (upgradeDelay_ < MIN_UPGRADE_DELAY || upgradeDelay_ > MAX_DELAY) revert InvalidDelay(upgradeDelay_);
        if (emergencyDelay_ < MIN_EMERGENCY_DELAY || emergencyDelay_ > MAX_DELAY) {
            revert InvalidDelay(emergencyDelay_);
        }
        governance = governance_;
        emergencyCouncil = emergencyCouncil_;
        deployer = deployer_;
        upgradeDelay = upgradeDelay_;
        emergencyDelay = emergencyDelay_;
        emit GovernanceTransferred(address(0), governance_);
        emit EmergencyCouncilSet(emergencyCouncil_);
    }

    // ------------------------------------------------------------------------------------------------- proxies

    /// @notice Deploys a TransparentUpgradeableProxy whose ProxyAdmin is owned by this contract, initializing it in
    ///         the same transaction (no takeover window).
    /// @dev The proxy creates its ProxyAdmin with its first CREATE (nonce 1). `initData` must not deploy contracts,
    ///      or the admin would land at a later nonce; the owner check below rejects that case.
    function deployProxy(address implementation, bytes calldata initData)
        external
        onlyGovernanceOrDeployer
        returns (address proxy)
    {
        if (implementation.code.length == 0) revert NotAContract(implementation);
        proxy = address(new TransparentUpgradeableProxy(implementation, address(this), initData));
        address admin = LibRLP.computeAddress(proxy, 1);
        if (admin.code.length == 0 || ProxyAdmin(admin).owner() != address(this)) revert UnknownProxy(proxy);
        proxyAdminOf[proxy] = admin;
        emit ProxyDeployed(proxy, admin, implementation, implementation.codehash);
    }

    // ------------------------------------------------------------------------------------------------- upgrades

    function setImplementationAllowed(bytes32 codeHash, bool allowed) external onlyGovernance {
        implementationAllowed[codeHash] = allowed;
        emit ImplementationAllowed(codeHash, allowed);
    }

    function scheduleUpgrade(address proxy, address implementation, bytes calldata data)
        external
        onlyGovernance
        returns (bytes32 id)
    {
        bytes32 codeHash = _checkTarget(proxy, implementation);
        if (!implementationAllowed[codeHash]) revert ImplementationNotAllowed(codeHash);
        id = _schedule(proxy, implementation, codeHash, data, upgradeDelay, false);
    }

    function scheduleEmergencyUpgrade(
        address proxy,
        address implementation,
        bytes calldata data,
        bytes32[] calldata affectedProducts
    ) external returns (bytes32 id) {
        if (msg.sender != emergencyCouncil) revert NotAuthorized(msg.sender);
        bytes32 codeHash = _checkTarget(proxy, implementation);
        id = _schedule(proxy, implementation, codeHash, data, emergencyDelay, true);
        if (affectedProducts.length != 0) {
            IProtocolControl pc = protocolControl;
            if (address(pc) == address(0)) revert ZeroAddress();
            for (uint256 i; i < affectedProducts.length; ++i) {
                pc.setProductCloseOnly(affectedProducts[i], true);
            }
        }
    }

    /// @notice Anyone may execute a pending upgrade once its eta has passed.
    /// @dev The implementation's code hash must still equal the scheduled one, and a normal upgrade's hash must
    ///      still be allowlisted (governance can block a scheduled upgrade by disallowing its hash).
    function executeUpgrade(bytes32 id) external {
        Operation storage op = _operations[id];
        if (op.state == OperationState.NONE) revert UnknownUpgrade(id);
        if (op.state != OperationState.PENDING) revert UpgradeNotPending(id);
        if (block.timestamp < op.eta) revert UpgradeNotReady(op.eta);
        bytes32 actual = op.implementation.codehash;
        if (actual != op.codeHash) revert CodeHashMismatch(op.codeHash, actual);
        if (!op.emergency && !implementationAllowed[actual]) revert ImplementationNotAllowed(actual);

        op.state = OperationState.EXECUTED;
        ProxyAdmin(proxyAdminOf[op.proxy])
            .upgradeAndCall(ITransparentUpgradeableProxy(op.proxy), op.implementation, op.data);
        emit UpgradeExecuted(id, op.proxy, op.implementation, actual);
    }

    function cancelUpgrade(bytes32 id) external {
        Operation storage op = _operations[id];
        if (op.state == OperationState.NONE) revert UnknownUpgrade(id);
        if (msg.sender != governance && !(op.emergency && msg.sender == emergencyCouncil)) {
            revert NotAuthorized(msg.sender);
        }
        if (op.state != OperationState.PENDING) revert UpgradeNotPending(id);
        op.state = OperationState.CANCELLED;
        emit UpgradeCancelled(id, msg.sender);
    }

    function getOperation(bytes32 id) external view returns (Operation memory) {
        return _operations[id];
    }

    // ------------------------------------------------------------------------------------------------- admin

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        pendingGovernance = newGovernance;
        emit GovernanceTransferStarted(governance, newGovernance);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotAuthorized(msg.sender);
        emit GovernanceTransferred(governance, msg.sender);
        governance = msg.sender;
        pendingGovernance = address(0);
    }

    function setEmergencyCouncil(address council) external onlyGovernance {
        if (council == address(0)) revert ZeroAddress();
        emergencyCouncil = council;
        emit EmergencyCouncilSet(council);
    }

    function setProtocolControl(IProtocolControl pc) external onlyGovernanceOrDeployer {
        if (address(pc).code.length == 0) revert NotAContract(address(pc));
        protocolControl = pc;
        emit ProtocolControlSet(address(pc));
    }

    function renounceDeployer() external {
        if (msg.sender != deployer || deployer == address(0)) revert NotAuthorized(msg.sender);
        emit DeployerRenounced(deployer);
        deployer = address(0);
    }

    // ------------------------------------------------------------------------------------------------- internal

    function _onlyGovernance() private view {
        if (msg.sender != governance) revert NotAuthorized(msg.sender);
    }

    function _onlyGovernanceOrDeployer() private view {
        if (msg.sender != governance && (msg.sender != deployer || deployer == address(0))) {
            revert NotAuthorized(msg.sender);
        }
    }

    function _checkTarget(address proxy, address implementation) private view returns (bytes32 codeHash) {
        if (proxyAdminOf[proxy] == address(0)) revert UnknownProxy(proxy);
        if (implementation.code.length == 0) revert NotAContract(implementation);
        codeHash = implementation.codehash;
    }

    function _schedule(
        address proxy,
        address implementation,
        bytes32 codeHash,
        bytes calldata data,
        uint256 delay,
        bool emergency
    ) private returns (bytes32 id) {
        id = keccak256(abi.encode(block.chainid, address(this), operationNonce++));
        uint64 eta = SafeCastLib.toUint64(block.timestamp + delay);
        _operations[id] = Operation({
            proxy: proxy,
            implementation: implementation,
            codeHash: codeHash,
            eta: eta,
            emergency: emergency,
            state: OperationState.PENDING,
            data: data
        });
        emit UpgradeScheduled(id, proxy, implementation, codeHash, eta, emergency);
    }
}
