// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {PauseBits} from "../governance/PauseBits.sol";
import {Roles} from "../governance/Roles.sol";
import {FixedPoint} from "../risk/FixedPoint.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {IPortfolioRiskManager} from "../interfaces/IPortfolioRiskManager.sol";
import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {IOptionClearing} from "../interfaces/IOptionClearing.sol";
import {ILiveSpotOracle} from "../interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../interfaces/IVolSurfaceOracle.sol";
import {IExternalOptionWrapper} from "../interfaces/IExternalOptionWrapper.sol";
import {OracleUpdate, OracleUpdates} from "../oracle/OracleUpdates.sol";
import {Position, SeriesTerms} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    AssetMismatch,
    SeriesNotActive,
    InsufficientShort,
    NotHealthy,
    NotLiquidatable,
    EmptyBucket,
    InvalidLiquidationParams,
    AuctionNotActive,
    AuctionActive,
    SliceOutOfBounds,
    HealthNotImproved,
    SlippageExceeded,
    RefundFailed
} from "../libraries/Errors.sol";

/// @title LiquidationModule
/// @notice Dutch-auction liquidation per risk bucket (docs/LIQUIDATION.md, MATH.md §12).
/// @dev Slice values come from the risk engine (DD-31): `sliceMark` = the account's equity drop from moving the legs
///      (before any cash moves) and `sliceMM` = its actual MM drop, both in LIQUIDATION mode (fresh spot; surface
///      fresh or within maxSurfaceStale with stale penalties, INV-45). The account's health must strictly improve
///      (INV-22) and the liquidator must cover its IM in the same mode (INV-23). Expired legs never move (INV-46).
contract LiquidationModule is OptaraModule, ILiquidationModule {
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    uint256 internal constant BPS = 10_000;
    uint32 public constant MAX_AUCTION_DURATION = 7 days;

    // InvalidLiquidationParams reasons
    uint8 internal constant LP_BONUS = 1; // startBonus > maxBonus, or maxBonus + penalty ≥ 10,000
    uint8 internal constant LP_DURATION = 2; // 0 or above MAX_AUCTION_DURATION
    uint8 internal constant LP_SLICE = 3; // 0 < minSlice ≤ maxSlice ≤ 10,000
    uint8 internal constant LP_TARGET = 4; // buffer ≤ 10,000

    uint8 internal constant END_HEALTHY = 0;
    uint8 internal constant END_EMPTY = 1;

    /// @custom:storage-location erc7201:optara.storage.LiquidationModule
    struct LiquidationStorage {
        ISubAccounts ledger;
        IOptionSeriesRegistry registry;
        IPortfolioRiskManager risk;
        IInsuranceFund insurance;
        IOptionClearing clearing;
        ILiveSpotOracle spot;
        IVolSurfaceOracle surface;
        LiquidationParams params;
        mapping(address asset => uint256) maxInsurance;
        mapping(uint256 accountId => mapping(address underlying => uint64)) auctions;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.LiquidationModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x9d2f6867212c048bb700c4f7fa2ada91429ae8c561ad8c30c8f9db86c2321b00;

    /// @dev Legs moved by a slice and the risk around them.
    struct Slice {
        address asset;
        uint256 scale; // WAD per native unit
        bytes32[] ids;
        int256[] moves; // signed quantity leaving the account per leg
        uint256 left; // unexpired legs of the bucket still non-zero after the slice
        uint256 bonusBps;
        IPortfolioRiskManager.Risk before;
        IPortfolioRiskManager.Risk afterPos; // after the moves, before any cash moves
        int256 sliceMark;
        uint256 sliceMM;
    }

    /// @dev Native-unit cash movements of one liquidation (MATH.md §12).
    struct Flows {
        uint256 fromAccount; // account → liquidator
        uint256 topUp; // insurance → liquidator
        uint256 unpaid; // owed to the liquidator but not paid
        uint256 fromLiquidator; // liquidator → account
        uint256 penalty; // account → insurance (reduced if cash runs out)
        uint256 discountWad;
    }

    /// @dev Defaults: PARAMETERS.md §5.
    function initialize(IProtocolControl control_, Modules calldata m) external initializer {
        __OptaraModule_init(control_);
        if (
            m.ledger == address(0) || m.registry == address(0) || m.risk == address(0) || m.insurance == address(0)
                || m.clearing == address(0) || m.spot == address(0) || m.surface == address(0)
        ) revert ZeroAddress();
        LiquidationStorage storage $ = _s();
        $.ledger = ISubAccounts(m.ledger);
        $.registry = IOptionSeriesRegistry(m.registry);
        $.risk = IPortfolioRiskManager(m.risk);
        $.insurance = IInsuranceFund(m.insurance);
        $.clearing = IOptionClearing(m.clearing);
        $.spot = ILiveSpotOracle(m.spot);
        $.surface = IVolSurfaceOracle(m.surface);
        _setParams(
            LiquidationParams({
                startBonusBps: 0,
                maxBonusBps: 1000,
                auctionDuration: 1800,
                minSliceBps: 500,
                maxSliceBps: 2500,
                targetHealthBufferBps: 500,
                liquidationPenaltyBps: 200
            })
        );
    }

    // ================================================================================================== auctions

    /// @inheritdoc ILiquidationModule
    function startAuction(uint256 accountId, address underlying, OracleUpdate calldata u)
        external
        payable
        nonReentrant
    {
        LiquidationStorage storage $ = _s();
        address asset = $.ledger.settlementAssetOf(accountId); // reverts UnknownAccount
        _requireNotPaused(PauseBits.LIQUIDATE, asset, $.registry.computeProductId(underlying, asset));
        if ($.auctions[accountId][underlying] != 0) revert AuctionActive();
        uint256 feePaid = _applyUpdate(u);
        if (_unexpiredLegs(accountId, underlying) == 0) revert EmptyBucket(accountId, underlying);
        IPortfolioRiskManager.Risk memory r = $.risk.riskForLiquidation(accountId);
        if (_covers(r.equity, r.maintenanceMargin)) revert NotLiquidatable(r.equity, r.maintenanceMargin);
        $.auctions[accountId][underlying] = uint64(block.timestamp);
        emit AuctionStarted(accountId, underlying, r.equity, r.maintenanceMargin, uint64(block.timestamp));
        _refund(feePaid);
    }

    /// @inheritdoc ILiquidationModule
    function liquidateSlice(
        uint256 accountId,
        address underlying,
        uint256 liquidatorAccountId,
        uint16 sliceBps,
        uint256 minCashToLiquidator,
        uint256 maxCashFromLiquidator,
        OracleUpdate calldata u
    ) external payable nonReentrant {
        Slice memory s = _beginSlice(accountId, underlying, liquidatorAccountId, sliceBps);
        uint256 feePaid = _applyUpdate(u);
        LiquidationStorage storage $ = _s();
        s.before = $.risk.riskForLiquidation(accountId);
        uint256 target = _target(s.before.initialMargin);
        if (_covers(s.before.equity, target)) revert NotLiquidatable(s.before.equity, target);

        // 1. move the legs; the ledger nets against the liquidator's opposite positions (INV-24) and checks limits
        _legs(accountId, underlying, sliceBps, s);
        for (uint256 i; i < s.ids.length; ++i) {
            $.ledger.applyDelta(accountId, s.ids[i], -s.moves[i]);
            $.ledger.applyDelta(liquidatorAccountId, s.ids[i], s.moves[i]);
        }
        s.afterPos = $.risk.riskForLiquidation(accountId);
        _measure(s);

        // 2. cash at mark value ± discount, then the penalty
        Flows memory f = _flows(s, $.ledger.cashOf(accountId), $.maxInsurance[s.asset]);
        _moveCash(accountId, liquidatorAccountId, s.asset, f);
        if (f.fromAccount + f.topUp < minCashToLiquidator || f.fromLiquidator > maxCashFromLiquidator) {
            revert SlippageExceeded();
        }

        // 3. the account improved (INV-22) and the liquidator carries its own margin (INV-23)
        int256 healthAfter = _healthAfter(s, f);
        _requireLiquidatorHealthy(liquidatorAccountId);
        int256 cashToLiquidator = (f.fromAccount + f.topUp).toInt256() - f.fromLiquidator.toInt256();
        emit SliceLiquidated(
            accountId,
            underlying,
            liquidatorAccountId,
            sliceBps,
            s.sliceMark,
            s.sliceMM,
            f.discountWad,
            f.penalty,
            cashToLiquidator
        );

        // 4. the auction ends by itself at the target or when nothing is left to move
        if (s.left == 0) {
            _end(accountId, underlying, END_EMPTY);
        } else if (_covers(healthAfter + s.afterPos.maintenanceMargin.toInt256(), _target(s.afterPos.initialMargin))) {
            _end(accountId, underlying, END_HEALTHY);
        }
        _refund(feePaid);
    }

    /// @inheritdoc ILiquidationModule
    function liquidateWithWrapper(
        uint256 accountId,
        bytes32 seriesId,
        uint256 qty,
        uint256 liquidatorAccountId,
        uint256 minCashToLiquidator,
        OracleUpdate calldata u
    ) external payable nonReentrant {
        LiquidationStorage storage $ = _s();
        Slice memory s;
        SeriesTerms memory t = $.registry.getSeries(seriesId); // reverts UnknownSeries
        _requireNotPaused(PauseBits.LIQUIDATE, t.settlementAsset, t.volSurfaceProductId);
        _checkLiquidator(accountId, liquidatorAccountId, t.settlementAsset);
        if (qty == 0) revert ZeroAmount();
        if (block.timestamp >= t.expiry) revert SeriesNotActive(seriesId);
        int256 balance = $.ledger.balanceOf(accountId, seriesId);
        if (balance > -qty.toInt256()) revert InsufficientShort(balance, qty);
        uint256 feePaid = _applyUpdate(u);
        s.before = $.risk.riskForLiquidation(accountId);
        if (_covers(s.before.equity, s.before.maintenanceMargin)) {
            revert NotLiquidatable(s.before.equity, s.before.maintenanceMargin);
        }
        s.asset = t.settlementAsset;
        s.scale = FixedPoint.scale($.registry.settlementAssetDecimals(t.settlementAsset));
        (s.bonusBps,) = _bonus($.auctions[accountId][t.underlying]);

        IExternalOptionWrapper(t.wrapper).burn(msg.sender, qty);
        $.ledger.applyDelta(accountId, seriesId, qty.toInt256());
        s.afterPos = $.risk.riskForLiquidation(accountId);
        _measure(s); // sliceMark = −(mark of the burned liability) ≤ 0; sliceMM = ΔMM > 0

        Flows memory f = _flows(s, $.ledger.cashOf(accountId), $.maxInsurance[s.asset]);
        _moveCash(accountId, liquidatorAccountId, s.asset, f);
        if (f.fromAccount + f.topUp < minCashToLiquidator) revert SlippageExceeded();
        _healthAfter(s, f);
        emit WrapperLiquidated(accountId, seriesId, qty, liquidatorAccountId, f.fromAccount + f.topUp, f.penalty);
        _refund(feePaid);
    }

    /// @inheritdoc ILiquidationModule
    function endAuction(uint256 accountId, address underlying, OracleUpdate calldata u) external payable nonReentrant {
        LiquidationStorage storage $ = _s();
        if ($.auctions[accountId][underlying] == 0) revert AuctionNotActive();
        uint256 feePaid = _applyUpdate(u);
        if (_unexpiredLegs(accountId, underlying) == 0) {
            _end(accountId, underlying, END_EMPTY);
        } else {
            IPortfolioRiskManager.Risk memory r = $.risk.riskForLiquidation(accountId);
            if (!_covers(r.equity, _target(r.initialMargin))) revert AuctionActive();
            _end(accountId, underlying, END_HEALTHY);
        }
        _refund(feePaid);
    }

    // ================================================================================================ governance

    /// @notice Governance (timelocked).
    function setLiquidationParams(LiquidationParams calldata params) external onlyRole(Roles.GOVERNANCE) {
        _setParams(params);
    }

    /// @notice Governance (timelocked). Native units of `asset`; 0 disables insurance top-ups for it.
    function setMaxInsurancePerLiquidation(address asset, uint256 amount) external onlyRole(Roles.GOVERNANCE) {
        _s().maxInsurance[asset] = amount;
        emit MaxInsurancePerLiquidationSet(asset, amount);
    }

    // ===================================================================================================== views

    /// @inheritdoc ILiquidationModule
    function previewSlice(uint256 accountId, address underlying, uint16 sliceBps)
        external
        view
        returns (int256 sliceMark, uint256 sliceMM, uint256 discount, uint256 penalty, int256 cashToLiquidator)
    {
        LiquidationStorage storage $ = _s();
        Slice memory s;
        s.asset = $.ledger.settlementAssetOf(accountId);
        s.scale = FixedPoint.scale($.registry.settlementAssetDecimals(s.asset));
        (s.bonusBps,) = _bonus($.auctions[accountId][underlying]);
        _legs(accountId, underlying, sliceBps, s);
        int256[] memory leaving = new int256[](s.moves.length);
        for (uint256 i; i < leaving.length; ++i) {
            leaving[i] = -s.moves[i];
        }
        s.before = $.risk.riskOf(accountId);
        s.afterPos = $.risk.previewWithDeltas(accountId, s.ids, leaving, 0);
        sliceMark = s.before.equity - s.afterPos.equity;
        sliceMM = s.before.maintenanceMargin > s.afterPos.maintenanceMargin
            ? s.before.maintenanceMargin - s.afterPos.maintenanceMargin
            : 0;
        (s.sliceMark, s.sliceMM) = (sliceMark, sliceMM);
        Flows memory f = _flows(s, $.ledger.cashOf(accountId), $.maxInsurance[s.asset]);
        (discount, penalty) = (f.discountWad, f.penalty);
        cashToLiquidator = (f.fromAccount + f.topUp).toInt256() - f.fromLiquidator.toInt256();
    }

    function auctionStart(uint256 accountId, address underlying) external view returns (uint64) {
        return _s().auctions[accountId][underlying];
    }

    function currentBonus(uint256 accountId, address underlying)
        external
        view
        returns (uint256 bonusBps, bool wholeBucket)
    {
        return _bonus(_s().auctions[accountId][underlying]);
    }

    function liquidationParams() external view returns (LiquidationParams memory) {
        return _s().params;
    }

    function maxInsurancePerLiquidation(address asset) external view returns (uint256) {
        return _s().maxInsurance[asset];
    }

    function modules() external view returns (Modules memory) {
        LiquidationStorage storage $ = _s();
        return Modules({
            ledger: address($.ledger),
            registry: address($.registry),
            risk: address($.risk),
            insurance: address($.insurance),
            clearing: address($.clearing),
            spot: address($.spot),
            surface: address($.surface)
        });
    }

    // ================================================================================================== internal

    /// @dev Checks for a slice that need no oracle data: pause, liquidator, auction, bounds.
    function _beginSlice(uint256 accountId, address underlying, uint256 liquidatorAccountId, uint16 sliceBps)
        private
        view
        returns (Slice memory s)
    {
        LiquidationStorage storage $ = _s();
        s.asset = $.ledger.settlementAssetOf(accountId);
        _requireNotPaused(PauseBits.LIQUIDATE, s.asset, $.registry.computeProductId(underlying, s.asset));
        _checkLiquidator(accountId, liquidatorAccountId, s.asset);
        uint64 start = $.auctions[accountId][underlying];
        if (start == 0) revert AuctionNotActive();
        bool wholeBucket;
        (s.bonusBps, wholeBucket) = _bonus(start);
        LiquidationParams storage p = $.params;
        if (sliceBps < p.minSliceBps || sliceBps > (wholeBucket ? BPS : p.maxSliceBps)) {
            revert SliceOutOfBounds(sliceBps);
        }
        s.scale = FixedPoint.scale($.registry.settlementAssetDecimals(s.asset));
    }

    /// @dev Caller operates the liquidator account; it is a different account in the same settlement asset.
    function _checkLiquidator(uint256 accountId, uint256 liquidatorAccountId, address asset) private view {
        LiquidationStorage storage $ = _s();
        if (!$.ledger.isAuthorized(liquidatorAccountId, msg.sender)) revert NotAuthorized(msg.sender);
        if (liquidatorAccountId == accountId) revert InvalidRecipient();
        if ($.ledger.settlementAssetOf(liquidatorAccountId) != asset) revert AssetMismatch();
    }

    /// @dev The unexpired legs of the bucket and the signed quantity of each that leaves the account:
    ///      |q| × sliceBps / 10,000 rounded down to a multiple of minPositionQty, with the sign of q.
    function _legs(uint256 accountId, address underlying, uint16 sliceBps, Slice memory s) private view {
        LiquidationStorage storage $ = _s();
        Position[] memory ps = $.ledger.positionsOf(accountId);
        uint256 minQ = $.ledger.minPositionQty();
        bytes32[] memory ids = new bytes32[](ps.length);
        int256[] memory moves = new int256[](ps.length);
        uint256 n;
        for (uint256 i; i < ps.length; ++i) {
            Position memory p = ps[i];
            if (p.series.underlying != underlying || block.timestamp >= p.series.expiry) continue;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 abs = p.balance < 0 ? uint256(-p.balance) : uint256(p.balance); // |balance| ≤ 1e24
            uint256 moved = abs * sliceBps / BPS / minQ * minQ;
            if (moved < abs) ++s.left;
            if (moved == 0) continue;
            ids[n] = p.seriesId;
            moves[n++] = p.balance < 0 ? -moved.toInt256() : moved.toInt256();
        }
        assembly {
            mstore(ids, n)
            mstore(moves, n)
        }
        (s.ids, s.moves) = (ids, moves);
    }

    function _unexpiredLegs(uint256 accountId, address underlying) private view returns (uint256 n) {
        Position[] memory ps = _s().ledger.positionsOf(accountId);
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].series.underlying == underlying && block.timestamp < ps[i].series.expiry) ++n;
        }
    }

    /// @dev sliceMark = equity drop from the moves (positions only: cash has not moved yet); sliceMM = MM drop > 0.
    function _measure(Slice memory s) private pure {
        s.sliceMark = s.before.equity - s.afterPos.equity;
        if (s.afterPos.maintenanceMargin >= s.before.maintenanceMargin) revert HealthNotImproved();
        s.sliceMM = s.before.maintenanceMargin - s.afterPos.maintenanceMargin;
    }

    /// @dev MATH.md §12. Debts to the liquidator and the penalty round up; payments from the liquidator round down
    ///      (INV-49). The liquidator is paid before the penalty; insurance tops up a shortfall up to the per-call
    ///      maximum and its balance (INV-25).
    function _flows(Slice memory s, uint256 cash, uint256 maxInsurance) private view returns (Flows memory f) {
        LiquidationParams storage p = _s().params;
        f.discountWad = M.fullMulDivUp(s.sliceMM, s.bonusBps, BPS);
        uint256 penaltyWad = M.fullMulDivUp(s.sliceMM, p.liquidationPenaltyBps, BPS);
        uint256 penaltyNative = M.divUp(penaltyWad, s.scale);
        uint256 left;
        if (s.sliceMark < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = M.divUp(uint256(-s.sliceMark) + f.discountWad, s.scale);
            f.fromAccount = owed < cash ? owed : cash;
            uint256 shortfall = owed - f.fromAccount;
            if (shortfall != 0) {
                uint256 available = _s().insurance.balanceOf(s.asset);
                uint256 cap = maxInsurance < available ? maxInsurance : available;
                f.topUp = shortfall < cap ? shortfall : cap;
                f.unpaid = shortfall - f.topUp;
            }
            left = cash - f.fromAccount;
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 markWad = uint256(s.sliceMark);
            f.fromLiquidator = markWad > f.discountWad ? (markWad - f.discountWad) / s.scale : 0;
            left = cash + f.fromLiquidator;
        }
        f.penalty = penaltyNative < left ? penaltyNative : left;
    }

    function _moveCash(uint256 accountId, uint256 liquidatorAccountId, address asset, Flows memory f) private {
        LiquidationStorage storage $ = _s();
        if (f.fromAccount != 0) {
            $.ledger.subCash(accountId, f.fromAccount);
            $.ledger.addCash(liquidatorAccountId, f.fromAccount);
        }
        if (f.fromLiquidator != 0) {
            $.ledger.subCash(liquidatorAccountId, f.fromLiquidator); // reverts InsufficientCash
            $.ledger.addCash(accountId, f.fromLiquidator);
        }
        if (f.topUp != 0) {
            $.insurance.cover(asset, f.topUp); // pays exactly topUp (≤ balance) into OptionClearing custody
            $.ledger.addCash(liquidatorAccountId, f.topUp);
        }
        if (f.topUp != 0 || f.unpaid != 0) emit BadDebtCovered(accountId, asset, f.topUp, f.unpaid);
        if (f.penalty != 0) {
            $.ledger.subCash(accountId, f.penalty);
            $.clearing.payInsurance(asset, f.penalty);
        }
    }

    /// @dev Requires the account's equity − MM to rise strictly (INV-22); returns it.
    function _healthAfter(Slice memory s, Flows memory f) private pure returns (int256 healthAfter) {
        int256 cashDelta = f.fromLiquidator.toInt256() - (f.fromAccount + f.penalty).toInt256();
        int256 equityAfter = s.afterPos.equity + cashDelta * s.scale.toInt256();
        healthAfter = equityAfter - s.afterPos.maintenanceMargin.toInt256();
        if (healthAfter <= s.before.equity - s.before.maintenanceMargin.toInt256()) revert HealthNotImproved();
    }

    function _requireLiquidatorHealthy(uint256 liquidatorAccountId) private view {
        IPortfolioRiskManager.Risk memory r = _s().risk.riskForLiquidation(liquidatorAccountId);
        if (!_covers(r.equity, r.initialMargin)) revert NotHealthy(r.equity, r.initialMargin);
    }

    /// @dev Linear from startBonusBps to maxBonusBps over auctionDuration, then flat; whole-bucket mode afterwards.
    ///      With no auction (start = 0) the bonus is startBonusBps.
    function _bonus(uint64 start) private view returns (uint256 bonusBps, bool wholeBucket) {
        LiquidationParams storage p = _s().params;
        if (start == 0) return (p.startBonusBps, false);
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= p.auctionDuration) return (p.maxBonusBps, true);
        bonusBps = p.startBonusBps + (uint256(p.maxBonusBps) - p.startBonusBps) * elapsed / p.auctionDuration;
    }

    /// @dev IM × (1 + targetHealthBufferBps), rounded up.
    function _target(uint256 initialMargin) private view returns (uint256) {
        return M.fullMulDivUp(initialMargin, BPS + _s().params.targetHealthBufferBps, BPS);
    }

    function _covers(int256 equity, uint256 requirement) private pure returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return equity >= 0 && uint256(equity) >= requirement; // cast guarded by the sign check
    }

    function _end(uint256 accountId, address underlying, uint8 reason) private {
        delete _s().auctions[accountId][underlying];
        emit AuctionEnded(accountId, underlying, reason);
    }

    function _setParams(LiquidationParams memory p) private {
        if (p.startBonusBps > p.maxBonusBps || uint256(p.maxBonusBps) + p.liquidationPenaltyBps >= BPS) {
            revert InvalidLiquidationParams(LP_BONUS);
        }
        if (p.auctionDuration == 0 || p.auctionDuration > MAX_AUCTION_DURATION) {
            revert InvalidLiquidationParams(LP_DURATION);
        }
        if (p.minSliceBps == 0 || p.minSliceBps > p.maxSliceBps || p.maxSliceBps > BPS) {
            revert InvalidLiquidationParams(LP_SLICE);
        }
        if (p.targetHealthBufferBps > BPS) revert InvalidLiquidationParams(LP_TARGET);
        _s().params = p;
        emit LiquidationParamsSet(p);
    }

    function _applyUpdate(OracleUpdate calldata u) private returns (uint256) {
        LiquidationStorage storage $ = _s();
        return OracleUpdates.applyUpdate(u, $.spot, $.surface);
    }

    function _refund(uint256 feePaid) private {
        uint256 refund = msg.value - feePaid;
        if (refund == 0) return;
        (bool success,) = msg.sender.call{value: refund}("");
        if (!success) revert RefundFailed();
    }

    function _s() private pure returns (LiquidationStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
