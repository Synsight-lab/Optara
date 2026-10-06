// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SeriesFixture} from "./SeriesFixture.sol";
import {SubAccounts} from "../../src/accounts/SubAccounts.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../../src/interfaces/IOptionSeriesRegistry.sol";
import {OptionType, ProductConfig, SeriesParams} from "../../src/libraries/OptaraTypes.sol";
import {MockERC20} from "../mocks/MockDependencies.sol";

/// @notice Governance + series modules + SubAccounts. Two underlyings (ETH, BTC) settled in USDC, two expiries,
///         and a second settlement asset (USDT) for mismatch tests. Writers are stand-in addresses until the
///         real modules exist (steps 9–11).
abstract contract LedgerFixture is SeriesFixture {
    SubAccounts internal ledger;
    MockERC20 internal usdt;
    address internal wbtc = makeAddr("WBTC");
    bytes32 internal constant BTC_CFG = keccak256("BTC/USDC chainlink");
    bytes32 internal btcUsdc;

    uint64 internal constant T0 = 1_791_244_800; // 2026-10-06
    uint64 internal constant EXP1 = 1_798_185_600; // 2026-12-25 08:00
    uint64 internal constant EXP2 = EXP1 + 7 days;
    uint256 internal constant MIN_QTY = 0.01e18;
    int256 internal constant MIN_QTY_I = 0.01e18;

    // series: ETH calls/puts in two groups, one BTC call
    bytes32 internal ethC4500; // group A (EXP1)
    bytes32 internal ethP3500; // group A
    bytes32 internal ethC5000; // group A
    bytes32 internal ethC4500b; // group B (EXP2)
    bytes32 internal btcC90k; // BTC, EXP1
    bytes32 internal groupA;
    bytes32 internal groupB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _deployLedger() internal {
        vm.warp(T0);
        _deployGovernanceCore();
        _deploySeriesModules();
        ledger = SubAccounts(
            upgradeAdmin.deployProxy(
                address(new SubAccounts()),
                abi.encodeCall(
                    SubAccounts.initialize,
                    (
                        IProtocolControl(address(pc)),
                        IOptionSeriesRegistry(address(registry)),
                        clearing,
                        liquidationModule,
                        settlementWindow,
                        16,
                        4,
                        MIN_QTY
                    )
                )
            )
        );
        _handOver();
        _configureSeries();

        usdt = new MockERC20("Tether", "USDT", 6);
        settlementConfigs.set(BTC_CFG, wbtc, address(usdc), true);
        ProductConfig memory btc = _ethConfig();
        btc.underlyingSymbol = "BTC";
        vm.startPrank(governance);
        registry.setSettlementAssetApproved(address(usdt), true);
        btcUsdc = registry.approveProduct(wbtc, address(usdc), btc);
        vm.stopPrank();

        ethC4500 = _create(_params(OptionType.CALL, 4500e18, EXP1));
        ethP3500 = _create(_params(OptionType.PUT, 3500e18, EXP1));
        ethC5000 = _create(_params(OptionType.CALL, 5000e18, EXP1));
        ethC4500b = _create(_params(OptionType.CALL, 4500e18, EXP2));
        btcC90k = _createBtc(90_000e18, EXP1);
        groupA = registry.groupOf(ethC4500);
        groupB = registry.groupOf(ethC4500b);
    }

    function _createBtc(uint256 strike, uint64 expiry) internal returns (bytes32) {
        vm.prank(seriesCreator);
        return registry.createSeries(_paramsFor(wbtc, BTC_CFG, btcUsdc, OptionType.CALL, strike, expiry));
    }

    function _paramsFor(address u, bytes32 cfg, bytes32 product, OptionType t, uint256 strike, uint64 expiry)
        internal
        view
        returns (SeriesParams memory p)
    {
        p = _params(t, strike, expiry);
        p.underlying = u;
        p.settlementOracleConfigId = cfg;
        p.volSurfaceProductId = product;
    }

    function _newAccount(address owner, address asset) internal returns (uint256 id) {
        vm.prank(owner);
        id = ledger.createSubAccount(asset);
    }

    function _delta(uint256 id, bytes32 s, int256 d) internal returns (int256) {
        vm.prank(clearing);
        return ledger.applyDelta(id, s, d);
    }
}
