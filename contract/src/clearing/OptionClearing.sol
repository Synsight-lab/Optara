// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {PauseBits} from "../governance/PauseBits.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IOptionClearing} from "../interfaces/IOptionClearing.sol";
import {ISubAccounts} from "../interfaces/ISubAccounts.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {IPortfolioRiskManager} from "../interfaces/IPortfolioRiskManager.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {ILiveSpotOracle} from "../interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../interfaces/IVolSurfaceOracle.sol";
import {IExternalOptionWrapper} from "../interfaces/IExternalOptionWrapper.sol";
import {ISettlementState} from "../interfaces/IExternalDependencies.sol";
import {OracleUpdate, OracleUpdates} from "../oracle/OracleUpdates.sol";
import {SeriesTerms} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    ZeroAmount,
    InvalidRecipient,
    NonExactTransfer,
    SeriesNotActive,
    GroupFinalized,
    InsuranceBelowMinimum,
    InsufficientShort,
    InsufficientLong,
    FeeTooHigh,
    RefundFailed
} from "../libraries/Errors.sol";

/// @title OptionClearing
/// @notice Collateral and position entry point (docs/PROTOCOL_SPEC.md §3–§4). Holds the settlement-asset tokens that
///         back every account's cash and every settlement pool (INV-7); only LiquidationModule and SettlementWindow
///         can move custody out other than by withdrawal, through `payInsurance` / `payOut`.
/// @dev Business rules (authorization, closing at most the short, finalization, health, fees) live here; accounting
///      rules (asset match, position limits, minimum quantity, totals) are enforced by the ledger on every write.
///      Risk-increasing calls apply their `OracleUpdate` and end with a STRICT health check, so they need fresh data;
///      deposits, unwraps and closes with wrappers need none (LIV-1).
contract OptionClearing is OptaraModule, IOptionClearing {
    using SafeERC20 for IERC20;
    using SafeCastLib for uint256;

    /// @custom:storage-location erc7201:optara.storage.OptionClearing
    struct ClearingStorage {
        ISubAccounts ledger;
        IOptionSeriesRegistry registry;
        IPortfolioRiskManager risk;
        IFeeController fees;
        IInsuranceFund insurance;
        ILiveSpotOracle spot;
        IVolSurfaceOracle surface;
        ISettlementState settlementState;
        address liquidationModule;
        address settlementWindow;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.OptionClearing")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xc7df4890a22998930b188ec0fab26942d302b411df836ac3f24dedb3367d6b00;

    function initialize(IProtocolControl control_, Modules calldata m) external initializer {
        __OptaraModule_init(control_);
        if (
            m.ledger == address(0) || m.registry == address(0) || m.risk == address(0) || m.fees == address(0)
                || m.insurance == address(0) || m.spot == address(0) || m.surface == address(0)
                || m.settlementState == address(0) || m.liquidationModule == address(0)
                || m.settlementWindow == address(0)
        ) revert ZeroAddress();
        ClearingStorage storage $ = _s();
        $.ledger = ISubAccounts(m.ledger);
        $.registry = IOptionSeriesRegistry(m.registry);
        $.risk = IPortfolioRiskManager(m.risk);
        $.fees = IFeeController(m.fees);
        $.insurance = IInsuranceFund(m.insurance);
        $.spot = ILiveSpotOracle(m.spot);
        $.surface = IVolSurfaceOracle(m.surface);
        $.settlementState = ISettlementState(m.settlementState);
        $.liquidationModule = m.liquidationModule;
        $.settlementWindow = m.settlementWindow;
    }

    // ================================================================================================ collateral

    /// @inheritdoc IOptionClearing
    function depositCollateral(uint256 accountId, uint256 amount) external nonReentrant {
        ClearingStorage storage $ = _s();
        address asset = $.ledger.settlementAssetOf(accountId); // reverts UnknownAccount
        _requireNotPaused(PauseBits.DEPOSIT, asset, 0);
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert NonExactTransfer(amount, received);
        $.ledger.addCash(accountId, amount);
        emit CollateralDeposited(accountId, msg.sender, amount);
    }

    /// @inheritdoc IOptionClearing
    function withdrawCollateral(uint256 accountId, uint256 amount, address recipient, OracleUpdate calldata u)
        external
        payable
        nonReentrant
    {
        ClearingStorage storage $ = _s();
        address asset = $.ledger.settlementAssetOf(accountId);
        _requireNotPaused(PauseBits.WITHDRAW, asset, 0);
        _requireAuthorized(accountId);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        uint256 feePaid = _applyUpdate(u);
        $.ledger.subCash(accountId, amount); // reverts InsufficientCash
        $.risk.requireHealthy(accountId); // with no positions this reads no oracle data
        IERC20(asset).safeTransfer(recipient, amount);
        emit CollateralWithdrawn(accountId, recipient, amount);
        _refund(feePaid);
    }

    // ================================================================================================= positions

    /// @inheritdoc IOptionClearing
    function mintExternalLong(
        uint256 accountId,
        bytes32 seriesId,
        uint256 qty,
        address recipient,
        uint256 maxSellerFeeNative,
        OracleUpdate calldata u
    ) external payable nonReentrant {
        ClearingStorage storage $ = _s();
        SeriesTerms memory t = $.registry.getSeries(seriesId); // reverts UnknownSeries
        // the registry requires volSurfaceProductId == the series' product id
        _requireNotPaused(PauseBits.MINT, t.settlementAsset, t.volSurfaceProductId);
        _requireAuthorized(accountId);
        if (qty == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (!$.fees.reservesHealthy(t.settlementAsset)) revert InsuranceBelowMinimum(t.settlementAsset);
        uint256 feePaid = _applyUpdate(u);

        // 1. the short (ledger: asset match, position limits, minimum quantity), then series/product/cap checks
        $.ledger.applyDelta(accountId, seriesId, -qty.toInt256());
        $.risk.checkOpenRisk(seriesId, true);
        // 2. the seller fee leaves before the health check, so it can never use up required margin
        uint256 fee = _chargeSellerFee(accountId, seriesId, t.settlementAsset, qty, maxSellerFeeNative);
        // 3. healthy after everything (STRICT: fresh spot and surface for every product held)
        $.risk.requireHealthy(accountId);
        // 4. the wrappers
        IExternalOptionWrapper(t.wrapper).mint(recipient, qty);
        emit ExternalLongMinted(accountId, seriesId, qty, recipient, fee);
        _refund(feePaid);
    }

    /// @inheritdoc IOptionClearing
    function wrapLong(uint256 accountId, bytes32 seriesId, uint256 qty, address recipient, OracleUpdate calldata u)
        external
        payable
        nonReentrant
    {
        ClearingStorage storage $ = _s();
        SeriesTerms memory t = $.registry.getSeries(seriesId);
        _requireNotPaused(PauseBits.WRAP, t.settlementAsset, t.volSurfaceProductId);
        _requireAuthorized(accountId);
        if (qty == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (block.timestamp >= t.expiry) revert SeriesNotActive(seriesId);
        int256 balance = $.ledger.balanceOf(accountId, seriesId);
        if (balance < qty.toInt256()) revert InsufficientLong(balance, qty);
        uint256 feePaid = _applyUpdate(u);
        $.ledger.applyDelta(accountId, seriesId, -qty.toInt256());
        $.risk.requireHealthy(accountId); // the long may have been a hedge
        IExternalOptionWrapper(t.wrapper).mint(recipient, qty);
        emit LongWrapped(accountId, seriesId, qty, recipient);
        _refund(feePaid);
    }

    /// @inheritdoc IOptionClearing
    function unwrapLong(uint256 accountId, bytes32 seriesId, uint256 qty) external nonReentrant {
        ClearingStorage storage $ = _s();
        SeriesTerms memory t = $.registry.getSeries(seriesId);
        _requireNotPaused(PauseBits.UNWRAP, t.settlementAsset, t.volSurfaceProductId);
        _requireAuthorized(accountId);
        if (qty == 0) revert ZeroAmount();
        if (block.timestamp >= t.expiry) revert SeriesNotActive(seriesId);
        IExternalOptionWrapper(t.wrapper).burn(msg.sender, qty);
        // adding a long never lowers health: no oracle data, no margin check (the ledger checks asset and limits)
        $.ledger.applyDelta(accountId, seriesId, qty.toInt256());
        emit LongUnwrapped(accountId, seriesId, qty, msg.sender);
    }

    /// @inheritdoc IOptionClearing
    function closeShortWithWrapper(uint256 accountId, bytes32 seriesId, uint256 qty) external nonReentrant {
        ClearingStorage storage $ = _s();
        SeriesTerms memory t = _closableSeries(seriesId);
        _requireAuthorized(accountId);
        if (qty == 0) revert ZeroAmount();
        int256 balance = $.ledger.balanceOf(accountId, seriesId);
        if (balance > -qty.toInt256()) revert InsufficientShort(balance, qty);
        IExternalOptionWrapper(t.wrapper).burn(msg.sender, qty);
        $.ledger.applyDelta(accountId, seriesId, qty.toInt256()); // reducing a short never lowers health
        emit ShortClosedWithWrapper(accountId, seriesId, qty);
    }

    /// @inheritdoc IOptionClearing
    function closeShortWithInternalLong(
        uint256 fromAccountId,
        uint256 toAccountId,
        bytes32 seriesId,
        uint256 qty,
        OracleUpdate calldata u
    ) external payable nonReentrant {
        ClearingStorage storage $ = _s();
        _closableSeries(seriesId);
        _requireAuthorized(fromAccountId);
        _requireAuthorized(toAccountId);
        if (qty == 0) revert ZeroAmount();
        int256 q = qty.toInt256();
        int256 fromBalance = $.ledger.balanceOf(fromAccountId, seriesId);
        if (fromBalance < q) revert InsufficientLong(fromBalance, qty);
        int256 toBalance = $.ledger.balanceOf(toAccountId, seriesId);
        if (toBalance > -q) revert InsufficientShort(toBalance, qty);
        uint256 feePaid = _applyUpdate(u);
        $.ledger.applyDelta(fromAccountId, seriesId, -q);
        $.ledger.applyDelta(toAccountId, seriesId, q); // the ledger rejects a different settlement asset
        $.risk.requireHealthy(fromAccountId); // the target only loses a short: its health never falls
        emit ShortClosedWithInternalLong(fromAccountId, toAccountId, seriesId, qty);
        _refund(feePaid);
    }

    /// @inheritdoc IOptionClearing
    function updateOracles(OracleUpdate calldata u) external payable nonReentrant {
        _refund(_applyUpdate(u));
    }

    // =================================================================================================== custody

    /// @inheritdoc IOptionClearing
    function payInsurance(address asset, uint256 amount) external nonReentrant {
        ClearingStorage storage $ = _s();
        if (msg.sender != $.liquidationModule && msg.sender != $.settlementWindow) revert NotAuthorized(msg.sender);
        if (amount == 0) return;
        IERC20(asset).safeTransfer(address($.insurance), amount);
        $.insurance.notifyDeposit(asset, amount);
    }

    /// @inheritdoc IOptionClearing
    function payOut(address asset, address to, uint256 amount) external nonReentrant {
        ClearingStorage storage $ = _s();
        if (msg.sender != $.settlementWindow) revert NotAuthorized(msg.sender);
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) return;
        IERC20(asset).safeTransfer(to, amount);
    }

    // ===================================================================================================== views

    /// @inheritdoc IOptionClearing
    function previewMint(uint256 accountId, bytes32 seriesId, uint256 qty)
        external
        view
        returns (uint256 fee, int256 equityAfter, uint256 imAfter, bool ok)
    {
        ClearingStorage storage $ = _s();
        SeriesTerms memory t = $.registry.getSeries(seriesId);
        fee = $.fees.previewSellerFee(seriesId, qty);
        IPortfolioRiskManager.Risk memory r =
            $.risk.previewWithDelta(accountId, seriesId, -qty.toInt256(), -fee.toInt256());
        (equityAfter, imAfter) = (r.equity, r.initialMargin);
        // forge-lint: disable-next-line(unsafe-typecast)
        bool healthy = equityAfter >= 0 && uint256(equityAfter) >= imAfter; // cast guarded by the sign check
        ok = healthy && r.fresh && block.timestamp < t.expiry && !$.risk.isProductCloseOnly(t.volSurfaceProductId)
            && $.ledger.cashOf(accountId) >= fee;
    }

    function modules() external view returns (Modules memory m) {
        ClearingStorage storage $ = _s();
        m = Modules({
            ledger: address($.ledger),
            registry: address($.registry),
            risk: address($.risk),
            fees: address($.fees),
            insurance: address($.insurance),
            spot: address($.spot),
            surface: address($.surface),
            settlementState: address($.settlementState),
            liquidationModule: $.liquidationModule,
            settlementWindow: $.settlementWindow
        });
    }

    // ================================================================================================== internal

    function _requireAuthorized(uint256 accountId) private view {
        if (!_s().ledger.isAuthorized(accountId, msg.sender)) revert NotAuthorized(msg.sender);
    }

    /// @dev Closes are allowed after expiry until the group is finalized; the CLOSE bit is checked here.
    function _closableSeries(bytes32 seriesId) private view returns (SeriesTerms memory t) {
        ClearingStorage storage $ = _s();
        t = $.registry.getSeries(seriesId);
        _requireNotPaused(PauseBits.CLOSE, t.settlementAsset, t.volSurfaceProductId);
        bytes32 groupId = $.registry.groupOf(seriesId);
        (bool finalized,) = $.settlementState.settlementPriceOf(groupId);
        if (finalized) revert GroupFinalized(groupId);
    }

    /// @dev Computes the seller fee, checks the user's maximum, debits it from cash and hands it to FeeController.
    function _chargeSellerFee(uint256 accountId, bytes32 seriesId, address asset, uint256 qty, uint256 maxFee)
        private
        returns (uint256 fee)
    {
        ClearingStorage storage $ = _s();
        fee = $.fees.previewSellerFee(seriesId, qty);
        if (fee > maxFee) revert FeeTooHigh(fee, maxFee);
        if (fee == 0) return 0;
        $.ledger.subCash(accountId, fee); // reverts InsufficientCash
        IERC20(asset).safeTransfer(address($.fees), fee);
        $.fees.notifySellerFee(accountId, seriesId, asset, fee);
    }

    function _applyUpdate(OracleUpdate calldata u) private returns (uint256 feePaid) {
        ClearingStorage storage $ = _s();
        return OracleUpdates.applyUpdate(u, $.spot, $.surface);
    }

    /// @dev Refunds `msg.value − feePaid` to the caller (last step of every payable entry point).
    function _refund(uint256 feePaid) private {
        uint256 refund = msg.value - feePaid;
        if (refund == 0) return;
        (bool success,) = msg.sender.call{value: refund}("");
        if (!success) revert RefundFailed();
    }

    function _s() private pure returns (ClearingStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
