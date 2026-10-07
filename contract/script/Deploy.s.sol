// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Manifest} from "./Manifest.sol";

/// @title Deploy
/// @notice Deploys Optara to a network from `deployments/config/<NETWORK>.json` and writes the manifest
///         `deployments/<NETWORK>.json` (DEPLOYMENT.md §2–§4). The broadcaster is `DEPLOYER_PRIVATE_KEY`; it ends
///         with no role. Listing products is a separate batch of role-holder calls: `script/ProposeListing.s.sol`.
/// @dev Dry run (no transactions): `NETWORK=monad-testnet forge script script/Deploy.s.sol --rpc-url <rpc>`.
///      Broadcast: add `--broadcast` (and `--verify` with the explorer settings). The script refuses a config whose
///      chain id differs from the RPC's, or any zero role address.
contract Deploy is Manifest {
    error WrongChain(uint256 config, uint256 actual);
    error MissingAddress(string key);

    function run() external returns (Deployment memory d) {
        string memory network = vm.envString("NETWORK");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/config/", network, ".json"));
        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        if (chainId != block.chainid) revert WrongChain(chainId, block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Config memory c = _config(json, deployer);
        vm.startBroadcast(pk);
        d = _deploy(c);
        vm.stopBroadcast();
        _writeManifest(network, d, c, "");
    }

    function _config(string memory json, address deployer) internal pure returns (Config memory c) {
        c.deployer = deployer;
        c.governance = _addr(json, "governance");
        c.guardian = _addr(json, "guardian");
        c.council = _addr(json, "council");
        c.riskAdmin = _addr(json, "riskAdmin");
        c.oracleAdmin = _addr(json, "oracleAdmin");
        c.seriesCreator = _addr(json, "seriesCreator");
        c.venueAdmin = _addr(json, "venueAdmin");
        c.pyth = _addr(json, "pyth");
        c.kuruRouter = vm.parseJsonAddress(json, ".kuruRouter"); // zero: no Kuru adapter on this network
        c.upgradeDelay = vm.parseJsonUint(json, ".upgradeDelay");
        c.emergencyDelay = vm.parseJsonUint(json, ".emergencyDelay");
        c.surfaceQuorum = vm.parseJsonUint(json, ".surfaceQuorum");
        c.maxSeriesPerAccount = vm.parseJsonUint(json, ".maxSeriesPerAccount");
        c.maxBucketsPerAccount = vm.parseJsonUint(json, ".maxBucketsPerAccount");
        c.minPositionQty = vm.parseJsonUint(json, ".minPositionQty");
    }

    function _addr(string memory json, string memory key) internal pure returns (address a) {
        a = vm.parseJsonAddress(json, string.concat(".", key));
        if (a == address(0)) revert MissingAddress(key);
    }
}
