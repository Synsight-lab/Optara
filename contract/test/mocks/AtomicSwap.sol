// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal venue that settles payment and delivery in one transaction (USER_FLOWS.md section 37 MVP sale).
contract AtomicSwap {
    function swap(IERC20 option, address seller, uint256 qty, IERC20 payToken, uint256 price) external {
        option.transferFrom(seller, msg.sender, qty);
        payToken.transferFrom(msg.sender, seller, price);
    }
}
