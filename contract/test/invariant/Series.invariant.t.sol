// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeriesFixture} from "../utils/SeriesFixture.sol";
import {OptionSeriesRegistry} from "../../src/series/OptionSeriesRegistry.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {OptionType, ProductConfig, SeriesParams, SeriesTerms} from "../../src/libraries/OptaraTypes.sol";

/// @notice Random series creation, product re-approval / enable / disable, and wrapper mint / burn / transfer.
contract SeriesHandler is Test {
    OptionSeriesRegistry internal registry;
    address internal creator;
    address internal governance;
    address internal guardian;
    address internal clearing;
    address internal settlementWindow;
    address internal liquidationModule;
    address internal weth;
    address internal usdc;
    bytes32 internal cfg;
    bytes32 internal riskSet;
    bytes32 internal productId;
    ProductConfig internal baseConfig;

    bytes32[] public ids;
    mapping(bytes32 => bytes32) public termsHash; // ghost: hash of terms at creation
    mapping(bytes32 => uint256) public ghostSupply; // minted − burned per series
    address[3] internal holders;

    constructor(
        OptionSeriesRegistry registry_,
        address[6] memory roles, // creator, governance, guardian, clearing, settlementWindow, liquidationModule
        address weth_,
        address usdc_,
        bytes32 cfg_,
        bytes32 riskSet_,
        bytes32 productId_,
        ProductConfig memory base
    ) {
        registry = registry_;
        (creator, governance, guardian, clearing, settlementWindow, liquidationModule) =
        (roles[0], roles[1], roles[2], roles[3], roles[4], roles[5]);
        (weth, usdc, cfg, riskSet, productId) = (weth_, usdc_, cfg_, riskSet_, productId_);
        baseConfig = base;
        holders = [makeAddr("h1"), makeAddr("h2"), makeAddr("h3")];
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function holder(uint256 i) external view returns (address) {
        return holders[i];
    }

    function createSeries(uint256 strikeSeed, uint256 expirySeed, bool isCall) external {
        SeriesParams memory p = SeriesParams({
            underlying: weth,
            settlementAsset: usdc,
            optionType: isCall ? OptionType.CALL : OptionType.PUT,
            strikeWad: (bound(strikeSeed, 0, 40) * 250 + 1000) * 1e18,
            contractSizeWad: 1e18,
            expiry: uint64(block.timestamp + bound(expirySeed, 0, 3) * 7 days + 2 hours),
            settlementOracleConfigId: cfg,
            volSurfaceProductId: productId,
            riskParameterSetId: riskSet
        });
        vm.prank(creator);
        try registry.createSeries(p) returns (bytes32 id) {
            ids.push(id);
            termsHash[id] = keccak256(abi.encode(registry.getSeries(id)));
        } catch {}
    }

    function reapproveProduct(uint256 maxStrikeSeed) external {
        ProductConfig memory c = baseConfig;
        c.maxStrikeWad = bound(maxStrikeSeed, 2000e18, 1_000_000e18);
        vm.prank(governance);
        registry.approveProduct(weth, usdc, c);
    }

    function toggleProduct(bool enable) external {
        vm.prank(enable ? governance : guardian);
        registry.setProductEnabled(productId, enable);
    }

    function mint(uint256 idSeed, uint256 holderSeed, uint256 amount) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        amount = bound(amount, 0, 1e24);
        ExternalOptionWrapper w = ExternalOptionWrapper(registry.getSeries(id).wrapper); // look up before the prank
        vm.prank(clearing);
        w.mint(holders[holderSeed % 3], amount);
        ghostSupply[id] += amount;
    }

    function burn(uint256 idSeed, uint256 holderSeed, uint256 amount, uint256 burnerSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        ExternalOptionWrapper w = ExternalOptionWrapper(registry.getSeries(id).wrapper);
        address h = holders[holderSeed % 3];
        amount = bound(amount, 0, w.balanceOf(h));
        address[3] memory burners = [clearing, settlementWindow, liquidationModule];
        vm.prank(burners[burnerSeed % 3]);
        w.burn(h, amount);
        ghostSupply[id] -= amount;
    }

    function transfer(uint256 idSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        if (ids.length == 0) return;
        ExternalOptionWrapper w = ExternalOptionWrapper(registry.getSeries(ids[idSeed % ids.length]).wrapper);
        address from = holders[fromSeed % 3];
        amount = bound(amount, 0, w.balanceOf(from));
        vm.prank(from);
        require(w.transfer(holders[toSeed % 3], amount), "transfer returned false");
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }
}

