// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOptaraCore} from "../interfaces/IOptaraCore.sol";
import {IOptaraConfig} from "../interfaces/IOptaraConfig.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {OptionToken} from "../token/OptionToken.sol";
import {Series, SeriesBounds, OptionType, OracleConfig, PairStatus, Actions} from "../libraries/OptaraTypes.sol";
import {SeriesMetadata} from "./SeriesMetadata.sol";

/// @title SeriesFactory
/// @notice Validates and creates immutable option series (OPTION_SPEC.md sections 17-18, ARCHITECTURE.md section 6).
/// Each series gets its own OptionToken, deployed with CREATE2 salted by seriesId, so the token address is a pure
/// function of the series identity and never an input to it.
contract SeriesFactory {
    struct SeriesParams {
        address underlying;
        address settlementAsset;
        OptionType optionType;
        uint256 strikeWad;
        uint256 capWad;
        uint256 contractSizeWad;
        uint64 expiry;
        bytes32 oracleConfigId;
    }

    IOptaraCore public immutable core;
    IOptaraConfig public immutable config;
    IOracleRegistry public immutable oracleRegistry;

    error NotAuthorized(address caller);
    error ZeroAddress();
    error UnderlyingEqualsAsset();
    error UnderlyingNotApproved();
    error AssetNotApproved();
    error PairNotEnabled();
    error ZeroStrike();
    error ZeroCap();
    error ZeroContractSize();
    error PutCapAboveStrike();
    error OutOfBounds(string field);
    error InvalidExpiry();
    error OracleConfigNotApproved();
    error OracleConfigMismatch();
    error SeriesCreationPaused();
    error SeriesAlreadyExists(bytes32 seriesId);

    constructor(IOptaraCore core_, IOptaraConfig config_, IOracleRegistry oracleRegistry_) {
        if (address(core_) == address(0) || address(config_) == address(0) || address(oracleRegistry_) == address(0)) {
            revert ZeroAddress();
        }
        core = core_;
        config = config_;
        oracleRegistry = oracleRegistry_;
    }

    /// @notice Create a factory-validated series. SERIES_CREATOR_ROLE or governance (ACCESS_CONTROL.md section 31).
    function createSeries(SeriesParams calldata p) external returns (bytes32 seriesId, address optionToken) {
        if (
            !config.hasRole(config.SERIES_CREATOR_ROLE(), msg.sender)
                && !config.hasRole(config.GOVERNANCE_ROLE(), msg.sender)
        ) revert NotAuthorized(msg.sender);
        if (config.isPaused(Actions.SERIES_CREATION, p.settlementAsset, p.oracleConfigId)) {
            revert SeriesCreationPaused();
        }
        Series memory s = _validate(p);

        seriesId = core.computeSeriesId(
            p.underlying,
            p.settlementAsset,
            p.optionType,
            p.strikeWad,
            p.capWad,
            p.contractSizeWad,
            p.expiry,
            p.oracleConfigId
        );
        if (core.seriesExists(seriesId)) revert SeriesAlreadyExists(seriesId);
        s.groupId = core.computeGroupId(p.underlying, p.expiry, p.settlementAsset, p.oracleConfigId);

        (, string memory underlyingSymbol) = config.underlyingInfo(p.underlying);
        string memory assetSymbol = config.assetSymbol(p.settlementAsset);
        optionToken = address(
            new OptionToken{salt: seriesId}(
                SeriesMetadata.name(underlyingSymbol, assetSymbol, p.optionType, p.strikeWad, p.capWad, p.expiry),
                SeriesMetadata.symbol(underlyingSymbol, assetSymbol, p.optionType, p.strikeWad, p.capWad, p.expiry),
                seriesId,
                address(core)
            )
        );
        s.optionToken = optionToken;
        core.registerSeries(seriesId, s);
    }

    function _validate(SeriesParams calldata p) internal view returns (Series memory s) {
        if (p.underlying == address(0) || p.settlementAsset == address(0)) revert ZeroAddress();
        if (p.underlying == p.settlementAsset) revert UnderlyingEqualsAsset();
        (bool underlyingApproved,) = config.underlyingInfo(p.underlying);
        if (!underlyingApproved) revert UnderlyingNotApproved();
        (bool known, bool newRiskEnabled, uint8 decimals) = config.assetInfo(p.settlementAsset);
        if (!known || !newRiskEnabled) revert AssetNotApproved();
        bytes32 pairId = config.pairIdOf(p.underlying, p.settlementAsset);
        (PairStatus pairStatus,,) = config.pairInfo(pairId);
        if (pairStatus != PairStatus.ENABLED) revert PairNotEnabled();

        if (p.strikeWad == 0) revert ZeroStrike();
        if (p.capWad == 0) revert ZeroCap();
        if (p.contractSizeWad == 0) revert ZeroContractSize();
        if (p.optionType == OptionType.PUT && p.capWad > p.strikeWad) revert PutCapAboveStrike();

        SeriesBounds memory b = config.seriesBounds(pairId);
        if (p.strikeWad < b.minStrikeWad || p.strikeWad > b.maxStrikeWad) revert OutOfBounds("strike");
        if (p.capWad < b.minCapWad || p.capWad > b.maxCapWad) revert OutOfBounds("cap");
        if (p.contractSizeWad < b.minContractSizeWad || p.contractSizeWad > b.maxContractSizeWad) {
            revert OutOfBounds("contractSize");
        }
        // Bounds guarantee strike + cap <= MAX_PRICE_WAD, so the call's K + C critical price cannot overflow.

        if (p.expiry <= block.timestamp) revert InvalidExpiry();
        uint256 timeToExpiry = p.expiry - block.timestamp;
        if (timeToExpiry < b.minTimeToExpiry || timeToExpiry > b.maxTimeToExpiry) revert InvalidExpiry();

        if (!oracleRegistry.isApprovedForNewRisk(p.oracleConfigId)) revert OracleConfigNotApproved();
        OracleConfig memory oc = oracleRegistry.getConfig(p.oracleConfigId);
        if (oc.underlying != p.underlying || oc.settlementAsset != p.settlementAsset) revert OracleConfigMismatch();
        oracleRegistry.validateSeriesExpiry(p.oracleConfigId, p.expiry);

        s.underlying = p.underlying;
        s.settlementAsset = p.settlementAsset;
        s.expiry = p.expiry;
        s.optionType = p.optionType;
        s.assetDecimals = decimals;
        s.oracleConfigId = p.oracleConfigId;
        s.pairId = pairId;
        s.strikeWad = p.strikeWad;
        s.capWad = p.capWad;
        s.contractSizeWad = p.contractSizeWad;
        s.quantityIncrement = b.quantityIncrement;
    }
}
