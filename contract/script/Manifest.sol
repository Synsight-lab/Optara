// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {OptaraDeploy} from "./OptaraDeploy.sol";

/// @title Manifest
/// @notice Writes `deployments/<network>.json` (DEPLOYMENT.md §3): every proxy with its implementation, ProxyAdmin and
///         implementation code hash, the non-proxy contracts, the chain, the deployment block and the deployer. The
///         frontend, SDK, indexer and keepers read it; `script/export_abis.py` adds the ABIs.
abstract contract Manifest is Script, OptaraDeploy {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev `deployedAtBlock` is the block the script simulated against: a lower bound for indexers. A dry run writes
    ///      `<network>.dry-run.json` instead.
    function _writeManifest(string memory network, Deployment memory d, Config memory c, string memory extra)
        internal
        returns (string memory path)
    {
        string memory root = "manifest";
        vm.serializeString(root, "network", network);
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedAtBlock", block.number);
        vm.serializeAddress(root, "deployer", c.deployer);
        vm.serializeAddress(root, "upgradeAdmin", address(d.upgradeAdmin));
        vm.serializeAddress(root, "kuruAdapter", address(d.kuruAdapter));
        vm.serializeString(root, "roles", _roles(c));
        vm.serializeString(root, "proxies", _proxies(d));
        string memory json = vm.serializeString(root, "extra", bytes(extra).length == 0 ? "{}" : extra);
        // A dry run (no --broadcast) must not overwrite the real manifest with simulated addresses.
        string memory suffix = vm.isContext(VmSafe.ForgeContext.ScriptDryRun) ? ".dry-run.json" : ".json";
        path = string.concat(vm.projectRoot(), "/../deployments/", network, suffix);
        vm.writeJson(json, path);
    }

    /// @dev The configured role holders and parameters; `Verify.s.sol` checks them on-chain.
    function _roles(Config memory c) internal returns (string memory) {
        string memory k = "roles";
        vm.serializeAddress(k, "governance", c.governance);
        vm.serializeAddress(k, "guardian", c.guardian);
        vm.serializeAddress(k, "council", c.council);
        vm.serializeAddress(k, "riskAdmin", c.riskAdmin);
        vm.serializeAddress(k, "oracleAdmin", c.oracleAdmin);
        vm.serializeAddress(k, "seriesCreator", c.seriesCreator);
        vm.serializeAddress(k, "venueAdmin", c.venueAdmin);
        vm.serializeUint(k, "upgradeDelay", c.upgradeDelay);
        return vm.serializeUint(k, "emergencyDelay", c.emergencyDelay);
    }

    function _proxies(Deployment memory d) internal returns (string memory) {
        string memory k = "proxies";
        _proxy(k, "ProtocolControl", address(d.control), d);
        _proxy(k, "OptionSeriesRegistry", address(d.registry), d);
        _proxy(k, "ExternalOptionFactory", address(d.factory), d);
        _proxy(k, "SubAccounts", address(d.ledger), d);
        _proxy(k, "LiveSpotOracle", address(d.spot), d);
        _proxy(k, "VolSurfaceOracle", address(d.surface), d);
        _proxy(k, "SettlementOracle", address(d.settlementOracle), d);
        _proxy(k, "PortfolioRiskManager", address(d.risk), d);
        _proxy(k, "InsuranceFund", address(d.insurance), d);
        _proxy(k, "FeeController", address(d.fees), d);
        _proxy(k, "OptionClearing", address(d.clearing), d);
        _proxy(k, "LiquidationModule", address(d.liquidation), d);
        _proxy(k, "SettlementWindow", address(d.window), d);
        _proxy(k, "VenueRegistry", address(d.venues), d);
        return _proxy(k, "VenueRouter", address(d.router), d);
    }

    function _proxy(string memory parent, string memory name, address proxy, Deployment memory d)
        internal
        returns (string memory)
    {
        address impl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        vm.serializeAddress(name, "proxy", proxy);
        vm.serializeAddress(name, "implementation", impl);
        vm.serializeAddress(name, "proxyAdmin", d.upgradeAdmin.proxyAdminOf(proxy));
        string memory entry = vm.serializeBytes32(name, "implementationCodeHash", impl.codehash);
        return vm.serializeString(parent, name, entry);
    }
}
