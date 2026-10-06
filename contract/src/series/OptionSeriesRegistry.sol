// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {PauseBits} from "../governance/PauseBits.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {IExternalOptionFactory} from "../interfaces/IExternalOptionFactory.sol";
import {ISettlementConfigs, IRiskSets} from "../interfaces/IExternalDependencies.sol";
import {SeriesNaming} from "./SeriesNaming.sol";
import {ProductStatus, ProductConfig, Product, SeriesParams, SeriesTerms, Group} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    NotAContract,
    UnknownSeries,
    AssetNotApproved,
    UnsupportedDecimals,
    InvalidProductConfig,
    ProductNotEnabled,
    InvalidSeriesParams,
    SeriesExists,
    GroupFull
} from "../libraries/Errors.sol";

/// @title OptionSeriesRegistry
/// @notice Approved settlement assets, products (underlying × settlement asset) with series bounds, and write-once
///         series terms (docs/OPTION_SPEC.md §2–§6, PROTOCOL_SPEC.md §2).
/// @dev Hard caps keep every settlement numerator q × intrinsic × CS (MATH.md §13) inside int256:
///      contract size × max settlement price ≤ 1e50, ≤ 256 series per group, open interest ≤ 1e24 per series
///      (risk parameters), so a group's gross claim numerator ≤ 256 × 1e24 × 1e50 = 2.56e76 < 5.79e76.
contract OptionSeriesRegistry is OptaraModule, IOptionSeriesRegistry {
    // ---- hard caps (changing them needs an upgrade) ----
    uint256 public constant MAX_NOTIONAL_WAD2 = 1e50; // maxContractSizeWad × maxSettlementPriceWad
    uint256 public constant MAX_SETTLEMENT_PRICE_WAD = 1e36;
    uint64 public constant MAX_TIME_TO_EXPIRY = 730 days;
    uint256 public constant MAX_SERIES_PER_GROUP = 256;
    uint256 public constant MAX_SYMBOL_LENGTH = 16;

    // ---- InvalidProductConfig reasons ----
    uint8 internal constant PC_ADDRESSES = 1;
    uint8 internal constant PC_STRIKE = 2;
    uint8 internal constant PC_CONTRACT_SIZE = 3;
    uint8 internal constant PC_TIME = 4;
    uint8 internal constant PC_SETTLEMENT_PRICE = 5;
    uint8 internal constant PC_SYMBOLS = 6;

    // ---- InvalidSeriesParams reasons ----
    uint8 internal constant SP_STRIKE = 1;
    uint8 internal constant SP_CONTRACT_SIZE = 2;
    uint8 internal constant SP_EXPIRY = 3;
    uint8 internal constant SP_SETTLEMENT_CONFIG = 4;
    uint8 internal constant SP_VOL_PRODUCT = 5;
    uint8 internal constant SP_RISK_SET = 6;

    bytes32 internal constant SERIES_TAG = keccak256("Optara.PM.Series");
    bytes32 internal constant GROUP_TAG = keccak256("Optara.PM.Group");
    bytes32 internal constant PRODUCT_TAG = keccak256("Optara.PM.Product");
    uint256 internal constant VERSION = 1;

    struct AssetInfo {
        bool approved;
        uint8 decimals;
    }

    /// @custom:storage-location erc7201:optara.storage.OptionSeriesRegistry
    struct RegistryStorage {
        IExternalOptionFactory factory;
        ISettlementConfigs settlementConfigs;
        IRiskSets riskSets;
        mapping(address asset => AssetInfo) assets;
        mapping(bytes32 productId => Product) products;
        mapping(bytes32 seriesId => SeriesTerms) series; // protected: written once
        mapping(bytes32 seriesId => bytes32) seriesGroup;
        mapping(bytes32 groupId => Group) groups;
        mapping(bytes32 groupId => bytes32[]) groupSeries;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.OptionSeriesRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x435ab850ba6fbcbb4ddad9da4cb5c8b5c5f14f7abcbe8bed47ec0d7523dc6600;

    /// @param factory_ ExternalOptionFactory. @param settlementConfigs_ SettlementOracle. @param riskSets_
    ///        PortfolioRiskManager. Addresses are fixed at deployment (known in advance; DEPLOYMENT.md §2).
    function initialize(
        IProtocolControl control_,
        IExternalOptionFactory factory_,
        ISettlementConfigs settlementConfigs_,
        IRiskSets riskSets_
    ) external initializer {
        __OptaraModule_init(control_);
        if (
            address(factory_) == address(0) || address(settlementConfigs_) == address(0)
                || address(riskSets_) == address(0)
        ) revert ZeroAddress();
        RegistryStorage storage $ = _s();
        $.factory = factory_;
        $.settlementConfigs = settlementConfigs_;
        $.riskSets = riskSets_;
    }

    // ------------------------------------------------------------------------------------------------- assets

    /// @notice Approving is governance (timelocked); revoking is also allowed for the guardian (risk-reducing).
    ///         Revoking blocks new subaccounts, products and series in that asset; existing positions run on.
    function setSettlementAssetApproved(address asset, bool approved) external {
        _requireGovernanceOr(approved ? bytes32(0) : Roles.GUARDIAN);
        uint8 decimals;
        if (approved) {
            if (asset.code.length == 0) revert NotAContract(asset);
            decimals = IERC20Metadata(asset).decimals();
            if (decimals > 18) revert UnsupportedDecimals(decimals);
        } else {
            decimals = _s().assets[asset].decimals;
        }
        _s().assets[asset] = AssetInfo({approved: approved, decimals: decimals});
        emit SettlementAssetApproved(asset, approved, decimals);
    }

    // ------------------------------------------------------------------------------------------------- products

    /// @notice Approve a product, or update the bounds of an existing one (bounds only affect new series).
    function approveProduct(address underlying, address settlementAsset, ProductConfig calldata config)
        external
        onlyRole(Roles.GOVERNANCE)
        returns (bytes32 productId)
    {
        if (underlying == address(0) || settlementAsset == address(0) || underlying == settlementAsset) {
            revert InvalidProductConfig(PC_ADDRESSES);
        }
        if (!_s().assets[settlementAsset].approved) revert AssetNotApproved(settlementAsset);
        _validateConfig(config);
        productId = computeProductId(underlying, settlementAsset);
        Product storage p = _s().products[productId];
        p.underlying = underlying;
        p.settlementAsset = settlementAsset;
        p.status = ProductStatus.ENABLED;
        p.config = config;
        emit ProductApproved(productId, underlying, settlementAsset, config);
        emit ProductEnabled(productId, true);
    }

    /// @notice Enabling is governance; disabling is also allowed for the guardian. A disabled product gets no new
    ///         series; existing series run to settlement.
    function setProductEnabled(bytes32 productId, bool enabled) external {
        _requireGovernanceOr(enabled ? bytes32(0) : Roles.GUARDIAN);
        Product storage p = _s().products[productId];
        if (p.status == ProductStatus.NONE) revert ProductNotEnabled(productId);
        p.status = enabled ? ProductStatus.ENABLED : ProductStatus.DISABLED;
        emit ProductEnabled(productId, enabled);
    }

    // ------------------------------------------------------------------------------------------------- series

    /// @inheritdoc IOptionSeriesRegistry
    function createSeries(SeriesParams calldata params)
        external
        nonReentrant
        onlyRole(Roles.SERIES_CREATOR)
        returns (bytes32 seriesId)
    {
        RegistryStorage storage $ = _s();
        bytes32 productId = computeProductId(params.underlying, params.settlementAsset);
        _requireNotPaused(PauseBits.SERIES_CREATE, params.settlementAsset, productId);

        Product storage product = $.products[productId];
        if (product.status != ProductStatus.ENABLED) revert ProductNotEnabled(productId);
        if (!$.assets[params.settlementAsset].approved) revert AssetNotApproved(params.settlementAsset);
        _validateSeries(params, product.config, productId);

        seriesId = computeSeriesId(params);
        if ($.series[seriesId].wrapper != address(0)) revert SeriesExists(seriesId);

        bytes32 groupId = _registerGroup(params);
        address wrapper = _deployWrapper(seriesId, product.config, params);
        _storeSeries(seriesId, groupId, wrapper, params);
    }

    // ------------------------------------------------------------------------------------------------- views

    function getSeries(bytes32 seriesId) external view returns (SeriesTerms memory terms) {
        terms = _s().series[seriesId];
        if (terms.wrapper == address(0)) revert UnknownSeries(seriesId);
    }

    function seriesExists(bytes32 seriesId) external view returns (bool) {
        return _s().series[seriesId].wrapper != address(0);
    }

    function groupOf(bytes32 seriesId) external view returns (bytes32 groupId) {
        groupId = _s().seriesGroup[seriesId];
        if (groupId == 0) revert UnknownSeries(seriesId);
    }

    function productOf(bytes32 seriesId) external view returns (bytes32) {
        SeriesTerms storage t = _s().series[seriesId];
        if (t.wrapper == address(0)) revert UnknownSeries(seriesId);
        return computeProductId(t.underlying, t.settlementAsset);
    }

    function seriesInGroup(bytes32 groupId) external view returns (bytes32[] memory) {
        return _s().groupSeries[groupId];
    }

    function getGroup(bytes32 groupId) external view returns (Group memory) {
        return _s().groups[groupId];
    }

    function getProduct(bytes32 productId) external view returns (Product memory) {
        return _s().products[productId];
    }

    function isProductEnabled(bytes32 productId) external view returns (bool) {
        return _s().products[productId].status == ProductStatus.ENABLED;
    }

    function isSettlementAssetApproved(address asset) external view returns (bool) {
        return _s().assets[asset].approved;
    }

    function settlementAssetDecimals(address asset) external view returns (uint8) {
        return _s().assets[asset].decimals;
    }

    /// @notice keccak256(abi.encode(keccak256("Optara.PM.Series"), chainId, registry, version)) (OPTION_SPEC.md §5).
    function seriesDomain() public view returns (bytes32) {
        return keccak256(abi.encode(SERIES_TAG, block.chainid, address(this), VERSION));
    }

    function computeSeriesId(SeriesParams calldata p) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                seriesDomain(),
                p.underlying,
                p.settlementAsset,
                p.optionType,
                p.strikeWad,
                p.contractSizeWad,
                p.expiry,
                p.settlementOracleConfigId,
                p.volSurfaceProductId
            )
        );
    }

    function computeGroupId(address underlying, address settlementAsset, uint64 expiry, bytes32 configId)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(GROUP_TAG, underlying, settlementAsset, expiry, configId));
    }

    function computeProductId(address underlying, address settlementAsset) public pure returns (bytes32) {
        return keccak256(abi.encode(PRODUCT_TAG, underlying, settlementAsset));
    }

    function factory() external view returns (address) {
        return address(_s().factory);
    }

    function settlementConfigs() external view returns (address) {
        return address(_s().settlementConfigs);
    }

    function riskSets() external view returns (address) {
        return address(_s().riskSets);
    }

    // ------------------------------------------------------------------------------------------------- internal

    /// @dev Creates the group on its first series; enforces MAX_SERIES_PER_GROUP.
    function _registerGroup(SeriesParams calldata p) private returns (bytes32 groupId) {
        RegistryStorage storage $ = _s();
        groupId = computeGroupId(p.underlying, p.settlementAsset, p.expiry, p.settlementOracleConfigId);
        uint256 count = $.groupSeries[groupId].length;
        if (count == 0) {
            $.groups[groupId] = Group({
                underlying: p.underlying,
                settlementAsset: p.settlementAsset,
                expiry: p.expiry,
                settlementOracleConfigId: p.settlementOracleConfigId
            });
            emit GroupCreated(groupId, p.underlying, p.settlementAsset, p.expiry, p.settlementOracleConfigId);
        } else if (count >= MAX_SERIES_PER_GROUP) {
            revert GroupFull(groupId);
        }
    }

    function _deployWrapper(bytes32 seriesId, ProductConfig storage c, SeriesParams calldata p)
        private
        returns (address)
    {
        string memory name = SeriesNaming.name(c.underlyingSymbol, c.assetSymbol, p.optionType, p.strikeWad, p.expiry);
        string memory symbol =
            SeriesNaming.symbol(c.underlyingSymbol, c.assetSymbol, p.optionType, p.strikeWad, p.expiry);
        return _s().factory.deployWrapper(seriesId, name, symbol);
    }

    /// @dev The only write of series terms (protected storage).
    function _storeSeries(bytes32 seriesId, bytes32 groupId, address wrapper, SeriesParams calldata p) private {
        RegistryStorage storage $ = _s();
        SeriesTerms storage t = $.series[seriesId];
        t.underlying = p.underlying;
        t.settlementAsset = p.settlementAsset;
        t.optionType = p.optionType;
        t.strikeWad = p.strikeWad;
        t.contractSizeWad = p.contractSizeWad;
        t.expiry = p.expiry;
        t.settlementOracleConfigId = p.settlementOracleConfigId;
        t.volSurfaceProductId = p.volSurfaceProductId;
        t.riskParameterSetId = p.riskParameterSetId;
        t.wrapper = wrapper;
        $.seriesGroup[seriesId] = groupId;
        $.groupSeries[groupId].push(seriesId);
        emit SeriesCreated(seriesId, groupId, wrapper, t);
    }

    /// @dev Governance always passes; `alsoAllowed` (0 = none) is the extra role for risk-reducing calls.
    function _requireGovernanceOr(bytes32 alsoAllowed) private view {
        if (_hasRole(Roles.GOVERNANCE, msg.sender)) return;
        if (alsoAllowed != 0 && _hasRole(alsoAllowed, msg.sender)) return;
        revert NotAuthorized(msg.sender);
    }

    function _validateConfig(ProductConfig calldata c) private pure {
        if (c.minStrikeWad == 0 || c.minStrikeWad > c.maxStrikeWad || c.maxStrikeWad > c.maxSettlementPriceWad) {
            revert InvalidProductConfig(PC_STRIKE);
        }
        if (c.minContractSizeWad == 0 || c.minContractSizeWad > c.maxContractSizeWad) {
            revert InvalidProductConfig(PC_CONTRACT_SIZE);
        }
        if (c.minTimeToExpiry == 0 || c.minTimeToExpiry > c.maxTimeToExpiry || c.maxTimeToExpiry > MAX_TIME_TO_EXPIRY) {
            revert InvalidProductConfig(PC_TIME);
        }
        // c.maxContractSizeWad ≤ MAX_NOTIONAL_WAD2 because maxSettlementPrice ≥ maxStrike ≥ 1, so no overflow here
        if (
            c.maxSettlementPriceWad > MAX_SETTLEMENT_PRICE_WAD
                || c.maxContractSizeWad > MAX_NOTIONAL_WAD2 / c.maxSettlementPriceWad
        ) revert InvalidProductConfig(PC_SETTLEMENT_PRICE);
        uint256 ul = bytes(c.underlyingSymbol).length;
        uint256 al = bytes(c.assetSymbol).length;
        if (ul == 0 || al == 0 || ul > MAX_SYMBOL_LENGTH || al > MAX_SYMBOL_LENGTH) {
            revert InvalidProductConfig(PC_SYMBOLS);
        }
    }

    function _validateSeries(SeriesParams calldata p, ProductConfig storage c, bytes32 productId) private view {
        if (p.strikeWad < c.minStrikeWad || p.strikeWad > c.maxStrikeWad) revert InvalidSeriesParams(SP_STRIKE);
        if (p.contractSizeWad < c.minContractSizeWad || p.contractSizeWad > c.maxContractSizeWad) {
            revert InvalidSeriesParams(SP_CONTRACT_SIZE);
        }
        if (p.expiry < block.timestamp + c.minTimeToExpiry || p.expiry > block.timestamp + c.maxTimeToExpiry) {
            revert InvalidSeriesParams(SP_EXPIRY);
        }
        RegistryStorage storage $ = _s();
        if (!$.settlementConfigs.isConfigUsable(p.settlementOracleConfigId, p.underlying, p.settlementAsset)) {
            revert InvalidSeriesParams(SP_SETTLEMENT_CONFIG);
        }
        if (p.volSurfaceProductId != productId) revert InvalidSeriesParams(SP_VOL_PRODUCT);
        if (!$.riskSets.isRiskSetForProduct(productId, p.riskParameterSetId)) revert InvalidSeriesParams(SP_RISK_SET);
    }

    function _s() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
