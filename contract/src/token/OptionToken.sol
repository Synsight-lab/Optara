// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";

/// @title OptionToken
/// @notice The transferable long claim of exactly one Optara series (OPTION_SPEC.md section 19).
/// 18 decimals, no rebasing, no transfer tax, no hooks. Only the immutable core can mint (on a margined write) or
/// burn (on close, unfinalized cancellation, internal hedge settlement and redemption). The core only ever burns
/// from the account that called it or from its own custody, so no third party can burn a holder's tokens.
contract OptionToken is ERC20, IOptionToken {
    bytes32 public immutable seriesId;
    address public immutable core;

    error OnlyCore(address caller);
    error ZeroCore();

    constructor(string memory name_, string memory symbol_, bytes32 seriesId_, address core_) ERC20(name_, symbol_) {
        if (core_ == address(0)) revert ZeroCore();
        seriesId = seriesId_;
        core = core_;
    }

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore(msg.sender);
        _;
    }

    function mint(address to, uint256 amount) external onlyCore {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyCore {
        _burn(from, amount);
    }
}
