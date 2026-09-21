// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OptionSeriesFactory} from "../src/OptionSeriesFactory.sol";
import {VaultDeployer} from "../src/VaultDeployer.sol";
import {PremiumExecutionGuard} from "../src/PremiumExecutionGuard.sol";
import {IVaultDeployer} from "../src/interfaces/IVaultDeployer.sol";
import {IOptionSeriesFactory} from "../src/interfaces/IOptionSeriesFactory.sol";
import {FeeConfig, PAUSER_ROLE} from "../src/Types.sol";

/// @notice Step 1 of the deployment runbook (simple-workflow/security-and-launch.md).
///
/// Deploys the VaultDeployer, the factory and the guard, then sets the fee defaults, the fee recipient and the
/// PAUSER. The broadcaster starts as the factory's ADMIN so it can finish configuration; it does NOT hand the
/// role over here. Run ConfigurePair for each pair next, then HandOverAdmin last.
///
/// Fee rates must be set BEFORE the first createSeries, because each series snapshots them for ever. That is why
/// they are set here, in the same script that deploys the factory.
///
/// Required env: FEE_RECIPIENT, PAUSER
/// Optional env: MINT_FEE_BPS (10), EXERCISE_FEE_BPS (25), GUARD_TOLERANCE_BPS (100), GUARD_MAX_REF_AGE (3600),
///               GUARD_MAX_VENUE_FEE_BPS (30)
contract Deploy is Script {
    function run() external returns (OptionSeriesFactory factory, PremiumExecutionGuard guard, VaultDeployer deployer) {
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address pauser = vm.envAddress("PAUSER");
        uint16 mintFee = uint16(vm.envOr("MINT_FEE_BPS", uint256(10)));
        uint16 exerciseFee = uint16(vm.envOr("EXERCISE_FEE_BPS", uint256(25)));
        uint16 tolerance = uint16(vm.envOr("GUARD_TOLERANCE_BPS", uint256(100)));
        uint32 maxRefAge = uint32(vm.envOr("GUARD_MAX_REF_AGE", uint256(3600)));
        uint16 maxVenueFee = uint16(vm.envOr("GUARD_MAX_VENUE_FEE_BPS", uint256(30)));

        require(feeRecipient != address(0) && pauser != address(0), "zero address");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();

        deployer = new VaultDeployer();
        factory = new OptionSeriesFactory(broadcaster, IVaultDeployer(address(deployer)));
        guard = new PremiumExecutionGuard(IOptionSeriesFactory(address(factory)), tolerance, maxRefAge, maxVenueFee);

        factory.setDefaultFeeConfig(FeeConfig({mintFeeBps: mintFee, exerciseFeeBps: exerciseFee}));
        factory.setFeeRecipient(feeRecipient);
        factory.grantRole(PAUSER_ROLE, pauser);
        vm.stopBroadcast();

        console.log("VaultDeployer         ", address(deployer));
        console.log("OptionSeriesFactory   ", address(factory));
        console.log("PremiumExecutionGuard ", address(guard));
        console.log("admin (broadcaster)   ", broadcaster);
        console.log("factory size (bytes)  ", address(factory).code.length);
    }
}
