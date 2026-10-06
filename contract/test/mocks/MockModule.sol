// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OptaraModule} from "../../src/governance/OptaraModule.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {Roles} from "../../src/governance/Roles.sol";
import {PauseBits} from "../../src/governance/PauseBits.sol";

/// @notice Minimal module used to test OptaraModule and upgrades. Storage follows the production pattern:
///         one ERC-7201 struct; V2 only appends fields.
contract MockModuleV1 is OptaraModule {
    /// @custom:storage-location erc7201:optara.storage.MockModule
    struct MockStorage {
        uint256 value;
        bytes32 protectedTerm; // write-once, like series terms (ACCESS_CONTROL.md §5)
    }

    bytes32 internal constant MOCK_SLOT =
        keccak256(abi.encode(uint256(keccak256("optara.storage.MockModule")) - 1)) & ~bytes32(uint256(0xff));

    event ValueSet(uint256 value);

    function initialize(IProtocolControl control_, uint256 value_) external initializer {
        __OptaraModule_init(control_);
        _ms().value = value_;
    }

    function setValue(uint256 v) external onlyRole(Roles.RISK_ADMIN) {
        _ms().value = v;
        emit ValueSet(v);
    }

    function setProtectedOnce(bytes32 t) external onlyRole(Roles.GOVERNANCE) {
        require(_ms().protectedTerm == 0, "written");
        _ms().protectedTerm = t;
    }

    function mintLike(address asset, bytes32 productId) external nonReentrant returns (bool) {
        _requireNotPaused(PauseBits.MINT, asset, productId);
        return true;
    }

    /// @dev Calls back into a nonReentrant function to prove the guard.
    function reenter() external nonReentrant {
        this.mintLike(address(0), 0);
    }

    function value() external view returns (uint256) {
        return _ms().value;
    }

    /// @dev Exposes OptaraModule._hasRole (modules use it for "role A or role B" checks).
    function isGuardianOrGovernance(address account) external view returns (bool) {
        return _hasRole(Roles.GUARDIAN, account) || _hasRole(Roles.GOVERNANCE, account);
    }

    function protectedTerm() external view returns (bytes32) {
        return _ms().protectedTerm;
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    function _ms() internal pure returns (MockStorage storage $) {
        bytes32 slot = MOCK_SLOT;
        assembly {
            $.slot := slot
        }
    }
}

/// @notice V2: same storage struct with one appended field and a migration hook.
contract MockModuleV2 is OptaraModule {
    /// @custom:storage-location erc7201:optara.storage.MockModule
    struct MockStorage {
        uint256 value;
        bytes32 protectedTerm;
        uint256 extra; // appended in V2
    }

    bytes32 internal constant MOCK_SLOT =
        keccak256(abi.encode(uint256(keccak256("optara.storage.MockModule")) - 1)) & ~bytes32(uint256(0xff));

    function migrate(uint256 extra_) external reinitializer(2) {
        _ms().extra = extra_;
    }

    function value() external view returns (uint256) {
        return _ms().value;
    }

    function protectedTerm() external view returns (bytes32) {
        return _ms().protectedTerm;
    }

    function extra() external view returns (uint256) {
        return _ms().extra;
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function _ms() internal pure returns (MockStorage storage $) {
        bytes32 slot = MOCK_SLOT;
        assembly {
            $.slot := slot
        }
    }
}

/// @notice Pretends to be an owned contract (owner() returns a fixed address).
contract FakeOwned {
    function owner() external pure returns (address) {
        return address(0xdead);
    }
}

/// @notice A module whose initializer deploys a contract. The proxy's ProxyAdmin then lands at nonce 2, so
///         UpgradeAdmin.deployProxy must refuse it (the contract at nonce 1 is not a ProxyAdmin it owns).
contract MockCreatingModule is OptaraModule {
    function initialize() external initializer {
        new FakeOwned();
    }
}
