// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IOptaraConfig} from "../interfaces/IOptaraConfig.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {OracleConfig, OracleConfigStatus} from "../libraries/OptaraTypes.sol";

/// @title OracleRegistry
/// @notice Immutable settlement configurations (ORACLE_AND_SETTLEMENT.md sections 6-7, 15-19, 70, 119).
/// A registered config's adapter, sources, offsets and delays can never change. Only its status for NEW series
/// changes; existing groups stay bound to the exact config they were created with (STATE_MACHINE.md section 17).
contract OracleRegistry is IOracleRegistry {
    /// @notice Bound on |offset| and on maxFinalizationDelay so every timestamp computation stays small and exact.
    uint64 public constant MAX_OFFSET = 365 days;
    uint64 public constant MAX_FINALIZATION_DELAY = 365 days;

    IOptaraConfig public immutable config;

    mapping(bytes32 => OracleConfig) internal _configs;
    mapping(bytes32 => OracleConfigStatus) internal _status;

    error NotAuthorized(address caller);
    error InvalidConfig(string reason);
    error ConfigAlreadyRegistered(bytes32 configId);
    error UnknownConfig(bytes32 configId);
    error InvalidStatusTransition(OracleConfigStatus from, OracleConfigStatus to);
    error InvalidObservationTime();

    constructor(IOptaraConfig config_) {
        if (address(config_) == address(0)) revert InvalidConfig("config");
        config = config_;
    }

    function _isGovernanceOr(bytes32 role) internal view returns (bool) {
        return config.hasRole(config.GOVERNANCE_ROLE(), msg.sender) || config.hasRole(role, msg.sender);
    }

    /// @notice Register an immutable config. Launch readiness (section 119) is enforced here: an implemented adapter
    ///         that validates its sources, a unique observation rule with a nonempty ordered window, a finite escalation
    ///         deadline, and earliest finalization strictly after observation end.
    function registerConfig(OracleConfig calldata cfg) external returns (bytes32 configId) {
        if (!_isGovernanceOr(config.ORACLE_CONFIG_ROLE())) revert NotAuthorized(msg.sender);
        if (cfg.underlying == address(0) || cfg.settlementAsset == address(0)) revert InvalidConfig("zero asset");
        if (cfg.underlying == cfg.settlementAsset) revert InvalidConfig("underlying == asset");
        if (cfg.adapter.code.length == 0) revert InvalidConfig("adapter");
        if (_abs(cfg.observationStartOffset) > MAX_OFFSET || _abs(cfg.observationEndOffset) > MAX_OFFSET) {
            revert InvalidConfig("offset bound");
        }
        if (cfg.observationStartOffset > cfg.observationEndOffset) revert InvalidConfig("inverted window");
        if (cfg.maxFinalizationDelay == 0 || cfg.maxFinalizationDelay > MAX_FINALIZATION_DELAY) {
            revert InvalidConfig("maxFinalizationDelay");
        }
        if (cfg.minFinalizationDelay > cfg.maxFinalizationDelay) revert InvalidConfig("min > max delay");
        // earliest finalization (expiry + minDelay) must be strictly after observation end (expiry + endOffset)
        if (int256(uint256(cfg.minFinalizationDelay)) <= int256(cfg.observationEndOffset)) {
            revert InvalidConfig("finalization before observation end");
        }
        if (cfg.ruleVersion == bytes32(0)) revert InvalidConfig("ruleVersion");
        ISettlementOracle(cfg.adapter).validateConfig(cfg);

        configId = keccak256(abi.encode(block.chainid, address(this), cfg));
        if (_status[configId] != OracleConfigStatus.NONE) revert ConfigAlreadyRegistered(configId);
        _configs[configId] = cfg;
        _status[configId] = OracleConfigStatus.APPROVED_FOR_NEW_SERIES;
        emit OracleConfigApproved(configId, cfg.underlying, cfg.settlementAsset, cfg.adapter);
        emit OracleConfigStatusChanged(
            configId, OracleConfigStatus.NONE, OracleConfigStatus.APPROVED_FOR_NEW_SERIES, msg.sender
        );
    }

    /// @notice Suspend (oracle-config role, governance, or guardian), re-approve (oracle-config role or governance)
    ///         or retire (governance, terminal). Affects new series and new writes only.
    function setStatus(bytes32 configId, OracleConfigStatus newStatus) external {
        OracleConfigStatus current = _status[configId];
        if (current == OracleConfigStatus.NONE) revert UnknownConfig(configId);
        if (current == OracleConfigStatus.RETIRED || newStatus == current || newStatus == OracleConfigStatus.NONE) {
            revert InvalidStatusTransition(current, newStatus);
        }
        if (newStatus == OracleConfigStatus.RETIRED) {
            if (!config.hasRole(config.GOVERNANCE_ROLE(), msg.sender)) revert NotAuthorized(msg.sender);
        } else if (newStatus == OracleConfigStatus.SUSPENDED_FOR_NEW_SERIES) {
            if (!(_isGovernanceOr(config.ORACLE_CONFIG_ROLE()) || config.hasRole(config.PAUSER_ROLE(), msg.sender))) {
                revert NotAuthorized(msg.sender);
            }
        } else if (!_isGovernanceOr(config.ORACLE_CONFIG_ROLE())) {
            revert NotAuthorized(msg.sender);
        }
        _status[configId] = newStatus;
        if (newStatus != OracleConfigStatus.APPROVED_FOR_NEW_SERIES) {
            emit OracleConfigDisabled(configId, newStatus, msg.sender);
        }
        emit OracleConfigStatusChanged(configId, current, newStatus, msg.sender);
    }

    function getConfig(bytes32 configId) external view returns (OracleConfig memory) {
        if (_status[configId] == OracleConfigStatus.NONE) revert UnknownConfig(configId);
        return _configs[configId];
    }

    function statusOf(bytes32 configId) external view returns (OracleConfigStatus) {
        return _status[configId];
    }

    function isApprovedForNewRisk(bytes32 configId) external view returns (bool) {
        return _status[configId] == OracleConfigStatus.APPROVED_FOR_NEW_SERIES;
    }

    function adapterOf(bytes32 configId) external view returns (address) {
        if (_status[configId] == OracleConfigStatus.NONE) revert UnknownConfig(configId);
        return _configs[configId].adapter;
    }

    function finalizationDelays(bytes32 configId) external view returns (uint64 minDelay, uint64 maxDelay) {
        if (_status[configId] == OracleConfigStatus.NONE) revert UnknownConfig(configId);
        OracleConfig storage c = _configs[configId];
        return (c.minFinalizationDelay, c.maxFinalizationDelay);
    }

    /// @notice [expiry + startOffset, expiry + endOffset] in checked signed wide arithmetic (section 119).
    function observationWindow(bytes32 configId, uint64 expiry) public view returns (uint64 start, uint64 end) {
        if (_status[configId] == OracleConfigStatus.NONE) revert UnknownConfig(configId);
        OracleConfig storage c = _configs[configId];
        start = _offsetTime(expiry, c.observationStartOffset);
        end = _offsetTime(expiry, c.observationEndOffset);
    }

    /// @notice Reverts unless every expiry-relative timestamp for this config is representable and nonnegative.
    function validateSeriesExpiry(bytes32 configId, uint64 expiry) external view {
        observationWindow(configId, expiry);
        OracleConfig storage c = _configs[configId];
        if (uint256(expiry) + uint256(c.maxFinalizationDelay) > type(uint64).max) revert InvalidObservationTime();
    }

    function _offsetTime(uint64 expiry, int64 offset) internal pure returns (uint64) {
        int256 t = int256(uint256(expiry)) + int256(offset);
        if (t < 0 || t > int256(uint256(type(uint64).max))) revert InvalidObservationTime();
        return uint64(uint256(t));
    }

    function _abs(int64 x) internal pure returns (uint64) {
        return x < 0 ? uint64(uint256(-int256(x))) : uint64(x);
    }
}
