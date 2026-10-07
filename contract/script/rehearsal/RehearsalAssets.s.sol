// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {MockERC20} from "../../test/mocks/MockDependencies.sol";
import {MockAggregator} from "../../test/mocks/MockAggregator.sol";

/// @title RehearsalAssets
/// @notice Fork rehearsal (`script/rehearse_fork.sh`), step 3: stand-in tokens and settlement feeds for an ETH/USDC
///         listing, and the listing file `deployments/config/<NETWORK>.eth-usdc.json` that `ProposeListing.s.sol`
///         reads. Spot is real: the listing uses Pyth's ETH/USD and USDC/USD feeds on the forked chain. Funds the
///         treasury (account 0) and the writer (account 5).
/// @dev Anvil fork only: the tokens and Chainlink-style feeds are mocks (the real ones are chosen at launch).
contract RehearsalAssets is Script {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    bytes32 internal constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    function run() external {
        string memory network = vm.envString("NETWORK");
        string memory dir = string.concat(vm.projectRoot(), "/../deployments/");
        address pyth = vm.parseJsonAddress(vm.readFile(string.concat(dir, "config/", network, ".json")), ".pyth");
        IPyth.Price memory eth = IPyth(pyth).getPriceUnsafe(PYTH_ETH_USD);

        vm.startBroadcast(vm.deriveKey(MNEMONIC, 0));
        MockERC20 weth = new MockERC20("Rehearsal WETH", "rWETH", 18);
        MockERC20 usdc = new MockERC20("Rehearsal USDC", "rUSDC", 6);
        MockAggregator ethUsd = new MockAggregator(8);
        MockAggregator usdcUsd = new MockAggregator(8);
        ethUsd.pushRound(_to8(eth), block.timestamp);
        usdcUsd.pushRound(1e8, block.timestamp);
        usdc.mint(vm.addr(vm.deriveKey(MNEMONIC, 0)), 11_000e6); // treasury: insurance seed + keeper reserve
        usdc.mint(vm.addr(vm.deriveKey(MNEMONIC, 5)), 100_000e6); // writer
        vm.stopBroadcast();

        vm.writeJson(
            _listing(address(weth), address(usdc), address(ethUsd), address(usdcUsd)),
            string.concat(dir, "config/", network, ".eth-usdc.json")
        );
    }

    function _to8(IPyth.Price memory p) internal pure returns (int256) {
        int256 v = p.price;
        for (int32 e = p.expo; e < -8; ++e) {
            v /= 10;
        }
        for (int32 e = p.expo; e > -8; --e) {
            v *= 10;
        }
        return v;
    }

    function _listing(address weth, address usdc, address ethUsd, address usdcUsd) internal returns (string memory) {
        string memory k = "listing";
        vm.serializeAddress(k, "underlying", weth);
        vm.serializeAddress(k, "asset", usdc);
        vm.serializeString(k, "underlyingSymbol", "ETH");
        vm.serializeString(k, "assetSymbol", "USDC");
        vm.serializeUint(k, "minStrikeWad", 100e18);
        vm.serializeUint(k, "maxStrikeWad", 1_000_000e18);
        vm.serializeUint(k, "maxReportLifetime", 900);
        vm.serializeString(k, "riskSet", "ETH/USDC default");
        vm.serializeUint(k, "shortCapUnderlyingWad", 10_000e18);
        vm.serializeBytes32(k, "pythBaseFeed", PYTH_ETH_USD);
        vm.serializeBytes32(k, "pythQuoteFeed", PYTH_USDC_USD);
        vm.serializeString(k, "settlement", _settlement(ethUsd, usdcUsd));
        address[] memory pubs = new address[](2);
        (pubs[0], pubs[1]) = (vm.addr(vm.deriveKey(MNEMONIC, 2)), vm.addr(vm.deriveKey(MNEMONIC, 3)));
        bool[] memory independent = new bool[](2);
        independent[0] = true;
        vm.serializeAddress(k, "publishers", pubs);
        vm.serializeBool(k, "independent", independent);
        vm.serializeUint(k, "minSellerFee", 0.1e6);
        vm.serializeUint(k, "insuranceSeed", 10_000e6);
        vm.serializeUint(k, "keeperReserveMin", 1_000e6);
        vm.serializeUint(k, "finalizeReward", 2e6);
        vm.serializeUint(k, "settleReward", 0.5e6);
        vm.serializeUint(k, "maxInsurancePerLiquidation", 5_000e6);
        vm.serializeBool(k, "approveAsset", true);
        return vm.serializeBool(k, "enableKuru", true);
    }

    function _settlement(address ethUsd, address usdcUsd) internal returns (string memory) {
        string memory p = "primary";
        vm.serializeString(p, "kind", "DERIVED");
        vm.serializeAddress(p, "feed", ethUsd);
        vm.serializeUint(p, "feedDecimals", 8);
        vm.serializeAddress(p, "quoteFeed", usdcUsd);
        string memory primary = vm.serializeUint(p, "quoteFeedDecimals", 8);
        string memory f = "fallback";
        string memory fallbackSource = vm.serializeString(f, "kind", "NONE");
        string memory s = "settlement";
        vm.serializeString(s, "primary", primary);
        vm.serializeString(s, "fallback", fallbackSource);
        vm.serializeInt(s, "observationStartOffset", -3600);
        vm.serializeInt(s, "observationEndOffset", 0);
        vm.serializeUint(s, "minFinalizationDelay", 300);
        vm.serializeUint(s, "maxFinalizationDelay", 7 days);
        return vm.serializeUint(s, "maxLegSkew", 3600);
    }
}
