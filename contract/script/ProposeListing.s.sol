// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {ListingCalls} from "./ListingCalls.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {UpgradeAdmin} from "../src/governance/UpgradeAdmin.sol";
import {OptionSeriesRegistry} from "../src/series/OptionSeriesRegistry.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {PortfolioRiskManager} from "../src/risk/PortfolioRiskManager.sol";
import {LiveSpotOracle} from "../src/oracle/LiveSpotOracle.sol";
import {VolSurfaceOracle} from "../src/oracle/VolSurfaceOracle.sol";
import {InsuranceFund} from "../src/insurance/InsuranceFund.sol";
import {FeeController} from "../src/fees/FeeController.sol";
import {LiquidationModule} from "../src/liquidation/LiquidationModule.sol";
import {VenueRegistry} from "../src/venues/VenueRegistry.sol";
import {KuruAdapter} from "../src/venues/kuru/KuruAdapter.sol";

/// @title ProposeListing
/// @notice Turns `deployments/config/<NETWORK>.<LISTING>.json` into the ordered calls that list the product
///         (DEPLOYMENT.md §3) and writes them, unsent, to `deployments/<NETWORK>.<LISTING>.proposals.json` for the
///         role holders to propose (governance batch through the parameter timelock; oracleAdmin, riskAdmin and
///         treasury from their multisigs). Execute in file order.
/// @dev `NETWORK=monad-testnet LISTING=eth-usdc forge script script/ProposeListing.s.sol --rpc-url <rpc>`. Reads the
///      deployment manifest and the chain (product and config ids); never broadcasts. Refuses zero addresses and a
///      zero insurance seed or keeper reserve minimum.
contract ProposeListing is Script, ListingCalls {
    error WrongChain(uint256 manifest, uint256 actual);
    error MissingAddress(string key);
    error MissingValue(string key);
    error UnknownFeedKind(string kind);

    string internal json;

    function run() external returns (string memory path) {
        string memory network = vm.envString("NETWORK");
        string memory listing = vm.envString("LISTING");
        string memory dir = string.concat(vm.projectRoot(), "/../deployments/");
        string memory manifest = vm.readFile(string.concat(dir, network, ".json"));
        uint256 chainId = vm.parseJsonUint(manifest, ".chainId");
        if (chainId != block.chainid) revert WrongChain(chainId, block.chainid);
        Deployment memory d = _fromManifest(manifest);

        json = vm.readFile(string.concat(dir, "config/", network, ".", listing, ".json"));
        ListingParams memory p = _params();
        Call[] memory batch = _listingCalls(d, p);
        Call[] memory seed = _seedCalls(d, p);

        string memory root = "proposals";
        vm.serializeString(root, "network", network);
        vm.serializeUint(root, "chainId", chainId);
        vm.serializeString(root, "listing", listing);
        vm.serializeBytes32(root, "productId", d.registry.computeProductId(p.underlying, p.asset));
        string memory head =
            vm.serializeBytes32(root, "settlementConfigId", d.settlementOracle.computeConfigId(p.settlement));
        path = string.concat(dir, network, ".", listing, ".proposals.json");
        vm.writeJson(_withArray(head, "calls", _encode(batch, seed)), path);
    }

    function _fromManifest(string memory m) internal pure returns (Deployment memory d) {
        d.upgradeAdmin = UpgradeAdmin(vm.parseJsonAddress(m, ".upgradeAdmin"));
        d.registry = OptionSeriesRegistry(_proxy(m, "OptionSeriesRegistry"));
        d.settlementOracle = SettlementOracle(_proxy(m, "SettlementOracle"));
        d.risk = PortfolioRiskManager(_proxy(m, "PortfolioRiskManager"));
        d.spot = LiveSpotOracle(_proxy(m, "LiveSpotOracle"));
        d.surface = VolSurfaceOracle(_proxy(m, "VolSurfaceOracle"));
        d.insurance = InsuranceFund(_proxy(m, "InsuranceFund"));
        d.fees = FeeController(_proxy(m, "FeeController"));
        d.liquidation = LiquidationModule(_proxy(m, "LiquidationModule"));
        d.venues = VenueRegistry(_proxy(m, "VenueRegistry"));
        d.kuruAdapter = KuruAdapter(vm.parseJsonAddress(m, ".kuruAdapter"));
    }

    function _proxy(string memory m, string memory name) internal pure returns (address) {
        return vm.parseJsonAddress(m, string.concat(".proxies.", name, ".proxy"));
    }

    // ------------------------------------------------------------------ listing file

    function _params() internal view returns (ListingParams memory p) {
        p.underlying = _addr(".underlying");
        p.asset = _addr(".asset");
        p.underlyingSymbol = vm.parseJsonString(json, ".underlyingSymbol");
        p.assetSymbol = vm.parseJsonString(json, ".assetSymbol");
        p.minStrikeWad = vm.parseJsonUint(json, ".minStrikeWad");
        p.maxStrikeWad = vm.parseJsonUint(json, ".maxStrikeWad");
        // forge-lint: disable-next-line(unsafe-typecast)
        p.maxReportLifetime = uint32(vm.parseJsonUint(json, ".maxReportLifetime")); // seconds; the oracle bounds it
        p.riskSetId = keccak256(bytes(vm.parseJsonString(json, ".riskSet")));
        p.shortCapUnderlyingWad = vm.parseJsonUint(json, ".shortCapUnderlyingWad");
        p.pythBaseFeed = vm.parseJsonBytes32(json, ".pythBaseFeed");
        p.pythQuoteFeed = vm.parseJsonBytes32(json, ".pythQuoteFeed");
        p.settlement = _settlement(p.underlying, p.asset);
        p.publishers = vm.parseJsonAddressArray(json, ".publishers");
        p.independent = vm.parseJsonBoolArray(json, ".independent");
        for (uint256 i; i < p.publishers.length; ++i) {
            if (p.publishers[i] == address(0)) revert MissingAddress("publishers");
        }
        if (p.publishers.length != p.independent.length) revert MissingAddress("independent");
        p.minSellerFee = vm.parseJsonUint(json, ".minSellerFee");
        p.insuranceSeed = _nonZero(".insuranceSeed"); // a zero minimum would pass the launch gate vacuously
        p.keeperReserveMin = _nonZero(".keeperReserveMin");
        p.finalizeReward = vm.parseJsonUint(json, ".finalizeReward");
        p.settleReward = vm.parseJsonUint(json, ".settleReward");
        p.maxInsurancePerLiquidation = vm.parseJsonUint(json, ".maxInsurancePerLiquidation");
        p.approveAsset = vm.parseJsonBool(json, ".approveAsset");
        p.enableKuru = vm.parseJsonBool(json, ".enableKuru");
    }

    /// @dev Signed offsets and delays are read as integers; out-of-range values are rejected by `registerConfig`.
    function _settlement(address underlying, address asset)
        internal
        view
        returns (ISettlementOracle.SettlementOracleConfig memory c)
    {
        c.underlying = underlying;
        c.settlementAsset = asset;
        c.primary = _feed(".settlement.primary");
        c.fallbackSource = _feed(".settlement.fallback");
        // forge-lint: disable-next-line(unsafe-typecast)
        c.observationStartOffset = int64(vm.parseJsonInt(json, ".settlement.observationStartOffset"));
        // forge-lint: disable-next-line(unsafe-typecast)
        c.observationEndOffset = int64(vm.parseJsonInt(json, ".settlement.observationEndOffset"));
        // forge-lint: disable-next-line(unsafe-typecast)
        c.minFinalizationDelay = uint64(vm.parseJsonUint(json, ".settlement.minFinalizationDelay"));
        // forge-lint: disable-next-line(unsafe-typecast)
        c.maxFinalizationDelay = uint64(vm.parseJsonUint(json, ".settlement.maxFinalizationDelay"));
        // forge-lint: disable-next-line(unsafe-typecast)
        c.maxLegSkew = uint32(vm.parseJsonUint(json, ".settlement.maxLegSkew"));
    }

    function _feed(string memory k) internal view returns (ISettlementOracle.FeedSource memory f) {
        string memory kind = vm.parseJsonString(json, string.concat(k, ".kind"));
        if (_is(kind, "NONE")) return f;
        if (_is(kind, "DIRECT")) f.kind = ISettlementOracle.FeedKind.DIRECT;
        else if (_is(kind, "DERIVED")) f.kind = ISettlementOracle.FeedKind.DERIVED;
        else revert UnknownFeedKind(kind);
        f.feed = _addr(string.concat(k, ".feed"));
        // forge-lint: disable-next-line(unsafe-typecast)
        f.feedDecimals = uint8(vm.parseJsonUint(json, string.concat(k, ".feedDecimals")));
        if (f.kind == ISettlementOracle.FeedKind.DERIVED) {
            f.quoteFeed = _addr(string.concat(k, ".quoteFeed"));
            // forge-lint: disable-next-line(unsafe-typecast)
            f.quoteFeedDecimals = uint8(vm.parseJsonUint(json, string.concat(k, ".quoteFeedDecimals")));
        }
    }

    function _addr(string memory key) internal view returns (address a) {
        a = vm.parseJsonAddress(json, key);
        if (a == address(0)) revert MissingAddress(key);
    }

    function _nonZero(string memory key) internal view returns (uint256 v) {
        v = vm.parseJsonUint(json, key);
        if (v == 0) revert MissingValue(key);
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ------------------------------------------------------------------ output

    /// @dev `vm.serialize*` embeds objects but turns arrays of objects into strings, so the array is spliced in.
    function _withArray(string memory obj, string memory key, string memory array)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(obj);
        assembly {
            mstore(b, sub(mload(b), 1)) // drop the closing brace
        }
        return string.concat(string(b), ",\"", key, "\":", array, "}");
    }

    function _encode(Call[] memory batch, Call[] memory seed) internal returns (string memory out) {
        out = "[";
        for (uint256 i; i < batch.length + seed.length; ++i) {
            Call memory c = i < batch.length ? batch[i] : seed[i - batch.length];
            string memory k = string.concat("call", vm.toString(i));
            vm.serializeUint(k, "step", i + 1);
            vm.serializeString(k, "role", c.role);
            vm.serializeAddress(k, "to", c.to);
            vm.serializeUint(k, "value", 0);
            vm.serializeBytes(k, "data", c.data);
            out = string.concat(out, i == 0 ? "" : ",", vm.serializeString(k, "label", c.label));
        }
        out = string.concat(out, "]");
    }
}
