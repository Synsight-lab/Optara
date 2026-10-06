// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskFixture} from "./RiskFixture.sol";
import {OracleUpdate} from "../../src/oracle/OracleUpdates.sol";
import {IVolSurfaceOracle} from "../../src/interfaces/IVolSurfaceOracle.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice RiskFixture with the real OptionClearing at the `clearing` address and the risk manager's reserve check
///         wired to the real FeeController. Provides the worked-example market and the series used in CLR tests.
abstract contract ClearingFixture is RiskFixture {
    bytes32 internal c4500;
    bytes32 internal c5000;
    bytes32 internal p3500;
    bytes32 internal group30;
    address internal bob = makeAddr("bob");

    function _deployRealClearing() internal pure override returns (bool) {
        return true;
    }

    function _useRealReserves() internal pure override returns (bool) {
        return true;
    }

    function _deployClearingMarket() internal {
        _deployRisk();
        _workedExampleMarket();
        c4500 = _series(ethUsdc, OptionType.CALL, 4500e18, EXP30);
        c5000 = _series(ethUsdc, OptionType.CALL, 5000e18, EXP30);
        p3500 = _series(ethUsdc, OptionType.PUT, 3500e18, EXP30);
        group30 = registry.groupOf(c4500);
    }

    // ------------------------------------------------------------------ oracle updates

    function _empty() internal pure returns (OracleUpdate memory u) {}

    /// @dev Spot at `priceWad` and a fresh worked-example surface (re-centred at that spot), as one OracleUpdate.
    function _marketUpdate(uint256 priceWad) internal returns (OracleUpdate memory u) {
        u.spotUpdates = new bytes[](1);
        u.spotUpdates[0] = _spotBlob(ethUsdc, priceWad);
        u.spotProductIds = new bytes32[](1);
        u.spotProductIds[0] = ethUsdc;
        uint256[] memory k = new uint256[](3);
        uint256[] memory iv = new uint256[](3);
        (k[0], k[1], k[2]) = (3500e18, 4500e18, 5000e18);
        (iv[0], iv[1], iv[2]) = (0.65e18, 0.6e18, 0.62e18);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (EXP30, T0 + 60 days);
        u.reports = new IVolSurfaceOracle.SurfaceReport[](1);
        u.reportSignatures = new bytes[][](1);
        (u.reports[0], u.reportSignatures[0], u.nodes) = _buildSurface(ethUsdc, priceWad, k, iv, tenors);
    }

    /// @dev Only a spot update for ETH.
    function _spotUpdate(uint256 priceWad) internal returns (OracleUpdate memory u) {
        u.spotUpdates = new bytes[](1);
        u.spotUpdates[0] = _spotBlob(ethUsdc, priceWad);
        u.spotProductIds = new bytes32[](1);
        u.spotProductIds[0] = ethUsdc;
    }

    // ------------------------------------------------------------------ actions

    function _deposit(uint256 accountId, address from, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(clearingModule), amount);
        clearingModule.depositCollateral(accountId, amount);
        vm.stopPrank();
    }

    function _mint(uint256 accountId, address owner, bytes32 seriesId, uint256 qty) internal {
        vm.prank(owner);
        clearingModule.mintExternalLong(accountId, seriesId, qty, owner, type(uint256).max, _empty());
    }

    function _wrapper(bytes32 seriesId) internal view returns (address) {
        return registry.getSeries(seriesId).wrapper;
    }
}
