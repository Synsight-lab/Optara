// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {FixedPoint} from "../risk/FixedPoint.sol";
import {OptionPricer} from "../risk/OptionPricer.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {IPortfolioRiskManager} from "../interfaces/IPortfolioRiskManager.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {IReserveStatus} from "../interfaces/IExternalDependencies.sol";
import {SeriesTerms} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    NonExactTransfer,
    InvalidFeeConfig,
    InsufficientTreasury,
    TokensNotReceived
} from "../libraries/Errors.sol";

/// @title FeeController
/// @notice Seller and buyer fees, the 60/30/10 split, treasury and keeper reserve, keeper rewards, and the reserve
///         minimums that gate new risk (docs/FEES.md, MATH.md §11).
/// @dev Tokens arrive by push-then-notify: OptionClearing / VenueRouter transfer the fee here, then call
///      `notify*Fee`, which checks the tokens are present before recording them. Recorded treasury + keeper reserve
///      never exceed the tokens held. Fees are never anyone's collateral after debit (INV-9).
contract FeeController is OptaraModule, IFeeController {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 1000; // hard cap, changing it needs an upgrade
    uint256 internal constant BPS = 10_000;
    uint256 public constant REWARD_ESCALATION_BPS_PER_HOUR = 2500; // +25% of base per hour
    uint256 public constant MAX_REWARD_MULTIPLE_BPS = 40_000; // capped at 4×

    // InvalidFeeConfig reasons
    uint8 internal constant FC_RATE = 1;
    uint8 internal constant FC_SPLIT = 2;
    uint8 internal constant FC_ADDRESS = 3;

    /// @custom:storage-location erc7201:optara.storage.FeeController
    struct FeeStorage {
        IInsuranceFund insurance;
        IPortfolioRiskManager risk;
        IOptionSeriesRegistry registry;
        address clearing;
        address router;
        address settlementWindow;
        uint16 sellerOpenFeeBps;
        uint16 buyerTradeFeeBps;
        Split split;
        mapping(address asset => AssetConfig) assets;
        mapping(address asset => uint256) treasury;
        mapping(address asset => uint256) keeperReserve;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.FeeController")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x3f8efbfa42f4a515fcf425f56c87f8660b89b94333fa8e8ac8ca47f03710f200;

    /// @dev Starts at the PARAMETERS.md §6 defaults: 300 / 300 bps, split 60 / 30 / 10.
    function initialize(
        IProtocolControl control_,
        IInsuranceFund insurance_,
        IPortfolioRiskManager risk_,
        IOptionSeriesRegistry registry_,
        address clearing_,
        address router_,
        address settlementWindow_
    ) external initializer {
        __OptaraModule_init(control_);
        if (
            address(insurance_) == address(0) || address(risk_) == address(0) || address(registry_) == address(0)
                || clearing_ == address(0) || router_ == address(0) || settlementWindow_ == address(0)
        ) revert ZeroAddress();
        FeeStorage storage $ = _s();
        $.insurance = insurance_;
        $.risk = risk_;
        $.registry = registry_;
        $.clearing = clearing_;
        $.router = router_;
        $.settlementWindow = settlementWindow_;
        _setFeeRates(300, 300);
        _setSplit(6000, 3000, 1000);
    }

    // ================================================================================================ collection

    /// @inheritdoc IFeeController
    function notifySellerFee(uint256 accountId, bytes32 seriesId, address asset, uint256 fee) external nonReentrant {
        if (msg.sender != _s().clearing) revert NotAuthorized(msg.sender);
        emit SellerFeeCharged(accountId, seriesId, asset, fee);
        _collect(asset, fee);
    }

    /// @inheritdoc IFeeController
    function notifyBuyerFee(address buyer, bytes32 seriesId, address asset, uint256 fee) external nonReentrant {
        if (msg.sender != _s().router) revert NotAuthorized(msg.sender);
        emit BuyerFeeCharged(buyer, seriesId, asset, fee);
        _collect(asset, fee);
    }

    /// @dev Checks the fee tokens arrived, then splits: insurance and keeper shares rounded down, the treasury takes
    ///      the remainder, so the parts always sum to the fee (INV-9).
    function _collect(address asset, uint256 fee) private {
        if (fee == 0) return;
        FeeStorage storage $ = _s();
        uint256 recorded = $.treasury[asset] + $.keeperReserve[asset];
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (held < recorded + fee) revert TokensNotReceived(fee, held - recorded);
        Split memory sp = $.split;
        uint256 toInsurance = fee * sp.insuranceBps / BPS;
        uint256 toKeeper = fee * sp.keeperBps / BPS;
        uint256 toTreasury = fee - toInsurance - toKeeper;
        $.treasury[asset] += toTreasury;
        $.keeperReserve[asset] += toKeeper;
        if (toInsurance != 0) {
            IERC20(asset).safeTransfer(address($.insurance), toInsurance);
            $.insurance.notifyDeposit(asset, toInsurance);
        }
        emit FeeSplit(asset, fee, toInsurance, toTreasury, toKeeper);
    }

    // ================================================================================================ keepers

    /// @inheritdoc IFeeController
    function fundKeeperReserve(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert NonExactTransfer(amount, received);
        _s().keeperReserve[asset] += amount;
        emit KeeperReserveFunded(asset, msg.sender, amount);
    }

    /// @inheritdoc IFeeController
    function payFinalizeReward(address asset, address keeper) external nonReentrant returns (uint256 paid) {
        if (msg.sender != _s().settlementWindow) revert NotAuthorized(msg.sender);
        paid = _payReward(asset, keeper, _s().assets[asset].finalizeRewardNative, true);
    }

    /// @inheritdoc IFeeController
    function paySettleReward(address asset, address keeper, uint64 finalizedAt)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (msg.sender != _s().settlementWindow) revert NotAuthorized(msg.sender);
        paid = _payReward(asset, keeper, settleRewardAt(asset, finalizedAt), false);
    }

    /// @dev Pays min(reward, reserve): rewards never exceed the reserve and drop to zero when it is empty (INV-37).
    function _payReward(address asset, address keeper, uint256 reward, bool finalize) private returns (uint256 paid) {
        FeeStorage storage $ = _s();
        uint256 reserve = $.keeperReserve[asset];
        paid = reward < reserve ? reward : reserve;
        if (paid == 0 || keeper == address(0)) return 0;
        $.keeperReserve[asset] = reserve - paid;
        IERC20(asset).safeTransfer(keeper, paid);
        emit KeeperRewardPaid(asset, keeper, paid, finalize);
    }

    // ================================================================================================ governance

    /// @notice Governance (timelocked). Each rate ≤ MAX_FEE_BPS.
    function setFeeRates(uint16 sellerBps, uint16 buyerBps) external onlyRole(Roles.GOVERNANCE) {
        _setFeeRates(sellerBps, buyerBps);
    }

    /// @notice Governance (timelocked). Shares sum to 10,000.
    function setSplit(uint16 insuranceBps, uint16 treasuryBps, uint16 keeperBps) external onlyRole(Roles.GOVERNANCE) {
        _setSplit(insuranceBps, treasuryBps, keeperBps);
    }

    function setMinSellerFee(address asset, uint256 minFee) external onlyRole(Roles.GOVERNANCE) {
        _s().assets[asset].minSellerFeeNative = minFee;
        emit MinSellerFeeSet(asset, minFee);
    }

    /// @notice Raising either minimum (risk-reducing) is instant for the risk admin, guardian or governance;
    ///         lowering either needs governance.
    function setMinimums(address asset, uint256 insuranceSeed, uint256 keeperMin) external {
        AssetConfig storage c = _s().assets[asset];
        if (insuranceSeed < c.minimumInsuranceSeed || keeperMin < c.minimumKeeperReserve) {
            _checkRole(Roles.GOVERNANCE);
        } else if (
            !_hasRole(Roles.GOVERNANCE, msg.sender) && !_hasRole(Roles.RISK_ADMIN, msg.sender)
                && !_hasRole(Roles.GUARDIAN, msg.sender)
        ) {
            revert NotAuthorized(msg.sender);
        }
        c.minimumInsuranceSeed = insuranceSeed;
        c.minimumKeeperReserve = keeperMin;
        emit MinimumsSet(asset, insuranceSeed, keeperMin);
    }

    function setRewards(address asset, uint256 finalizeReward, uint256 settleReward)
        external
        onlyRole(Roles.GOVERNANCE)
    {
        AssetConfig storage c = _s().assets[asset];
        c.finalizeRewardNative = finalizeReward;
        c.settleRewardNative = settleReward;
        emit RewardsSet(asset, finalizeReward, settleReward);
    }

    /// @notice Governance (timelocked). Only the treasury balance (INV-10).
    function withdrawTreasury(address asset, uint256 amount, address to) external onlyRole(Roles.GOVERNANCE) {
        if (to == address(0)) revert InvalidFeeConfig(FC_ADDRESS);
        FeeStorage storage $ = _s();
        uint256 t = $.treasury[asset];
        if (amount > t) revert InsufficientTreasury(amount, t);
        $.treasury[asset] = t - amount;
        IERC20(asset).safeTransfer(to, amount);
        emit TreasuryWithdrawn(asset, amount, to);
    }

    // ================================================================================================ views

    /// @inheritdoc IFeeController
    function previewSellerFee(bytes32 seriesId, uint256 qty) external view returns (uint256 fee) {
        FeeStorage storage $ = _s();
        SeriesTerms memory t = $.registry.getSeries(seriesId);
        (uint256 mid,,) = $.risk.priceOf(seriesId);
        // mark of the minted quantity at the mid IV, rounded down (MATH.md §11); legValue ≥ 0 for a long quantity
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 markWad = uint256(OptionPricer.legValue(SafeCastLib.toInt256(qty), t.contractSizeWad, mid));
        uint256 scale = FixedPoint.scale($.registry.settlementAssetDecimals(t.settlementAsset));
        fee = M.fullMulDivUp(markWad, $.sellerOpenFeeBps, BPS * scale);
        uint256 minFee = $.assets[t.settlementAsset].minSellerFeeNative;
        if (fee < minFee) fee = minFee;
    }

    /// @inheritdoc IFeeController
    function previewBuyerFee(uint256 premiumNative) external view returns (uint256) {
        return M.fullMulDivUp(premiumNative, _s().buyerTradeFeeBps, BPS);
    }

    /// @inheritdoc IFeeController
    function settleRewardAt(address asset, uint64 finalizedAt) public view returns (uint256) {
        uint256 base = _s().assets[asset].settleRewardNative;
        uint256 hoursSince = block.timestamp > finalizedAt ? (block.timestamp - finalizedAt) / 1 hours : 0;
        uint256 multiple = BPS + REWARD_ESCALATION_BPS_PER_HOUR * hoursSince;
        if (multiple > MAX_REWARD_MULTIPLE_BPS) multiple = MAX_REWARD_MULTIPLE_BPS;
        return base * multiple / BPS;
    }

    /// @inheritdoc IReserveStatus
    function reservesHealthy(address asset) external view returns (bool) {
        FeeStorage storage $ = _s();
        AssetConfig storage c = $.assets[asset];
        return
            $.insurance.balanceOf(asset) >= c.minimumInsuranceSeed && $.keeperReserve[asset] >= c.minimumKeeperReserve;
    }

    function treasury(address asset) external view returns (uint256) {
        return _s().treasury[asset];
    }

    function keeperReserve(address asset) external view returns (uint256) {
        return _s().keeperReserve[asset];
    }

    function insuranceBalance(address asset) external view returns (uint256) {
        return _s().insurance.balanceOf(asset);
    }

    function feeRates() external view returns (uint16, uint16) {
        return (_s().sellerOpenFeeBps, _s().buyerTradeFeeBps);
    }

    function split() external view returns (Split memory) {
        return _s().split;
    }

    function assetConfig(address asset) external view returns (AssetConfig memory) {
        return _s().assets[asset];
    }

    // ================================================================================================ internal

    function _setFeeRates(uint16 sellerBps, uint16 buyerBps) private {
        if (sellerBps > MAX_FEE_BPS || buyerBps > MAX_FEE_BPS) revert InvalidFeeConfig(FC_RATE);
        _s().sellerOpenFeeBps = sellerBps;
        _s().buyerTradeFeeBps = buyerBps;
        emit FeeRatesSet(sellerBps, buyerBps);
    }

    function _setSplit(uint16 insuranceBps, uint16 treasuryBps, uint16 keeperBps) private {
        if (uint256(insuranceBps) + treasuryBps + keeperBps != BPS) revert InvalidFeeConfig(FC_SPLIT);
        _s().split = Split(insuranceBps, treasuryBps, keeperBps);
        emit SplitSet(insuranceBps, treasuryBps, keeperBps);
    }

    function _s() private pure returns (FeeStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
