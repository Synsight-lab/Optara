// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {LocalMarketData} from "../local/LocalMarketData.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {IOptionClearing} from "../../src/interfaces/IOptionClearing.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {ISubAccounts} from "../../src/interfaces/ISubAccounts.sol";
import {ILiveSpotOracle} from "../../src/interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {IPortfolioRiskManager} from "../../src/interfaces/IPortfolioRiskManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionType, SeriesParams} from "../../src/libraries/OptaraTypes.sol";

/// @title RehearsalSmoke
/// @notice Fork rehearsal (`script/rehearse_fork.sh`), last step, after the listing proposals were executed: creates
///         an ATM weekly call, publishes a signed surface centered on the live Pyth price, and writes one contract
///         against the real Pyth ETH/USD ÷ USDC/USD spot. The spot comes from a real signed Pyth update (`PYTH_UPDATE`,
///         hex) pushed by the keeper through `updateOracles`, or, without one, from the forked chain's own price.
///         Reverts unless the writer is short 1, holds the wrapper and is above IM.
contract RehearsalSmoke is LocalMarketData {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";

    error SmokeFailed(string what);

    struct Stack {
        IOptionSeriesRegistry registry;
        IOptionClearing clearing;
        ISubAccounts ledger;
        IPortfolioRiskManager risk;
        ILiveSpotOracle spot;
        IERC20 usdc;
        bytes32 configId;
    }

    function run() external {
        string memory network = vm.envString("NETWORK");
        string memory dir = string.concat(vm.projectRoot(), "/../deployments/");
        string memory manifest = vm.readFile(string.concat(dir, network, ".json"));
        string memory listing = vm.readFile(string.concat(dir, "config/", network, ".eth-usdc.json"));
        string memory proposals = vm.readFile(string.concat(dir, network, ".eth-usdc.proposals.json"));
        Stack memory s = Stack({
            registry: IOptionSeriesRegistry(_proxy(manifest, "OptionSeriesRegistry")),
            clearing: IOptionClearing(_proxy(manifest, "OptionClearing")),
            ledger: ISubAccounts(_proxy(manifest, "SubAccounts")),
            risk: IPortfolioRiskManager(_proxy(manifest, "PortfolioRiskManager")),
            spot: ILiveSpotOracle(_proxy(manifest, "LiveSpotOracle")),
            usdc: IERC20(vm.parseJsonAddress(listing, ".asset")),
            configId: vm.parseJsonBytes32(proposals, ".settlementConfigId")
        });
        Market memory m = Market({
            pyth: address(0), // no spot blob: the forked Pyth price is used as is
            surface: IVolSurfaceOracle(_proxy(manifest, "VolSurfaceOracle")),
            productId: vm.parseJsonBytes32(proposals, ".productId"),
            underlying: vm.parseJsonAddress(listing, ".underlying"),
            asset: address(s.usdc),
            pythFeed: bytes32(0),
            keyA: vm.deriveKey(MNEMONIC, 2),
            keyB: vm.deriveKey(MNEMONIC, 3)
        });

        _pushSpot(s, m.productId, vm.envOr("PYTH_UPDATE", bytes("")));
        uint256 price = s.spot.requireFreshSpot(m.productId);
        uint64[] memory expiries = _weeklyExpiries();
        bytes32 seriesId = _createSeries(s, m, price, expiries[0]);
        OracleUpdate memory u = _surfaceUpdate(m, new bytes[](0), price, 0.6e18, expiries, 1);
        vm.broadcast(vm.deriveKey(MNEMONIC, 4)); // keeper
        s.clearing.updateOracles(u);
        uint256 a = _write(s, seriesId, vm.deriveKey(MNEMONIC, 5));
        console.log("rehearsal ok: live Pyth ETH/USDC spot %s (1e18); account %s short 1", price, a);
    }

    /// @dev The keeper's spot push through `updateOracles`, with a real signed Pyth update (replayed from the forked
    ///      chain by the rehearsal script). Without one, the forked price must still be fresh.
    function _pushSpot(Stack memory s, bytes32 productId, bytes memory blob) internal {
        if (blob.length == 0) return;
        OracleUpdate memory u;
        u.spotUpdates = new bytes[](1);
        u.spotUpdates[0] = blob;
        u.spotProductIds = new bytes32[](1);
        u.spotProductIds[0] = productId;
        uint256 fee = s.spot.updateFee(u.spotUpdates);
        vm.broadcast(vm.deriveKey(MNEMONIC, 4)); // keeper
        s.clearing.updateOracles{value: fee}(u);
        console.log("real Pyth update applied (fee %s wei)", fee);
    }

    /// @dev The first 100-USDC strike at or above spot.
    function _createSeries(Stack memory s, Market memory m, uint256 price, uint64 expiry) internal returns (bytes32) {
        SeriesParams memory sp = SeriesParams({
            underlying: m.underlying,
            settlementAsset: m.asset,
            optionType: OptionType.CALL,
            strikeWad: (price / 100e18 + 1) * 100e18,
            contractSizeWad: 1e18,
            expiry: expiry,
            settlementOracleConfigId: s.configId,
            volSurfaceProductId: m.productId,
            riskParameterSetId: keccak256("ETH/USDC default")
        });
        vm.broadcast(vm.deriveKey(MNEMONIC, 8)); // series creator
        return s.registry.createSeries(sp);
    }

    function _write(Stack memory s, bytes32 seriesId, uint256 key) internal returns (uint256 a) {
        address writer = vm.addr(key);
        OracleUpdate memory none;
        vm.startBroadcast(key);
        a = s.ledger.createSubAccount(address(s.usdc));
        s.usdc.approve(address(s.clearing), 20_000e6);
        s.clearing.depositCollateral(a, 20_000e6);
        s.clearing.mintExternalLong(a, seriesId, 1e18, writer, type(uint256).max, none);
        vm.stopBroadcast();
        IPortfolioRiskManager.Risk memory r = s.risk.riskOf(a);
        if (s.ledger.balanceOf(a, seriesId) != -1e18) revert SmokeFailed("writer short 1");
        if (IERC20(s.registry.getSeries(seriesId).wrapper).balanceOf(writer) != 1e18) revert SmokeFailed("wrapper");
        if (!r.fresh || r.equity < int256(r.initialMargin)) revert SmokeFailed("writer above initial margin");
        console.log("writer equity %s, IM %s, MM %s (1e18)", uint256(r.equity), r.initialMargin, r.maintenanceMargin);
    }

    function _proxy(string memory manifest, string memory name) internal pure returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".proxies.", name, ".proxy"));
    }
}
