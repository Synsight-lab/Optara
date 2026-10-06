// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title PauseBits
/// @notice Pause bit indices (docs/PROTOCOL_SPEC.md §11). A pause mask is `1 << bit` per paused action.
/// @dev Guidance: never pause DEPOSIT, UNWRAP or CLOSE unless they themselves are broken; they only reduce risk.
library PauseBits {
    uint8 internal constant DEPOSIT = 0;
    uint8 internal constant WITHDRAW = 1;
    uint8 internal constant MINT = 2;
    uint8 internal constant WRAP = 3;
    uint8 internal constant UNWRAP = 4;
    uint8 internal constant CLOSE = 5;
    uint8 internal constant LIQUIDATE = 6;
    uint8 internal constant FINALIZE = 7;
    uint8 internal constant SETTLE = 8;
    uint8 internal constant CLAIM_REDEEM = 9;
    uint8 internal constant ROUTER = 10;
    uint8 internal constant SERIES_CREATE = 11;

    uint8 internal constant COUNT = 12;
    /// @dev Mask with every defined bit set.
    // forge-lint: disable-next-line(incorrect-shift)
    uint256 internal constant ALL = (1 << COUNT) - 1; // 1 shifted left by COUNT: intended
}
