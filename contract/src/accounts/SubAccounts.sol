// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {SeriesTerms, LedgerSeries, Position} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    UnknownAccount,
    AssetMismatch,
    AssetNotApproved,
    InsufficientCash,
    PositionLimit,
    PositionBelowMinimum,
    InvalidLimits
} from "../libraries/Errors.sol";

/// @title SubAccounts
/// @notice The ledger (docs/PROTOCOL_SPEC.md §1, OPTION_SPEC.md §8, SETTLEMENT.md §5). Holds no tokens: custody is
///         in OptionClearing. Every balance change goes through `applyDelta`, which in O(1) keeps
///         - per-series totals of internal longs and shorts (INV-2),
///         - the bounded per-account series list and underlying buckets (INV-43),
///         - the per-(account, group) series count and the group participant counter (INV-27),
///         - the minimum position size (INV-6) and settlement-asset matching (INV-5).
/// @dev Writers (OptionClearing, LiquidationModule, SettlementWindow) are fixed at initialization. They check
///      business rules (who may act, closing more than a short, finalization); the ledger checks accounting rules.
contract SubAccounts is OptaraModule, ISubAccounts {
    uint256 public constant MAX_SERIES_CAP = 64;
    uint256 public constant MAX_BUCKETS_CAP = 16;

    struct Account {
        address owner;
        address settlementAsset;
        uint256 cash; // native units of the settlement asset
    }

    /// @dev Series count and 1-based list index of one underlying bucket, packed in one slot.
    struct Bucket {
        uint128 seriesCount;
        uint128 index;
    }

    struct Totals {
        uint256 internalLong;
        uint256 internalShort;
    }

    /// @custom:storage-location erc7201:optara.storage.SubAccounts
    struct SubAccountsStorage {
        IOptionSeriesRegistry registry;
        address clearing;
        address liquidationModule;
        address settlementWindow;
        uint256 maxSeriesPerAccount;
        uint256 maxBucketsPerAccount;
        uint256 minPositionQty;
        uint256 accountCount;
        mapping(uint256 accountId => Account) accounts;
        mapping(uint256 accountId => mapping(address operator => bool)) operators;
        mapping(uint256 accountId => mapping(bytes32 seriesId => int256)) balances;
        mapping(uint256 accountId => bytes32[]) seriesList;
        mapping(uint256 accountId => mapping(bytes32 seriesId => uint256)) seriesIndex; // 1-based
        mapping(uint256 accountId => address[]) bucketList;
        mapping(uint256 accountId => mapping(address underlying => Bucket)) buckets;
        mapping(uint256 accountId => mapping(bytes32 groupId => uint256)) groupSeriesCount;
        mapping(bytes32 groupId => uint256) participants;
        mapping(bytes32 seriesId => Totals) totals;
        mapping(bytes32 seriesId => LedgerSeries) seriesInfo; // immutable series data, cached on first use
        mapping(bytes32 productId => uint256) productShortNotional; // Σ |short qty| × CS (1e36 units)
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.SubAccounts")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x3c61caf276ff6aa03256c196c9e21581e53ffd178fe58fa13f741a87fa864200;

    function initialize(
        IProtocolControl control_,
        IOptionSeriesRegistry registry_,
        address clearing_,
        address liquidationModule_,
        address settlementWindow_,
        uint256 maxSeriesPerAccount_,
        uint256 maxBucketsPerAccount_,
        uint256 minPositionQty_
    ) external initializer {
        __OptaraModule_init(control_);
        if (
            address(registry_) == address(0) || clearing_ == address(0) || liquidationModule_ == address(0)
                || settlementWindow_ == address(0)
        ) revert ZeroAddress();
        SubAccountsStorage storage $ = _s();
        $.registry = registry_;
        $.clearing = clearing_;
        $.liquidationModule = liquidationModule_;
        $.settlementWindow = settlementWindow_;
        _setPositionLimits(maxSeriesPerAccount_, maxBucketsPerAccount_);
        if (minPositionQty_ == 0 || minPositionQty_ > 1e18) revert InvalidLimits();
        $.minPositionQty = minPositionQty_;
        emit MinPositionQtySet(minPositionQty_);
    }

    // ------------------------------------------------------------------------------------------------- users

    /// @inheritdoc ISubAccounts
    function createSubAccount(address settlementAsset) external returns (uint256 accountId) {
        SubAccountsStorage storage $ = _s();
        if (!$.registry.isSettlementAssetApproved(settlementAsset)) revert AssetNotApproved(settlementAsset);
        accountId = ++$.accountCount;
        $.accounts[accountId] = Account({owner: msg.sender, settlementAsset: settlementAsset, cash: 0});
        emit SubAccountCreated(accountId, msg.sender, settlementAsset);
    }

    /// @inheritdoc ISubAccounts
    function setOperator(uint256 accountId, address operator, bool approved) external {
        if (_account(accountId).owner != msg.sender) revert NotAuthorized(msg.sender);
        if (operator == address(0)) revert ZeroAddress();
        _s().operators[accountId][operator] = approved;
        emit OperatorSet(accountId, operator, approved);
    }

    // ------------------------------------------------------------------------------------------------- writers

    /// @inheritdoc ISubAccounts
    function addCash(uint256 accountId, uint256 amount) external nonReentrant {
        _onlyWriter();
        Account storage a = _account(accountId);
        a.cash += amount;
        emit CashUpdated(accountId, _toInt(amount), a.cash);
    }

    /// @inheritdoc ISubAccounts
    function subCash(uint256 accountId, uint256 amount) external nonReentrant {
        _onlyWriter();
        Account storage a = _account(accountId);
        uint256 cash = a.cash;
        if (amount > cash) revert InsufficientCash(amount, cash);
        a.cash = cash - amount;
        emit CashUpdated(accountId, -_toInt(amount), cash - amount);
    }

    /// @inheritdoc ISubAccounts
    function applyDelta(uint256 accountId, bytes32 seriesId, int256 delta)
        external
        nonReentrant
        returns (int256 balance)
    {
        _onlyWriter();
        SubAccountsStorage storage $ = _s();
        Account storage a = _account(accountId);
        int256 old = $.balances[accountId][seriesId];
        if (delta == 0) return old;

        LedgerSeries memory info = _seriesInfo(seriesId);
        if (info.settlementAsset != a.settlementAsset) revert AssetMismatch();

        balance = old + delta;
        if (balance != 0) {
            uint256 mag = M.abs(balance);
            uint256 minQty = $.minPositionQty;
            if (mag < minQty || mag % minQty != 0) revert PositionBelowMinimum(balance);
        }
        $.balances[accountId][seriesId] = balance;

        Totals storage t = $.totals[seriesId];
        t.internalLong = t.internalLong - _pos(old) + _pos(balance);
        t.internalShort = t.internalShort - _neg(old) + _neg(balance);
        if (_neg(old) != _neg(balance)) {
            uint256 cs = info.contractSizeWad;
            $.productShortNotional[info.productId] =
                $.productShortNotional[info.productId] - _neg(old) * cs + _neg(balance) * cs;
        }

        if (old == 0) _openPosition(accountId, seriesId, info);
        else if (balance == 0) _closePosition(accountId, seriesId, info);

        emit BalanceUpdated(accountId, seriesId, delta, balance);
    }

    // ------------------------------------------------------------------------------------------------- governance

    /// @notice Governance (timelocked). Lowering never forces anything: it only blocks adding positions beyond the
    ///         new limit. Hard caps keep the risk check's gas bounded (INV-36).
    function setPositionLimits(uint256 maxSeries, uint256 maxBuckets) external onlyRole(Roles.GOVERNANCE) {
        _setPositionLimits(maxSeries, maxBuckets);
    }

    /// @notice Governance (timelocked). The new minimum must divide the current one exactly, so every existing
    ///         balance (a multiple of the old minimum) stays valid (INV-6).
    function setMinPositionQty(uint256 newMin) external onlyRole(Roles.GOVERNANCE) {
        SubAccountsStorage storage $ = _s();
        if (newMin == 0 || $.minPositionQty % newMin != 0) revert InvalidLimits();
        $.minPositionQty = newMin;
        emit MinPositionQtySet(newMin);
    }

    // ------------------------------------------------------------------------------------------------- views

    function ownerOf(uint256 accountId) external view returns (address) {
        return _account(accountId).owner;
    }

    function settlementAssetOf(uint256 accountId) external view returns (address) {
        return _account(accountId).settlementAsset;
    }

    function cashOf(uint256 accountId) external view returns (uint256) {
        return _account(accountId).cash;
    }

    function balanceOf(uint256 accountId, bytes32 seriesId) external view returns (int256) {
        return _s().balances[accountId][seriesId];
    }

    function seriesOf(uint256 accountId) external view returns (bytes32[] memory) {
        return _s().seriesList[accountId];
    }

    function bucketsOf(uint256 accountId) external view returns (address[] memory) {
        return _s().bucketList[accountId];
    }

    function isAuthorized(uint256 accountId, address caller) external view returns (bool) {
        SubAccountsStorage storage $ = _s();
        address owner = $.accounts[accountId].owner;
        return owner != address(0) && (caller == owner || $.operators[accountId][caller]);
    }

    function isOperator(uint256 accountId, address operator) external view returns (bool) {
        return _s().operators[accountId][operator];
    }

    function participants(bytes32 groupId) external view returns (uint256) {
        return _s().participants[groupId];
    }

    function seriesCountInGroup(uint256 accountId, bytes32 groupId) external view returns (uint256) {
        return _s().groupSeriesCount[accountId][groupId];
    }

    function totals(bytes32 seriesId) external view returns (uint256 internalLong, uint256 internalShort) {
        Totals storage t = _s().totals[seriesId];
        return (t.internalLong, t.internalShort);
    }

    /// @inheritdoc ISubAccounts
    function positionsOf(uint256 accountId) external view returns (Position[] memory positions) {
        SubAccountsStorage storage $ = _s();
        bytes32[] storage list = $.seriesList[accountId];
        positions = new Position[](list.length);
        for (uint256 i; i < list.length; ++i) {
            bytes32 sid = list[i];
            positions[i] = Position({seriesId: sid, balance: $.balances[accountId][sid], series: $.seriesInfo[sid]});
        }
    }

    /// @inheritdoc ISubAccounts
    function seriesInfo(bytes32 seriesId) external view returns (LedgerSeries memory info, bool cached) {
        info = _s().seriesInfo[seriesId];
        cached = info.groupId != 0;
    }

    /// @inheritdoc ISubAccounts
    function productShortNotional(bytes32 productId) external view returns (uint256) {
        return _s().productShortNotional[productId];
    }

    function accountCount() external view returns (uint256) {
        return _s().accountCount;
    }

    function maxSeriesPerAccount() external view returns (uint256) {
        return _s().maxSeriesPerAccount;
    }

    function maxBucketsPerAccount() external view returns (uint256) {
        return _s().maxBucketsPerAccount;
    }

    function minPositionQty() external view returns (uint256) {
        return _s().minPositionQty;
    }

    function writers() external view returns (address clearing, address liquidationModule, address settlementWindow) {
        SubAccountsStorage storage $ = _s();
        return ($.clearing, $.liquidationModule, $.settlementWindow);
    }

    // ------------------------------------------------------------------------------------------------- internal

    /// @dev First non-zero balance in a series: series list, bucket and group participation.
    function _openPosition(uint256 accountId, bytes32 seriesId, LedgerSeries memory info) private {
        SubAccountsStorage storage $ = _s();
        bytes32[] storage list = $.seriesList[accountId];
        if (list.length >= $.maxSeriesPerAccount) revert PositionLimit();
        list.push(seriesId);
        $.seriesIndex[accountId][seriesId] = list.length;

        Bucket storage bucket = $.buckets[accountId][info.underlying];
        if (bucket.seriesCount == 0) {
            address[] storage bucketList = $.bucketList[accountId];
            if (bucketList.length >= $.maxBucketsPerAccount) revert PositionLimit();
            bucketList.push(info.underlying);
            // forge-lint: disable-next-line(unsafe-typecast)
            bucket.index = uint128(bucketList.length); // ≤ MAX_BUCKETS_CAP
        }
        ++bucket.seriesCount; // ≤ MAX_SERIES_CAP

        if ($.groupSeriesCount[accountId][info.groupId]++ == 0) {
            emit ParticipantsUpdated(info.groupId, ++$.participants[info.groupId]);
        }
    }

    /// @dev Balance back to zero: remove from the series list, bucket and group participation (swap-and-pop).
    function _closePosition(uint256 accountId, bytes32 seriesId, LedgerSeries memory info) private {
        SubAccountsStorage storage $ = _s();
        bytes32[] storage list = $.seriesList[accountId];
        uint256 idx = $.seriesIndex[accountId][seriesId] - 1;
        bytes32 last = list[list.length - 1];
        list[idx] = last;
        $.seriesIndex[accountId][last] = idx + 1;
        list.pop();
        delete $.seriesIndex[accountId][seriesId];

        Bucket storage bucket = $.buckets[accountId][info.underlying];
        if (--bucket.seriesCount == 0) {
            address[] storage bucketList = $.bucketList[accountId];
            uint128 bIdx = bucket.index - 1;
            address lastU = bucketList[bucketList.length - 1];
            bucketList[bIdx] = lastU;
            $.buckets[accountId][lastU].index = bIdx + 1;
            bucketList.pop();
            delete $.buckets[accountId][info.underlying];
        }

        if (--$.groupSeriesCount[accountId][info.groupId] == 0) {
            emit ParticipantsUpdated(info.groupId, --$.participants[info.groupId]);
        }
    }

    function _seriesInfo(bytes32 seriesId) private returns (LedgerSeries memory info) {
        SubAccountsStorage storage $ = _s();
        info = $.seriesInfo[seriesId];
        if (info.groupId == 0) {
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
            $.seriesInfo[seriesId] = info;
        }
    }

    function _setPositionLimits(uint256 maxSeries, uint256 maxBuckets) private {
        if (
            maxSeries == 0 || maxSeries > MAX_SERIES_CAP || maxBuckets == 0 || maxBuckets > MAX_BUCKETS_CAP
                || maxBuckets > maxSeries
        ) revert InvalidLimits();
        SubAccountsStorage storage $ = _s();
        $.maxSeriesPerAccount = maxSeries;
        $.maxBucketsPerAccount = maxBuckets;
        emit PositionLimitsSet(maxSeries, maxBuckets);
    }

    function _onlyWriter() private view {
        SubAccountsStorage storage $ = _s();
        if (msg.sender != $.clearing && msg.sender != $.liquidationModule && msg.sender != $.settlementWindow) {
            revert NotAuthorized(msg.sender);
        }
    }

    function _account(uint256 accountId) private view returns (Account storage a) {
        a = _s().accounts[accountId];
        if (a.owner == address(0)) revert UnknownAccount(accountId);
    }

    function _pos(int256 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x > 0 ? uint256(x) : 0; // x > 0
    }

    function _neg(int256 x) private pure returns (uint256) {
        return x < 0 ? M.abs(x) : 0;
    }

    function _toInt(uint256 x) private pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x <= uint256(type(int256).max) ? int256(x) : type(int256).max; // event value only; cash ≪ 2^255
    }

    function _s() private pure returns (SubAccountsStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
