// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeAdmin} from "../src/governance/UpgradeAdmin.sol";
import {ProtocolControl} from "../src/governance/ProtocolControl.sol";
import {Roles} from "../src/governance/Roles.sol";

/// @title Verify
/// @notice Read-only post-deployment check of `deployments/<NETWORK>.json` against the chain (DEPLOYMENT.md §2 step
///         5–6, launch checklist): every proxy points at the recorded implementation with the recorded code hash, is
///         administered by its recorded ProxyAdmin owned by UpgradeAdmin; UpgradeAdmin and ProtocolControl hold the
///         recorded role holders and delays; the deployer holds nothing. Reverts on the first mismatch.
/// @dev `NETWORK=monad-testnet forge script script/Verify.s.sol --rpc-url <rpc>` (never broadcasts). ProtocolControl is
///      not enumerable: extra role holders are found from `RoleGranted` events (the indexer), not here.
contract Verify is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error Mismatch(string what, address expected, address actual);
    error WrongValue(string what, uint256 expected, uint256 actual);
    error CodeHashMismatch(string proxy, bytes32 expected, bytes32 actual);
    error RoleMissing(string role, address holder);
    error DeployerHoldsRole(bytes32 role);

    string internal json;

    function run() external {
        string memory network = vm.envString("NETWORK");
        json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/", network, ".json"));
        _eq("chainId", vm.parseJsonUint(json, ".chainId"), block.chainid);

        UpgradeAdmin ua = UpgradeAdmin(vm.parseJsonAddress(json, ".upgradeAdmin"));
        ProtocolControl control = ProtocolControl(_proxyOf("ProtocolControl"));
        _proxies(address(ua));
        _governance(ua, control);
        console.log("deployment %s verified: 15 proxies, roles, delays, deployer holds nothing", network);
    }

    function _proxies(address ua) internal view {
        string[15] memory names = [
            "ProtocolControl",
            "OptionSeriesRegistry",
            "ExternalOptionFactory",
            "SubAccounts",
            "LiveSpotOracle",
            "VolSurfaceOracle",
            "SettlementOracle",
            "PortfolioRiskManager",
            "InsuranceFund",
            "FeeController",
            "OptionClearing",
            "LiquidationModule",
            "SettlementWindow",
            "VenueRegistry",
            "VenueRouter"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory k = string.concat(".proxies.", names[i]);
            address proxy = vm.parseJsonAddress(json, string.concat(k, ".proxy"));
            address impl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
            address admin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
            _same(
                string.concat(names[i], " implementation"),
                vm.parseJsonAddress(json, string.concat(k, ".implementation")),
                impl
            );
            _same(
                string.concat(names[i], " proxy admin"),
                vm.parseJsonAddress(json, string.concat(k, ".proxyAdmin")),
                admin
            );
            _same(string.concat(names[i], " UpgradeAdmin record"), admin, UpgradeAdmin(ua).proxyAdminOf(proxy));
            _same(string.concat(names[i], " ProxyAdmin owner"), ua, Ownable(admin).owner());
            bytes32 hash = vm.parseJsonBytes32(json, string.concat(k, ".implementationCodeHash"));
            if (impl.codehash != hash) revert CodeHashMismatch(names[i], hash, impl.codehash);
        }
    }

    function _governance(UpgradeAdmin ua, ProtocolControl control) internal view {
        address deployer = vm.parseJsonAddress(json, ".deployer");
        _same("ProtocolControl.upgradeAdmin", address(ua), control.upgradeAdmin());
        _same("UpgradeAdmin.governance", _role("governance"), ua.governance());
        _same("UpgradeAdmin.emergencyCouncil", _role("council"), ua.emergencyCouncil());
        _same("UpgradeAdmin.deployer (renounced)", address(0), ua.deployer());
        _eq("upgradeDelay", vm.parseJsonUint(json, ".roles.upgradeDelay"), ua.upgradeDelay());
        _eq("emergencyDelay", vm.parseJsonUint(json, ".roles.emergencyDelay"), ua.emergencyDelay());

        bytes32[6] memory roles = [
            Roles.GOVERNANCE,
            Roles.GUARDIAN,
            Roles.RISK_ADMIN,
            Roles.ORACLE_ADMIN,
            Roles.SERIES_CREATOR,
            Roles.VENUE_ADMIN
        ];
        string[6] memory keys = ["governance", "guardian", "riskAdmin", "oracleAdmin", "seriesCreator", "venueAdmin"];
        for (uint256 i; i < 6; ++i) {
            address holder = _role(keys[i]);
            if (!control.hasRole(roles[i], holder)) revert RoleMissing(keys[i], holder);
            if (control.hasRole(roles[i], deployer)) revert DeployerHoldsRole(roles[i]);
        }
    }

    function _proxyOf(string memory name) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".proxies.", name, ".proxy"));
    }

    function _role(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".roles.", key));
    }

    function _same(string memory what, address expected, address actual) internal pure {
        if (expected != actual) revert Mismatch(what, expected, actual);
    }

    function _eq(string memory what, uint256 expected, uint256 actual) internal pure {
        if (expected != actual) revert WrongValue(what, expected, actual);
    }
}