contract SeriesInvariantTest is SeriesFixture {
    SeriesHandler internal handler;

    function setUp() public {
        vm.warp(1_791_244_800);
        _deploySeries();
        handler = new SeriesHandler(
            registry,
            [seriesCreator, governance, guardian, clearing, settlementWindow, liquidationModule],
            weth,
            address(usdc),
            CFG,
            RISK_SET,
            ethUsdc,
            _ethConfig()
        );
        targetContract(address(handler));
    }

    /// @dev SER-005 / INV-34: terms never change after creation, whatever admin actions happen.
    function invariant_termsAreWriteOnce() public view {
        for (uint256 i; i < handler.idsLength(); ++i) {
            bytes32 id = handler.ids(i);
            assertEq(keccak256(abi.encode(registry.getSeries(id))), handler.termsHash(id));
        }
    }

    /// @dev Every series is in exactly its group; groups stay within MAX_SERIES_PER_GROUP; wrappers point back.
    function invariant_groupMembership() public view {
        for (uint256 i; i < handler.idsLength(); ++i) {
            bytes32 id = handler.ids(i);
            bytes32 g = registry.groupOf(id);
            bytes32[] memory members = registry.seriesInGroup(g);
            assertLe(members.length, registry.MAX_SERIES_PER_GROUP());
            uint256 found;
            for (uint256 j; j < members.length; ++j) {
                if (members[j] == id) found++;
            }
            assertEq(found, 1);
            SeriesTerms memory t = registry.getSeries(id);
            assertEq(ExternalOptionWrapper(t.wrapper).seriesId(), id);
            assertEq(ExternalOptionWrapper(t.wrapper).minter(), clearing);
            assertEq(registry.getGroup(g).expiry, t.expiry);
        }
    }

    /// @dev INV-4 (wrapper part): total supply equals minted − burned and the sum of all balances.
    function invariant_wrapperSupplyConservation() public view {
        for (uint256 i; i < handler.idsLength(); ++i) {
            bytes32 id = handler.ids(i);
            ExternalOptionWrapper w = ExternalOptionWrapper(registry.getSeries(id).wrapper);
            uint256 sum;
            for (uint256 h; h < 3; ++h) {
                sum += w.balanceOf(handler.holder(h));
            }
            assertEq(w.totalSupply(), handler.ghostSupply(id));
            assertEq(w.totalSupply(), sum);
        }
    }

    /// @dev Proves the handler's success paths run (the invariants are not vacuous).
    function test_handlerPathsReachable() public {
        handler.createSeries(3, 1, true);
        handler.createSeries(3, 1, false);
        assertEq(handler.idsLength(), 2);
        handler.mint(0, 0, 5e18);
        handler.transfer(0, 0, 1, 2e18);
        handler.burn(0, 1, 1e18, 2);
        handler.reapproveProduct(3000e18);
        handler.toggleProduct(false);
        handler.createSeries(5, 2, true); // disabled: no new series
        assertEq(handler.idsLength(), 2);
        handler.toggleProduct(true);
        handler.createSeries(5, 2, true);
        assertEq(handler.idsLength(), 3);
        invariant_termsAreWriteOnce();
        invariant_groupMembership();
        invariant_wrapperSupplyConservation();
    }
}
