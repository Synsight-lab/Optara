// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {OptaraCoreBase} from "./OptaraCoreBase.sol";
import {IOptaraConfig} from "../interfaces/IOptaraConfig.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";
import {
    Series,
    SeriesState,
    Group,
    Position,
    Leg,
    OptionType,
    CloseSource,
    AssetStatus,
    AssetIncident,
    SeriesStatus,
    PairStatus,
    Actions
} from "../libraries/OptaraTypes.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {PayoffMath} from "../libraries/PayoffMath.sol";
import {RiskMath} from "../libraries/RiskMath.sol";

/// @title OptaraCore
/// @notice Optara V2 clearing, custody, risk, settlement and containment in one immutable contract.
///
/// Solvency rule enforced after every risk-increasing or collateral-decreasing action (MATH.md section 29):
///     cash(account, asset) >= sum over the account's active and expired-unfinalized groups in `asset` of
///     ceilDiv(WorstLossNumerator, D_A) + SafetyBufferNative
/// with every finalized group of that asset synchronized first. Payoffs are exact integer numerators and each
/// accounting boundary rounds once: margin and net debits up, credits and payouts down.
contract OptaraCore is OptaraCoreBase {
    using SafeCast for uint256;

    constructor(IOptaraConfig config_, IOracleRegistry oracleRegistry_, uint64 shortfallResolutionDelay_)
        OptaraCoreBase(config_, oracleRegistry_, shortfallResolutionDelay_)
    {}

    // =============================================================================================
    // One-time wiring (ACCESS_CONTROL.md section 44)
    // =============================================================================================

    /// @notice Bind the only contract allowed to register series, then seal forever.
    function bindSeriesFactory(address factory) external {
        if (msg.sender != deployer) revert NotAuthorized(msg.sender);
        if (isSealed) revert AlreadySealed();
        if (factory == address(0)) revert ZeroAddress();
        seriesFactory = factory;
        isSealed = true;
        emit CoreSealed(factory);
    }

    /// @notice Store immutable series terms. The factory has validated them (OPTION_SPEC.md section 18); the core
    ///         re-derives the identities it depends on and snapshots new groups' buffer policy (MATH.md section 25).
    function registerSeries(bytes32 seriesId, Series calldata s) external {
        if (!isSealed) revert NotSealed();
        if (msg.sender != seriesFactory) revert OnlySeriesFactory(msg.sender);
        if (_series[seriesId].optionToken != address(0)) revert SeriesAlreadyExists(seriesId);
        if (
            s.optionToken == address(0)
                || seriesId
                    != computeSeriesId(
                        s.underlying,
                        s.settlementAsset,
                        s.optionType,
                        s.strikeWad,
                        s.capWad,
                        s.contractSizeWad,
                        s.expiry,
                        s.oracleConfigId
                    ) || s.groupId != computeGroupId(s.underlying, s.expiry, s.settlementAsset, s.oracleConfigId)
                || s.pairId != _pairId(s.underlying, s.settlementAsset) || s.quantityIncrement == 0
        ) revert InvalidSeriesRegistration();

        Group storage g = _groups[s.groupId];
        if (!g.exists) {
            (uint16 bps, uint256 fixedBuffer) = config.bufferDefaults(s.settlementAsset);
            g.exists = true;
            g.underlying = s.underlying;
            g.expiry = s.expiry;
            g.settlementAsset = s.settlementAsset;
            g.assetDecimals = s.assetDecimals;
            g.oracleConfigId = s.oracleConfigId;
            g.pairId = s.pairId;
            g.bufferBps = bps;
            g.fixedBufferNative = fixedBuffer;
            _allGroups.push(s.groupId);
            emit GroupCreated(s.groupId, s.underlying, s.settlementAsset, s.expiry, s.oracleConfigId, bps, fixedBuffer);
        }
        _series[seriesId] = s;
        _allSeries.push(seriesId);
        emit SeriesCreated(
            seriesId,
            s.groupId,
            s.optionToken,
            s.underlying,
            s.settlementAsset,
            s.optionType,
            s.strikeWad,
            s.capWad,
            s.contractSizeWad,
            s.expiry,
            s.oracleConfigId,
            s.quantityIncrement
        );
    }

    // =============================================================================================
    // Cash: deposit, recapitalize, withdraw (PROTOCOL_SPEC.md sections 10, 19)
    // =============================================================================================

    /// @notice Deposit the exact settlement stablecoin. While the asset is restricted only a cure deposit is
    ///         accepted: into an account below its requirement, at most its deficit (LIQUIDATION.md section 101).
    function deposit(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireKnownAsset(asset);
        _requireNotPaused(Actions.DEPOSIT, asset, bytes32(0));
        AssetStatus status = _incidents[asset].status;
        if (status == AssetStatus.WIND_DOWN) revert AssetInWindDown(asset);
        bool cure;
        if (status == AssetStatus.RESTRICTED) {
            uint256 d = _deficit(msg.sender, asset);
            if (d == 0 || amount > d) revert CureDepositExceedsDeficit(amount, d);
            cure = true;
        }
        _pullExact(asset, msg.sender, amount);
        _creditCash(msg.sender, asset, amount);
        emit CollateralDeposited(msg.sender, asset, amount, cure);
    }

    /// @notice Add backing without crediting any account (unallocated surplus). Anyone may call; disabled in
    ///         wind-down, where rho is already fixed.
    function recapitalize(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireKnownAsset(asset);
        _requireNotPaused(Actions.DEPOSIT, asset, bytes32(0));
        if (_incidents[asset].status == AssetStatus.WIND_DOWN) revert AssetInWindDown(asset);
        _pullExact(asset, msg.sender, amount);
        _totalRecapitalized[asset] += amount;
        emit Recapitalized(asset, msg.sender, amount);
    }

    /// @notice Withdraw free collateral. Every finalized group of the asset is synchronized first from the complete
    ///         canonical index; unfinalized groups stay reserved at their exact worst case.
    function withdraw(address asset, uint256 amount, address recipient) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        _requireKnownAsset(asset);
        _requireNotPaused(Actions.WITHDRAW, asset, bytes32(0));
        _requireNotRestricted(asset);
        _syncAllFinalized(msg.sender, asset);
        uint256 cash = _cash[msg.sender][asset];
        if (amount > cash) revert InsufficientCash(amount, cash);
        _debitCash(msg.sender, asset, amount);
        _requireMarginSafe(msg.sender, asset);
        uint256 paid = _outflowAmount(asset, amount);
        _pay(asset, recipient, paid);
        emit CollateralWithdrawn(msg.sender, asset, recipient, amount, paid);
    }

    // =============================================================================================
    // Issuance (PROTOCOL_SPEC.md section 11)
    // =============================================================================================

    /// @notice Record a short and mint the identical long quantity to `recipient` after the exact post-write check.
    function write(bytes32 seriesId, uint256 quantity, address recipient) external nonReentrant {
        Series storage s = _seriesOf(seriesId);
        if (block.timestamp >= s.expiry) revert SeriesNotActive(seriesId);
        if (quantity == 0) revert ZeroAmount();
        if (quantity % s.quantityIncrement != 0) revert QuantityGranularity(quantity, s.quantityIncrement);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        address asset = s.settlementAsset;
        _requireNotPaused(Actions.WRITE, asset, s.oracleConfigId);
        AssetStatus status = _incidents[asset].status;
        if (status == AssetStatus.RESTRICTED) revert AssetIsRestricted(asset);
        if (status == AssetStatus.WIND_DOWN) revert AssetInWindDown(asset);
        _requireNewRiskEnabled(s);

        _syncAllFinalized(msg.sender, asset);

        Group storage g = _groups[s.groupId];
        _addToIndex(msg.sender, seriesId, s.groupId);
        _positions[msg.sender][seriesId].shortQty += quantity;
        _checkNumeratorBounds(msg.sender, s.groupId);

        uint256 e = PayoffMath.maxPayoffNumerator(s.capWad, s.contractSizeWad, quantity);
        _increaseExposure(seriesId, s, g, e);
        SeriesState storage st = _seriesState[seriesId];
        st.openShortQty += quantity;
        st.minted += quantity;

        _requireMarginSafe(msg.sender, asset);

        IOptionToken(s.optionToken).mint(recipient, quantity);
        emit OptionWritten(msg.sender, seriesId, recipient, quantity, e);
    }

    function _requireNewRiskEnabled(Series storage s) internal view {
        (, bool newRiskEnabled,) = config.assetInfo(s.settlementAsset);
        if (!newRiskEnabled) revert NewRiskDisabled();
        (PairStatus pairStatus,,) = config.pairInfo(s.pairId);
        if (pairStatus != PairStatus.ENABLED) revert NewRiskDisabled();
        if (!oracleRegistry.isApprovedForNewRisk(s.oracleConfigId)) revert NewRiskDisabled();
    }

    // =============================================================================================
    // Close and unfinalized cancellation (PROTOCOL_SPEC.md sections 16, 41)
    // =============================================================================================

    /// @notice Close an ACTIVE short with identical longs from an explicit source. Cannot increase risk
    ///         (EXTERNAL lowers every leg's liability; LOCKED removes identical short and long legs together).
    function closeShort(bytes32 seriesId, uint256 quantity, CloseSource source) external nonReentrant {
        Series storage s = _seriesOf(seriesId);
        if (block.timestamp >= s.expiry) revert SeriesNotActive(seriesId);
        _burnPair(seriesId, s, quantity, source);
        emit ShortClosed(msg.sender, seriesId, quantity, source);
    }

    /// @notice Cancel an expired-but-unfinalized short against an identical long. Pays no option cash and accepts no
    ///         price. After finalization only normal settlement applies (transaction ordering resolves races).
    function cancelUnfinalizedShort(bytes32 seriesId, uint256 quantity, CloseSource source) external nonReentrant {
        Series storage s = _seriesOf(seriesId);
        if (block.timestamp < s.expiry) revert SeriesNotExpired(seriesId);
        if (_groups[s.groupId].finalized) revert GroupAlreadyFinalized(s.groupId);
        _burnPair(seriesId, s, quantity, source);
        emit ShortCancelledUnfinalized(msg.sender, seriesId, quantity, source);
    }

    function _burnPair(bytes32 seriesId, Series storage s, uint256 quantity, CloseSource source) internal {
        if (quantity == 0) revert ZeroAmount();
        _requireNotPaused(Actions.CLOSE, s.settlementAsset, s.oracleConfigId);
        Position storage p = _positions[msg.sender][seriesId];
        if (quantity > p.shortQty) revert InsufficientShort(quantity, p.shortQty);
        IOptionToken token = IOptionToken(s.optionToken);
        if (source == CloseSource.LOCKED) {
            if (quantity > p.lockedQty) revert InsufficientLocked(quantity, p.lockedQty);
            p.lockedQty -= quantity;
            token.burn(address(this), quantity);
        } else {
            // Burns the caller's own tokens; reverts if the caller holds fewer than `quantity`.
            token.burn(msg.sender, quantity);
        }
        p.shortQty -= quantity;
        SeriesState storage st = _seriesState[seriesId];
        st.openShortQty -= quantity;
        st.closed += quantity;
        _decreaseExposure(seriesId, s, _groups[s.groupId], PayoffMath.product(s.capWad, s.contractSizeWad, quantity));
        _removeIfEmpty(msg.sender, seriesId, s.groupId);
    }

    // =============================================================================================
    // Hedge custody (PROTOCOL_SPEC.md sections 14-15, 41)
    // =============================================================================================

    /// @notice Transfer identical longs into custody and lock them.
    function lockLong(bytes32 seriesId, uint256 quantity) external nonReentrant {
        Series storage s = _seriesOf(seriesId);
        if (block.timestamp >= s.expiry) revert SeriesNotActive(seriesId);
        if (quantity == 0) revert ZeroAmount();
        _requireNotPaused(Actions.LOCK, s.settlementAsset, s.oracleConfigId);

        _addToIndex(msg.sender, seriesId, s.groupId);
        _positions[msg.sender][seriesId].lockedQty += quantity;
        _checkNumeratorBounds(msg.sender, s.groupId);

        // The OptionToken is the factory-deployed exact ERC-20, so transferFrom moves exactly `quantity`; only
        // this call's transfer is credited, never a pre-existing custody surplus (INV-HEDGE-02).
        IOptionToken(s.optionToken).transferFrom(msg.sender, address(this), quantity);
        emit LongLocked(msg.sender, seriesId, quantity);
    }

    /// @notice Release a locked long only after the complete post-removal margin check. Finalized hedges settle
    ///         atomically through sync and cannot be unlocked.
    function unlockLong(bytes32 seriesId, uint256 quantity, address recipient) external nonReentrant {
        Series storage s = _seriesOf(seriesId);
        if (quantity == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        if (_groups[s.groupId].finalized) revert GroupAlreadyFinalized(s.groupId);
        address asset = s.settlementAsset;
        _requireNotPaused(Actions.UNLOCK, asset, s.oracleConfigId);
        _requireNotRestricted(asset);
        Position storage p = _positions[msg.sender][seriesId];
        if (quantity > p.lockedQty) revert InsufficientLocked(quantity, p.lockedQty);

        _syncAllFinalized(msg.sender, asset);
        p.lockedQty -= quantity;
        _removeIfEmpty(msg.sender, seriesId, s.groupId);
        _requireMarginSafe(msg.sender, asset);

        IOptionToken(s.optionToken).transfer(recipient, quantity);
        emit LongUnlocked(msg.sender, seriesId, recipient, quantity);
    }

    // =============================================================================================
    // Settlement (PROTOCOL_SPEC.md sections 21-24, ORACLE_AND_SETTLEMENT.md sections 32-58)
    // =============================================================================================

    /// @notice Permissionless: record the group's single immutable price from the precommitted oracle rule, and
    ///         release the group's exposure from pair/oracle/asset caps in O(1). Moves no funds.
    function finalizeRiskGroup(bytes32 groupId, bytes calldata oracleData)
        external
        payable
        nonReentrant
        returns (uint256 priceWad)
    {
        Group storage g = _groups[groupId];
        if (!g.exists) revert UnknownGroup(groupId);
        if (g.finalized) revert GroupAlreadyFinalized(groupId);
        (uint64 minDelay,) = oracleRegistry.finalizationDelays(g.oracleConfigId);
        uint256 earliest = uint256(g.expiry) + minDelay;
        if (block.timestamp < earliest) revert FinalizationTooEarly(earliest);
        _requireNotPaused(Actions.FINALIZE, g.settlementAsset, g.oracleConfigId);

        address adapter = oracleRegistry.adapterOf(g.oracleConfigId);
        uint64 observationTimestamp;
        (priceWad, observationTimestamp) =
            ISettlementOracle(adapter).verifySettlementPrice{value: msg.value}(g.oracleConfigId, g.expiry, oracleData);
        _recordFinalization(groupId, g, priceWad, observationTimestamp, keccak256(oracleData));
    }

    /// @dev Stores the single price and releases the group's exposure from pair/oracle/asset scopes in O(1).
    function _recordFinalization(
        bytes32 groupId,
        Group storage g,
        uint256 priceWad,
        uint64 observationTimestamp,
        bytes32 oracleDataHash
    ) internal {
        g.finalized = true;
        g.settlementPriceWad = priceWad;
        g.finalizedAt = uint64(block.timestamp);
        g.observationTimestamp = observationTimestamp;

        uint256 released = g.exposureN;
        _pairExposureN[g.pairId] -= released;
        _oracleExposureN[g.oracleConfigId] -= released;
        _assetExposureN[g.settlementAsset] -= released;
        g.released = true;

        emit RiskGroupFinalized(
            groupId,
            g.oracleConfigId,
            g.settlementAsset,
            priceWad,
            observationTimestamp,
            msg.sender,
            released,
            oracleDataHash
        );
    }

    /// @notice Permissionless deterministic synchronization of one finalized account group. No recipient and no
    ///         economic choice exist. Returns false (no-op) when the account has nothing left in the group.
    function syncRiskGroup(address account, bytes32 groupId) external nonReentrant returns (bool synced) {
        Group storage g = _groups[groupId];
        if (!g.exists) revert UnknownGroup(groupId);
        if (!g.finalized) revert GroupNotFinalized(groupId);
        return _syncGroup(account, groupId, g);
    }

    /// @notice Permissionless: synchronize every finalized group of `asset` in the account's canonical index.
    function syncAccount(address account, address asset) external nonReentrant returns (uint256 groupsSynced) {
        return _syncAllFinalized(account, asset);
    }

    /// @notice Burn settled longs and pay floorDiv(phi* * CS * Q, D_A) of the series' settlement asset
    ///         (floor(rho * payout) after verified-shortfall resolution). Zero payouts still burn.
    function redeem(bytes32 seriesId, uint256 quantity, address recipient)
        external
        nonReentrant
        returns (uint256 paid)
    {
        Series storage s = _seriesOf(seriesId);
        Group storage g = _groups[s.groupId];
        if (!g.finalized) revert GroupNotFinalized(s.groupId);
        if (quantity == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        address asset = s.settlementAsset;
        _requireNotPaused(Actions.REDEEM, asset, s.oracleConfigId);
        _requireNotRestricted(asset);

        IOptionToken(s.optionToken).burn(msg.sender, quantity);
        uint256 n = PayoffMath.payoffNumerator(
            s.optionType, s.strikeWad, s.capWad, s.contractSizeWad, g.settlementPriceWad, quantity
        );
        uint256 d = FixedPointMath.nativeDenominator(s.assetDecimals);
        uint256 payout = n / d;
        _roundingResidualN[asset] += n - payout * d;
        _seriesState[seriesId].redeemed += quantity;
        _decreaseExposure(seriesId, s, g, PayoffMath.product(s.capWad, s.contractSizeWad, quantity));

        paid = _outflowAmount(asset, payout);
        _pay(asset, recipient, paid);
        emit LongRedeemed(msg.sender, recipient, seriesId, quantity, asset, payout, paid);
    }

    // =============================================================================================
    // Containment and verified-shortfall resolution (LIQUIDATION.md sections 101-102)
    // =============================================================================================

    /// @notice Permissionless. Restricts `asset` only on a reproducible existing-state deficit of `account`
    ///         (pending finalized deltas and unfinalized reservations included). Healthy checks change nothing.
    function checkAndRestrict(address account, address asset) external nonReentrant returns (bool restricted) {
        if (account == address(0)) revert ZeroAddress();
        _requireKnownAsset(asset);
        AssetIncident storage inc = _incidents[asset];
        if (inc.status != AssetStatus.NORMAL) return inc.status == AssetStatus.RESTRICTED;
        uint256 d = _deficit(account, asset);
        if (d == 0) return false;
        inc.status = AssetStatus.RESTRICTED;
        emit AssetRestricted(asset, account, d, bytes32("VERIFIED_DEFICIT"), msg.sender);
        return true;
    }

    /// @notice Guardian or governance restriction for alarms that cannot be proven from one account's state.
    function restrictAsset(address asset, bytes32 reason) external {
        if (!_hasRole(config.PAUSER_ROLE()) && !_hasRole(config.GOVERNANCE_ROLE())) revert NotAuthorized(msg.sender);
        _requireKnownAsset(asset);
        AssetIncident storage inc = _incidents[asset];
        if (inc.status != AssetStatus.NORMAL) revert AssetIsRestricted(asset);
        inc.status = AssetStatus.RESTRICTED;
        emit AssetRestricted(asset, address(0), 0, reason, msg.sender);
    }

    /// @notice Governance clears a restriction after reconciliation proves backing intact (or recapitalized).
    function clearAssetRestriction(address asset, bytes32 reconciliationRef) external {
        _onlyGovernance();
        AssetIncident storage inc = _incidents[asset];
        if (inc.status != AssetStatus.RESTRICTED) revert AssetNotRestricted(asset);
        inc.status = AssetStatus.NORMAL;
        inc.pendingEta = 0;
        inc.pendingRhoWad = 0;
        inc.pendingReference = bytes32(0);
        emit AssetRestrictionCleared(asset, reconciliationRef, msg.sender);
    }

    /// @notice Queue a single uniform recovery ratio for a restricted asset behind the in-contract timelock, so
    ///         anyone can check the published reconciliation before it takes effect. 0 < rho < 1.
    function proposeShortfallResolution(address asset, uint256 rhoWad, bytes32 reconciliationRef) external {
        _onlyGovernance();
        AssetIncident storage inc = _incidents[asset];
        if (inc.status != AssetStatus.RESTRICTED) revert AssetNotRestricted(asset);
        if (rhoWad == 0 || rhoWad >= FixedPointMath.WAD) revert InvalidRho(rhoWad);
        if (inc.pendingEta != 0) revert ShortfallResolutionExists(asset);
        uint64 eta = uint64(block.timestamp) + shortfallResolutionDelay;
        inc.pendingRhoWad = rhoWad;
        inc.pendingEta = eta;
        inc.pendingReference = reconciliationRef;
        emit ShortfallResolutionProposed(asset, rhoWad, eta, reconciliationRef);
    }

    /// @notice Apply the queued ratio after the delay: the asset enters terminal WIND_DOWN on this core.
    function executeShortfallResolution(address asset) external {
        _onlyGovernance();
        AssetIncident storage inc = _incidents[asset];
        if (inc.status != AssetStatus.RESTRICTED) revert AssetNotRestricted(asset);
        if (inc.pendingEta == 0) revert NoPendingResolution(asset);
        if (block.timestamp < inc.pendingEta) revert ResolutionTimelocked(inc.pendingEta);
        inc.rhoWad = inc.pendingRhoWad;
        inc.status = AssetStatus.WIND_DOWN;
        bytes32 ref = inc.pendingReference;
        inc.pendingEta = 0;
        inc.pendingRhoWad = 0;
        inc.pendingReference = bytes32(0);
        emit ShortfallResolved(asset, inc.rhoWad, ref);
    }

    function cancelShortfallResolution(address asset) external {
        _onlyGovernance();
        AssetIncident storage inc = _incidents[asset];
        if (inc.pendingEta == 0) revert NoPendingResolution(asset);
        inc.pendingEta = 0;
        inc.pendingRhoWad = 0;
        inc.pendingReference = bytes32(0);
        emit ShortfallResolutionCancelled(asset, msg.sender);
    }

    // =============================================================================================
    // Identity views
    // =============================================================================================

    function computeSeriesId(
        address underlying,
        address settlementAsset,
        OptionType optionType,
        uint256 strikeWad,
        uint256 capWad,
        uint256 contractSizeWad,
        uint64 expiry,
        bytes32 oracleConfigId
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                protocolSeriesDomain(),
                underlying,
                settlementAsset,
                optionType,
                strikeWad,
                capWad,
                contractSizeWad,
                expiry,
                oracleConfigId
            )
        );
    }

    function computeGroupId(address underlying, uint64 expiry, address settlementAsset, bytes32 oracleConfigId)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(protocolSeriesDomain(), underlying, expiry, settlementAsset, oracleConfigId));
    }

    function seriesExists(bytes32 seriesId) external view returns (bool) {
        return _series[seriesId].optionToken != address(0);
    }

    function seriesCount() external view returns (uint256) {
        return _allSeries.length;
    }

    function seriesIdAt(uint256 index) external view returns (bytes32) {
        return _allSeries[index];
    }

    function groupCount() external view returns (uint256) {
        return _allGroups.length;
    }

    function groupIdAt(uint256 index) external view returns (bytes32) {
        return _allGroups[index];
    }

    // =============================================================================================
    // State views
    // =============================================================================================

    function getSeries(bytes32 seriesId) external view returns (Series memory) {
        return _seriesOf(seriesId);
    }

    function getSeriesState(bytes32 seriesId) external view returns (SeriesState memory) {
        return _seriesState[seriesId];
    }

    function getGroup(bytes32 groupId) external view returns (Group memory) {
        return _groups[groupId];
    }

    function positionOf(address account, bytes32 seriesId) external view returns (Position memory) {
        return _positions[account][seriesId];
    }

    function cashBalance(address account, address asset) external view returns (uint256) {
        return _cash[account][asset];
    }

    function totalCash(address asset) external view returns (uint256) {
        return _totalCash[asset];
    }

    function totalRecapitalized(address asset) external view returns (uint256) {
        return _totalRecapitalized[asset];
    }

    /// @notice Exact realized rounding residual of `asset`, numerator over D_A (never user collateral).
    function roundingResidualN(address asset) external view returns (uint256) {
        return _roundingResidualN[asset];
    }

    function accountGroups(address account) external view returns (bytes32[] memory) {
        return _accountGroups[account];
    }

    function accountGroupSeries(address account, bytes32 groupId) external view returns (bytes32[] memory) {
        return _accountGroupSeries[account][groupId];
    }

    function accountSeriesCount(address account) external view returns (uint256) {
        return _accountSeriesCount[account];
    }

    function accountGroupLegs(address account, bytes32 groupId) external view returns (Leg[] memory) {
        return _groupLegs(account, groupId);
    }

    function exposureOf(bytes32 pairId, bytes32 oracleConfigId, address asset)
        external
        view
        returns (uint256 pairN, uint256 oracleN, uint256 assetN)
    {
        return (_pairExposureN[pairId], _oracleExposureN[oracleConfigId], _assetExposureN[asset]);
    }

    function assetStatus(address asset) external view returns (AssetStatus status, uint256 rhoWad) {
        AssetIncident storage inc = _incidents[asset];
        return (inc.status, inc.rhoWad);
    }

    function assetIncident(address asset) external view returns (AssetIncident memory) {
        return _incidents[asset];
    }

    // =============================================================================================
    // Risk views (MARGIN_AND_RISK.md section 84). Advisory for clients; enforcement uses the same internals.
    // =============================================================================================

    function requiredMargin(address account, address asset) external view returns (uint256) {
        return _requiredMargin(account, asset);
    }

    function effectiveCash(address account, address asset) external view returns (int256) {
        return _effectiveCash(account, asset);
    }

    function freeCollateral(address account, address asset) public view returns (uint256) {
        int256 free = _effectiveCash(account, asset) - _requiredMargin(account, asset).toInt256();
        return free > 0 ? uint256(free) : 0;
    }

    function deficit(address account, address asset) external view returns (uint256) {
        return _deficit(account, asset);
    }

    /// @notice Largest amount withdraw() can currently accept (ledger units; paid at rho after wind-down).
    function maxWithdrawable(address account, address asset) external view returns (uint256) {
        if (_incidents[asset].status == AssetStatus.RESTRICTED) return 0;
        return freeCollateral(account, asset);
    }

    function worstCaseLossNumerator(address account, bytes32 groupId) external view returns (uint256) {
        return RiskMath.worstCaseLossNumerator(_groupLegs(account, groupId));
    }

    function groupRequiredMargin(address account, bytes32 groupId) external view returns (uint256) {
        Group storage g = _groups[groupId];
        if (!g.exists || g.finalized) return 0;
        return _groupMarginNative(g, _groupLegs(account, groupId));
    }

    /// @notice Required margin of the settlement asset after hypothetically changing one series' short and/or locked
    ///         quantity by the given signed deltas (write, close, lock, unlock previews).
    function requiredMarginAfter(address account, bytes32 seriesId, int256 shortDelta, int256 lockedDelta)
        public
        view
        returns (uint256 total)
    {
        Series storage s = _seriesOf(seriesId);
        bytes32[] storage groups = _accountGroups[account];
        bool seen;
        for (uint256 i = 0; i < groups.length; ++i) {
            Group storage g = _groups[groups[i]];
            if (g.settlementAsset != s.settlementAsset || g.finalized) continue;
            Leg[] memory legs = _groupLegs(account, groups[i]);
            if (groups[i] == s.groupId) {
                legs = _adjustLegs(account, groups[i], legs, seriesId, s, shortDelta, lockedDelta);
                seen = true;
            }
            total += _groupMarginNative(g, legs);
        }
        if (!seen && !_groups[s.groupId].finalized) {
            Leg[] memory legs = _adjustLegs(account, s.groupId, new Leg[](0), seriesId, s, shortDelta, lockedDelta);
            total += _groupMarginNative(_groups[s.groupId], legs);
        }
    }

    function _adjustLegs(
        address account,
        bytes32 groupId,
        Leg[] memory legs,
        bytes32 seriesId,
        Series storage s,
        int256 shortDelta,
        int256 lockedDelta
    ) internal view returns (Leg[] memory out) {
        uint256 idx = _accountSeriesIndex[account][seriesId];
        if (idx != 0 && _accountGroupSeries[account][groupId].length == legs.length) {
            out = legs;
            idx -= 1;
        } else {
            out = new Leg[](legs.length + 1);
            for (uint256 i = 0; i < legs.length; ++i) {
                out[i] = legs[i];
            }
            idx = legs.length;
            out[idx] = Leg(s.optionType, s.strikeWad, s.capWad, s.contractSizeWad, 0, 0);
        }
        out[idx].shortQty = _applyDelta(out[idx].shortQty, shortDelta);
        out[idx].lockedQty = _applyDelta(out[idx].lockedQty, lockedDelta);
    }

    function _applyDelta(uint256 value, int256 delta) internal pure returns (uint256) {
        if (delta >= 0) return value + uint256(delta);
        uint256 minus = uint256(-delta);
        return minus >= value ? 0 : value - minus;
    }

    /// @notice max(RequiredMarginPostWrite - EffectiveCash, 0), the number to show before writing (MATH.md 31).
    function additionalCollateralForWrite(address account, bytes32 seriesId, uint256 quantity)
        external
        view
        returns (uint256)
    {
        int256 need = requiredMarginAfter(account, seriesId, quantity.toInt256(), 0).toInt256()
            - _effectiveCash(account, _seriesOf(seriesId).settlementAsset);
        return need > 0 ? uint256(need) : 0;
    }

    function accountRiskState(address account, address asset) external view returns (AccountRiskState memory r) {
        r.cash = _cash[account][asset];
        r.effectiveCash = _effectiveCash(account, asset);
        r.requiredMargin = _requiredMargin(account, asset);
        int256 free = r.effectiveCash - r.requiredMargin.toInt256();
        r.freeCollateral = free > 0 ? uint256(free) : 0;
        r.deficit = free < 0 ? uint256(-free) : 0;
        bytes32[] storage groups = _accountGroups[account];
        for (uint256 i = 0; i < groups.length; ++i) {
            Group storage g = _groups[groups[i]];
            if (g.settlementAsset == asset && g.finalized) {
                r.hasUnsyncedMaturedGroups = true;
                break;
            }
        }
        r.assetStatus = _incidents[asset].status;
    }

    // =============================================================================================
    // Lifecycle and settlement previews
    // =============================================================================================

    function seriesStatus(bytes32 seriesId) external view returns (SeriesStatus) {
        Series storage s = _series[seriesId];
        if (s.optionToken == address(0)) return SeriesStatus.NONE;
        if (_groups[s.groupId].finalized) return SeriesStatus.SETTLED;
        if (block.timestamp >= s.expiry) return SeriesStatus.EXPIRED_UNSETTLED;
        return SeriesStatus.ACTIVE;
    }

    /// @notice ORACLE_STALLED is a monitoring/recovery flag, never a price (PROTOCOL_SPEC.md section 41).
    function isOracleStalled(bytes32 groupId) external view returns (bool) {
        Group storage g = _groups[groupId];
        if (!g.exists || g.finalized) return false;
        (, uint64 maxDelay) = oracleRegistry.finalizationDelays(g.oracleConfigId);
        return block.timestamp >= uint256(g.expiry) + maxDelay;
    }

    /// @notice Exact phi* per underlying unit, WAD (MATH.md section 43). Reverts before finalization.
    function seriesPayoffPerUnderlying(bytes32 seriesId) external view returns (uint256) {
        Series storage s = _seriesOf(seriesId);
        Group storage g = _groups[s.groupId];
        if (!g.finalized) revert GroupNotFinalized(s.groupId);
        return PayoffMath.phi(s.optionType, s.strikeWad, s.capWad, g.settlementPriceWad);
    }

    /// @notice (contractual payout, amount actually transferred) for redeeming `quantity` now.
    function previewRedeem(bytes32 seriesId, uint256 quantity) external view returns (uint256 payout, uint256 paid) {
        Series storage s = _seriesOf(seriesId);
        Group storage g = _groups[s.groupId];
        if (!g.finalized) revert GroupNotFinalized(s.groupId);
        payout = FixedPointMath.floorDiv(
            PayoffMath.payoffNumerator(
                s.optionType, s.strikeWad, s.capWad, s.contractSizeWad, g.settlementPriceWad, quantity
            ),
            FixedPointMath.nativeDenominator(s.assetDecimals)
        );
        paid = _outflowAmount(s.settlementAsset, payout);
    }

    /// @notice Signed cash delta a sync of this finalized account group would apply.
    function previewSync(address account, bytes32 groupId)
        external
        view
        returns (int256 delta, uint256 shortNumerator, uint256 lockedLongNumerator)
    {
        if (!_groups[groupId].finalized) revert GroupNotFinalized(groupId);
        return _settlementDelta(account, groupId);
    }

    /// @notice Physical custody of `asset` held by the core (for reconciliation; includes surplus and reserve).
    function vaultBalance(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}
