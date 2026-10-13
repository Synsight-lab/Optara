// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OptaraDeploy} from "./OptaraDeploy.sol";
import {IPortfolioRiskManager} from "../src/interfaces/IPortfolioRiskManager.sol";
import {ILiveSpotOracle} from "../src/interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../src/interfaces/IVolSurfaceOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {OptionSeriesRegistry} from "../src/series/OptionSeriesRegistry.sol";
import {PortfolioRiskManager} from "../src/risk/PortfolioRiskManager.sol";
import {LiveSpotOracle} from "../src/oracle/LiveSpotOracle.sol";
import {VolSurfaceOracle} from "../src/oracle/VolSurfaceOracle.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {FeeController} from "../src/fees/FeeController.sol";
import {LiquidationModule} from "../src/liquidation/LiquidationModule.sol";
import {VenueRegistry} from "../src/venues/VenueRegistry.sol";
import {InsuranceFund} from "../src/insurance/InsuranceFund.sol";
import {ProductConfig} from "../src/libraries/OptaraTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ListingCalls
/// @notice The ordered role-holder calls that list a product (USER_FLOWS.md F18, DEPLOYMENT.md §3) with the
///         PARAMETERS.md defaults. On a real network they are proposed to the multisigs/timelock as a batch
///         (`ProposeListing.s.sol`); the local stack sends them directly (`LocalStack.s.sol`), which proves the batch.
abstract contract ListingCalls is OptaraDeploy {
    /// @param role Who must send it: "governance" (timelocked), "oracleAdmin", "riskAdmin" or "treasury".
    struct Call {
        string role;
        address to;
        bytes data;
        string label;
    }

    struct ListingParams {
        address underlying;
        address asset;
        string underlyingSymbol;
        string assetSymbol;
        uint256 minStrikeWad; // PARAMETERS.md §9 (ETH/USDC: 100 / 1,000,000)
        uint256 maxStrikeWad;
        uint32 maxReportLifetime; // PARAMETERS.md §4 (ETH, BTC: 900; MON: 300)
        bytes32 riskSetId;
        uint256 shortCapUnderlyingWad; // product short cap in underlying units (PARAMETERS.md §4)
        bytes32 pythBaseFeed; // DIRECT: underlying/asset; DERIVED: underlying/USD (RedStone: bytes32 of its feed name)
        bytes32 pythQuoteFeed; // DERIVED: asset/USD; zero for DIRECT (RedStone: bytes32 of its feed name)
        bool setFeeRates; // network config sets the protocol fee rates (else the deployment's stay)
        uint16 sellerFeeBps; // writer's open fee, of the minted mark
        uint16 buyerFeeBps; // buyer's fee, of the premium spent through the router
        bool redstoneSpot; // spot from RedStone pull feeds instead of Pyth
        address[] redstoneSigners; // RedStone signers the oracle accepts (redstoneSpot only)
        uint8 redstoneThreshold; // distinct signers a feed needs (redstoneSpot only)
        ISettlementOracle.SettlementOracleConfig settlement;
        address[] publishers;
        bool[] independent;
        uint256 minSellerFee; // native
        uint256 insuranceSeed; // native
        uint256 keeperReserveMin; // native
        uint256 finalizeReward; // native
        uint256 settleReward; // native
        uint256 maxInsurancePerLiquidation; // native
        bool approveAsset;
        bool enableKuru;
    }

    function _listingCalls(Deployment memory d, ListingParams memory p) internal view returns (Call[] memory calls) {
        bytes32 productId = d.registry.computeProductId(p.underlying, p.asset);
        bytes32 cfgId = d.settlementOracle.computeConfigId(p.settlement);
        calls = new Call[](17 + p.publishers.length);
        uint256 n;
        if (p.approveAsset) {
            calls[n++] = Call(
                "governance",
                address(d.registry),
                abi.encodeCall(OptionSeriesRegistry.setSettlementAssetApproved, (p.asset, true)),
                "approve settlement asset"
            );
        }
        calls[n++] = Call(
            "governance",
            address(d.registry),
            abi.encodeCall(OptionSeriesRegistry.approveProduct, (p.underlying, p.asset, _productConfig(p))),
            "approve product"
        );
        calls[n++] = Call(
            "governance",
            address(d.risk),
            abi.encodeCall(PortfolioRiskManager.createRiskSet, (p.riskSetId, defaultRiskParams())),
            "create risk set"
        );
        calls[n++] = Call(
            "governance",
            address(d.risk),
            abi.encodeCall(PortfolioRiskManager.assignProductRiskSet, (productId, p.riskSetId)),
            "assign risk set"
        );
        calls[n++] = Call(
            "governance",
            address(d.risk),
            abi.encodeCall(PortfolioRiskManager.setProductShortCap, (productId, p.shortCapUnderlyingWad)),
            "product short cap"
        );
        if (p.redstoneSpot) {
            calls[n++] = Call(
                "governance",
                address(d.spot),
                abi.encodeCall(LiveSpotOracle.setRedstoneSigners, (p.redstoneSigners, p.redstoneThreshold)),
                "RedStone signers"
            );
        }
        calls[n++] = Call(
            "governance",
            address(d.spot),
            abi.encodeCall(LiveSpotOracle.setSource, (productId, _spotSource(p))),
            "spot source"
        );
        calls[n++] = Call(
            "governance",
            address(d.surface),
            abi.encodeCall(VolSurfaceOracle.setSurfaceConfig, (productId, defaultSurfaceConfig(p.maxReportLifetime))),
            "surface config"
        );
        for (uint256 i; i < p.publishers.length; ++i) {
            // Publishers are global to the surface oracle: one an earlier listing added is already active.
            (bool active,) = d.surface.isPublisher(p.publishers[i]);
            if (active) continue;
            calls[n++] = Call(
                "governance",
                address(d.surface),
                abi.encodeCall(VolSurfaceOracle.addPublisher, (p.publishers[i], p.independent[i])),
                "add publisher"
            );
        }
        calls[n++] = Call(
            "oracleAdmin",
            address(d.settlementOracle),
            abi.encodeCall(SettlementOracle.registerConfig, (p.settlement)),
            "register settlement config"
        );
        calls[n++] = Call(
            "governance",
            address(d.settlementOracle),
            abi.encodeCall(SettlementOracle.setConfigApproved, (cfgId, true)),
            "approve settlement config"
        );
        if (p.setFeeRates) {
            calls[n++] = Call(
                "governance",
                address(d.fees),
                abi.encodeCall(FeeController.setFeeRates, (p.sellerFeeBps, p.buyerFeeBps)),
                "fee rates"
            );
        }
        calls[n++] = Call(
            "governance",
            address(d.fees),
            abi.encodeCall(FeeController.setMinSellerFee, (p.asset, p.minSellerFee)),
            "minimum seller fee"
        );
        calls[n++] = Call(
            "governance",
            address(d.fees),
            abi.encodeCall(FeeController.setRewards, (p.asset, p.finalizeReward, p.settleReward)),
            "keeper rewards"
        );
        calls[n++] = Call(
            "governance",
            address(d.liquidation),
            abi.encodeCall(LiquidationModule.setMaxInsurancePerLiquidation, (p.asset, p.maxInsurancePerLiquidation)),
            "max insurance per liquidation"
        );
        calls[n++] = Call(
            "riskAdmin",
            address(d.fees),
            abi.encodeCall(FeeController.setMinimums, (p.asset, p.insuranceSeed, p.keeperReserveMin)),
            "reserve minimums (new risk waits for the seed)"
        );
        if (p.enableKuru && address(d.kuruAdapter) != address(0)) {
            calls[n++] = Call(
                "governance",
                address(d.venues),
                abi.encodeCall(VenueRegistry.setAdapterEnabled, (d.kuruAdapter.VENUE_ID(), true)),
                "enable Kuru adapter"
            );
        }
        assembly {
            mstore(calls, n)
        }
    }

    /// @notice The treasury's deposits of the minimums `_listingCalls` sets. Until both are funded the asset's products
    ///         stay close-only (FEES.md §7), so these follow the batch. A zero amount (a listing that bootstraps its
    ///         reserves from fees) has nothing to deposit, and the deposit functions reject zero, so its pair is left out.
    function _seedCalls(Deployment memory d, ListingParams memory p) internal pure returns (Call[] memory calls) {
        calls = new Call[](4);
        uint256 n;
        if (p.insuranceSeed > 0) {
            calls[n++] = Call(
                "treasury",
                p.asset,
                abi.encodeCall(IERC20.approve, (address(d.insurance), p.insuranceSeed)),
                "approve insurance seed"
            );
            calls[n++] = Call(
                "treasury",
                address(d.insurance),
                abi.encodeCall(InsuranceFund.deposit, (p.asset, p.insuranceSeed)),
                "deposit insurance seed"
            );
        }
        if (p.keeperReserveMin > 0) {
            calls[n++] = Call(
                "treasury",
                p.asset,
                abi.encodeCall(IERC20.approve, (address(d.fees), p.keeperReserveMin)),
                "approve keeper reserve"
            );
            calls[n++] = Call(
                "treasury",
                address(d.fees),
                abi.encodeCall(FeeController.fundKeeperReserve, (p.asset, p.keeperReserveMin)),
                "fund keeper reserve"
            );
        }
        assembly {
            mstore(calls, n)
        }
    }

    // ------------------------------------------------------------------ PARAMETERS.md defaults

    function _productConfig(ListingParams memory p) internal pure returns (ProductConfig memory) {
        return ProductConfig({
            minStrikeWad: p.minStrikeWad,
            maxStrikeWad: p.maxStrikeWad,
            minContractSizeWad: 0.001e18,
            maxContractSizeWad: 100e18,
            minTimeToExpiry: 1 hours,
            maxTimeToExpiry: 400 days,
            maxSettlementPriceWad: 1e30,
            underlyingSymbol: p.underlyingSymbol,
            assetSymbol: p.assetSymbol
        });
    }

    function _spotSource(ListingParams memory p) internal pure returns (ILiveSpotOracle.SpotSource memory) {
        ILiveSpotOracle.SourceKind kind;
        if (p.redstoneSpot) {
            kind = p.pythQuoteFeed == 0 ? ILiveSpotOracle.SourceKind.REDSTONE_DIRECT : ILiveSpotOracle.SourceKind.REDSTONE_DERIVED;
        } else {
            kind = p.pythQuoteFeed == 0 ? ILiveSpotOracle.SourceKind.PYTH_DIRECT : ILiveSpotOracle.SourceKind.PYTH_DERIVED;
        }
        return ILiveSpotOracle.SpotSource({
            kind: kind,
            baseFeedId: p.pythBaseFeed,
            quoteFeedId: p.pythQuoteFeed,
            maxSpotAge: 60,
            maxConfidenceBps: 100
        });
    }

    /// @dev PARAMETERS.md §2–§3: 24 IM scenarios (8 spots × IV −30% / +75% / near-expiry) and 12 MM scenarios.
    function defaultRiskParams() public pure returns (IPortfolioRiskManager.RiskParams memory p) {
        int32[8] memory imSpots = [int32(-5000), -3000, -1500, 0, 1500, 3000, 5000, 10_000];
        int32[6] memory mmSpots = [int32(-3000), -1500, 0, 1500, 3000, 5000];
        p.initialSet = new IPortfolioRiskManager.Scenario[](24);
        for (uint256 i; i < 8; ++i) {
            p.initialSet[i] = IPortfolioRiskManager.Scenario(imSpots[i], -3000, 0, 0);
            p.initialSet[8 + i] = IPortfolioRiskManager.Scenario(imSpots[i], 7500, 0, 0);
            p.initialSet[16 + i] = IPortfolioRiskManager.Scenario(imSpots[i], 0, 1, 0);
        }
        p.maintenanceSet = new IPortfolioRiskManager.Scenario[](12);
        for (uint256 i; i < 6; ++i) {
            p.maintenanceSet[i] = IPortfolioRiskManager.Scenario(mmSpots[i], -3000, 0, 0);
            p.maintenanceSet[6 + i] = IPortfolioRiskManager.Scenario(mmSpots[i], 3000, 0, 0);
        }
        p.imBufferBps = 500;
        p.minIv = 0.1e18;
        p.maxIv = 5e18;
        p.nearExpiryFloorSeconds = 3600;
        p.maxOpenInterestPerSeries = 1e24;
    }

    /// @dev PARAMETERS.md §4 / ORACLES.md §3 (IV sanity bounds 10%–500%, matching the risk sets' minIv / maxIv).
    function defaultSurfaceConfig(uint32 maxReportLifetime)
        public
        pure
        returns (IVolSurfaceOracle.SurfaceConfig memory)
    {
        return IVolSurfaceOracle.SurfaceConfig({
            maxReportLifetime: maxReportLifetime,
            maxIvMoveBps: 2000,
            maxConfidenceBps: 1000,
            minIvBps: 1000,
            maxIvBps: 50_000,
            surfaceStaleAfter: 300,
            maxSurfaceStale: 21_600,
            staleIvPenaltyBpsPerHour: 1000,
            maxLongTimeValueStale: 1800
        });
    }
}
