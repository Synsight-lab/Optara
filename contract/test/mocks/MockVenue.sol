// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Kuru-like external venue for boundary tests (KURU_INTEGRATION.md, PROTOCOL_SPEC.md section 13).
/// Traders keep balances in the venue's OWN margin account; fills move those internal balances and charge a
/// quote-side taker fee. The venue can be halted (outage). Optara never calls this contract.
contract MockVenue {
    mapping(address => mapping(address => uint256)) public marginBalance; // trader => token => amount
    uint256 public feeBps;
    bool public halted;
    uint256 public feesCollected;

    error VenueHalted();
    error InsufficientVenueBalance();
    error SlippageExceeded(uint256 cost, uint256 maxCost);

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function setHalted(bool h) external {
        halted = h;
    }

    function depositMargin(IERC20 token, uint256 amount) external {
        if (halted) revert VenueHalted();
        token.transferFrom(msg.sender, address(this), amount);
        marginBalance[msg.sender][address(token)] += amount;
    }

    function withdrawMargin(IERC20 token, uint256 amount) external {
        if (halted) revert VenueHalted();
        if (marginBalance[msg.sender][address(token)] < amount) revert InsufficientVenueBalance();
        marginBalance[msg.sender][address(token)] -= amount;
        token.transfer(msg.sender, amount);
    }

    /// @notice Buyer takes `qty` base from `seller` at `price` quote (total), paying a taker fee on top, bounded by
    ///         `maxCost`. Balances move only inside the venue's margin accounts.
    function fill(address seller, IERC20 base, IERC20 quote, uint256 qty, uint256 price, uint256 maxCost) external {
        if (halted) revert VenueHalted();
        uint256 fee = price * feeBps / 10_000;
        uint256 cost = price + fee;
        if (cost > maxCost) revert SlippageExceeded(cost, maxCost);
        address buyer = msg.sender;
        if (marginBalance[seller][address(base)] < qty || marginBalance[buyer][address(quote)] < cost) {
            revert InsufficientVenueBalance();
        }
        marginBalance[seller][address(base)] -= qty;
        marginBalance[buyer][address(base)] += qty;
        marginBalance[buyer][address(quote)] -= cost;
        marginBalance[seller][address(quote)] += price;
        feesCollected += fee;
    }
}
