// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployLocal} from "../../script/local/DeployLocal.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {OptaraConfig} from "../../src/config/OptaraConfig.sol";
import {IOptaraCoreErrors} from "../../src/interfaces/IOptaraCore.sol";
import {IOptionToken} from "../../src/interfaces/IOptionToken.sol";
import {SeriesFactory} from "../../src/factory/SeriesFactory.sol";
import {OptionType, CloseSource, Actions} from "../../src/libraries/OptaraTypes.sol";

/// @notice Exposes the local deployment pieces to tests (non-broadcast mode: this contract is the deployer).
contract DeployHarness is DeployLocal {
    function mocks() external returns (Mocks memory m) {
        return _deployMocks(address(this));
    }

    function config(Mocks memory m) external view returns (string memory) {
        return _localConfig(m, address(this));
    }

    function seed(SeriesFactory f, Mocks memory m, bytes32[] memory cfg) external returns (bytes32[] memory) {
        return _seedSeries(f, m, cfg);
    }
}

/// @notice DEPLOYMENT.md Part XXIII: DEPLOY-TEST-001..015.
contract DeployTest is Test {
    DeployHarness h;
    DeployLocal.Mocks m;
    string json;

    function setUp() public {
        vm.warp(1_760_000_000);
        h = new DeployHarness();
        m = h.mocks();
        json = h.config(m);
    }

    function _replace(string memory s, string memory from, string memory to) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory f = bytes(from);
        for (uint256 i = 0; i + f.length <= b.length; ++i) {
            bool eq = true;
            for (uint256 j = 0; j < f.length; ++j) {
                if (b[i + j] != f[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) {
                bytes memory head = new bytes(i);
                for (uint256 k = 0; k < i; ++k) {
                    head[k] = b[k];
                }
                bytes memory tail = new bytes(b.length - i - f.length);
                for (uint256 k = 0; k < tail.length; ++k) {
                    tail[k] = b[i + f.length + k];
                }
                return string.concat(string(head), to, string(tail));
            }
        }
        revert("pattern not found");
    }

    /// DEPLOY-TEST-001/007/008/010: fresh deployment, exact roles, deployer revoked, limits as configured.
    function test_DEPLOY_001_007_008_010_freshDeployment() public {
        Deploy.Deployment memory d = h.deploy(json, false);
        OptaraConfig c = d.config;
        assertFalse(c.hasRole(c.GOVERNANCE_ROLE(), address(h)));
        assertTrue(c.hasRole(c.GOVERNANCE_ROLE(), d.governance));
        assertEq(c.getRoleMemberCount(c.PAUSER_ROLE()), 1);
        assertEq(c.getRoleMember(c.PAUSER_ROLE(), 0), h.PAUSER());
        (uint32 a, uint32 b, uint32 e) = c.positionLimits();
        assertEq(a, 8);
        assertEq(b, 8);
        assertEq(e, 32);
        assertEq(d.oracleConfigIds.length, 3);
        assertEq(d.pairIds.length, 3);
        assertTrue(d.core.isSealed());
    }

    /// DEPLOY-TEST-002: a second initializer/binding fails.
    function test_DEPLOY_002_secondInitializerFails() public {
        Deploy.Deployment memory d = h.deploy(json, false);
        vm.prank(address(h));
        vm.expectRevert(IOptaraCoreErrors.AlreadySealed.selector);
        d.core.bindSeriesFactory(address(1));
    }

    /// DEPLOY-TEST-003: wrong chain id aborts.
    function test_DEPLOY_003_wrongChainAborts() public {
        vm.chainId(10143);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainIdMismatch.selector, 31337, 10143));
        h.deploy(json, false);
    }

    /// DEPLOY-TEST-004: missing or zero governance aborts.
    function test_DEPLOY_004_missingGovernanceAborts() public {
        string memory bad = _replace(json, vm.toString(h.GOVERNANCE()), vm.toString(address(0)));
        vm.expectRevert(abi.encodeWithSelector(Deploy.InvalidDeployConfig.selector, ".governance.multisig"));
        h.deploy(bad, false);
    }

    /// DEPLOY-TEST-005: no oracle config -> abort before pair risk can be enabled.
    function test_DEPLOY_005_missingOracleConfigAborts() public {
        string memory bad = _replace(json, '"oracleConfigs":[', '"oracleConfigsDisabled":[');
        vm.expectRevert(abi.encodeWithSelector(Deploy.InvalidDeployConfig.selector, "no oracle configs"));
        h.deploy(bad, false);
    }

    /// DEPLOY-TEST-006: a pair on an unknown settlement token aborts.
    function test_DEPLOY_006_unknownSettlementTokenAborts() public {
        // replace the first pair's asset with an address that was never approved as a settlement asset
        string memory bad = _replace(
            json,
            string.concat('","asset":"', vm.toString(address(m.usdt)), '","bounds"'),
            string.concat('","asset":"', vm.toString(h.USER()), '","bounds"')
        );
        vm.expectRevert(abi.encodeWithSelector(Deploy.InvalidDeployConfig.selector, "pair asset not approved"));
        h.deploy(bad, false);
    }

    /// DEPLOY-TEST-009: fee configuration is "none"; the core has no fee setter or treasury path.
    function test_DEPLOY_009_feeConfig() public {
        Deploy.Deployment memory d = h.deploy(json, false);
        (bool ok,) = address(d.core).call(abi.encodeWithSignature("setIssuanceFeeBps(uint256)", 10));
        assertFalse(ok);
        (ok,) = address(d.core).call(abi.encodeWithSignature("collectFees(address,uint256)", address(m.usdt), 1));
        assertFalse(ok);
    }

    /// DEPLOY-TEST-011: the manifest matches deployed addresses.
    function test_DEPLOY_011_manifestMatches() public {
        Deploy.Deployment memory d = h.deploy(json, false);
        string memory net = "deploytest";
        string memory j2 = _replace(json, '"network":"local"', string.concat('"network":"', net, '"'));
        h.writeManifest(j2, d);
        string memory manifest = vm.readFile(h.manifestPath(net));
        assertEq(vm.parseJsonAddress(manifest, ".contracts.OptaraCore"), address(d.core));
        assertEq(vm.parseJsonAddress(manifest, ".contracts.SeriesFactory"), address(d.factory));
        assertEq(vm.parseJsonAddress(manifest, ".contracts.OptaraConfig"), address(d.config));
        assertEq(vm.parseJsonAddress(manifest, ".contracts.OracleRegistry"), address(d.registry));
        assertEq(vm.parseJsonAddress(manifest, ".contracts.ChainlinkSettlementAdapter"), address(d.adapter));
        assertEq(vm.parseJsonUint(manifest, ".chainId"), block.chainid);
        assertEq(vm.parseJsonBytes32(manifest, ".protocolSeriesDomain"), d.core.protocolSeriesDomain());
        vm.removeFile(h.manifestPath(net));
    }

    /// DEPLOY-TEST-013/014/015: tiny smoke flow; pause works immediately; unauthorized admin calls revert.
    function test_DEPLOY_013_014_015_smokePauseAuth() public {
        Deploy.Deployment memory d = h.deploy(json, false);
        _activate(d);
        bytes32[] memory ids = h.seed(d.factory, m, d.oracleConfigIds);
        address user = h.USER();
        vm.startPrank(user);
        m.usdt.approve(address(d.core), type(uint256).max);
        d.core.deposit(address(m.usdt), 5e6);
        d.core.write(ids[0], 1e18, user);
        d.core.closeShort(ids[0], 1e18, CloseSource.EXTERNAL);
        d.core.withdraw(address(m.usdt), 5e6, user);
        vm.stopPrank();
        assertEq(IOptionToken(d.core.getSeries(ids[0]).optionToken).totalSupply(), 0);
        // DEPLOY-TEST-014
        vm.prank(h.PAUSER());
        d.config.pause(bytes32(0), Actions.WRITE);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.ActionPaused.selector, Actions.WRITE));
        d.core.write(ids[0], 1e18, user);
        // DEPLOY-TEST-015
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, user));
        d.config.setPositionLimits(1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IOptaraCoreErrors.NotAuthorized.selector, user));
        d.core.restrictAsset(address(m.usdt), "X");
        vm.stopPrank();
    }

    function _activate(Deploy.Deployment memory d) internal {
        (address unpauser, uint256 bits) = (h.GOVERNANCE(), h.SAFE_MODE_BITS()); // the local unpauser
        vm.prank(unpauser);
        d.config.unpause(bytes32(0), bits);
    }

    /// DEPLOYMENT.md sections 24, 35, 58, 66: a fresh deployment is in safe mode. Nobody can create a series or write
    /// until the unpauser activates it; the pauser (fast guardian) cannot lift it.
    function test_deploymentStartsInSafeMode() public {
        Deploy.Deployment memory d = h.deploy(json, false);
        assertEq(d.config.pausedBits(bytes32(0)), Actions.WRITE | Actions.SERIES_CREATION);
        vm.expectRevert(SeriesFactory.SeriesCreationPaused.selector);
        h.seed(d.factory, m, d.oracleConfigIds);

        (address pauser, uint256 bits) = (h.PAUSER(), h.SAFE_MODE_BITS());
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, pauser));
        d.config.unpause(bytes32(0), bits);

        _activate(d);
        assertEq(d.config.pausedBits(bytes32(0)), 0);
        bytes32[] memory ids = h.seed(d.factory, m, d.oracleConfigIds);
        address user = h.USER();
        vm.startPrank(user);
        m.usdt.approve(address(d.core), 5e6);
        d.core.deposit(address(m.usdt), 5e6);
        d.core.write(ids[0], 1e18, user);
        vm.stopPrank();
        assertEq(IOptionToken(d.core.getSeries(ids[0]).optionToken).balanceOf(user), 1e18);
    }

    /// DEPLOYMENT.md section 84: the production template cannot deploy until every REQUIRED value is filled in.
    function test_productionTemplateRefusesToDeploy() public {
        string memory tpl = vm.readFile("deploy/production.template.json");
        vm.chainId(143);
        vm.expectRevert();
        h.deploy(tpl, false);
    }

    /// Timelock governance: the multisig cannot act directly; a scheduled call executes only after the delay.
    function test_timelockGovernance() public {
        string memory tl = _replace(json, '"mode":"address"', '"mode":"timelock"');
        tl = _replace(tl, '"timelockMinDelay":0', '"timelockMinDelay":172800');
        Deploy.Deployment memory d = h.deploy(tl, false);
        TimelockController t = TimelockController(payable(d.timelock));
        assertEq(d.governance, d.timelock);
        assertEq(t.getMinDelay(), 172800);
        address multisig = h.GOVERNANCE();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(OptaraConfig.NotAuthorized.selector, multisig));
        d.config.setPositionLimits(4, 4, 16);
        bytes memory call = abi.encodeCall(d.config.setPositionLimits, (4, 4, 16));
        vm.prank(multisig);
        t.schedule(address(d.config), 0, call, bytes32(0), bytes32(0), 172800);
        vm.prank(multisig);
        vm.expectRevert();
        t.execute(address(d.config), 0, call, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 172800);
        vm.prank(multisig);
        t.execute(address(d.config), 0, call, bytes32(0), bytes32(0));
        (uint32 a,,) = d.config.positionLimits();
        assertEq(a, 4);
    }
}
