// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibRLP} from "solady/utils/LibRLP.sol";
import {UpgradeAdmin} from "../src/governance/UpgradeAdmin.sol";
import {ProtocolControl} from "../src/governance/ProtocolControl.sol";
import {Roles} from "../src/governance/Roles.sol";
import {OptionSeriesRegistry} from "../src/series/OptionSeriesRegistry.sol";
import {ExternalOptionFactory} from "../src/series/ExternalOptionFactory.sol";
import {ExternalOptionWrapper} from "../src/series/ExternalOptionWrapper.sol";
import {SubAccounts} from "../src/accounts/SubAccounts.sol";
import {LiveSpotOracle} from "../src/oracle/LiveSpotOracle.sol";
import {VolSurfaceOracle} from "../src/oracle/VolSurfaceOracle.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {PortfolioRiskManager} from "../src/risk/PortfolioRiskManager.sol";
import {InsuranceFund} from "../src/insurance/InsuranceFund.sol";
import {FeeController} from "../src/fees/FeeController.sol";
import {OptionClearing} from "../src/clearing/OptionClearing.sol";
import {LiquidationModule} from "../src/liquidation/LiquidationModule.sol";
import {SettlementWindow} from "../src/settlement/SettlementWindow.sol";
import {VenueRegistry} from "../src/venues/VenueRegistry.sol";
import {VenueRouter} from "../src/venues/VenueRouter.sol";
import {KuruAdapter} from "../src/venues/kuru/KuruAdapter.sol";
import {IKuruRouter} from "../src/venues/kuru/IKuru.sol";
import {IProtocolControl} from "../src/interfaces/IProtocolControl.sol";
import {IOptionSeriesRegistry} from "../src/interfaces/IOptionSeriesRegistry.sol";
import {IExternalOptionFactory} from "../src/interfaces/IExternalOptionFactory.sol";
import {ISubAccounts} from "../src/interfaces/ISubAccounts.sol";
import {ILiveSpotOracle} from "../src/interfaces/ILiveSpotOracle.sol";
import {IVolSurfaceOracle} from "../src/interfaces/IVolSurfaceOracle.sol";
import {IPortfolioRiskManager} from "../src/interfaces/IPortfolioRiskManager.sol";
import {IInsuranceFund} from "../src/interfaces/IInsuranceFund.sol";
import {IFeeController} from "../src/interfaces/IFeeController.sol";
import {IOptionClearing} from "../src/interfaces/IOptionClearing.sol";
import {ILiquidationModule} from "../src/interfaces/ILiquidationModule.sol";
import {ISettlementWindow} from "../src/interfaces/ISettlementWindow.sol";
import {IVenueRegistry} from "../src/interfaces/IVenueRegistry.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {
    ISettlementConfigs,
    IRiskSets,
    ISettlementState,
    IReserveStatus
} from "../src/interfaces/IExternalDependencies.sol";

