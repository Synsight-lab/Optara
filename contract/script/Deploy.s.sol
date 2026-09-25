// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {OptaraConfig} from "../src/config/OptaraConfig.sol";
import {OracleRegistry} from "../src/oracle/OracleRegistry.sol";
import {ChainlinkSettlementAdapter} from "../src/oracle/ChainlinkSettlementAdapter.sol";
import {OptaraCore} from "../src/core/OptaraCore.sol";
import {SeriesFactory} from "../src/factory/SeriesFactory.sol";
import {SeriesBounds, OracleConfig, ExposureScope, Actions} from "../src/libraries/OptaraTypes.sol";

/// @title Deploy
/// @notice Config-driven Optara V2 deployment (DEPLOYMENT.md sections 5, 20-30, 81-84).
///
/// Usage: OPTARA_DEPLOY_CONFIG=deploy/staging.json forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
///
/// Rules enforced here:
/// - the config's chainId must equal the connected chain (DEPLOY-TEST-003);
/// - every critical value must be present; missing or malformed values abort (no silent defaults, section 84);
/// - the deployer only holds governance while configuring, then hands it to the final governance
///   (a TimelockController when governance.mode == "timelock") and renounces (sections 25, 30);
/// - the core is sealed to its factory before any risk can exist (ACCESS_CONTROL.md section 44);
/// - the deployment ends in SAFE MODE (sections 24, 58, 66 phase 0): writes and series creation are paused globally,
///   so no one can create risk until the deployment is verified and the unpauser or governance activates it with
///   config.unpause(GLOBAL_SCOPE, SAFE_MODE_BITS);
/// - the manifest (deployments/<network>.json) contains addresses, roles, ids and limits, never secrets.
contract Deploy is Script {
    struct Deployment {
        OptaraConfig config;
        OracleRegistry registry;
        ChainlinkSettlementAdapter adapter;
        OptaraCore core;
        SeriesFactory factory;
        address governance;
        address timelock;
        bytes32[] oracleConfigIds;
        bytes32[] pairIds;
    }

    /// @notice Actions paused at deployment until explicit activation (DEPLOYMENT.md sections 24, 58).
    uint256 public constant SAFE_MODE_BITS = Actions.WRITE | Actions.SERIES_CREATION;

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error InvalidDeployConfig(string reason);

    function run() external virtual returns (Deployment memory d) {
        string memory path = vm.envString("OPTARA_DEPLOY_CONFIG");
        string memory json = vm.readFile(path);
        d = deploy(json, true);
        writeManifest(json, d);
    }

    /// @param broadcast true for real deployments (signer from the CLI); false inside tests.
    function deploy(string memory json, bool broadcast) public returns (Deployment memory d) {
        uint256 expectedChain = vm.parseJsonUint(json, ".chainId");
        if (expectedChain != block.chainid) revert ChainIdMismatch(expectedChain, block.chainid);

        address deployer;
        if (broadcast) {
            vm.startBroadcast();
            (, deployer,) = vm.readCallers();
        } else {
            deployer = address(this);
        }

        // 1-2: roles/config plumbing with the deployer as temporary governance
        d.config = new OptaraConfig(deployer);
        d.registry = new OracleRegistry(d.config);
        d.adapter = new ChainlinkSettlementAdapter(d.registry);
        d.core = new OptaraCore(d.config, d.registry, uint64(vm.parseJsonUint(json, ".shortfallResolutionDelay")));
        d.factory = new SeriesFactory(d.core, d.config, d.registry);
        d.core.bindSeriesFactory(address(d.factory));

        _grantOperationalRoles(json, d.config);
        d.config
            .setPositionLimits(
                uint32(vm.parseJsonUint(json, ".positionLimits.maxSeriesPerGroup")),
                uint32(vm.parseJsonUint(json, ".positionLimits.maxGroupsPerAccount")),
                uint32(vm.parseJsonUint(json, ".positionLimits.maxSeriesPerAccount"))
            );
        _configureAssets(json, d.config);
        _configureUnderlyings(json, d.config);
        d.pairIds = _configurePairs(json, d.config);
        d.oracleConfigIds = _configureOracles(json, d);

        // Initial safe mode: nothing can create risk before verification and explicit activation.
        d.config.pause(d.config.GLOBAL_SCOPE(), SAFE_MODE_BITS);

        // Final governance handover (sections 25-26, 29-30).
        (d.governance, d.timelock) = _finalGovernance(json);
        bytes32 gov = d.config.GOVERNANCE_ROLE();
        d.config.grantRole(gov, d.governance);
        d.config.renounceRole(gov, deployer);

        if (broadcast) vm.stopBroadcast();
        verify(json, d, deployer);
    }

    // ---------------------------------------------------------------------------------------------
    // Configuration steps
    // ---------------------------------------------------------------------------------------------

    function _grantOperationalRoles(string memory json, OptaraConfig c) internal {
        c.grantRole(c.PAUSER_ROLE(), _addr(json, ".roles.pauser"));
        c.grantRole(c.UNPAUSER_ROLE(), _addr(json, ".roles.unpauser"));
        c.grantRole(c.SERIES_CREATOR_ROLE(), _addr(json, ".roles.seriesCreator"));
        c.grantRole(c.ORACLE_CONFIG_ROLE(), _addr(json, ".roles.oracleConfigAdmin"));
        c.grantRole(c.CONFIG_ROLE(), _addr(json, ".roles.configAdmin"));
    }

    function _configureAssets(string memory json, OptaraConfig c) internal {
        uint256 n = _count(json, ".assets");
        if (n == 0) revert InvalidDeployConfig("no settlement assets");
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".assets[", vm.toString(i), "]");
            address asset = _addr(json, string.concat(p, ".address"));
            uint8 expectedDecimals = uint8(vm.parseJsonUint(json, string.concat(p, ".decimals")));
            if (IERC20Metadata(asset).decimals() != expectedDecimals) revert InvalidDeployConfig("asset decimals");
            c.approveAsset(
                asset,
                vm.parseJsonString(json, string.concat(p, ".symbol")),
                uint16(vm.parseJsonUint(json, string.concat(p, ".bufferBps"))),
                vm.parseJsonUint(json, string.concat(p, ".fixedBufferNative"))
            );
            c.setExposureLimit(
                ExposureScope.ASSET,
                bytes32(uint256(uint160(asset))),
                _limitN(vm.parseJsonUint(json, string.concat(p, ".exposureLimitNative")), expectedDecimals)
            );
        }
    }

    function _configureUnderlyings(string memory json, OptaraConfig c) internal {
        uint256 n = _count(json, ".underlyings");
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".underlyings[", vm.toString(i), "]");
            c.approveUnderlying(
                _addr(json, string.concat(p, ".address")), vm.parseJsonString(json, string.concat(p, ".symbol"))
            );
        }
    }

    function _configurePairs(string memory json, OptaraConfig c) internal returns (bytes32[] memory ids) {
        uint256 n = _count(json, ".pairs");
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = _approvePair(json, string.concat(".pairs[", vm.toString(i), "]"), c);
        }
    }

    function _approvePair(string memory json, string memory p, OptaraConfig c) internal returns (bytes32) {
        address asset = _addr(json, string.concat(p, ".asset"));
        (bool known,, uint8 dec) = c.assetInfo(asset);
        if (!known) revert InvalidDeployConfig("pair asset not approved"); // DEPLOY-TEST-006
        uint256 seriesLimitN = _limitN(vm.parseJsonUint(json, string.concat(p, ".seriesExposureLimitNative")), dec);
        uint256 pairLimitN = _limitN(vm.parseJsonUint(json, string.concat(p, ".pairExposureLimitNative")), dec);
        return c.approvePair(
            _addr(json, string.concat(p, ".underlying")),
            asset,
            _bounds(json, string.concat(p, ".bounds")),
            seriesLimitN,
            pairLimitN
        );
    }

    function _bounds(string memory json, string memory p) internal pure returns (SeriesBounds memory b) {
        b.minStrikeWad = vm.parseJsonUint(json, string.concat(p, ".minStrikeWad"));
        b.maxStrikeWad = vm.parseJsonUint(json, string.concat(p, ".maxStrikeWad"));
        b.minCapWad = vm.parseJsonUint(json, string.concat(p, ".minCapWad"));
        b.maxCapWad = vm.parseJsonUint(json, string.concat(p, ".maxCapWad"));
        b.minContractSizeWad = vm.parseJsonUint(json, string.concat(p, ".minContractSizeWad"));
        b.maxContractSizeWad = vm.parseJsonUint(json, string.concat(p, ".maxContractSizeWad"));
        b.minTimeToExpiry = uint64(vm.parseJsonUint(json, string.concat(p, ".minTimeToExpiry")));
        b.maxTimeToExpiry = uint64(vm.parseJsonUint(json, string.concat(p, ".maxTimeToExpiry")));
        b.quantityIncrement = vm.parseJsonUint(json, string.concat(p, ".quantityIncrement"));
    }

    function _configureOracles(string memory json, Deployment memory d) internal returns (bytes32[] memory ids) {
        uint256 n = _count(json, ".oracleConfigs");
        if (n == 0) revert InvalidDeployConfig("no oracle configs"); // DEPLOY-TEST-005
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".oracleConfigs[", vm.toString(i), "]");
            OracleConfig memory oc;
            oc.underlying = _addr(json, string.concat(p, ".underlying"));
            oc.settlementAsset = _addr(json, string.concat(p, ".asset"));
            oc.adapter = address(d.adapter);
            oc.observationStartOffset = int64(vm.parseJsonInt(json, string.concat(p, ".observationStartOffset")));
            oc.observationEndOffset = int64(vm.parseJsonInt(json, string.concat(p, ".observationEndOffset")));
            oc.minFinalizationDelay = uint64(vm.parseJsonUint(json, string.concat(p, ".minFinalizationDelay")));
            oc.maxFinalizationDelay = uint64(vm.parseJsonUint(json, string.concat(p, ".maxFinalizationDelay")));
            oc.ruleVersion = keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".ruleVersion"))));
            ChainlinkSettlementAdapter.Params memory params;
            params.primary = _source(json, string.concat(p, ".primary"));
            if (vm.keyExistsJson(json, string.concat(p, ".secondary"))) {
                params.secondary = _source(json, string.concat(p, ".secondary"));
            }
            oc.sourceParams = abi.encode(params);
            ids[i] = d.registry.registerConfig(oc);
            (,, uint8 dec) = d.config.assetInfo(oc.settlementAsset);
            d.config
                .setExposureLimit(
                    ExposureScope.ORACLE_CONFIG,
                    ids[i],
                    _limitN(vm.parseJsonUint(json, string.concat(p, ".exposureLimitNative")), dec)
                );
        }
    }

    function _source(string memory json, string memory p)
        internal
        view
        returns (ChainlinkSettlementAdapter.Source memory s)
    {
        string memory kind = vm.parseJsonString(json, string.concat(p, ".kind"));
        s.feed = _addr(json, string.concat(p, ".feed"));
        s.feedDecimals = uint8(vm.parseJsonUint(json, string.concat(p, ".feedDecimals")));
        if (keccak256(bytes(kind)) == keccak256("DIRECT")) {
            s.kind = 1;
        } else if (keccak256(bytes(kind)) == keccak256("DERIVED")) {
            s.kind = 2;
            s.quoteFeed = _addr(json, string.concat(p, ".quoteFeed"));
            s.quoteFeedDecimals = uint8(vm.parseJsonUint(json, string.concat(p, ".quoteFeedDecimals")));
            s.maxLegSkew = uint32(vm.parseJsonUint(json, string.concat(p, ".maxLegSkew")));
        } else {
            revert InvalidDeployConfig("oracle source kind");
        }
    }

    function _finalGovernance(string memory json) internal returns (address governance, address timelock) {
        string memory mode = vm.parseJsonString(json, ".governance.mode");
        address multisig = _addr(json, ".governance.multisig"); // DEPLOY-TEST-004: required
        if (keccak256(bytes(mode)) == keccak256("timelock")) {
            address[] memory members = new address[](1);
            members[0] = multisig;
            timelock = address(
                new TimelockController(
                    vm.parseJsonUint(json, ".governance.timelockMinDelay"), members, members, address(0)
                )
            );
            return (timelock, timelock);
        }
        if (keccak256(bytes(mode)) == keccak256("address")) return (multisig, address(0));
        revert InvalidDeployConfig("governance.mode");
    }

    // ---------------------------------------------------------------------------------------------
    // Post-deployment verification (DEPLOYMENT.md sections 30, 62; DEPLOY-TEST-007/008/010)
    // ---------------------------------------------------------------------------------------------

    function verify(string memory json, Deployment memory d, address deployer) public view {
        OptaraConfig c = d.config;
        bytes32 gov = c.GOVERNANCE_ROLE();
        if (c.hasRole(gov, deployer)) revert InvalidDeployConfig("deployer still governance");
        if (c.getRoleMemberCount(gov) != 1 || !c.hasRole(gov, d.governance)) revert InvalidDeployConfig("governance");
        _expectSoleMember(c, c.PAUSER_ROLE(), _addr(json, ".roles.pauser"));
        _expectSoleMember(c, c.UNPAUSER_ROLE(), _addr(json, ".roles.unpauser"));
        _expectSoleMember(c, c.SERIES_CREATOR_ROLE(), _addr(json, ".roles.seriesCreator"));
        _expectSoleMember(c, c.ORACLE_CONFIG_ROLE(), _addr(json, ".roles.oracleConfigAdmin"));
        _expectSoleMember(c, c.CONFIG_ROLE(), _addr(json, ".roles.configAdmin"));
        if (c.getRoleMemberCount(c.DEFAULT_ADMIN_ROLE()) != 0) revert InvalidDeployConfig("default admin held");
        if (!d.core.isSealed() || d.core.seriesFactory() != address(d.factory)) revert InvalidDeployConfig("sealing");
        if (c.pausedBits(c.GLOBAL_SCOPE()) & SAFE_MODE_BITS != SAFE_MODE_BITS) revert InvalidDeployConfig("safe mode");
        (uint32 a, uint32 b, uint32 e) = c.positionLimits();
        if (
            a != vm.parseJsonUint(json, ".positionLimits.maxSeriesPerGroup")
                || b != vm.parseJsonUint(json, ".positionLimits.maxGroupsPerAccount")
                || e != vm.parseJsonUint(json, ".positionLimits.maxSeriesPerAccount")
        ) revert InvalidDeployConfig("position limits");
    }

    function _expectSoleMember(OptaraConfig c, bytes32 role, address who) internal view {
        if (c.getRoleMemberCount(role) != 1 || !c.hasRole(role, who)) revert InvalidDeployConfig("role members");
    }

    // ---------------------------------------------------------------------------------------------
    // Manifest (DEPLOYMENT.md section 19): machine-readable, no secrets
    // ---------------------------------------------------------------------------------------------

    function writeManifest(string memory json, Deployment memory d) public {
        string memory network = vm.parseJsonString(json, ".network");
        string memory k = "manifest";
        vm.serializeString(k, "network", network);
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "coreVersion", d.core.CORE_VERSION());
        vm.serializeString(k, "commit", vm.envOr("GIT_COMMIT", string("unknown")));
        vm.serializeUint(k, "deployBlock", block.number);
        vm.serializeBytes32(k, "protocolSeriesDomain", d.core.protocolSeriesDomain());
        vm.serializeString(k, "fees", "none: fee-free MVP, no fee code (FEES.md section 2)");

        string memory ck = "contracts";
        vm.serializeAddress(ck, "OptaraConfig", address(d.config));
        vm.serializeAddress(ck, "OracleRegistry", address(d.registry));
        vm.serializeAddress(ck, "ChainlinkSettlementAdapter", address(d.adapter));
        vm.serializeAddress(ck, "SeriesFactory", address(d.factory));
        string memory contractsJson = vm.serializeAddress(ck, "OptaraCore", address(d.core));
        vm.serializeString(k, "contracts", contractsJson);

        string memory rk = "roles";
        vm.serializeAddress(rk, "governance", d.governance);
        vm.serializeAddress(rk, "timelock", d.timelock);
        vm.serializeAddress(rk, "pauser", _addr(json, ".roles.pauser"));
        vm.serializeAddress(rk, "unpauser", _addr(json, ".roles.unpauser"));
        vm.serializeAddress(rk, "seriesCreator", _addr(json, ".roles.seriesCreator"));
        vm.serializeAddress(rk, "oracleConfigAdmin", _addr(json, ".roles.oracleConfigAdmin"));
        string memory rolesJson = vm.serializeAddress(rk, "configAdmin", _addr(json, ".roles.configAdmin"));
        vm.serializeString(k, "roles", rolesJson);

        address[] memory assets = new address[](_count(json, ".assets"));
        for (uint256 i = 0; i < assets.length; ++i) {
            assets[i] = _addr(json, string.concat(".assets[", vm.toString(i), "].address"));
        }
        address[] memory underlyings = new address[](_count(json, ".underlyings"));
        for (uint256 i = 0; i < underlyings.length; ++i) {
            underlyings[i] = _addr(json, string.concat(".underlyings[", vm.toString(i), "].address"));
        }
        vm.serializeAddress(k, "assets", assets);
        vm.serializeAddress(k, "underlyings", underlyings);
        vm.serializeBytes32(k, "pairIds", d.pairIds);
        string memory out = vm.serializeBytes32(k, "oracleConfigIds", d.oracleConfigIds);
        vm.writeJson(out, manifestPath(network));
    }

    function manifestPath(string memory network) public pure returns (string memory) {
        return string.concat("../deployments/", network, ".json");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Native units of the asset -> exact max-payoff numerator: N = native * 10^(54 - d).
    function _limitN(uint256 native, uint8 decimals) internal pure returns (uint256) {
        if (native == 0) revert InvalidDeployConfig("zero exposure limit");
        return native * 10 ** (54 - uint256(decimals));
    }

    function _addr(string memory json, string memory key) internal pure returns (address a) {
        a = vm.parseJsonAddress(json, key);
        if (a == address(0)) revert InvalidDeployConfig(key);
    }

    function _count(string memory json, string memory key) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(key, "[", vm.toString(n), "]"))) ++n;
    }
}
