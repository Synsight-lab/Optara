// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {PauseBits} from "../governance/PauseBits.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {ISettlementWindow} from "../interfaces/ISettlementWindow.sol";
import {ISettlementState} from "../interfaces/IExternalDependencies.sol";
import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {IOptionClearing} from "../interfaces/IOptionClearing.sol";
import {IExternalOptionWrapper} from "../interfaces/IExternalOptionWrapper.sol";
import {OptionType, Group, SeriesTerms, Position, LedgerSeries} from "../libraries/OptaraTypes.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    GroupAlreadyFinalized,
    GroupNotFinalized,
    NotParticipant,
    SettlementIncomplete,
    RatioAlreadySet,
    RatioNotSet,
    NothingToClaim,
    UnknownGroup,
    OracleNotStalled,
    PayoutsOutstanding
} from "../libraries/Errors.sol";

/// @title SettlementWindow
/// @notice Settlement groups from expiry to payout (docs/SETTLEMENT.md, MATH.md §13, PROTOCOL_SPEC.md §7).
/// @dev Everything is computed from exact numerators `q × intrinsic × CS` (scale 1e54) and rounded once per
///      amount: debts up, credits, the ratio and payouts down (INV-49). Cash and the pool both live in OptionClearing
///      custody, so collecting a debt or paying a credit moves no tokens; only insurance cover (in), wrapper
///      payouts and swept dust (out) do. The payoff price is capped per group at finalization so every numerator and
///      sum fits in int256 (MATH.md §14, C-14).
contract SettlementWindow is OptaraModule, ISettlementWindow {
    using SafeCastLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_UNIT_PAYOFF = 1e50; // intrinsic × CS bound (MATH.md §14)

    /// @custom:storage-location erc7201:optara.storage.SettlementWindow
    struct SettlementStorage {
        ISubAccounts ledger;
        IOptionSeriesRegistry registry;
        ISettlementOracle settlementOracle;
        IFeeController fees;
        IInsuranceFund insurance;
        IOptionClearing clearing;
        mapping(bytes32 groupId => GroupAccounting) groups;
        mapping(bytes32 seriesId => uint256) supplyAtFinalization;
        mapping(uint256 accountId => mapping(bytes32 groupId => uint256)) creditN;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.SettlementWindow")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x762a75442dd64cff610cf13e79ad28128ccc17ebe38c916cc51bbd63afc72c00;

    function initialize(IProtocolControl control_, Modules calldata m) external initializer {
        __OptaraModule_init(control_);
        if (
            m.ledger == address(0) || m.registry == address(0) || m.settlementOracle == address(0)
                || m.fees == address(0) || m.insurance == address(0) || m.clearing == address(0)
        ) revert ZeroAddress();
        SettlementStorage storage $ = _s();
        $.ledger = ISubAccounts(m.ledger);
        $.registry = IOptionSeriesRegistry(m.registry);
        $.settlementOracle = ISettlementOracle(m.settlementOracle);
        $.fees = IFeeController(m.fees);
        $.insurance = IInsuranceFund(m.insurance);
        $.clearing = IOptionClearing(m.clearing);
    }

    // ============================================================================================== finalization

    /// @inheritdoc ISettlementWindow
    function finalizeGroup(bytes32 groupId, bytes calldata settlementData) external nonReentrant {
        SettlementStorage storage $ = _s();
        Group memory g = _group(groupId);
        _requireNotPaused(PauseBits.FINALIZE, g.settlementAsset, _productId(g));
        GroupAccounting storage a = $.groups[groupId];
        if (a.finalized) revert GroupAlreadyFinalized(groupId); // INV-26: the price is written once
        (uint256 price, uint64 observationTime,) =
            $.settlementOracle.verify(g.settlementOracleConfigId, g.expiry, settlementData);

        (price, a.wrapperClaimN) = _snapshot(groupId, price);
        a.finalized = true;
        a.priceWad = price;
        a.finalizedAt = uint64(block.timestamp);
        a.observationTime = observationTime;
        emit GroupFinalized(groupId, price, observationTime, $.ledger.participants(groupId));
        $.fees.payFinalizeReward(g.settlementAsset, msg.sender);
    }

    /// @inheritdoc ISettlementWindow
    function flagOracleStalled(bytes32 groupId) external nonReentrant {
        SettlementStorage storage $ = _s();
        Group memory g = _group(groupId);
        GroupAccounting storage a = $.groups[groupId];
        uint64 stalledAfter = $.settlementOracle.stalledAfter(g.settlementOracleConfigId, g.expiry);
        if (a.finalized || block.timestamp < stalledAfter) revert OracleNotStalled(groupId, stalledAfter);
        if (a.stalledFlagged) return;
        a.stalledFlagged = true;
        emit OracleStalled(groupId, stalledAfter);
    }

    // ================================================================================================ settlement

    /// @inheritdoc ISettlementWindow
    function settleAccountGroup(uint256 accountId, bytes32 groupId) external nonReentrant {
        (Group memory g, GroupAccounting storage a) = _finalizedForSettle(groupId);
        if (_s().ledger.seriesCountInGroup(accountId, groupId) == 0) revert NotParticipant(accountId, groupId);
        _settle(accountId, groupId, g.settlementAsset, a);
    }

    /// @inheritdoc ISettlementWindow
    function settleAccountsGroup(uint256[] calldata accountIds, bytes32 groupId) external nonReentrant {
        (Group memory g, GroupAccounting storage a) = _finalizedForSettle(groupId);
        ISubAccounts ledger = _s().ledger;
        for (uint256 i; i < accountIds.length; ++i) {
            if (ledger.seriesCountInGroup(accountIds[i], groupId) == 0) continue; // already settled or never in
            _settle(accountIds[i], groupId, g.settlementAsset, a);
        }
    }

    /// @inheritdoc ISettlementWindow
    function computeRecoveryRatio(bytes32 groupId) external nonReentrant {
        SettlementStorage storage $ = _s();
        (Group memory g, GroupAccounting storage a) = _finalizedForSettle(groupId);
        if (a.ratioSet) revert RatioAlreadySet();
        uint256 left = $.ledger.participants(groupId);
        if (left != 0) revert SettlementIncomplete(left); // INV-28

        uint256 d = _denominator(g.settlementAsset);
        uint256 grossClaimN = a.wrapperClaimN + a.netCreditN; // netted claims only (MATH.md §13.1)
        uint256 grossClaim = M.divUp(grossClaimN, d);
        if (grossClaim > a.collected) {
            uint256 paid = $.insurance.cover(g.settlementAsset, grossClaim - a.collected); // into OptionClearing
            if (paid != 0) {
                (a.insurance, a.pool) = (paid, a.pool + paid);
                emit InsuranceCovered(groupId, g.settlementAsset, paid);
            }
        }
        uint256 ratio = WAD;
        if (grossClaimN != 0) {
            ratio = M.fullMulDiv(a.collected + a.insurance, d * WAD, grossClaimN); // rounded down
            if (ratio > WAD) ratio = WAD;
        }
        (a.ratioSet, a.ratioWad) = (true, ratio); // INV-29: once, the same for everyone
        emit RecoveryRatioSet(groupId, ratio, grossClaim, a.collected, a.insurance);
    }

    // =================================================================================================== payouts

    /// @inheritdoc ISettlementWindow
    function claimSettlement(uint256 accountId, bytes32 groupId) external nonReentrant {
        SettlementStorage storage $ = _s();
        (Group memory g, GroupAccounting storage a) = _redeemable(groupId);
        uint256 credit = $.creditN[accountId][groupId];
        if (credit == 0) revert NothingToClaim(); // INV-48: once
        $.creditN[accountId][groupId] = 0;
        a.unclaimedCredits -= 1;
        uint256 amount = M.fullMulDiv(credit, a.ratioWad, _denominator(g.settlementAsset) * WAD);
        a.pool -= amount; // INV-31: never negative (checked)
        if (amount != 0) $.ledger.addCash(accountId, amount); // pool → cash, both in OptionClearing custody
        emit SettlementClaimed(accountId, groupId, amount);
    }

    /// @inheritdoc ISettlementWindow
    function redeemWrapper(bytes32 seriesId, uint256 qty, address recipient) external nonReentrant {
        SettlementStorage storage $ = _s();
        if (qty == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        SeriesTerms memory t = $.registry.getSeries(seriesId); // reverts UnknownSeries
        (Group memory g, GroupAccounting storage a) = _redeemable($.registry.groupOf(seriesId));
        uint256 payout = _redeemPayout(t, qty, a, g.settlementAsset);
        IExternalOptionWrapper(t.wrapper).burn(msg.sender, qty);
        a.pool -= payout; // INV-31
        if (payout != 0) $.clearing.payOut(g.settlementAsset, recipient, payout);
        emit WrapperRedeemed(seriesId, msg.sender, recipient, qty, payout);
    }

    /// @inheritdoc ISettlementWindow
    function sweepDust(bytes32 groupId) external nonReentrant {
        SettlementStorage storage $ = _s();
        (Group memory g, GroupAccounting storage a) = _redeemable(groupId);
        if (a.unclaimedCredits != 0) revert PayoutsOutstanding(groupId);
        bytes32[] memory ids = $.registry.seriesInGroup(groupId);
        for (uint256 i; i < ids.length; ++i) {
            if (IERC20($.registry.getSeries(ids[i]).wrapper).totalSupply() != 0) revert PayoutsOutstanding(groupId);
        }
        uint256 dust = a.pool;
        a.pool = 0;
        if (dust != 0) $.clearing.payInsurance(g.settlementAsset, dust);
        emit DustSwept(groupId, dust);
    }

    // ===================================================================================================== views

    /// @inheritdoc ISettlementState
    function settlementPriceOf(bytes32 groupId) external view returns (bool finalized, uint256 priceWad) {
        GroupAccounting storage a = _s().groups[groupId];
        return (a.finalized, a.priceWad);
    }

    function groupState(bytes32 groupId) external view returns (GroupState) {
        SettlementStorage storage $ = _s();
        Group memory g = _group(groupId);
        GroupAccounting storage a = $.groups[groupId];
        if (a.ratioSet) return GroupState.REDEEMABLE;
        if (a.finalized) return $.ledger.participants(groupId) == 0 ? GroupState.ALL_SETTLED : GroupState.FINALIZED;
        if (block.timestamp < g.expiry) return GroupState.ACTIVE;
        if (block.timestamp >= $.settlementOracle.stalledAfter(g.settlementOracleConfigId, g.expiry)) {
            return GroupState.ORACLE_STALLED;
        }
        return GroupState.EXPIRED;
    }

    function isOracleStalled(bytes32 groupId) external view returns (bool) {
        SettlementStorage storage $ = _s();
        Group memory g = _group(groupId);
        return !$.groups[groupId].finalized
            && block.timestamp >= $.settlementOracle.stalledAfter(g.settlementOracleConfigId, g.expiry);
    }

    function groupAccounting(bytes32 groupId) external view returns (GroupAccounting memory) {
        return _s().groups[groupId];
    }

    function settlementPrice(bytes32 groupId) external view returns (uint256) {
        return _s().groups[groupId].priceWad;
    }

    function recoveryRatio(bytes32 groupId) external view returns (bool set, uint256 ratioWad) {
        GroupAccounting storage a = _s().groups[groupId];
        return (a.ratioSet, a.ratioWad);
    }

    /// @inheritdoc ISettlementWindow
    function previewSettle(uint256 accountId, bytes32 groupId)
        external
        view
        returns (int256 netNumerator, uint256 debt, uint256 collectable)
    {
        SettlementStorage storage $ = _s();
        Group memory g = _group(groupId);
        GroupAccounting storage a = $.groups[groupId];
        if (!a.finalized) revert GroupNotFinalized(groupId);
        netNumerator = _net($.ledger.positionsOf(accountId), groupId, a.priceWad);
        if (netNumerator < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            debt = M.divUp(uint256(-netNumerator), _denominator(g.settlementAsset));
            uint256 cash = $.ledger.cashOf(accountId);
            collectable = debt < cash ? debt : cash;
        }
    }

    /// @inheritdoc ISettlementWindow
    function previewRedeem(bytes32 seriesId, uint256 qty) external view returns (uint256 payout, bool ratioFixed) {
        SettlementStorage storage $ = _s();
        SeriesTerms memory t = $.registry.getSeries(seriesId);
        bytes32 groupId = $.registry.groupOf(seriesId);
        GroupAccounting storage a = $.groups[groupId];
        if (!a.finalized) revert GroupNotFinalized(groupId);
        payout = _redeemPayout(t, qty, a, t.settlementAsset);
        ratioFixed = a.ratioSet;
    }

    function creditOf(uint256 accountId, bytes32 groupId) external view returns (uint256) {
        return _s().creditN[accountId][groupId];
    }

    function wrapperSupplyAtFinalization(bytes32 seriesId) external view returns (uint256) {
        return _s().supplyAtFinalization[seriesId];
    }

    function modules() external view returns (Modules memory) {
        SettlementStorage storage $ = _s();
        return Modules({
            ledger: address($.ledger),
            registry: address($.registry),
            settlementOracle: address($.settlementOracle),
            fees: address($.fees),
            insurance: address($.insurance),
            clearing: address($.clearing)
        });
    }

    // ================================================================================================== internal

    /// @dev Caps the payoff price for the group's contract sizes (MATH.md §14), snapshots each wrapper supply
    ///      (INV-33) and sums the wrapper claims at the capped price.
    function _snapshot(bytes32 groupId, uint256 price) private returns (uint256 capped, uint256 wrapperClaimN) {
        SettlementStorage storage $ = _s();
        bytes32[] memory ids = $.registry.seriesInGroup(groupId);
        SeriesTerms[] memory terms = new SeriesTerms[](ids.length);
        capped = price;
        for (uint256 i; i < ids.length; ++i) {
            terms[i] = $.registry.getSeries(ids[i]);
            uint256 cap = MAX_UNIT_PAYOFF / terms[i].contractSizeWad;
            if (capped > cap) capped = cap;
        }
        for (uint256 i; i < ids.length; ++i) {
            uint256 supply = IERC20(terms[i].wrapper).totalSupply();
            $.supplyAtFinalization[ids[i]] = supply;
            wrapperClaimN += supply
                * _unitPayoff(terms[i].optionType, terms[i].strikeWad, terms[i].contractSizeWad, capped);
        }
    }

    /// @dev Nets the account's series in the group, zeroes them through the ledger (which decrements the participant
    ///      counter, INV-27), collects the debt or records the credit, and pays the caller the settle reward.
    function _settle(uint256 accountId, bytes32 groupId, address asset, GroupAccounting storage a) private {
        SettlementStorage storage $ = _s();
        Position[] memory ps = $.ledger.positionsOf(accountId);
        int256 net = _net(ps, groupId, a.priceWad);
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].series.groupId == groupId) $.ledger.applyDelta(accountId, ps[i].seriesId, -ps[i].balance);
        }
        uint256 collected;
        uint256 unpaid;
        if (net < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 debt = M.divUp(uint256(-net), _denominator(asset)); // debts round up
            uint256 cash = $.ledger.cashOf(accountId);
            collected = debt < cash ? debt : cash;
            unpaid = debt - collected;
            if (collected != 0) $.ledger.subCash(accountId, collected); // cash → pool, same custody
            (a.collected, a.pool, a.unpaid) = (a.collected + collected, a.pool + collected, a.unpaid + unpaid);
        } else if (net > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            $.creditN[accountId][groupId] = uint256(net);
            // forge-lint: disable-next-line(unsafe-typecast)
            (a.netCreditN, a.unclaimedCredits) = (a.netCreditN + uint256(net), a.unclaimedCredits + 1);
        }
        emit AccountSettled(accountId, groupId, net, collected, unpaid);
        $.fees.paySettleReward(asset, msg.sender, a.finalizedAt);
    }

    /// @dev Σ balance × intrinsic × CS over the account's series in the group (exact, 1e54 scale; fits in int256 by
    ///      the MATH.md §14 caps).
    function _net(Position[] memory ps, bytes32 groupId, uint256 price) private pure returns (int256 net) {
        for (uint256 i; i < ps.length; ++i) {
            LedgerSeries memory s = ps[i].series;
            if (s.groupId != groupId) continue;
            // forge-lint: disable-next-line(unsafe-typecast)
            net += ps[i].balance * int256(_unitPayoff(s.optionType, s.strikeWad, s.contractSizeWad, price));
        }
    }

    /// @dev floor(qty × intrinsic × CS × ratio / (D × 1e18)); ratio 1 until it is set (previews only).
    function _redeemPayout(SeriesTerms memory t, uint256 qty, GroupAccounting storage a, address asset)
        private
        view
        returns (uint256)
    {
        uint256 claimN = qty * _unitPayoff(t.optionType, t.strikeWad, t.contractSizeWad, a.priceWad);
        return M.fullMulDiv(claimN, a.ratioSet ? a.ratioWad : WAD, _denominator(asset) * WAD);
    }

    /// @dev intrinsic(price) × contract size, both WAD (≤ 1e50 after the per-group price cap).
    function _unitPayoff(OptionType optionType, uint256 strike, uint256 contractSize, uint256 price)
        private
        pure
        returns (uint256)
    {
        uint256 intrinsic;
        if (optionType == OptionType.CALL) intrinsic = price > strike ? price - strike : 0;
        else intrinsic = strike > price ? strike - price : 0;
        return intrinsic * contractSize;
    }

    function _finalizedForSettle(bytes32 groupId) private view returns (Group memory g, GroupAccounting storage a) {
        g = _group(groupId);
        _requireNotPaused(PauseBits.SETTLE, g.settlementAsset, _productId(g));
        a = _s().groups[groupId];
        if (!a.finalized) revert GroupNotFinalized(groupId);
    }

    function _redeemable(bytes32 groupId) private view returns (Group memory g, GroupAccounting storage a) {
        g = _group(groupId);
        _requireNotPaused(PauseBits.CLAIM_REDEEM, g.settlementAsset, _productId(g));
        a = _s().groups[groupId];
        if (!a.ratioSet) revert RatioNotSet(); // INV-28
    }

    function _group(bytes32 groupId) private view returns (Group memory g) {
        g = _s().registry.getGroup(groupId);
        if (g.expiry == 0) revert UnknownGroup(groupId);
    }

    function _productId(Group memory g) private view returns (bytes32) {
        return _s().registry.computeProductId(g.underlying, g.settlementAsset);
    }

    /// @dev D = 10^(54 − decimals): numerator → native units.
    function _denominator(address asset) private view returns (uint256) {
        return 10 ** (54 - uint256(_s().registry.settlementAssetDecimals(asset)));
    }

    function _s() private pure returns (SettlementStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
