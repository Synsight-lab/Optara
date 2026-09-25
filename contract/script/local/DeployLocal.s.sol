// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deploy} from "../Deploy.s.sol";
import {SeriesFactory} from "../../src/factory/SeriesFactory.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockAggregator} from "../../test/mocks/MockAggregator.sol";

/// @title DeployLocal
/// @notice LOCAL/ANVIL ONLY. Deploys mock stablecoins and mock Chainlink feeds, runs the real config-driven
///         deployment with test parameters, and seeds example series. None of these values are production values.
///
/// anvil &
/// forge script script/local/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///   --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployLocal is Deploy {
    // Anvil default accounts 1-3 (public, well-known test keys).
    address public constant GOVERNANCE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant PAUSER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address public constant USER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    /// @dev Anvil account 1's well-known key: GOVERNANCE is also the local unpauser that activates the deployment.
    uint256 internal constant GOVERNANCE_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    struct Mocks {
        MockERC20 usdt;
        MockERC20 usdc;
        MockERC20 usde;
        address mon;
        address eth;
        MockAggregator monUsdt;
        MockAggregator ethUsd;
        MockAggregator usdcUsd;
        MockAggregator monUsde;
    }

    function run() external override returns (Deployment memory d) {
        require(block.chainid == 31337, "local only");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Mocks memory m = _deployMocks(deployer);
        vm.stopBroadcast();

        string memory network = vm.envOr("OPTARA_LOCAL_NETWORK", string("local"));
        string memory json = _replaceNetwork(_localConfig(m, deployer), network);
        vm.writeFile(string.concat("../deployments/", network, ".config.json"), json);
        d = deploy(json, true);

        // Phase 1 activation (DEPLOYMENT.md section 66): the unpauser lifts safe mode after verify() passed.
        vm.startBroadcast(GOVERNANCE_KEY);
        d.config.unpause(d.config.GLOBAL_SCOPE(), SAFE_MODE_BITS);
        vm.stopBroadcast();

        vm.startBroadcast();
        bytes32[] memory series = _seedSeries(d.factory, m, d.oracleConfigIds);
        vm.stopBroadcast();

        writeManifest(json, d);
        _writeLocalExtras(m, series, network);
    }

    /// @dev The generated config always starts with {"network":"local", ...; swap in another name for isolated runs.
    function _replaceNetwork(string memory json, string memory network) internal pure returns (string memory) {
        bytes memory b = bytes(json);
        bytes memory prefix = bytes('{"network":"local"');
        for (uint256 i = 0; i < prefix.length; ++i) {
            require(b[i] == prefix[i], "unexpected config prefix");
        }
        bytes memory rest = new bytes(b.length - prefix.length);
        for (uint256 i = 0; i < rest.length; ++i) {
            rest[i] = b[prefix.length + i];
        }
        return string.concat('{"network":"', network, '"', string(rest));
    }

    function _deployMocks(address deployer) internal virtual returns (Mocks memory m) {
        m.usdt = new MockERC20("Tether USD (mock)", "USDT", 6);
        m.usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        m.usde = new MockERC20("Ethena USDe (mock)", "USDe", 18);
        m.mon = address(uint160(uint256(keccak256("optara.local.MON"))));
        m.eth = address(uint160(uint256(keccak256("optara.local.ETH"))));
        m.monUsdt = new MockAggregator(8);
        m.ethUsd = new MockAggregator(8);
        m.usdcUsd = new MockAggregator(8);
        m.monUsde = new MockAggregator(18);
        m.monUsdt.pushRound(8e8, block.timestamp);
        m.ethUsd.pushRound(3000e8, block.timestamp);
        m.usdcUsd.pushRound(1e8, block.timestamp);
        m.monUsde.pushRound(8e18, block.timestamp);
        address[3] memory users = [deployer, USER, PAUSER];
        for (uint256 i = 0; i < users.length; ++i) {
            m.usdt.mint(users[i], 1_000_000e6);
            m.usdc.mint(users[i], 1_000_000e6);
            m.usde.mint(users[i], 1_000_000e18);
        }
    }

    function _localConfig(Mocks memory m, address deployer) internal view virtual returns (string memory) {
        return string.concat(
            '{"network":"local","chainId":31337,"shortfallResolutionDelay":86400,',
            '"governance":{"mode":"address","multisig":"',
            vm.toString(GOVERNANCE),
            '","timelockMinDelay":0},',
            _rolesJson(deployer),
            ',"positionLimits":{"maxSeriesPerGroup":8,"maxGroupsPerAccount":8,"maxSeriesPerAccount":32},',
            _assetsJson(m),
            ',"underlyings":[{"address":"',
            vm.toString(m.mon),
            '","symbol":"MON"},{"address":"',
            vm.toString(m.eth),
            '","symbol":"ETH"}],',
            _pairsJson(m),
            ",",
            _oraclesJson(m),
            "}"
        );
    }

    function _rolesJson(address deployer) internal pure returns (string memory) {
        return string.concat(
            '"roles":{"pauser":"',
            vm.toString(PAUSER),
            '","unpauser":"',
            vm.toString(GOVERNANCE),
            '","seriesCreator":"',
            vm.toString(deployer),
            '","oracleConfigAdmin":"',
            vm.toString(deployer),
            '","configAdmin":"',
            vm.toString(deployer),
            '"}'
        );
    }

    function _assetJson(address asset, string memory sym, uint8 dec, string memory limit)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"address":"',
            vm.toString(asset),
            '","symbol":"',
            sym,
            '","decimals":',
            vm.toString(uint256(dec)),
            ',"bufferBps":0,"fixedBufferNative":0,"exposureLimitNative":',
            limit,
            "}"
        );
    }

    function _assetsJson(Mocks memory m) internal pure returns (string memory) {
        return string.concat(
            '"assets":[',
            _assetJson(address(m.usdt), "USDT", 6, "100000000000000"),
            ",",
            _assetJson(address(m.usdc), "USDC", 6, "100000000000000"),
            ",",
            _assetJson(address(m.usde), "USDe", 18, "100000000000000000000000000"),
            "]"
        );
    }

    function _pairJson(address u, address asset, string memory seriesLimit, string memory pairLimit)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"underlying":"',
            vm.toString(u),
            '","asset":"',
            vm.toString(asset),
            '","bounds":{"minStrikeWad":1000000000000,"maxStrikeWad":1000000000000000000000000000000,',
            '"minCapWad":1000000000000,"maxCapWad":1000000000000000000000000000000,',
            '"minContractSizeWad":1000000000000,"maxContractSizeWad":1000000000000000000000000,',
            '"minTimeToExpiry":3600,"maxTimeToExpiry":34560000,"quantityIncrement":1000000000000000},',
            '"seriesExposureLimitNative":',
            seriesLimit,
            ',"pairExposureLimitNative":',
            pairLimit,
            "}"
        );
    }

    function _pairsJson(Mocks memory m) internal pure returns (string memory) {
        return string.concat(
            '"pairs":[',
            _pairJson(m.mon, address(m.usdt), "10000000000000", "50000000000000"),
            ",",
            _pairJson(m.eth, address(m.usdc), "10000000000000", "50000000000000"),
            ",",
            _pairJson(m.mon, address(m.usde), "10000000000000000000000000", "50000000000000000000000000"),
            "]"
        );
    }

    function _oraclesJson(Mocks memory m) internal pure returns (string memory) {
        string memory derived = string.concat(
            '{"kind":"DERIVED","feed":"',
            vm.toString(address(m.ethUsd)),
            '","feedDecimals":8,"quoteFeed":"',
            vm.toString(address(m.usdcUsd)),
            '","quoteFeedDecimals":8,"maxLegSkew":3600}'
        );
        return string.concat(
            '"oracleConfigs":[',
            _oracleJson(
                vm.toString(m.mon),
                vm.toString(address(m.usdt)),
                string.concat('{"kind":"DIRECT","feed":"', vm.toString(address(m.monUsdt)), '","feedDecimals":8}'),
                "100000000000000"
            ),
            ",",
            _oracleJson(vm.toString(m.eth), vm.toString(address(m.usdc)), derived, "100000000000000"),
            ",",
            _oracleJson(
                vm.toString(m.mon),
                vm.toString(address(m.usde)),
                string.concat('{"kind":"DIRECT","feed":"', vm.toString(address(m.monUsde)), '","feedDecimals":18}'),
                "100000000000000000000000000"
            ),
            "]"
        );
    }

    function _oracleJson(string memory u, string memory asset, string memory primary, string memory limit)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"underlying":"',
            u,
            '","asset":"',
            asset,
            '","observationStartOffset":-3600,"observationEndOffset":0,"minFinalizationDelay":300,',
            '"maxFinalizationDelay":604800,"ruleVersion":"chainlink-round-in-force/v1","exposureLimitNative":',
            limit,
            ',"primary":',
            primary,
            "}"
        );
    }

    function _seedSeries(SeriesFactory f, Mocks memory m, bytes32[] memory cfg)
        internal
        returns (bytes32[] memory ids)
    {
        uint64 day = 1 days;
        uint64 base = uint64(block.timestamp / day) * day + 8 hours; // 08:00 UTC
        uint64 e1 = base + 7 days;
        uint64 e2 = base + 30 days;
        ids = new bytes32[](7);
        (ids[0],) = f.createSeries(
            SeriesFactory.SeriesParams(m.mon, address(m.usdt), OptionType.CALL, 10e18, 5e18, 1e18, e1, cfg[0])
        );
        (ids[1],) = f.createSeries(
            SeriesFactory.SeriesParams(m.mon, address(m.usdt), OptionType.CALL, 12e18, 3e18, 1e18, e1, cfg[0])
        );
        (ids[2],) = f.createSeries(
            SeriesFactory.SeriesParams(m.mon, address(m.usdt), OptionType.PUT, 8e18, 4e18, 1e18, e1, cfg[0])
        );
        (ids[3],) = f.createSeries(
            SeriesFactory.SeriesParams(m.mon, address(m.usdt), OptionType.CALL, 10e18, 5e18, 1e18, e2, cfg[0])
        );
        (ids[4],) = f.createSeries(
            SeriesFactory.SeriesParams(m.eth, address(m.usdc), OptionType.CALL, 4000e18, 500e18, 0.1e18, e2, cfg[1])
        );
        (ids[5],) = f.createSeries(
            SeriesFactory.SeriesParams(m.eth, address(m.usdc), OptionType.PUT, 3000e18, 500e18, 0.1e18, e2, cfg[1])
        );
        (ids[6],) = f.createSeries(
            SeriesFactory.SeriesParams(m.mon, address(m.usde), OptionType.CALL, 9e18, 4e18, 1e18, e1, cfg[2])
        );
    }

    function _writeLocalExtras(Mocks memory m, bytes32[] memory series, string memory network) internal {
        string memory k = "local";
        vm.serializeAddress(k, "usdt", address(m.usdt));
        vm.serializeAddress(k, "usdc", address(m.usdc));
        vm.serializeAddress(k, "usde", address(m.usde));
        vm.serializeAddress(k, "MON", m.mon);
        vm.serializeAddress(k, "ETH", m.eth);
        vm.serializeAddress(k, "feedMonUsdt", address(m.monUsdt));
        vm.serializeAddress(k, "feedEthUsd", address(m.ethUsd));
        vm.serializeAddress(k, "feedUsdcUsd", address(m.usdcUsd));
        vm.serializeAddress(k, "feedMonUsde", address(m.monUsde));
        string memory out = vm.serializeBytes32(k, "seededSeries", series);
        vm.writeJson(out, string.concat("../deployments/", network, ".mocks.json"));
    }
}
