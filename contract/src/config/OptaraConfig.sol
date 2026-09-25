// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOptaraConfig} from "../interfaces/IOptaraConfig.sol";
import {PairStatus, ExposureScope, SeriesBounds, Actions} from "../libraries/OptaraTypes.sol";
import {PayoffMath} from "../libraries/PayoffMath.sol";

/// @title OptaraConfig
/// @notice Roles, prospective approvals, bounds, limits and scoped pauses (ACCESS_CONTROL.md sections 23-37, 47-54).
/// @dev GOVERNANCE_ROLE is expected to be held by a TimelockController in production (DEPLOYMENT.md sections 26, 29),
///      so every governance-only setter below is timelocked. PAUSER_ROLE can only reduce what is allowed.
///      Changes are prospective: existing series terms, finalized prices and snapshotted group buffers live in the
///      core and are never read back from here.
contract OptaraConfig is AccessControlEnumerable, IOptaraConfig {
    bytes32 public constant override GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant override CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant override SERIES_CREATOR_ROLE = keccak256("SERIES_CREATOR_ROLE");
    bytes32 public constant override ORACLE_CONFIG_ROLE = keccak256("ORACLE_CONFIG_ROLE");
    bytes32 public constant override PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant override UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    /// @notice Gas-safety hard caps; governance can set lower values only (PROTOCOL_SPEC.md section 28).
    uint32 public constant HARD_MAX_SERIES_PER_GROUP = 16;
    uint32 public constant HARD_MAX_GROUPS_PER_ACCOUNT = 16;
    uint32 public constant HARD_MAX_SERIES_PER_ACCOUNT = 64;

    /// @notice Upper bound for strike, cap and strike + cap, so every price comparison and K + C stays exact.
    uint256 public constant MAX_PRICE_WAD = type(uint128).max;
    uint16 public constant MAX_BUFFER_BPS = 10_000;
    bytes32 public constant GLOBAL_SCOPE = bytes32(0);

    struct AssetConfig {
        bool known;
        bool newRiskEnabled;
        uint8 decimals;
        uint16 bufferBps;
        uint256 fixedBufferNative;
        uint256 exposureLimitN;
        string symbol;
    }

    struct UnderlyingConfig {
        bool approved;
        bool known;
        string symbol;
    }

    struct PairConfig {
        PairStatus status;
        address underlying;
        address asset;
        uint256 seriesExposureLimitN;
        uint256 pairExposureLimitN;
        SeriesBounds bounds;
    }

    error ZeroAddress();
    error NotAuthorized(address caller);
    error AssetAlreadyKnown(address asset);
    error UnknownAsset(address asset);
    error UnsupportedDecimals(uint8 decimals);
    error UnderlyingNotApproved(address underlying);
    error UnderlyingEqualsAsset();
    error PairAlreadyApproved(bytes32 pairId);
    error UnknownPair(bytes32 pairId);
    error InvalidPairTransition(PairStatus from, PairStatus to);
    error InvalidBounds();
    error InvalidLimit();
    error InvalidBuffer();
    error InvalidPauseBits();
    error LastGovernanceMember();
    error EmptySymbol();

    mapping(address => AssetConfig) internal _assets;
    mapping(address => UnderlyingConfig) internal _underlyings;
    mapping(bytes32 => PairConfig) internal _pairs;
    mapping(bytes32 => uint256) internal _oracleExposureLimitN;
    mapping(bytes32 => uint256) internal _pausedBits;

    uint32 internal _maxSeriesPerGroup;
    uint32 internal _maxGroupsPerAccount;
    uint32 internal _maxSeriesPerAccount;

    constructor(address governance) {
        if (governance == address(0)) revert ZeroAddress();
        _setRoleAdmin(GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(CONFIG_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(SERIES_CREATOR_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(ORACLE_CONFIG_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(PAUSER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(UNPAUSER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(DEFAULT_ADMIN_ROLE, GOVERNANCE_ROLE);
        _grantRole(GOVERNANCE_ROLE, governance);
    }

    // ---------------------------------------------------------------------------------------------
    // Authorization helpers
    // ---------------------------------------------------------------------------------------------

    function _onlyGovernance() internal view {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized(msg.sender);
    }

    function _isGovernanceOr(bytes32 role) internal view returns (bool) {
        return hasRole(GOVERNANCE_ROLE, msg.sender) || hasRole(role, msg.sender);
    }

    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IAccessControl, IOptaraConfig)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /// @dev Keeps at least one governance member so administration can never become impossible
    ///      (ACCESS_CONTROL.md section 50).
    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        if (role == GOVERNANCE_ROLE && hasRole(role, account) && getRoleMemberCount(role) == 1) {
            revert LastGovernanceMember();
        }
        return super._revokeRole(role, account);
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement assets
    // ---------------------------------------------------------------------------------------------

    /// @notice Approve a settlement stablecoin by exact address (DEPLOYMENT.md section 33). Decimals are read once
    ///         and never change. Buffer defaults apply only to risk groups created afterward (MATH.md section 25).
    function approveAsset(address asset, string calldata symbol, uint16 bufferBps, uint256 fixedBufferNative) external {
        _onlyGovernance();
        if (asset == address(0) || asset.code.length == 0) revert ZeroAddress();
        if (_assets[asset].known) revert AssetAlreadyKnown(asset);
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (bufferBps > MAX_BUFFER_BPS) revert InvalidBuffer();
        uint8 decimals = IERC20Metadata(asset).decimals();
        if (decimals > 18) revert UnsupportedDecimals(decimals);
        AssetConfig storage a = _assets[asset];
        a.known = true;
        a.newRiskEnabled = true;
        a.decimals = decimals;
        a.bufferBps = bufferBps;
        a.fixedBufferNative = fixedBufferNative;
        a.symbol = symbol;
        emit AssetApproved(asset, decimals, symbol);
        emit BufferDefaultsChanged(asset, bufferBps, fixedBufferNative);
    }

    /// @notice Disabling new risk is immediate (pauser); re-enabling is governance-only.
    function setAssetNewRiskEnabled(address asset, bool enabled) external {
        AssetConfig storage a = _assets[asset];
        if (!a.known) revert UnknownAsset(asset);
        if (enabled) {
            if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized(msg.sender);
            a.newRiskEnabled = true;
            emit AssetReenabled(asset, msg.sender);
        } else {
            if (!_isGovernanceOr(PAUSER_ROLE)) revert NotAuthorized(msg.sender);
            a.newRiskEnabled = false;
            emit AssetDisabled(asset, msg.sender);
        }
    }

    /// @notice Prospective buffer defaults for groups created afterward. Existing groups keep their snapshot.
    function setAssetBufferDefaults(address asset, uint16 bufferBps, uint256 fixedBufferNative) external {
        _onlyGovernance();
        AssetConfig storage a = _assets[asset];
        if (!a.known) revert UnknownAsset(asset);
        if (bufferBps > MAX_BUFFER_BPS) revert InvalidBuffer();
        a.bufferBps = bufferBps;
        a.fixedBufferNative = fixedBufferNative;
        emit BufferDefaultsChanged(asset, bufferBps, fixedBufferNative);
    }

    // ---------------------------------------------------------------------------------------------
    // Underlyings and pairs
    // ---------------------------------------------------------------------------------------------

    /// @notice Approve an underlying identifier. `symbol` is display metadata only (OPTION_SPEC.md section 20).
    function approveUnderlying(address underlying, string calldata symbol) external {
        _onlyGovernance();
        if (underlying == address(0)) revert ZeroAddress();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        UnderlyingConfig storage u = _underlyings[underlying];
        u.approved = true;
        u.known = true;
        if (bytes(u.symbol).length == 0) u.symbol = symbol;
        emit UnderlyingApproved(underlying, u.symbol);
    }

    /// @notice Stop new series for an underlying (pauser or governance); re-approval is governance-only.
    function setUnderlyingApproved(address underlying, bool approved) external {
        UnderlyingConfig storage u = _underlyings[underlying];
        if (!u.known) revert UnderlyingNotApproved(underlying);
        if (approved) {
            if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized(msg.sender);
        } else if (!_isGovernanceOr(PAUSER_ROLE)) {
            revert NotAuthorized(msg.sender);
        }
        u.approved = approved;
        emit UnderlyingStatusChanged(underlying, approved, msg.sender);
    }

    /// @notice Approve UNDERLYING / ASSET with its series bounds and initial exposure caps (STATE_MACHINE.md section 11).
    function approvePair(
        address underlying,
        address asset,
        SeriesBounds calldata bounds,
        uint256 seriesExposureLimitN,
        uint256 pairExposureLimitN
    ) external returns (bytes32 pairId) {
        _onlyGovernance();
        if (!_underlyings[underlying].approved) revert UnderlyingNotApproved(underlying);
        if (!_assets[asset].known) revert UnknownAsset(asset);
        if (underlying == asset) revert UnderlyingEqualsAsset();
        pairId = pairIdOf(underlying, asset);
        PairConfig storage p = _pairs[pairId];
        if (p.status != PairStatus.UNAPPROVED) revert PairAlreadyApproved(pairId);
        _validateBounds(bounds);
        _validateLimit(seriesExposureLimitN);
        _validateLimit(pairExposureLimitN);
        p.status = PairStatus.ENABLED;
        p.underlying = underlying;
        p.asset = asset;
        p.bounds = bounds;
        p.seriesExposureLimitN = seriesExposureLimitN;
        p.pairExposureLimitN = pairExposureLimitN;
        emit PairApproved(pairId, underlying, asset);
        emit SeriesBoundsChanged(pairId, bounds);
        emit ExposureLimitChanged(ExposureScope.SERIES, pairId, 0, seriesExposureLimitN);
        emit ExposureLimitChanged(ExposureScope.PAIR, pairId, 0, pairExposureLimitN);
    }

    /// @notice ENABLED <-> NEW_RISK_DISABLED, or -> RETIRED (terminal). Existing series are never affected.
    function setPairStatus(bytes32 pairId, PairStatus newStatus) external {
        PairConfig storage p = _pairs[pairId];
        PairStatus current = p.status;
        if (current == PairStatus.UNAPPROVED) revert UnknownPair(pairId);
        if (current == PairStatus.RETIRED || newStatus == current || newStatus == PairStatus.UNAPPROVED) {
            revert InvalidPairTransition(current, newStatus);
        }
        if (newStatus == PairStatus.RETIRED) {
            if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized(msg.sender);
        } else if (newStatus == PairStatus.NEW_RISK_DISABLED) {
            if (!(_isGovernanceOr(PAUSER_ROLE) || hasRole(CONFIG_ROLE, msg.sender))) revert NotAuthorized(msg.sender);
        } else if (!_isGovernanceOr(CONFIG_ROLE)) {
            // re-enable: governance or config role after governance approval
            revert NotAuthorized(msg.sender);
        }
        p.status = newStatus;
        if (newStatus == PairStatus.ENABLED) emit PairEnabled(pairId, msg.sender);
        else emit PairDisabled(pairId, newStatus, msg.sender);
    }

    /// @notice Prospective series parameter bounds (CONFIG_ROLE or governance).
    function setSeriesBounds(bytes32 pairId, SeriesBounds calldata bounds) external {
        if (!_isGovernanceOr(CONFIG_ROLE)) revert NotAuthorized(msg.sender);
        PairConfig storage p = _pairs[pairId];
        if (p.status == PairStatus.UNAPPROVED) revert UnknownPair(pairId);
        _validateBounds(bounds);
        p.bounds = bounds;
        emit SeriesBoundsChanged(pairId, bounds);
    }

    function _validateBounds(SeriesBounds calldata b) internal pure {
        if (b.minStrikeWad == 0 || b.minCapWad == 0 || b.minContractSizeWad == 0) revert InvalidBounds();
        if (b.minStrikeWad > b.maxStrikeWad || b.minCapWad > b.maxCapWad) revert InvalidBounds();
        if (b.minContractSizeWad > b.maxContractSizeWad) revert InvalidBounds();
        if (b.maxStrikeWad > MAX_PRICE_WAD || b.maxCapWad > MAX_PRICE_WAD) revert InvalidBounds();
        if (b.maxStrikeWad + b.maxCapWad > MAX_PRICE_WAD) revert InvalidBounds();
        if (b.maxContractSizeWad > MAX_PRICE_WAD) revert InvalidBounds();
        if (b.maxTimeToExpiry == 0 || b.minTimeToExpiry > b.maxTimeToExpiry) revert InvalidBounds();
        if (b.quantityIncrement == 0) revert InvalidBounds();
    }

    // ---------------------------------------------------------------------------------------------
    // Aggregate exposure caps (PROTOCOL_SPEC.md section 42)
    // ---------------------------------------------------------------------------------------------

    /// @notice Raising a cap is governance-only (timelocked); lowering is allowed to the guardian as well.
    ///         A cap below current exposure only blocks new writes; it never forces burns or blocks exits.
    /// @param key pairId for SERIES and PAIR, oracleConfigId for ORACLE_CONFIG, bytes32(uint160(asset)) for ASSET.
    function setExposureLimit(ExposureScope scope, bytes32 key, uint256 newLimitN) external {
        _validateLimit(newLimitN);
        uint256 oldLimitN;
        if (scope == ExposureScope.SERIES || scope == ExposureScope.PAIR) {
            PairConfig storage p = _pairs[key];
            if (p.status == PairStatus.UNAPPROVED) revert UnknownPair(key);
            oldLimitN = scope == ExposureScope.SERIES ? p.seriesExposureLimitN : p.pairExposureLimitN;
            _authorizeLimitChange(oldLimitN, newLimitN);
            if (scope == ExposureScope.SERIES) p.seriesExposureLimitN = newLimitN;
            else p.pairExposureLimitN = newLimitN;
        } else if (scope == ExposureScope.ORACLE_CONFIG) {
            oldLimitN = _oracleExposureLimitN[key];
            _authorizeLimitChange(oldLimitN, newLimitN);
            _oracleExposureLimitN[key] = newLimitN;
        } else {
            address asset = address(uint160(uint256(key)));
            AssetConfig storage a = _assets[asset];
            if (!a.known || bytes32(uint256(uint160(asset))) != key) revert UnknownAsset(asset);
            oldLimitN = a.exposureLimitN;
            _authorizeLimitChange(oldLimitN, newLimitN);
            a.exposureLimitN = newLimitN;
        }
        emit ExposureLimitChanged(scope, key, oldLimitN, newLimitN);
    }

    function _authorizeLimitChange(uint256 oldLimitN, uint256 newLimitN) internal view {
        if (newLimitN > oldLimitN) {
            if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized(msg.sender);
        } else if (!_isGovernanceOr(PAUSER_ROLE)) {
            revert NotAuthorized(msg.sender);
        }
    }

    function _validateLimit(uint256 limitN) internal pure {
        if (limitN > PayoffMath.MAX_NUMERATOR) revert InvalidLimit();
    }

    // ---------------------------------------------------------------------------------------------
    // Per-account position-count limits (gas controls, not economic caps)
    // ---------------------------------------------------------------------------------------------

    /// @notice Lower limits never block processing of existing positions; they only stop new index entries
    ///         (MARGIN_AND_RISK.md section 120, INV-POLICY-01).
    function setPositionLimits(uint32 maxSeriesPerGroup, uint32 maxGroupsPerAccount, uint32 maxSeriesPerAccount)
        external
    {
        _onlyGovernance();
        if (
            maxSeriesPerGroup == 0 || maxSeriesPerGroup > HARD_MAX_SERIES_PER_GROUP || maxGroupsPerAccount == 0
                || maxGroupsPerAccount > HARD_MAX_GROUPS_PER_ACCOUNT || maxSeriesPerAccount == 0
                || maxSeriesPerAccount > HARD_MAX_SERIES_PER_ACCOUNT
        ) revert InvalidLimit();
        _maxSeriesPerGroup = maxSeriesPerGroup;
        _maxGroupsPerAccount = maxGroupsPerAccount;
        _maxSeriesPerAccount = maxSeriesPerAccount;
        emit PositionLimitsChanged(maxSeriesPerGroup, maxGroupsPerAccount, maxSeriesPerAccount);
    }

    // ---------------------------------------------------------------------------------------------
    // Scoped pauses
    // ---------------------------------------------------------------------------------------------

    /// @notice Pause action bits in a scope: GLOBAL_SCOPE, assetScope(asset) or an oracleConfigId.
    function pause(bytes32 scope, uint256 bits) external {
        if (!_isGovernanceOr(PAUSER_ROLE)) revert NotAuthorized(msg.sender);
        if (bits == 0 || bits & ~Actions.ALL != 0) revert InvalidPauseBits();
        uint256 oldBits = _pausedBits[scope];
        uint256 newBits = oldBits | bits;
        _pausedBits[scope] = newBits;
        emit PauseStateChanged(scope, oldBits, newBits, msg.sender);
    }

    /// @notice Unpausing is governance or a dedicated UNPAUSER_ROLE, never the pauser (ACCESS_CONTROL.md section 36).
    function unpause(bytes32 scope, uint256 bits) external {
        if (!_isGovernanceOr(UNPAUSER_ROLE)) revert NotAuthorized(msg.sender);
        if (bits == 0 || bits & ~Actions.ALL != 0) revert InvalidPauseBits();
        uint256 oldBits = _pausedBits[scope];
        uint256 newBits = oldBits & ~bits;
        _pausedBits[scope] = newBits;
        emit PauseStateChanged(scope, oldBits, newBits, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function assetScope(address asset) public pure returns (bytes32) {
        return bytes32(uint256(uint160(asset)));
    }

    function pausedBits(bytes32 scope) external view returns (uint256) {
        return _pausedBits[scope];
    }

    function isPaused(uint256 action, address asset, bytes32 oracleConfigId) external view returns (bool) {
        uint256 bits = _pausedBits[GLOBAL_SCOPE];
        if (asset != address(0)) bits |= _pausedBits[assetScope(asset)];
        if (oracleConfigId != bytes32(0)) bits |= _pausedBits[oracleConfigId];
        return bits & action != 0;
    }

    function assetInfo(address asset) external view returns (bool known, bool newRiskEnabled, uint8 decimals) {
        AssetConfig storage a = _assets[asset];
        return (a.known, a.newRiskEnabled, a.decimals);
    }

    function assetSymbol(address asset) external view returns (string memory) {
        return _assets[asset].symbol;
    }

    function bufferDefaults(address asset) external view returns (uint16 bufferBps, uint256 fixedBufferNative) {
        AssetConfig storage a = _assets[asset];
        return (a.bufferBps, a.fixedBufferNative);
    }

    function underlyingInfo(address underlying) external view returns (bool approved, string memory symbol) {
        UnderlyingConfig storage u = _underlyings[underlying];
        return (u.approved, u.symbol);
    }

    function pairInfo(bytes32 pairId) external view returns (PairStatus status, address underlying, address asset) {
        PairConfig storage p = _pairs[pairId];
        return (p.status, p.underlying, p.asset);
    }

    function seriesBounds(bytes32 pairId) external view returns (SeriesBounds memory) {
        return _pairs[pairId].bounds;
    }

    function exposureLimits(bytes32 pairId, bytes32 oracleConfigId, address asset)
        external
        view
        returns (uint256 seriesLimitN, uint256 pairLimitN, uint256 oracleLimitN, uint256 assetLimitN)
    {
        PairConfig storage p = _pairs[pairId];
        return (
            p.seriesExposureLimitN,
            p.pairExposureLimitN,
            _oracleExposureLimitN[oracleConfigId],
            _assets[asset].exposureLimitN
        );
    }

    function positionLimits()
        external
        view
        returns (uint32 maxSeriesPerGroup, uint32 maxGroupsPerAccount, uint32 maxSeriesPerAccount)
    {
        return (_maxSeriesPerGroup, _maxGroupsPerAccount, _maxSeriesPerAccount);
    }

    function pairIdOf(address underlying, address asset) public pure returns (bytes32) {
        return keccak256(abi.encode(underlying, asset));
    }
}
