// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IExternalOptionWrapper} from "../interfaces/IExternalOptionWrapper.sol";
import {NotAuthorized, ZeroAddress} from "../libraries/Errors.sol";

/// @title ExternalOptionWrapper
/// @notice ERC-20 long claim on one Optara series (docs/OPTION_SPEC.md §7). Deployed as an immutable EIP-1167 clone
///         per series by ExternalOptionFactory. The series id, the minter and the burners are fixed at
///         initialization; nothing can change them afterwards. No hooks, no pausing, no fee on transfer.
/// @dev The implementation contract itself can never be initialized.
contract ExternalOptionWrapper is Initializable, ERC20PermitUpgradeable, IExternalOptionWrapper {
    /// @custom:storage-location erc7201:optara.storage.ExternalOptionWrapper
    struct WrapperStorage {
        bytes32 seriesId;
        address minter; // OptionClearing
        address settlementWindow;
        address liquidationModule;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.ExternalOptionWrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x548e9da9289d772a751b46194c2eaf79f956832cf6b54fe06e13ee0d6aff3500;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param minter_ OptionClearing (mints; also burns on unwrap and close).
    /// @param settlementWindow_ Burns on redemption.
    /// @param liquidationModule_ Burns on wrapper-burn liquidation.
    function initialize(
        bytes32 seriesId_,
        string calldata name_,
        string calldata symbol_,
        address minter_,
        address settlementWindow_,
        address liquidationModule_
    ) external initializer {
        if (minter_ == address(0) || settlementWindow_ == address(0) || liquidationModule_ == address(0)) {
            revert ZeroAddress();
        }
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        WrapperStorage storage $ = _s();
        $.seriesId = seriesId_;
        $.minter = minter_;
        $.settlementWindow = settlementWindow_;
        $.liquidationModule = liquidationModule_;
    }

    /// @inheritdoc IExternalOptionWrapper
    function mint(address to, uint256 amount) external {
        if (msg.sender != _s().minter) revert NotAuthorized(msg.sender);
        _mint(to, amount);
    }

    /// @inheritdoc IExternalOptionWrapper
    function burn(address from, uint256 amount) external {
        if (!isBurner(msg.sender)) revert NotAuthorized(msg.sender);
        _burn(from, amount);
    }

    /// @inheritdoc IExternalOptionWrapper
    function seriesId() external view returns (bytes32) {
        return _s().seriesId;
    }

    /// @inheritdoc IExternalOptionWrapper
    function minter() external view returns (address) {
        return _s().minter;
    }

    /// @inheritdoc IExternalOptionWrapper
    function isBurner(address account) public view returns (bool) {
        WrapperStorage storage $ = _s();
        return account == $.minter || account == $.settlementWindow || account == $.liquidationModule;
    }

    /// @dev Resolves the diamond between OpenZeppelin's ERC20 and the interface.
    function nonces(address owner) public view override(ERC20PermitUpgradeable, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    function _s() private pure returns (WrapperStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
