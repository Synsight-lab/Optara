// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OptionSeriesRegistry} from "../src/series/OptionSeriesRegistry.sol";
import {PortfolioRiskManager} from "../src/risk/PortfolioRiskManager.sol";
import {VenueRegistry} from "../src/venues/VenueRegistry.sol";
import {OptionType, SeriesParams} from "../src/libraries/OptaraTypes.sol";

/// @dev Kuru's market factory: permissionless on Monad testnet, owner-gated on mainnet (Kuru deploys those books).
interface IKuruMarketFactory {
    function deployProxy(
        uint8 _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) external returns (address proxy);
}

/// @title RollSeries
/// @notice Lists a set of options for each product: every expiry in EXPIRIES × every strike (spot ± the
///         STRIKE_OFFSETS_BPS, rounded to the product's strike step) × call and put. Network differences are
///         settings, never code (`scripts/markets.sh` reads them from `deployments/config/<NETWORK>.markets.json`):
///           KURU_BOOKS=deploy   also deploy each option's Kuru book (wrapper / settlement asset) and register it
///                               (testnet, where Kuru's factory is permissionless);
///           KURU_BOOKS=none     options only; Kuru deploys the books, `markets.sh register` registers them (mainnet);
///           EXECUTION=direct    broadcast with ADMIN_PRIVATE_KEY (holds SERIES_CREATOR and VENUE_ADMIN);
///           EXECUTION=propose   broadcast nothing: simulate as the role holders and write the calls to
///                               `deployments/<NETWORK>.roll.proposals.json` for their multisigs.
///         Always writes `deployments/<NETWORK>.series.json` (series, option tokens and books).
/// @dev Inputs: NETWORK, PRODUCTS (listing names), SPOT_WAD_<i> (spot of product i, 1e18 settlement-asset units),
///      EXPIRIES (unix times), STRIKE_OFFSETS_BPS (e.g. -500,0,500), KURU_BOOKS, KURU_ROUTER (deploy only),
///      EXECUTION, ADMIN_PRIVATE_KEY (direct only).
contract RollSeries is Script {
    bytes32 internal constant KURU = keccak256("KURU");

    // Kuru book parameters: sizes to 1e-16 wrapper, minimum 0.01 and maximum 10,000 wrappers per order. The price grid
    // is per product (listing config kuruPricePrecision / kuruTickSize); the default, prices to 1e-4 of the settlement
    // asset with a 0.01 tick, suits options worth dollars (WETH). Cheap options (MON: fractions of a cent per token)
    // need a finer grid, e.g. precision 1e6 with tick 1 (0.000001).
    uint96 internal constant SIZE_PRECISION = 1e16;
    uint32 internal constant DEFAULT_PRICE_PRECISION = 1e4;
    uint32 internal constant DEFAULT_TICK_SIZE = 100;
    uint96 internal constant MIN_SIZE = 1e14;
    uint96 internal constant MAX_SIZE = 1e20;
    uint256 internal constant TAKER_FEE_BPS = 30;
    uint256 internal constant MAKER_FEE_BPS = 10;
    uint96 internal constant AMM_SPREAD = 100;

    struct Product {
        string listing;
        address underlying;
        address asset;
        bytes32 productId;
        bytes32 settlementConfigId;
        bytes32 riskSetId;
        uint256 spotWad;
        uint256 strikeStepWad;
        uint256 contractSizeWad;
        uint32 kuruPricePrecision;
        uint32 kuruTickSize;
    }

    OptionSeriesRegistry internal registry;
    PortfolioRiskManager internal risk;
    VenueRegistry internal venues;
    IKuruMarketFactory internal kuru;
    bool internal deployBooks;
    bool internal propose;
    address internal seriesCreator;
    address internal venueAdmin;
    string internal calls; // propose: JSON call objects
    uint256 internal nCalls;

    function run() external {
        string memory network = vm.envString("NETWORK");
        string memory dir = string.concat(vm.projectRoot(), "/../deployments/");
        string memory manifest = vm.readFile(string.concat(dir, network, ".json"));
        registry = OptionSeriesRegistry(vm.parseJsonAddress(manifest, ".proxies.OptionSeriesRegistry.proxy"));
        risk = PortfolioRiskManager(vm.parseJsonAddress(manifest, ".proxies.PortfolioRiskManager.proxy"));
        venues = VenueRegistry(vm.parseJsonAddress(manifest, ".proxies.VenueRegistry.proxy"));
        deployBooks = _is(vm.envString("KURU_BOOKS"), "deploy");
        propose = _is(vm.envString("EXECUTION"), "propose");
        if (deployBooks) kuru = IKuruMarketFactory(vm.envAddress("KURU_ROUTER"));
        seriesCreator = vm.parseJsonAddress(manifest, ".roles.seriesCreator");
        venueAdmin = vm.parseJsonAddress(manifest, ".roles.venueAdmin");
        require(!(propose && deployBooks), "propose mode cannot deploy Kuru books (Kuru deploys them on mainnet)");
        string[] memory listings = vm.envString("PRODUCTS", ",");
        uint256[] memory expiries = vm.envUint("EXPIRIES", ",");
        int256[] memory offsets = vm.envInt("STRIKE_OFFSETS_BPS", ",");

        string memory rows;
        uint256 n;
        if (!propose) vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        for (uint256 i; i < listings.length; ++i) {
            Product memory p = _product(dir, network, listings[i], i);
            uint256[] memory strikes = _strikes(p.spotWad, p.strikeStepWad, offsets);
            for (uint256 e; e < expiries.length; ++e) {
                for (uint256 k; k < strikes.length * 2; ++k) {
                    string memory row = _list(p, strikes[k / 2], uint64(expiries[e]), k % 2 == 0);
                    rows = n++ == 0 ? row : string.concat(rows, ",", row);
                }
            }
            console2.log("listed", listings[i], "spot (1e18):", p.spotWad);
        }
        if (!propose) vm.stopBroadcast();

        vm.writeFile(
            string.concat(dir, network, ".series.json"),
            string.concat('{"network":"', network, '","createdAt":', vm.toString(block.timestamp), ',"series":[', rows, "]}")
        );
        if (propose) {
            vm.writeFile(
                string.concat(dir, network, ".roll.proposals.json"),
                string.concat('{"network":"', network, '","calls":[', calls, "]}")
            );
            console2.log("proposal calls written (nothing sent):", nCalls);
        }
        console2.log("series listed:", n);
    }

    /// @dev One series: create it; with deployBooks, also deploy and register its Kuru book.
    function _list(Product memory p, uint256 strike, uint64 expiry, bool call) internal returns (string memory) {
        SeriesParams memory sp = SeriesParams({
            underlying: p.underlying,
            settlementAsset: p.asset,
            optionType: call ? OptionType.CALL : OptionType.PUT,
            strikeWad: strike,
            contractSizeWad: p.contractSizeWad,
            expiry: expiry,
            settlementOracleConfigId: p.settlementConfigId,
            volSurfaceProductId: p.productId,
            riskParameterSetId: p.riskSetId
        });
        if (propose) {
            _record(seriesCreator, "seriesCreator", address(registry), abi.encodeCall(OptionSeriesRegistry.createSeries, (sp)), "create series");
            vm.prank(seriesCreator); // simulate, so the series id and option token are known
        }
        bytes32 id = registry.createSeries(sp);
        address wrapper = registry.getSeries(id).wrapper;
        address market;
        if (deployBooks) {
            market = kuru.deployProxy(
                0, wrapper, p.asset, SIZE_PRECISION, p.kuruPricePrecision, p.kuruTickSize, MIN_SIZE, MAX_SIZE, TAKER_FEE_BPS, MAKER_FEE_BPS, AMM_SPREAD
            );
            venues.registerMarket(KURU, market, id, "");
        }
        return _row(p.listing, id, wrapper, market, call, strike, expiry);
    }

    function _record(address from, string memory role, address to, bytes memory data, string memory label) internal {
        string memory c = string.concat(
            '{"role":"', role, '","from":"', vm.toString(from), '","to":"', vm.toString(to), '","value":0,"data":"',
            vm.toString(data), '","label":"', label, '"}'
        );
        calls = nCalls++ == 0 ? c : string.concat(calls, ",", c);
    }

    function _product(string memory dir, string memory network, string memory listing, uint256 i)
        internal
        view
        returns (Product memory p)
    {
        string memory cfg = vm.readFile(string.concat(dir, "config/", network, ".", listing, ".json"));
        string memory props = vm.readFile(string.concat(dir, network, ".", listing, ".proposals.json"));
        p.listing = listing;
        p.underlying = vm.parseJsonAddress(cfg, ".underlying");
        p.asset = vm.parseJsonAddress(cfg, ".asset");
        p.strikeStepWad = vm.parseJsonUint(cfg, ".strikeStepWad");
        p.contractSizeWad = vm.parseJsonUint(cfg, ".contractSizeWad");
        // forge-lint: disable-next-line(unsafe-typecast)
        p.kuruPricePrecision = uint32(vm.keyExistsJson(cfg, ".kuruPricePrecision") ? vm.parseJsonUint(cfg, ".kuruPricePrecision") : DEFAULT_PRICE_PRECISION);
        // forge-lint: disable-next-line(unsafe-typecast)
        p.kuruTickSize = uint32(vm.keyExistsJson(cfg, ".kuruTickSize") ? vm.parseJsonUint(cfg, ".kuruTickSize") : DEFAULT_TICK_SIZE);
        p.productId = vm.parseJsonBytes32(props, ".productId");
        p.settlementConfigId = vm.parseJsonBytes32(props, ".settlementConfigId");
        p.riskSetId = risk.productRiskSet(p.productId);
        p.spotWad = vm.envUint(string.concat("SPOT_WAD_", vm.toString(i)));
        require(p.spotWad != 0 && p.strikeStepWad != 0, "spot or strike step missing");
    }

    /// @dev spot × (1 + offset), each rounded to the nearest step; kept positive, distinct and increasing.
    function _strikes(uint256 spot, uint256 step, int256[] memory offsetsBps) internal pure returns (uint256[] memory s) {
        s = new uint256[](offsetsBps.length);
        for (uint256 i; i < s.length; ++i) {
            int256 bps = 10_000 + offsetsBps[i];
            require(bps > 0, "strike offset below -100%");
            s[i] = _round(spot * uint256(bps) / 10_000, step);
            if (s[i] == 0) s[i] = step;
            if (i > 0 && s[i] <= s[i - 1]) s[i] = s[i - 1] + step;
        }
    }

    function _round(uint256 x, uint256 step) internal pure returns (uint256) {
        return (x + step / 2) / step * step;
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _row(string memory listing, bytes32 id, address wrapper, address market, bool call, uint256 strike, uint64 expiry)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"listing":"', listing,
            '","seriesId":"', vm.toString(id),
            '","wrapper":"', vm.toString(wrapper),
            '","kuruMarket":"', vm.toString(market),
            '","type":"', call ? "CALL" : "PUT",
            '","strikeWad":"', vm.toString(strike),
            '","expiry":', vm.toString(expiry), "}"
        );
    }
}
