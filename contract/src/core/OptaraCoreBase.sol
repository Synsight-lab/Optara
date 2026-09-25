// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IOptaraCore} from "../interfaces/IOptaraCore.sol";
import {IOptaraConfig} from "../interfaces/IOptaraConfig.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";
import {
    Series,
    SeriesState,
    Group,
    Position,
    Leg,
    AssetIncident,
    AssetStatus,
    ExposureScope,
    Actions
} from "../libraries/OptaraTypes.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {PayoffMath} from "../libraries/PayoffMath.sol";
import {RiskMath} from "../libraries/RiskMath.sol";

/// @title OptaraCoreBase
/// @notice Storage and internal logic of the merged Optara V2 core: account ledger, stablecoin custody, bounded
/// position indexes, exact risk evaluation, exposure counters and atomic group settlement.
/// @dev The core is immutable. Its only wiring is the one-time, deployer-only SeriesFactory binding.
abstract contract OptaraCoreBase is IOptaraCore, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    string public constant CORE_VERSION = "optara-v2-core/1";
    bytes32 internal constant SERIES_DOMAIN_TAG = keccak256("Optara.V2.SeriesDomain");
    /// @notice Floor for the in-contract shortfall-resolution timelock (LIQUIDATION.md section 102 step 4).
    uint64 public constant MIN_SHORTFALL_RESOLUTION_DELAY = 1 days;

    IOptaraConfig public immutable config;
    IOracleRegistry public immutable oracleRegistry;
    uint64 public immutable shortfallResolutionDelay;
    address public immutable deployer;

    address public seriesFactory;
    bool public isSealed;

    // Series and groups
    mapping(bytes32 => Series) internal _series;
    mapping(bytes32 => SeriesState) internal _seriesState;
    mapping(bytes32 => Group) internal _groups;
    bytes32[] internal _allSeries;
    bytes32[] internal _allGroups;

    // Accounts: native-unit cash per settlement asset, positions, bounded indexes
    mapping(address => mapping(address => uint256)) internal _cash;
    mapping(address => mapping(bytes32 => Position)) internal _positions;
    mapping(address => bytes32[]) internal _accountGroups;
    mapping(address => mapping(bytes32 => uint256)) internal _accountGroupIndex; // 1-based
    mapping(address => mapping(bytes32 => bytes32[])) internal _accountGroupSeries;
    mapping(address => mapping(bytes32 => uint256)) internal _accountSeriesIndex; // 1-based within its group list
    mapping(address => uint256) internal _accountSeriesCount;

    // Wider-scope exposure counters: always the sum of unreleased groups' exposure (INV-CAP-01)
    mapping(bytes32 => uint256) internal _pairExposureN;
    mapping(bytes32 => uint256) internal _oracleExposureN;
    mapping(address => uint256) internal _assetExposureN;

    // Per-asset incident state and monitoring totals
    mapping(address => AssetIncident) internal _incidents;
    mapping(address => uint256) internal _totalCash;
    mapping(address => uint256) internal _totalRecapitalized;
    /// @notice Exact rounding residual per asset, as a numerator over D_A (PROTOCOL_SPEC.md section 27, MATH.md
    ///         section 55): ceil-debit excess, floor-credit shortfall and floored-redemption remainder. Never withdrawable.
    mapping(address => uint256) internal _roundingResidualN;

    constructor(IOptaraConfig config_, IOracleRegistry oracleRegistry_, uint64 shortfallResolutionDelay_) {
        if (address(config_) == address(0) || address(oracleRegistry_) == address(0)) revert ZeroAddress();
        if (shortfallResolutionDelay_ < MIN_SHORTFALL_RESOLUTION_DELAY) revert InvalidDelay();
        config = config_;
        oracleRegistry = oracleRegistry_;
        shortfallResolutionDelay = shortfallResolutionDelay_;
        deployer = msg.sender;
    }

    // ---------------------------------------------------------------------------------------------
    // Identity (PROTOCOL_SPEC.md section 43, OPTION_SPEC.md section 17)
    // ---------------------------------------------------------------------------------------------

    /// @notice Includes chain id, this core, its bound factory and the immutable core version.
    function protocolSeriesDomain() public view returns (bytes32) {
        return keccak256(
            abi.encode(SERIES_DOMAIN_TAG, block.chainid, address(this), seriesFactory, keccak256(bytes(CORE_VERSION)))
        );
    }

    function _pairId(address underlying, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(underlying, asset));
    }

    // ---------------------------------------------------------------------------------------------
    // Access and gating helpers
    // ---------------------------------------------------------------------------------------------

    function _hasRole(bytes32 role) internal view returns (bool) {
        return config.hasRole(role, msg.sender);
    }

    function _onlyGovernance() internal view {
        if (!_hasRole(config.GOVERNANCE_ROLE())) revert NotAuthorized(msg.sender);
    }

    function _requireNotPaused(uint256 action, address asset, bytes32 oracleConfigId) internal view {
        if (config.isPaused(action, asset, oracleConfigId)) revert ActionPaused(action);
    }

    function _requireKnownAsset(address asset) internal view returns (uint8 decimals) {
        bool known;
        (known,, decimals) = config.assetInfo(asset);
        if (!known) revert UnknownAsset(asset);
    }

    function _seriesOf(bytes32 seriesId) internal view returns (Series storage s) {
        s = _series[seriesId];
        if (s.optionToken == address(0)) revert UnknownSeries(seriesId);
    }

    function _requireNotRestricted(address asset) internal view {
        if (_incidents[asset].status == AssetStatus.RESTRICTED) revert AssetIsRestricted(asset);
    }

    // ---------------------------------------------------------------------------------------------
    // Custody
    // ---------------------------------------------------------------------------------------------

    /// @dev Credits only the exact amount received. Non-exact (fee-on-transfer) tokens revert (DD-040).
    function _pullExact(address asset, address from, uint256 amount) internal {
        IERC20 token = IERC20(asset);
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBal;
        if (received != amount) revert NonExactTransfer(amount, received);
    }

    function _pay(address asset, address to, uint256 amount) internal {
        if (amount != 0) IERC20(asset).safeTransfer(to, amount);
    }

    /// @dev After verified-shortfall resolution every external transfer pays floor(rho * amount) (MATH.md section 119).
    function _outflowAmount(address asset, uint256 amount) internal view returns (uint256) {
        AssetIncident storage inc = _incidents[asset];
        if (inc.status == AssetStatus.WIND_DOWN) return FixedPointMath.scaleByRho(amount, inc.rhoWad);
        return amount;
    }

    function _creditCash(address account, address asset, uint256 amount) internal {
        _cash[account][asset] += amount;
        _totalCash[asset] += amount;
    }

    function _debitCash(address account, address asset, uint256 amount) internal {
        _cash[account][asset] -= amount;
        _totalCash[asset] -= amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Bounded account indexes (PROTOCOL_SPEC.md section 28, MATH.md section 22)
    // ---------------------------------------------------------------------------------------------

    /// @dev Adds a series to the account index when it gains its first short or locked unit. Limits apply only to
    ///      NEW index entries, so lowering limits never blocks processing existing positions (INV-POLICY-01).
    function _addToIndex(address account, bytes32 seriesId, bytes32 groupId) internal {
        if (_accountSeriesIndex[account][seriesId] != 0) return;
        (uint32 maxPerGroup, uint32 maxGroups, uint32 maxSeries) = config.positionLimits();
        if (_accountGroupIndex[account][groupId] == 0) {
            if (_accountGroups[account].length >= maxGroups) revert PositionLimitReached();
            _accountGroups[account].push(groupId);
            _accountGroupIndex[account][groupId] = _accountGroups[account].length;
        }
        bytes32[] storage list = _accountGroupSeries[account][groupId];
        if (list.length >= maxPerGroup || _accountSeriesCount[account] >= maxSeries) revert PositionLimitReached();
        list.push(seriesId);
        _accountSeriesIndex[account][seriesId] = list.length;
        _accountSeriesCount[account] += 1;
    }

    /// @dev Removes a series whose short and locked quantities are both zero; removes the group when empty.
    function _removeIfEmpty(address account, bytes32 seriesId, bytes32 groupId) internal {
        Position storage p = _positions[account][seriesId];
        if (p.shortQty != 0 || p.lockedQty != 0) return;
        // A position can only be nonzero after _addToIndex, so a series reaching zero here is always indexed.
        uint256 idx = _accountSeriesIndex[account][seriesId];
        bytes32[] storage list = _accountGroupSeries[account][groupId];
        uint256 last = list.length;
        if (idx != last) {
            bytes32 moved = list[last - 1];
            list[idx - 1] = moved;
            _accountSeriesIndex[account][moved] = idx;
        }
        list.pop();
        delete _accountSeriesIndex[account][seriesId];
        _accountSeriesCount[account] -= 1;
        if (list.length == 0) _removeGroup(account, groupId);
    }

    function _removeGroup(address account, bytes32 groupId) internal {
        // Only called when the group's series list just became empty, so the group is always indexed.
        uint256 idx = _accountGroupIndex[account][groupId];
        bytes32[] storage groups = _accountGroups[account];
        uint256 last = groups.length;
        if (idx != last) {
            bytes32 moved = groups[last - 1];
            groups[idx - 1] = moved;
            _accountGroupIndex[account][moved] = idx;
        }
        groups.pop();
        delete _accountGroupIndex[account][groupId];
    }

    // ---------------------------------------------------------------------------------------------
    // Risk evaluation (MATH.md sections 22-27, 92-93)
    // ---------------------------------------------------------------------------------------------

    function _legsOf(address account, bytes32[] memory ids) internal view returns (Leg[] memory legs) {
        legs = new Leg[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            Series storage s = _series[ids[i]];
            Position storage p = _positions[account][ids[i]];
            legs[i] = Leg(s.optionType, s.strikeWad, s.capWad, s.contractSizeWad, p.shortQty, p.lockedQty);
        }
    }

    function _groupLegs(address account, bytes32 groupId) internal view returns (Leg[] memory) {
        return _legsOf(account, _accountGroupSeries[account][groupId]);
    }

    /// @notice ceilDiv(WorstLossNumerator, D_A) + SafetyBufferNative with the group's snapshotted buffer (MATH.md 25-26).
    function _groupMarginNative(Group storage g, Leg[] memory legs) internal view returns (uint256) {
        uint256 worstN = RiskMath.worstCaseLossNumerator(legs);
        uint256 base = FixedPointMath.ceilDiv(worstN, FixedPointMath.nativeDenominator(g.assetDecimals));
        if (base == 0) return 0;
        return base + FixedPointMath.ceilDiv(base * g.bufferBps, FixedPointMath.BPS) + g.fixedBufferNative;
    }

    /// @notice Sum over the account's active and expired-unfinalized groups settled in `asset`. Finalized groups are
    ///         represented by their settlement delta instead (effective cash), never by worst-case margin.
    function _requiredMargin(address account, address asset) internal view returns (uint256 total) {
        bytes32[] storage groups = _accountGroups[account];
        for (uint256 i = 0; i < groups.length; ++i) {
            Group storage g = _groups[groups[i]];
            if (g.settlementAsset != asset || g.finalized) continue;
            total += _groupMarginNative(g, _groupLegs(account, groups[i]));
        }
    }

    /// @notice Signed native delta the finalized group owes the account: credit floors, debit ceils (MATH.md 54).
    function _settlementDelta(address account, bytes32 groupId)
        internal
        view
        returns (int256 delta, uint256 shortN, uint256 longN)
    {
        Group storage g = _groups[groupId];
        (shortN, longN) = RiskMath.numeratorsAt(_groupLegs(account, groupId), g.settlementPriceWad);
        uint256 d = FixedPointMath.nativeDenominator(g.assetDecimals);
        if (shortN >= longN) delta = -FixedPointMath.ceilDiv(shortN - longN, d).toInt256();
        else delta = FixedPointMath.floorDiv(longN - shortN, d).toInt256();
    }

    /// @notice RawCash + sum of finalized-but-unsynced group deltas (MATH.md section 46, LIQUIDATION.md section 14).
    function _effectiveCash(address account, address asset) internal view returns (int256 effective) {
        effective = _cash[account][asset].toInt256();
        bytes32[] storage groups = _accountGroups[account];
        for (uint256 i = 0; i < groups.length; ++i) {
            Group storage g = _groups[groups[i]];
            if (g.settlementAsset != asset || !g.finalized) continue;
            (int256 delta,,) = _settlementDelta(account, groups[i]);
            effective += delta;
        }
    }

    /// @notice max(RequiredMargin - SafeEffectiveCash, 0) (LIQUIDATION.md section 3.7).
    function _deficit(address account, address asset) internal view returns (uint256) {
        int256 required = _requiredMargin(account, asset).toInt256();
        int256 effective = _effectiveCash(account, asset);
        return effective >= required ? 0 : uint256(required - effective);
    }

    /// @dev Post-state check B >= RequiredMargin. Callers have already synchronized every finalized group of `asset`.
    function _requireMarginSafe(address account, address asset) internal view {
        uint256 required = _requiredMargin(account, asset);
        uint256 available = _cash[account][asset];
        if (available < required) revert InsufficientMargin(required, available);
    }

    /// @dev MATH.md section 24: the account/group sums of C*CS*short and C*CS*locked must each fit int256.
    function _checkNumeratorBounds(address account, bytes32 groupId) internal view {
        RiskMath.maxNumeratorSums(_groupLegs(account, groupId));
    }

    // ---------------------------------------------------------------------------------------------
    // Aggregate exposure (PROTOCOL_SPEC.md section 42)
    // ---------------------------------------------------------------------------------------------

    function _increaseExposure(bytes32 seriesId, Series storage s, Group storage g, uint256 e) internal {
        (uint256 seriesL, uint256 pairL, uint256 oracleL, uint256 assetL) =
            config.exposureLimits(s.pairId, s.oracleConfigId, s.settlementAsset);
        SeriesState storage st = _seriesState[seriesId];
        uint256 v = st.exposureN + e;
        if (v > seriesL) revert ExposureLimitExceeded(ExposureScope.SERIES, v, seriesL);
        st.exposureN = v;
        v = _pairExposureN[s.pairId] + e;
        if (v > pairL) revert ExposureLimitExceeded(ExposureScope.PAIR, v, pairL);
        _pairExposureN[s.pairId] = v;
        v = _oracleExposureN[s.oracleConfigId] + e;
        if (v > oracleL) revert ExposureLimitExceeded(ExposureScope.ORACLE_CONFIG, v, oracleL);
        _oracleExposureN[s.oracleConfigId] = v;
        v = _assetExposureN[s.settlementAsset] + e;
        if (v > assetL) revert ExposureLimitExceeded(ExposureScope.ASSET, v, assetL);
        _assetExposureN[s.settlementAsset] = v;
        g.exposureN += e;
    }

    /// @dev Burns release exposure exactly once: every scope before finalization, only series/group afterwards,
    ///      because finalization already released the group from pair/oracle/asset scopes in O(1).
    function _decreaseExposure(bytes32 seriesId, Series storage s, Group storage g, uint256 e) internal {
        _seriesState[seriesId].exposureN -= e;
        g.exposureN -= e;
        if (!g.released) {
            _pairExposureN[s.pairId] -= e;
            _oracleExposureN[s.oracleConfigId] -= e;
            _assetExposureN[s.settlementAsset] -= e;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Atomic account/group settlement (PROTOCOL_SPEC.md section 22, MATH.md section 97)
    // ---------------------------------------------------------------------------------------------

    /// @dev Synchronizes every finalized group of `asset` in the account's complete canonical index. Callers never
    ///      supply a partial list (DD-078).
    function _syncAllFinalized(address account, address asset) internal returns (uint256 count) {
        bytes32[] memory groups = _accountGroups[account];
        for (uint256 i = 0; i < groups.length; ++i) {
            Group storage g = _groups[groups[i]];
            if (g.finalized && g.settlementAsset == asset) {
                if (_syncGroup(account, groups[i], g)) ++count;
            }
        }
    }

    /// @dev Nets every short and locked-long numerator of the complete account group, applies ONE native delta,
    ///      burns consumed hedges, clears positions and indexes. A debit above cash reverts: that is an invariant
    ///      failure handled by separate containment (LIQUIDATION.md sections 45, 101), never a partial settlement.
    function _syncGroup(address account, bytes32 groupId, Group storage g) internal returns (bool) {
        bytes32[] memory ids = _accountGroupSeries[account][groupId];
        if (ids.length == 0) return false;
        _requireNotPaused(Actions.SYNC, g.settlementAsset, g.oracleConfigId);

        (int256 delta, uint256 shortN, uint256 longN) = _settlementDelta(account, groupId);
        address asset = g.settlementAsset;
        uint256 d = FixedPointMath.nativeDenominator(g.assetDecimals);
        if (delta < 0) {
            uint256 debit = uint256(-delta);
            uint256 cash = _cash[account][asset];
            if (debit > cash) revert SettlementDeficit(account, groupId, cash, debit);
            _debitCash(account, asset, debit);
            _roundingResidualN[asset] += debit * d - (shortN - longN);
        } else {
            if (delta > 0) _creditCash(account, asset, uint256(delta));
            // delta == 0 with shortN > longN cannot happen (ceil of a positive value is >= 1)
            if (longN > shortN) _roundingResidualN[asset] += (longN - shortN) - uint256(delta) * d;
        }

        for (uint256 i = 0; i < ids.length; ++i) {
            _consumeSettledPosition(account, ids[i], g);
        }
        _accountSeriesCount[account] -= ids.length;
        delete _accountGroupSeries[account][groupId];
        _removeGroup(account, groupId);

        emit RiskGroupSynced(account, groupId, asset, shortN, longN, delta, msg.sender);
        return true;
    }

    /// @dev Burns a settled locked hedge (releasing its series/group exposure), clears the short, and drops the
    ///      series from the account index. Group-level bookkeeping is done by the caller.
    function _consumeSettledPosition(address account, bytes32 id, Group storage g) internal {
        Position storage p = _positions[account][id];
        SeriesState storage st = _seriesState[id];
        Series storage s = _series[id];
        uint256 locked = p.lockedQty;
        if (locked != 0) {
            IOptionToken(s.optionToken).burn(address(this), locked);
            st.hedgeConsumed += locked;
            _decreaseExposure(id, s, g, PayoffMath.product(s.capWad, s.contractSizeWad, locked));
        }
        uint256 shortQty = p.shortQty;
        if (shortQty != 0) {
            st.openShortQty -= shortQty;
            st.shortSynced += shortQty;
        }
        delete _positions[account][id];
        delete _accountSeriesIndex[account][id];
    }
}
