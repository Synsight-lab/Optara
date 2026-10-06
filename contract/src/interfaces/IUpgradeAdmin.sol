// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IUpgradeAdmin
/// @notice Owner of every module proxy: implementation allowlist, timelocked upgrades, emergency path
///         (docs/ACCESS_CONTROL.md §2–§4).
interface IUpgradeAdmin {
    enum OperationState {
        NONE,
        PENDING,
        EXECUTED,
        CANCELLED
    }

    struct Operation {
        address proxy;
        address implementation;
        bytes32 codeHash;
        uint64 eta;
        bool emergency;
        OperationState state;
        bytes data;
    }

    event ProxyDeployed(
        address indexed proxy, address indexed proxyAdmin, address indexed implementation, bytes32 codeHash
    );
    event ImplementationAllowed(bytes32 indexed codeHash, bool allowed);
    event UpgradeScheduled(
        bytes32 indexed id,
        address indexed proxy,
        address indexed implementation,
        bytes32 codeHash,
        uint64 eta,
        bool emergency
    );
    event UpgradeExecuted(bytes32 indexed id, address indexed proxy, address indexed implementation, bytes32 codeHash);
    event UpgradeCancelled(bytes32 indexed id, address indexed by);
    event GovernanceTransferStarted(address indexed current, address indexed pending);
    event GovernanceTransferred(address indexed previous, address indexed current);
    event EmergencyCouncilSet(address indexed council);
    event ProtocolControlSet(address indexed protocolControl);
    event DeployerRenounced(address indexed deployer);

    function deployProxy(address implementation, bytes calldata initData) external returns (address proxy);
    function setImplementationAllowed(bytes32 codeHash, bool allowed) external;
    function scheduleUpgrade(address proxy, address implementation, bytes calldata data) external returns (bytes32 id);
    function scheduleEmergencyUpgrade(
        address proxy,
        address implementation,
        bytes calldata data,
        bytes32[] calldata affectedProducts
    ) external returns (bytes32 id);
    function executeUpgrade(bytes32 id) external;
    function cancelUpgrade(bytes32 id) external;

    function upgradeDelay() external view returns (uint256);
    function emergencyDelay() external view returns (uint256);
    function governance() external view returns (address);
    function emergencyCouncil() external view returns (address);
    function proxyAdminOf(address proxy) external view returns (address);
    function implementationAllowed(bytes32 codeHash) external view returns (bool);
    function getOperation(bytes32 id) external view returns (Operation memory);
}