/// @title OptaraDeploy
/// @notice The production deployment (docs/DEPLOYMENT.md §2), shared by the broadcast script and the E2E tests so the
///         tests exercise exactly what ships. Every call is made by `config.deployer`.
/// @dev UpgradeAdmin is fresh, so its k-th proxy (counting ProtocolControl as the first) is created at its nonce
///      1 + k (one CREATE per proxy; DD-22). Each initializer receives the final addresses of the modules it calls, so
///      there are no wiring setters. The deployer ends holding nothing.
abstract contract OptaraDeploy {
    struct Config {
        address deployer; // sends every call; holds GOVERNANCE and the UpgradeAdmin deployer seat until the end
        address governance; // the governance timelock
        address guardian;
        address council; // emergency council
        address riskAdmin;
        address oracleAdmin;
        address seriesCreator;
        address venueAdmin;
        uint256 upgradeDelay;
        uint256 emergencyDelay;
        address pyth;
        address kuruRouter; // zero: no Kuru adapter
        uint256 surfaceQuorum;
        uint256 maxSeriesPerAccount;
        uint256 maxBucketsPerAccount;
        uint256 minPositionQty;
    }

    struct Deployment {
        UpgradeAdmin upgradeAdmin;
        ProtocolControl control;
        OptionSeriesRegistry registry;
        ExternalOptionFactory factory;
        SubAccounts ledger;
        LiveSpotOracle spot;
        VolSurfaceOracle surface;
        SettlementOracle settlementOracle;
        PortfolioRiskManager risk;
        InsuranceFund insurance;
        FeeController fees;
        OptionClearing clearing;
        LiquidationModule liquidation;
        SettlementWindow window;
        VenueRegistry venues;
        VenueRouter router;
        KuruAdapter kuruAdapter; // zero if no Kuru router was given
    }

    // proxy order after ProtocolControl (DEPLOYMENT.md §2)
    uint256 internal constant P_REGISTRY = 1;
    uint256 internal constant P_FACTORY = 2;
    uint256 internal constant P_LEDGER = 3;
    uint256 internal constant P_SPOT = 4;
    uint256 internal constant P_SURFACE = 5;
    uint256 internal constant P_SETTLEMENT_ORACLE = 6;
    uint256 internal constant P_RISK = 7;
    uint256 internal constant P_INSURANCE = 8;
    uint256 internal constant P_FEES = 9;
    uint256 internal constant P_CLEARING = 10;
    uint256 internal constant P_LIQUIDATION = 11;
    uint256 internal constant P_WINDOW = 12;
    uint256 internal constant P_VENUES = 13;
    uint256 internal constant P_ROUTER = 14;

    error DeploymentMismatch(uint256 index, address expected, address actual);
    error DeployerKeptRole();

    function _deploy(Config memory c) internal returns (Deployment memory d) {
        _deployGovernance(c, d);
        _deployCore(c, d);
        _deployEngine(d);
        _deployVenues(c, d);
        _handOver(c, d);
    }

    // ------------------------------------------------------------------------------------------------ steps

    function _deployGovernance(Config memory c, Deployment memory d) private {
        d.upgradeAdmin = new UpgradeAdmin(c.governance, c.council, c.deployer, c.upgradeDelay, c.emergencyDelay);
        d.control = ProtocolControl(
            d.upgradeAdmin
                .deployProxy(
                    address(new ProtocolControl()),
                    abi.encodeCall(ProtocolControl.initialize, (c.deployer, address(d.upgradeAdmin)))
                )
        );
        _check(d, 0, address(d.control));
        d.upgradeAdmin.setProtocolControl(IProtocolControl(address(d.control)));
        d.control.grantRole(Roles.GOVERNANCE, c.governance);
        d.control.grantRole(Roles.GUARDIAN, c.guardian);
        d.control.grantRole(Roles.RISK_ADMIN, c.riskAdmin);
        d.control.grantRole(Roles.ORACLE_ADMIN, c.oracleAdmin);
        d.control.grantRole(Roles.SERIES_CREATOR, c.seriesCreator);
        d.control.grantRole(Roles.VENUE_ADMIN, c.venueAdmin);
    }

    /// @dev Registry, factory, ledger and the three oracles.
    function _deployCore(Config memory c, Deployment memory d) private {
        IProtocolControl pc = IProtocolControl(address(d.control));
        d.registry = OptionSeriesRegistry(
            _proxy(
                d,
                P_REGISTRY,
                address(new OptionSeriesRegistry()),
                abi.encodeCall(
                    OptionSeriesRegistry.initialize,
                    (
                        pc,
                        IExternalOptionFactory(_at(d, P_FACTORY)),
                        ISettlementConfigs(_at(d, P_SETTLEMENT_ORACLE)),
                        IRiskSets(_at(d, P_RISK))
                    )
                )
            )
        );
        d.factory = ExternalOptionFactory(
            _proxy(
                d,
                P_FACTORY,
                address(new ExternalOptionFactory()),
                abi.encodeCall(
                    ExternalOptionFactory.initialize,
                    (
                        pc,
                        address(new ExternalOptionWrapper()),
                        address(d.registry),
                        _at(d, P_CLEARING),
                        _at(d, P_WINDOW),
                        _at(d, P_LIQUIDATION)
                    )
                )
            )
        );
        d.ledger = SubAccounts(
            _proxy(
                d,
                P_LEDGER,
                address(new SubAccounts()),
                abi.encodeCall(
                    SubAccounts.initialize,
                    (
                        pc,
                        IOptionSeriesRegistry(address(d.registry)),
                        _at(d, P_CLEARING),
                        _at(d, P_LIQUIDATION),
                        _at(d, P_WINDOW),
                        c.maxSeriesPerAccount,
                        c.maxBucketsPerAccount,
                        c.minPositionQty
                    )
                )
            )
        );
        d.spot = LiveSpotOracle(
            _proxy(
                d,
                P_SPOT,
                address(new LiveSpotOracle()),
                abi.encodeCall(
                    LiveSpotOracle.initialize, (pc, IPyth(c.pyth), IOptionSeriesRegistry(address(d.registry)))
                )
            )
        );
        d.surface = VolSurfaceOracle(
            _proxy(
                d,
                P_SURFACE,
                address(new VolSurfaceOracle()),
                abi.encodeCall(
                    VolSurfaceOracle.initialize, (pc, IOptionSeriesRegistry(address(d.registry)), c.surfaceQuorum)
                )
            )
        );
        d.settlementOracle = SettlementOracle(
            _proxy(
                d,
                P_SETTLEMENT_ORACLE,
                address(new SettlementOracle()),
                abi.encodeCall(SettlementOracle.initialize, (pc))
            )
        );
    }

    /// @dev Risk, insurance, fees, clearing, liquidation and settlement.
    function _deployEngine(Deployment memory d) private {
        IProtocolControl pc = IProtocolControl(address(d.control));
        d.risk = PortfolioRiskManager(
            _proxy(
                d,
                P_RISK,
                address(new PortfolioRiskManager()),
                abi.encodeCall(
                    PortfolioRiskManager.initialize,
                    (
                        pc,
                        ISubAccounts(address(d.ledger)),
                        IOptionSeriesRegistry(address(d.registry)),
                        ILiveSpotOracle(address(d.spot)),
                        IVolSurfaceOracle(address(d.surface)),
                        ISettlementState(_at(d, P_WINDOW)),
                        IReserveStatus(_at(d, P_FEES))
                    )
                )
            )
        );
        d.insurance = InsuranceFund(
            _proxy(
                d,
                P_INSURANCE,
                address(new InsuranceFund()),
                abi.encodeCall(
                    InsuranceFund.initialize,
                    (pc, _at(d, P_FEES), _at(d, P_CLEARING), _at(d, P_LIQUIDATION), _at(d, P_WINDOW))
                )
            )
        );
        d.fees = FeeController(
            _proxy(
                d,
                P_FEES,
                address(new FeeController()),
                abi.encodeCall(
                    FeeController.initialize,
                    (
                        pc,
                        IInsuranceFund(address(d.insurance)),
                        IPortfolioRiskManager(address(d.risk)),
                        IOptionSeriesRegistry(address(d.registry)),
                        _at(d, P_CLEARING),
                        _at(d, P_ROUTER),
                        _at(d, P_WINDOW)
                    )
                )
            )
        );
        _deployClearing(d, pc);
        _deploySettlement(d, pc);
    }

    function _deployClearing(Deployment memory d, IProtocolControl pc) private {
        IOptionClearing.Modules memory m = IOptionClearing.Modules({
            ledger: address(d.ledger),
            registry: address(d.registry),
            risk: address(d.risk),
            fees: address(d.fees),
            insurance: address(d.insurance),
            spot: address(d.spot),
            surface: address(d.surface),
            settlementState: _at(d, P_WINDOW),
            liquidationModule: _at(d, P_LIQUIDATION),
            settlementWindow: _at(d, P_WINDOW)
        });
        d.clearing = OptionClearing(
            _proxy(d, P_CLEARING, address(new OptionClearing()), abi.encodeCall(OptionClearing.initialize, (pc, m)))
        );
        ILiquidationModule.Modules memory l = ILiquidationModule.Modules({
            ledger: address(d.ledger),
            registry: address(d.registry),
            risk: address(d.risk),
            insurance: address(d.insurance),
            clearing: address(d.clearing),
            spot: address(d.spot),
            surface: address(d.surface)
        });
        d.liquidation = LiquidationModule(
            _proxy(
                d,
                P_LIQUIDATION,
                address(new LiquidationModule()),
                abi.encodeCall(LiquidationModule.initialize, (pc, l))
            )
        );
    }

    function _deploySettlement(Deployment memory d, IProtocolControl pc) private {
        ISettlementWindow.Modules memory m = ISettlementWindow.Modules({
            ledger: address(d.ledger),
            registry: address(d.registry),
            settlementOracle: address(d.settlementOracle),
            fees: address(d.fees),
            insurance: address(d.insurance),
            clearing: address(d.clearing)
        });
        d.window = SettlementWindow(
            _proxy(d, P_WINDOW, address(new SettlementWindow()), abi.encodeCall(SettlementWindow.initialize, (pc, m)))
        );
    }

    function _deployVenues(Config memory c, Deployment memory d) private {
        IProtocolControl pc = IProtocolControl(address(d.control));
        IOptionSeriesRegistry reg = IOptionSeriesRegistry(address(d.registry));
        d.venues = VenueRegistry(
            _proxy(d, P_VENUES, address(new VenueRegistry()), abi.encodeCall(VenueRegistry.initialize, (pc, reg)))
        );
        d.router = VenueRouter(
            _proxy(
                d,
                P_ROUTER,
                address(new VenueRouter()),
                abi.encodeCall(
                    VenueRouter.initialize,
                    (pc, reg, IVenueRegistry(address(d.venues)), IFeeController(address(d.fees)))
                )
            )
        );
        if (c.kuruRouter != address(0)) {
            d.kuruAdapter = new KuruAdapter(address(d.router), IKuruRouter(c.kuruRouter));
            d.venues.registerAdapter(d.kuruAdapter.VENUE_ID(), address(d.kuruAdapter)); // registered disabled
        }
    }

    /// @dev DEPLOYMENT.md §2 step 5: the deployer keeps nothing.
    function _handOver(Config memory c, Deployment memory d) private {
        d.control.renounceRole(Roles.GOVERNANCE, c.deployer);
        d.upgradeAdmin.renounceDeployer();
        if (d.control.hasRole(Roles.GOVERNANCE, c.deployer) || d.upgradeAdmin.deployer() != address(0)) {
            revert DeployerKeptRole();
        }
    }

    // ------------------------------------------------------------------------------------------------ helpers

    /// @dev The address of proxy `index` (ProtocolControl = 0): UpgradeAdmin's CREATE at nonce 1 + index.
    function _at(Deployment memory d, uint256 index) internal pure returns (address) {
        return LibRLP.computeAddress(address(d.upgradeAdmin), 1 + index);
    }

    function _proxy(Deployment memory d, uint256 index, address implementation, bytes memory init)
        private
        returns (address proxy)
    {
        proxy = d.upgradeAdmin.deployProxy(implementation, init);
        _check(d, index, proxy);
    }

    function _check(Deployment memory d, uint256 index, address actual) private pure {
        address expected = _at(d, index);
        if (actual != expected) revert DeploymentMismatch(index, expected, actual);
    }
}
