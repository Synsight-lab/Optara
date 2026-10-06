// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {FixedPoint} from "./FixedPoint.sol";
import {OptionPricer} from "./OptionPricer.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IPortfolioRiskManager} from "../interfaces/IPortfolioRiskManager.sol";
import {IRiskSets, ISettlementState, IReserveStatus} from "../interfaces/IExternalDependencies.sol";
import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {ILiveSpotOracle} from "../interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../interfaces/IVolSurfaceOracle.sol";
import {OptionType, LedgerSeries, Position, SeriesTerms} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    StaleSpot,
    StaleSurface,
    MissingSurfaceNode,
    SeriesNotPriceable,
    SeriesNotActive,
    NotHealthy,
    ProductCloseOnly,
    OpenInterestCap,
    InvalidRiskParams,
    UnknownRiskSet,
    RiskSetExists,
    RiskSetAlreadyAssigned,
    LengthMismatch
} from "../libraries/Errors.sol";

/// @title PortfolioRiskManager
/// @notice Portfolio margin (docs/MATH.md §5–§9, MARGIN_AND_RISK.md).
///         - Equity = cash + mark value of every leg (Black-76; intrinsic once expired; exact payoff once finalized).
///         - Per risk bucket (one product): loss = worst drop of the bucket's value over the stress scenarios.
///         - IM = Σ loss over initialSet ∪ maintenanceSet + imBufferBps × mark of all shorts; MM = Σ loss over
///           maintenanceSet. Buckets never offset each other.
///         - Every series of a product uses the product's one risk set, so a bucket has one scenario set.
/// @dev Three modes: STRICT (risk-increasing actions: fresh spot and FRESH surface for every product held),
///      LIQUIDATION (fresh spot; surface FRESH or STALE with direction-aware penalties), VIEW (never reverts on
///      staleness; reports `fresh`). Values are WAD; rounding follows MATH.md §2 (position values toward −∞).
contract PortfolioRiskManager is OptaraModule, IPortfolioRiskManager {
    using SafeCastLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_SCENARIOS = 24;
    uint256 public constant MAX_OPEN_INTEREST = 1e24;
    uint16 public constant MAX_IM_BUFFER_BPS = 5000;
    uint256 public constant MAX_IV = 10e18;

    // InvalidRiskParams reasons
    uint8 internal constant RP_BUFFER = 1;
    uint8 internal constant RP_IV = 2;
    uint8 internal constant RP_FLOOR = 3;
    uint8 internal constant RP_OPEN_INTEREST = 4;
    uint8 internal constant RP_SCENARIO_COUNT = 5;
    uint8 internal constant RP_SCENARIO_VALUE = 6;
    uint8 internal constant RP_DIRECTION = 7;
    uint8 internal constant RP_PRODUCT = 8;

    enum Mode {
        STRICT,
        LIQUIDATION,
        VIEW
    }

    struct RiskSet {
        bool exists;
        bool enabled;
        uint16 imBufferBps;
        uint32 nearExpiryFloorSeconds;
        uint256 minIv;
        uint256 maxIv;
        uint256 maxOpenInterestPerSeries;
        Scenario[] initialSet;
        Scenario[] maintenanceSet;
    }

    struct ProductRisk {
        bytes32 riskSetId; // write-once
        address settlementAsset;
        uint256 maxShortUnderlyingWad;
    }

    /// @custom:storage-location erc7201:optara.storage.PortfolioRiskManager
    struct RiskStorage {
        ISubAccounts ledger;
        IOptionSeriesRegistry registry;
        ILiveSpotOracle spot;
        IVolSurfaceOracle surface;
        ISettlementState settlement;
        IReserveStatus reserves;
        mapping(bytes32 id => RiskSet) riskSets;
        mapping(bytes32 productId => ProductRisk) products;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.PortfolioRiskManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x56fda77de9c393009338eb8e180cc765886087ad611b20968d83f77d78c18000;

    // ---- computation structs (memory) ----

    struct Leg {
        int256 q;
        bool isCall;
        bool intrinsicOnly; // long leg on a surface older than maxLongTimeValueStale
        uint256 strike;
        uint256 cs;
        uint256 t; // WAD years; 0 once expired
        uint256 sigma; // σ_short for shorts, σ_long for longs
    }

    struct Bucket {
        bytes32 productId;
        uint256 spot;
        bool fresh;
        int256 value; // mark value of all legs incl. finalized
        uint256 lossIm;
        uint256 lossMm;
        uint256 buffer;
        bool hasActive;
    }

    struct Result {
        Risk risk;
        bool hasActive;
    }

    /// @dev Hypothetical balance changes (one entry per series; repeated ids add up) and a cash change.
    struct Delta {
        bytes32[] seriesIds;
        int256[] qtys;
        int256 cashNative;
    }

    function initialize(
        IProtocolControl control_,
        ISubAccounts ledger_,
        IOptionSeriesRegistry registry_,
        ILiveSpotOracle spot_,
        IVolSurfaceOracle surface_,
        ISettlementState settlement_,
        IReserveStatus reserves_
    ) external initializer {
        __OptaraModule_init(control_);
        if (
            address(ledger_) == address(0) || address(registry_) == address(0) || address(spot_) == address(0)
                || address(surface_) == address(0) || address(settlement_) == address(0)
                || address(reserves_) == address(0)
        ) revert ZeroAddress();
        RiskStorage storage $ = _s();
        $.ledger = ledger_;
        $.registry = registry_;
        $.spot = spot_;
        $.surface = surface_;
        $.settlement = settlement_;
        $.reserves = reserves_;
    }

    // =================================================================================================== admin

    function createRiskSet(bytes32 id, RiskParams calldata p) external onlyRole(Roles.GOVERNANCE) {
        RiskSet storage rs = _s().riskSets[id];
        if (rs.exists) revert RiskSetExists(id);
        _validate(p);
        rs.exists = true;
        rs.enabled = true;
        _write(rs, p);
        emit RiskSetCreated(id, p);
        emit RiskSetEnabled(id, true);
    }

    /// @notice Governance (timelocked): replace every parameter, in either direction.
    function updateRiskSet(bytes32 id, RiskParams calldata p) external onlyRole(Roles.GOVERNANCE) {
        RiskSet storage rs = _set(id);
        _validate(p);
        _write(rs, p);
        emit RiskSetUpdated(id, p);
    }

    /// @notice Risk admin (instant) or governance: increase only.
    function raiseImBuffer(bytes32 id, uint16 bps) external {
        _riskAdminOrGovernance();
        RiskSet storage rs = _set(id);
        if (bps <= rs.imBufferBps || bps > MAX_IM_BUFFER_BPS) revert InvalidRiskParams(RP_DIRECTION);
        rs.imBufferBps = bps;
        emit RiskSetUpdated(id, _params(rs));
    }

    /// @notice Risk admin (instant) or governance: increase only, below maxIv.
    function raiseMinIv(bytes32 id, uint256 minIv) external {
        _riskAdminOrGovernance();
        RiskSet storage rs = _set(id);
        if (minIv <= rs.minIv || minIv >= rs.maxIv) revert InvalidRiskParams(RP_DIRECTION);
        rs.minIv = minIv;
        emit RiskSetUpdated(id, _params(rs));
    }

    /// @notice Risk admin (instant) or governance: append scenarios. A larger set can only raise a maximum loss.
    function addScenarios(bytes32 id, Scenario[] calldata initialAdd, Scenario[] calldata maintenanceAdd) external {
        _riskAdminOrGovernance();
        RiskSet storage rs = _set(id);
        if (
            rs.initialSet.length + initialAdd.length > MAX_SCENARIOS
                || rs.maintenanceSet.length + maintenanceAdd.length > MAX_SCENARIOS
        ) revert InvalidRiskParams(RP_SCENARIO_COUNT);
        for (uint256 i; i < initialAdd.length; ++i) {
            _validateScenario(initialAdd[i]);
            rs.initialSet.push(initialAdd[i]);
        }
        for (uint256 i; i < maintenanceAdd.length; ++i) {
            _validateScenario(maintenanceAdd[i]);
            rs.maintenanceSet.push(maintenanceAdd[i]);
        }
        emit RiskSetUpdated(id, _params(rs));
    }

    /// @notice Lowering: risk admin or governance (instant). Raising: governance.
    function setOpenInterestCap(bytes32 id, uint256 cap) external {
        RiskSet storage rs = _set(id);
        if (cap > rs.maxOpenInterestPerSeries) _checkRole(Roles.GOVERNANCE);
        else _riskAdminOrGovernance();
        if (cap == 0 || cap > MAX_OPEN_INTEREST) revert InvalidRiskParams(RP_OPEN_INTEREST);
        rs.maxOpenInterestPerSeries = cap;
        emit RiskSetUpdated(id, _params(rs));
    }

    /// @notice Disabling (no new series may use the set): risk admin, guardian or governance. Enabling: governance.
    ///         Existing series keep being margined with the set either way.
    function setRiskSetEnabled(bytes32 id, bool enabled) external {
        if (enabled) {
            _checkRole(Roles.GOVERNANCE);
        } else if (
            !_hasRole(Roles.GOVERNANCE, msg.sender) && !_hasRole(Roles.RISK_ADMIN, msg.sender)
                && !_hasRole(Roles.GUARDIAN, msg.sender)
        ) {
            revert NotAuthorized(msg.sender);
        }
        _set(id).enabled = enabled;
        emit RiskSetEnabled(id, enabled);
    }

    /// @notice Governance, once per product: every series of the product uses this set.
    function assignProductRiskSet(bytes32 productId, bytes32 id) external onlyRole(Roles.GOVERNANCE) {
        RiskStorage storage $ = _s();
        ProductRisk storage pr = $.products[productId];
        if (pr.riskSetId != 0) revert RiskSetAlreadyAssigned(productId);
        RiskSet storage rs = _set(id);
        if (!rs.enabled) revert UnknownRiskSet(id);
        address asset = $.registry.getProduct(productId).settlementAsset;
        if (asset == address(0)) revert InvalidRiskParams(RP_PRODUCT);
        pr.riskSetId = id;
        pr.settlementAsset = asset;
        emit ProductRiskSetAssigned(productId, id);
    }

    /// @notice Cap on Σ |short| × contract size for the product (underlying units, WAD). Lowering: risk admin or
    ///         governance (instant). Raising: governance. Lowering forces nothing; it blocks new mints.
    function setProductShortCap(bytes32 productId, uint256 capWad) external {
        ProductRisk storage pr = _s().products[productId];
        if (pr.riskSetId == 0) revert InvalidRiskParams(RP_PRODUCT);
        if (capWad > pr.maxShortUnderlyingWad) _checkRole(Roles.GOVERNANCE);
        else _riskAdminOrGovernance();
        pr.maxShortUnderlyingWad = capWad;
        emit ProductShortCapSet(productId, capWad);
    }

    // =================================================================================================== checks

    /// @inheritdoc IPortfolioRiskManager
    function requireHealthy(uint256 accountId) external view returns (Risk memory risk) {
        risk = _compute(accountId, Mode.STRICT, _noDelta()).risk;
        if (!_covers(risk.equity, risk.initialMargin)) revert NotHealthy(risk.equity, risk.initialMargin);
    }

    /// @inheritdoc IPortfolioRiskManager
    function checkOpenRisk(bytes32 seriesId, bool checkCaps) external view {
        RiskStorage storage $ = _s();
        LedgerSeries memory info = _seriesInfo(seriesId);
        if (block.timestamp >= info.expiry) revert SeriesNotActive(seriesId);
        if (_isProductCloseOnly(info.productId)) revert ProductCloseOnly(info.productId);
        if (!checkCaps) return;
        (, uint256 shorts) = $.ledger.totals(seriesId);
        if (shorts > $.riskSets[info.riskParameterSetId].maxOpenInterestPerSeries) revert OpenInterestCap(seriesId);
        if ($.ledger.productShortNotional(info.productId) > $.products[info.productId].maxShortUnderlyingWad * WAD) {
            revert OpenInterestCap(info.productId);
        }
    }

    /// @inheritdoc IPortfolioRiskManager
    function riskForLiquidation(uint256 accountId) external view returns (Risk memory) {
        return _compute(accountId, Mode.LIQUIDATION, _noDelta()).risk;
    }

    // =================================================================================================== views

    function riskOf(uint256 accountId) external view returns (Risk memory) {
        return _compute(accountId, Mode.VIEW, _noDelta()).risk;
    }

    function healthOf(uint256 accountId)
        external
        view
        returns (HealthState state, int256 equity, uint256 initialMargin, uint256 maintenanceMargin, bool fresh)
    {
        Result memory r = _compute(accountId, Mode.VIEW, _noDelta());
        (equity, initialMargin, maintenanceMargin, fresh) =
        (r.risk.equity, r.risk.initialMargin, r.risk.maintenanceMargin, r.risk.fresh);
        if (_covers(equity, initialMargin)) state = HealthState.HEALTHY;
        else if (_covers(equity, maintenanceMargin)) state = HealthState.CLOSE_ONLY;
        else if (equity < 0 && !r.hasActive) state = HealthState.INSOLVENT;
        else state = HealthState.LIQUIDATABLE;
    }

    function equityOf(uint256 accountId) external view returns (int256) {
        return _compute(accountId, Mode.VIEW, _noDelta()).risk.equity;
    }

    function marginOf(uint256 accountId) external view returns (uint256 initialMargin, uint256 maintenanceMargin) {
        Risk memory r = _compute(accountId, Mode.VIEW, _noDelta()).risk;
        return (r.initialMargin, r.maintenanceMargin);
    }

    /// @inheritdoc IPortfolioRiskManager
    function previewWithDelta(uint256 accountId, bytes32 seriesId, int256 qtyDelta, int256 cashDeltaNative)
        external
        view
        returns (Risk memory)
    {
        return _compute(accountId, Mode.VIEW, _oneDelta(seriesId, qtyDelta, cashDeltaNative)).risk;
    }

    /// @inheritdoc IPortfolioRiskManager
    function previewWithDeltas(
        uint256 accountId,
        bytes32[] calldata seriesIds,
        int256[] calldata qtyDeltas,
        int256 cashDeltaNative
    ) external view returns (Risk memory) {
        if (seriesIds.length != qtyDeltas.length) revert LengthMismatch();
        return _compute(accountId, Mode.VIEW, Delta(seriesIds, qtyDeltas, cashDeltaNative)).risk;
    }

    function previewWrap(uint256 accountId, bytes32 seriesId, uint256 qty)
        external
        view
        returns (int256 equityAfter, uint256 imAfter, bool ok)
    {
        int256 q = qty.toInt256();
        Risk memory r = _compute(accountId, Mode.VIEW, _oneDelta(seriesId, -q, 0)).risk;
        ok = _s().ledger.balanceOf(accountId, seriesId) >= q && _healthy(r);
        return (r.equity, r.initialMargin, ok);
    }

    function previewWithdraw(uint256 accountId, uint256 amount)
        external
        view
        returns (int256 equityAfter, uint256 imAfter, bool ok)
    {
        Risk memory r = _compute(accountId, Mode.VIEW, _oneDelta(0, 0, -amount.toInt256())).risk;
        ok = amount <= _s().ledger.cashOf(accountId) && _healthy(r);
        return (r.equity, r.initialMargin, ok);
    }

    /// @notice min(cash, floor((equity − IM) / scale)); 0 if not healthy. Withdrawing cash lowers equity 1:1 and
    ///         leaves IM unchanged, so withdrawing exactly this keeps the account healthy.
    function maxWithdrawable(uint256 accountId) external view returns (uint256) {
        RiskStorage storage $ = _s();
        Risk memory r = _compute(accountId, Mode.VIEW, _noDelta()).risk;
        if (!_healthy(r)) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 free = uint256(r.equity) - r.initialMargin; // equity ≥ IM ≥ 0
        uint8 d = $.registry.settlementAssetDecimals($.ledger.settlementAssetOf(accountId));
        uint256 native = FixedPoint.toNativeDown(free, d);
        uint256 cash = $.ledger.cashOf(accountId);
        return native < cash ? native : cash;
    }

    /// @inheritdoc IPortfolioRiskManager
    function priceOf(bytes32 seriesId) external view returns (uint256 mid, uint256 shortPrice, uint256 longPrice) {
        LedgerSeries memory info = _seriesInfo(seriesId);
        bool isCall = info.optionType == OptionType.CALL;
        (bool finalized, uint256 settle) = _s().settlement.settlementPriceOf(info.groupId);
        if (finalized) {
            mid = OptionPricer.intrinsic(isCall, settle, info.strikeWad);
            return (mid, mid, mid);
        }
        (uint256 spot,) = _s().spot.spotPrice(info.productId);
        if (block.timestamp >= info.expiry) {
            mid = OptionPricer.intrinsic(isCall, spot, info.strikeWad);
            return (mid, mid, mid);
        }
        (uint256 s, uint256 sShort, uint256 sLong, bool intrinsicOnly) = _ivs(info, spot);
        uint256 t = FixedPoint.yearsUntil(info.expiry, block.timestamp);
        mid = OptionPricer.black76(isCall, spot, info.strikeWad, s, t);
        shortPrice = OptionPricer.black76(isCall, spot, info.strikeWad, sShort, t);
        longPrice = intrinsicOnly
            ? OptionPricer.intrinsic(isCall, spot, info.strikeWad)
            : OptionPricer.black76(isCall, spot, info.strikeWad, sLong, t);
    }

    /// @inheritdoc IPortfolioRiskManager
    function ivOf(bytes32 seriesId) external view returns (uint256 sigma, uint256 sigmaShort, uint256 sigmaLong) {
        LedgerSeries memory info = _seriesInfo(seriesId);
        (uint256 spot,) = _s().spot.spotPrice(info.productId);
        (sigma, sigmaShort, sigmaLong,) = _ivs(info, spot);
    }

    function isProductCloseOnly(bytes32 productId) external view returns (bool) {
        return _isProductCloseOnly(productId);
    }

    /// @inheritdoc IRiskSets
    function isRiskSetForProduct(bytes32 productId, bytes32 id) external view returns (bool) {
        RiskStorage storage $ = _s();
        return $.products[productId].riskSetId == id && $.riskSets[id].enabled;
    }

    function getRiskSet(bytes32 id) external view returns (RiskParams memory params, bool enabled) {
        RiskSet storage rs = _set(id);
        return (_params(rs), rs.enabled);
    }

    function productRiskSet(bytes32 productId) external view returns (bytes32) {
        return _s().products[productId].riskSetId;
    }

    function productShortCap(bytes32 productId) external view returns (uint256) {
        return _s().products[productId].maxShortUnderlyingWad;
    }

    // =================================================================================================== core

    /// @dev Equity, IM and MM of an account (optionally with one hypothetical balance and cash change).
    function _compute(uint256 accountId, Mode mode, Delta memory d) private view returns (Result memory res) {
        RiskStorage storage $ = _s();
        Position[] memory ps = _positions(accountId, d);
        uint8 dec = $.registry.settlementAssetDecimals($.ledger.settlementAssetOf(accountId));
        int256 cash = FixedPoint.toWad($.ledger.cashOf(accountId), dec).toInt256() + d.cashNative
            * FixedPoint.scale(dec).toInt256();
        res.risk.equity = cash;
        res.risk.fresh = true;

        // buckets = distinct products, in first-seen order (≤ maxBucketsPerAccount)
        bool[] memory done = new bool[](ps.length);
        for (uint256 i; i < ps.length; ++i) {
            if (done[i]) continue;
            Bucket memory b = _bucket(ps, done, i, mode);
            res.risk.equity += b.value;
            res.risk.initialMargin += b.lossIm + b.buffer;
            res.risk.maintenanceMargin += b.lossMm;
            res.risk.fresh = res.risk.fresh && b.fresh;
            res.hasActive = res.hasActive || b.hasActive;
        }
    }

    /// @dev Legs of one bucket: live (not finalized) legs for pricing, and the active ones' IV queries.
    struct Work {
        Leg[] legs;
        uint256 n;
        uint256[] strikes; // active legs only, in leg order
        uint64[] expiries;
        bytes32[] activeIds;
        uint256 nActive;
        uint256 shortMark;
    }

    /// @dev Value and losses of the bucket whose product is ps[first].series.productId; marks its positions done.
    function _bucket(Position[] memory ps, bool[] memory done, uint256 first, Mode mode)
        private
        view
        returns (Bucket memory b)
    {
        RiskSet storage rs = _s().riskSets[_s().products[ps[first].series.productId].riskSetId];
        b.productId = ps[first].series.productId;
        b.fresh = true;
        Work memory w = _collect(ps, done, first, b);
        if (w.n != 0) {
            b.spot = _spotFor(b, mode);
            if (w.nActive != 0) _assignVols(b, w, rs, mode);
            _losses(b, w, rs);
        }
        b.buffer = _buffer(w.shortMark, rs.imBufferBps);
    }

    /// @dev Phase 1: finalized legs are valued exactly (and leave the scenario loop); the rest become `Leg`s.
    function _collect(Position[] memory ps, bool[] memory done, uint256 first, Bucket memory b)
        private
        view
        returns (Work memory w)
    {
        ISettlementState st = _s().settlement;
        w.legs = new Leg[](ps.length);
        w.strikes = new uint256[](ps.length);
        w.expiries = new uint64[](ps.length);
        w.activeIds = new bytes32[](ps.length);
        for (uint256 i = first; i < ps.length; ++i) {
            if (ps[i].series.productId != b.productId) continue;
            done[i] = true;
            if (ps[i].balance == 0) continue;
            LedgerSeries memory s = ps[i].series;
            bool isCall = s.optionType == OptionType.CALL;
            (bool finalized, uint256 settle) = st.settlementPriceOf(s.groupId);
            if (finalized) {
                int256 v = OptionPricer.legValue(
                    ps[i].balance, s.contractSizeWad, OptionPricer.intrinsic(isCall, settle, s.strikeWad)
                );
                b.value += v;
                if (v < 0) w.shortMark += M.abs(v);
                continue;
            }
            uint256 t = FixedPoint.yearsUntil(s.expiry, block.timestamp);
            w.legs[w.n++] = Leg({
                q: ps[i].balance,
                isCall: isCall,
                intrinsicOnly: false,
                strike: s.strikeWad,
                cs: s.contractSizeWad,
                t: t,
                sigma: 0
            });
            if (t != 0) {
                (w.strikes[w.nActive], w.expiries[w.nActive], w.activeIds[w.nActive]) =
                (s.strikeWad, s.expiry, ps[i].seriesId);
                w.nActive++;
            }
        }
        Leg[] memory legs = w.legs;
        uint256[] memory strikes = w.strikes;
        uint64[] memory expiries = w.expiries;
        (uint256 n, uint256 na) = (w.n, w.nActive);
        assembly {
            // shrink the arrays to their used lengths
            mstore(legs, n)
            mstore(strikes, na)
            mstore(expiries, na)
        }
        if (na != 0) b.hasActive = true;
    }

    struct IvAdjust {
        uint64 staleSeconds;
        uint32 penaltyPerHour;
        bool longIntrinsic;
        uint256 minIv;
        uint256 maxIv;
    }

    /// @dev Phase 2: σ for every active leg: surface IV (one batch call), clamped to the risk set, direction-aware
    ///      when the surface is stale (MATH.md §5.1).
    function _assignVols(Bucket memory b, Work memory w, RiskSet storage rs, Mode mode) private view {
        IvAdjust memory adj;
        (adj.staleSeconds, adj.penaltyPerHour, adj.longIntrinsic) = _surfaceFor(b, mode);
        (adj.minIv, adj.maxIv) = (rs.minIv, rs.maxIv);
        uint256[] memory sigmas = _fetchIvs(b, w);
        uint256 a;
        for (uint256 i; i < w.legs.length; ++i) {
            Leg memory l = w.legs[i];
            if (l.t == 0) continue; // expired, not finalized: intrinsic at (shocked) spot
            _setSigma(l, sigmas[a++], adj);
        }
    }

    function _fetchIvs(Bucket memory b, Work memory w) private view returns (uint256[] memory sigmas) {
        uint8 status;
        uint256 failed;
        uint8 tIdx;
        uint8 nIdx;
        (sigmas, status, failed, tIdx, nIdx) = _s().surface.impliedVols(b.productId, b.spot, w.strikes, w.expiries);
        // IV_NO_SURFACE can't happen here: _surfaceFor already reverted on a missing surface
        if (status == 3) revert MissingSurfaceNode(b.productId, tIdx, nIdx);
        if (status != 0) revert SeriesNotPriceable(w.activeIds[failed]);
    }

    function _setSigma(Leg memory l, uint256 sig, IvAdjust memory adj) private pure {
        if (sig < adj.minIv) sig = adj.minIv;
        if (sig > adj.maxIv) sig = adj.maxIv;
        (uint256 sShort, uint256 sLong) =
            OptionPricer.staleIvs(sig, adj.staleSeconds, adj.penaltyPerHour, adj.minIv, adj.maxIv);
        l.sigma = l.q < 0 ? sShort : sLong;
        l.intrinsicOnly = adj.longIntrinsic;
    }

    /// @dev Phase 3: base value, short mark, and the worst loss over MM set (both margins) and IM set (IM only).
    function _losses(Bucket memory b, Work memory w, RiskSet storage rs) private view {
        int256 base;
        for (uint256 i; i < w.legs.length; ++i) {
            Leg memory l = w.legs[i];
            int256 v = OptionPricer.legValue(l.q, l.cs, _price(l, b.spot, l.sigma, l.t));
            base += v;
            if (v < 0) w.shortMark += M.abs(v);
        }
        b.value += base;
        uint256 floorT = uint256(rs.nearExpiryFloorSeconds) * WAD / FixedPoint.YEAR;
        Scenario[] memory mmSet = rs.maintenanceSet;
        for (uint256 j; j < mmSet.length; ++j) {
            int256 loss = base - _scenarioValue(w.legs, b.spot, mmSet[j], rs.minIv, rs.maxIv, floorT);
            if (loss > 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 l = uint256(loss);
                if (l > b.lossMm) b.lossMm = l;
                if (l > b.lossIm) b.lossIm = l;
            }
        }
        Scenario[] memory imSet = rs.initialSet;
        for (uint256 j; j < imSet.length; ++j) {
            int256 loss = base - _scenarioValue(w.legs, b.spot, imSet[j], rs.minIv, rs.maxIv, floorT);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (loss > 0 && uint256(loss) > b.lossIm) b.lossIm = uint256(loss);
        }
    }

    /// @dev Value of the bucket's live legs under one scenario (MATH.md §9). σ is sticky-strike.
    function _scenarioValue(
        Leg[] memory legs,
        uint256 spot,
        Scenario memory sc,
        uint256 minIv,
        uint256 maxIv,
        uint256 floorT
    ) private pure returns (int256 v) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 s = spot * uint256(int256(BPS) + sc.spotShockBps) / BPS; // spotShockBps ≥ −10_000
        uint256 shift = uint256(sc.timeShiftSeconds) * WAD / FixedPoint.YEAR;
        for (uint256 i; i < legs.length; ++i) {
            Leg memory l = legs[i];
            uint256 t = l.t;
            if (sc.timeMode == 1 && t > floorT) t = floorT;
            else if (sc.timeMode == 2) t = t > shift ? t - shift : 0;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 sig = l.sigma * uint256(int256(BPS) + sc.volShockBps) / BPS; // volShockBps ≥ −10_000
            if (sig < minIv) sig = minIv;
            if (sig > maxIv) sig = maxIv;
            v += OptionPricer.legValue(l.q, l.cs, _price(l, s, sig, t));
        }
    }

    function _price(Leg memory l, uint256 spot, uint256 sigma, uint256 t) private pure returns (uint256) {
        if (l.intrinsicOnly && l.q > 0) return OptionPricer.intrinsic(l.isCall, spot, l.strike);
        return OptionPricer.black76(l.isCall, spot, l.strike, sigma, t);
    }

    /// @dev Spot for the bucket under the mode's freshness rule.
    function _spotFor(Bucket memory b, Mode mode) private view returns (uint256 spot) {
        ILiveSpotOracle so = _s().spot;
        if (mode != Mode.VIEW) return so.requireFreshSpot(b.productId);
        uint64 publishTime;
        (spot, publishTime) = so.spotPrice(b.productId);
        if (spot == 0) revert StaleSpot(b.productId, type(uint64).max);
        if (!so.isSpotFresh(b.productId)) b.fresh = false;
    }

    /// @dev Surface staleness under the mode's rule: STRICT needs FRESH; LIQUIDATION accepts STALE; VIEW accepts all.
    function _surfaceFor(Bucket memory b, Mode mode)
        private
        view
        returns (uint64 staleSeconds, uint32 penaltyPerHour, bool longIntrinsic)
    {
        IVolSurfaceOracle so = _s().surface;
        IVolSurfaceOracle.SurfaceStatus status;
        (status, staleSeconds) = so.surfaceStatus(b.productId);
        IVolSurfaceOracle.SurfaceConfig memory c = so.surfaceConfig(b.productId);
        if (status == IVolSurfaceOracle.SurfaceStatus.NONE) revert StaleSurface(b.productId, type(uint64).max);
        uint64 age = staleSeconds + c.surfaceStaleAfter;
        if (status != IVolSurfaceOracle.SurfaceStatus.FRESH) {
            b.fresh = false;
            if (
                mode == Mode.STRICT
                    || (mode == Mode.LIQUIDATION && status == IVolSurfaceOracle.SurfaceStatus.EXPIRED_DATA)
            ) revert StaleSurface(b.productId, age);
        }
        penaltyPerHour = c.staleIvPenaltyBpsPerHour;
        longIntrinsic = status != IVolSurfaceOracle.SurfaceStatus.FRESH && age > c.maxLongTimeValueStale;
    }

    /// @dev IVs of one series at `spot` (VIEW semantics), for priceOf/ivOf.
    function _ivs(LedgerSeries memory info, uint256 spot)
        private
        view
        returns (uint256 s, uint256 sShort, uint256 sLong, bool intrinsicOnly)
    {
        if (spot == 0) revert StaleSpot(info.productId, type(uint64).max);
        Bucket memory b;
        b.productId = info.productId;
        b.spot = spot;
        (uint64 staleSeconds, uint32 penalty, bool longIntrinsic) = _surfaceFor(b, Mode.VIEW);
        RiskSet storage rs = _s().riskSets[_s().products[info.productId].riskSetId];
        s = _clampedIv(info, spot, rs);
        (sShort, sLong) = OptionPricer.staleIvs(s, staleSeconds, penalty, rs.minIv, rs.maxIv);
        intrinsicOnly = longIntrinsic;
    }

    function _clampedIv(LedgerSeries memory info, uint256 spot, RiskSet storage rs) private view returns (uint256 s) {
        uint256[] memory strikes = new uint256[](1);
        uint64[] memory expiries = new uint64[](1);
        (strikes[0], expiries[0]) = (info.strikeWad, info.expiry);
        (uint256[] memory sig, uint8 status,, uint8 tIdx, uint8 nIdx) =
            _s().surface.impliedVols(info.productId, spot, strikes, expiries);
        if (status == 3) revert MissingSurfaceNode(info.productId, tIdx, nIdx);
        if (status != 0) revert SeriesNotPriceable(0);
        s = sig[0];
        if (s < rs.minIv) s = rs.minIv;
        if (s > rs.maxIv) s = rs.maxIv;
    }

    function _noDelta() private pure returns (Delta memory d) {}

    function _oneDelta(bytes32 seriesId, int256 qty, int256 cashNative) private pure returns (Delta memory d) {
        d.seriesIds = new bytes32[](1);
        d.qtys = new int256[](1);
        (d.seriesIds[0], d.qtys[0], d.cashNative) = (seriesId, qty, cashNative);
    }

    /// @dev The account's positions with the hypothetical balance changes applied. A series not held yet is appended
    ///      once (later deltas for it add to the appended entry).
    function _positions(uint256 accountId, Delta memory d) private view returns (Position[] memory ps) {
        ps = _s().ledger.positionsOf(accountId);
        uint256 n = ps.length;
        Position[] memory added = new Position[](d.seriesIds.length);
        uint256 nAdded;
        for (uint256 j; j < d.seriesIds.length; ++j) {
            (bytes32 id, int256 q) = (d.seriesIds[j], d.qtys[j]);
            if (id == 0 || q == 0) continue;
            bool found;
            for (uint256 i; i < n && !found; ++i) {
                if (ps[i].seriesId == id) (ps[i].balance, found) = (ps[i].balance + q, true);
            }
            for (uint256 i; i < nAdded && !found; ++i) {
                if (added[i].seriesId == id) (added[i].balance, found) = (added[i].balance + q, true);
            }
            if (!found) added[nAdded++] = Position({seriesId: id, balance: q, series: _seriesInfo(id)});
        }
        if (nAdded == 0) return ps;
        Position[] memory out = new Position[](n + nAdded);
        for (uint256 i; i < n; ++i) {
            out[i] = ps[i];
        }
        for (uint256 i; i < nAdded; ++i) {
            out[n + i] = added[i];
        }
        return out;
    }

    /// @dev Series data from the ledger cache, or the registry for a series never written yet.
    function _seriesInfo(bytes32 seriesId) private view returns (LedgerSeries memory info) {
        RiskStorage storage $ = _s();
        bool cached;
        (info, cached) = $.ledger.seriesInfo(seriesId);
        if (cached) return info;
        SeriesTerms memory t = $.registry.getSeries(seriesId); // reverts UnknownSeries
        info = LedgerSeries({
            underlying: t.underlying,
            expiry: t.expiry,
            optionType: t.optionType,
            settlementAsset: t.settlementAsset,
            groupId: $.registry.groupOf(seriesId),
            productId: $.registry.productOf(seriesId),
            riskParameterSetId: t.riskParameterSetId,
            strikeWad: t.strikeWad,
            contractSizeWad: t.contractSizeWad
        });
    }

    /// @dev Manual flag, surface missing / expired data / low confidence / emergency, or reserves below minimum.
    function _isProductCloseOnly(bytes32 productId) private view returns (bool) {
        RiskStorage storage $ = _s();
        if (control().isProductCloseOnly(productId)) return true;
        IVolSurfaceOracle so = $.surface;
        (IVolSurfaceOracle.SurfaceStatus status,) = so.surfaceStatus(productId);
        if (status == IVolSurfaceOracle.SurfaceStatus.NONE || status == IVolSurfaceOracle.SurfaceStatus.EXPIRED_DATA) {
            return true;
        }
        if (so.header(productId).lowConfidence || so.isEmergency(productId)) return true;
        return !$.reserves.reservesHealthy($.products[productId].settlementAsset);
    }

    function _healthy(Risk memory r) private pure returns (bool) {
        return _covers(r.equity, r.initialMargin);
    }

    /// @dev equity ≥ margin, with a negative equity never covering anything.
    function _covers(int256 equity, uint256 margin) private pure returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return equity >= 0 && uint256(equity) >= margin; // equity ≥ 0 here
    }

    function _buffer(uint256 shortMark, uint16 bps) private pure returns (uint256) {
        return M.fullMulDivUp(shortMark, bps, BPS);
    }

    // =================================================================================================== params

    function _validate(RiskParams calldata p) private pure {
        if (p.imBufferBps > MAX_IM_BUFFER_BPS) revert InvalidRiskParams(RP_BUFFER);
        if (p.minIv == 0 || p.minIv >= p.maxIv || p.maxIv > MAX_IV) revert InvalidRiskParams(RP_IV);
        if (p.nearExpiryFloorSeconds > 1 days) revert InvalidRiskParams(RP_FLOOR);
        if (p.maxOpenInterestPerSeries == 0 || p.maxOpenInterestPerSeries > MAX_OPEN_INTEREST) {
            revert InvalidRiskParams(RP_OPEN_INTEREST);
        }
        if (
            p.maintenanceSet.length == 0 || p.maintenanceSet.length > MAX_SCENARIOS
                || p.initialSet.length > MAX_SCENARIOS
        ) revert InvalidRiskParams(RP_SCENARIO_COUNT);
        for (uint256 i; i < p.initialSet.length; ++i) {
            _validateScenario(p.initialSet[i]);
        }
        for (uint256 i; i < p.maintenanceSet.length; ++i) {
            _validateScenario(p.maintenanceSet[i]);
        }
    }

    function _validateScenario(Scenario calldata s) private pure {
        if (
            s.spotShockBps < -10_000 || s.spotShockBps > 100_000 || s.volShockBps < -10_000 || s.volShockBps > 100_000
                || s.timeMode > 2 || s.timeShiftSeconds > 730 days || (s.timeMode != 2 && s.timeShiftSeconds != 0)
        ) revert InvalidRiskParams(RP_SCENARIO_VALUE);
    }

    function _write(RiskSet storage rs, RiskParams calldata p) private {
        rs.imBufferBps = p.imBufferBps;
        rs.minIv = p.minIv;
        rs.maxIv = p.maxIv;
        rs.nearExpiryFloorSeconds = p.nearExpiryFloorSeconds;
        rs.maxOpenInterestPerSeries = p.maxOpenInterestPerSeries;
        delete rs.initialSet;
        delete rs.maintenanceSet;
        for (uint256 i; i < p.initialSet.length; ++i) {
            rs.initialSet.push(p.initialSet[i]);
        }
        for (uint256 i; i < p.maintenanceSet.length; ++i) {
            rs.maintenanceSet.push(p.maintenanceSet[i]);
        }
    }

    function _params(RiskSet storage rs) private view returns (RiskParams memory p) {
        p.imBufferBps = rs.imBufferBps;
        p.minIv = rs.minIv;
        p.maxIv = rs.maxIv;
        p.nearExpiryFloorSeconds = rs.nearExpiryFloorSeconds;
        p.maxOpenInterestPerSeries = rs.maxOpenInterestPerSeries;
        p.initialSet = rs.initialSet;
        p.maintenanceSet = rs.maintenanceSet;
    }

    function _set(bytes32 id) private view returns (RiskSet storage rs) {
        rs = _s().riskSets[id];
        if (!rs.exists) revert UnknownRiskSet(id);
    }

    function _riskAdminOrGovernance() private view {
        if (!_hasRole(Roles.RISK_ADMIN, msg.sender) && !_hasRole(Roles.GOVERNANCE, msg.sender)) {
            revert NotAuthorized(msg.sender);
        }
    }

    function _s() private pure returns (RiskStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
