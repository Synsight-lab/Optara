// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token that calls back into a target from inside transfer / transferFrom, to test reentrancy.
///         It records whether the reentrant call succeeded. The vault must make it fail.
contract ReentrantERC20 is ERC20 {
    uint8 private immutable _decimals;
    address public target;
    bytes public data;
    bool public armed;
    bool public reentered; // the callback ran
    bool public reenterSucceeded; // the callback SUCCEEDED (must stay false)

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
        reentered = false;
        reenterSucceeded = false;
    }

    function disarm() external {
        armed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0) && to != address(0)) {
            armed = false; // only once
            reentered = true;
            (bool ok,) = target.call(data);
            reenterSucceeded = ok;
        }
    }
}

/// @notice A USDC-like token that refuses to transfer to blacklisted addresses, to test that one bad
///         recipient cannot block a keeper batch.
contract BlacklistERC20 is ERC20 {
    uint8 private immutable _decimals;
    mapping(address => bool) public blacklisted;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address a, bool v) external {
        blacklisted[a] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[to], "blacklisted");
        super._update(from, to, value);
    }
}

/// @notice A fee-on-transfer token. The protocol does NOT support these: the asset allowlist is the only
///         defense. A test uses this to document exactly why.
contract FeeOnTransferERC20 is ERC20 {
    uint8 private immutable _decimals;
    uint256 public feeBps = 100; // 1%

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice A token that reverts on zero-value transfers, like some real tokens. The vault must skip a transfer
///         entirely when the amount is zero.
contract NoZeroTransferERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(value != 0 || from == address(0) || to == address(0), "zero transfer");
        super._update(from, to, value);
    }
}

/// @notice A contract that is a real writer / holder / receiver, so that a reentrant call from a hostile token
///         hook is a call the vault would accept if it were not guarded. It runs a payload on `reenter()`.
contract ReentrancyAttacker {
    address public vault;
    bytes public payload;
    bool public ran;
    bool public succeeded;

    function setPayload(address vault_, bytes calldata payload_) external {
        vault = vault_;
        payload = payload_;
        ran = false;
        succeeded = false;
    }

    function reenter() external {
        ran = true;
        (bool ok,) = vault.call(payload);
        succeeded = ok;
    }

    /// Forwards an arbitrary call so the attacker is msg.sender.
    function forward(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    function approve(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }
}

/// @notice A token with decimals() but NO symbol(): creation must still work and fall back to "?" in the name.
contract NoSymbolToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
