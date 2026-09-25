// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract DecimalsERC20 is ERC20 {
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
}

/// @notice Calls back into a target from inside transfer/transferFrom to test reentrancy guards.
contract ReentrantERC20 is DecimalsERC20 {
    address public target;
    bytes public data;
    bool public armed;
    bool public reentered;
    bool public reenterSucceeded;
    bytes public reenterReturn;

    constructor(string memory n, string memory s, uint8 d) DecimalsERC20(n, s, d) {}

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
        reentered = false;
        reenterSucceeded = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0) && to != address(0)) {
            armed = false;
            reentered = true;
            (bool ok, bytes memory ret) = target.call(data);
            reenterSucceeded = ok;
            reenterReturn = ret;
        }
    }
}

/// @notice Refuses transfers to blacklisted recipients (USDC-like freeze) and can be globally paused.
contract BlacklistERC20 is DecimalsERC20 {
    mapping(address => bool) public blacklisted;
    bool public paused;

    constructor(string memory n, string memory s, uint8 d) DecimalsERC20(n, s, d) {}

    function setBlacklisted(address a, bool v) external {
        blacklisted[a] = v;
    }

    function setPaused(bool v) external {
        paused = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "paused");
        require(!blacklisted[to] && !blacklisted[from], "blacklisted");
        super._update(from, to, value);
    }
}

/// @notice 1% fee-on-transfer token. Unsupported (DD-040); the core must reject the deposit.
contract FeeOnTransferERC20 is DecimalsERC20 {
    constructor(string memory n, string memory s, uint8 d) DecimalsERC20(n, s, d) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Rebasing-like token: the owner can scale every balance, mutating custody without a transfer.
contract RebasingERC20 is DecimalsERC20 {
    uint256 public multiplierBps = 10_000;

    constructor(string memory n, string memory s, uint8 d) DecimalsERC20(n, s, d) {}

    function rebase(uint256 newMultiplierBps) external {
        multiplierBps = newMultiplierBps;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return super.balanceOf(a) * multiplierBps / 10_000;
    }
}

/// @notice Returns false instead of reverting when a transfer fails.
contract FalseReturnERC20 {
    string public name = "False";
    string public symbol = "FALSE";
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (balanceOf[msg.sender] < a) return false;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (balanceOf[f] < a || allowance[f][msg.sender] < a) return false;
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice USDT-style token: transfer/transferFrom return nothing and revert on failure.
contract NoReturnERC20 {
    string public name = "NoReturn";
    string public symbol = "NORET";
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        require(balanceOf[msg.sender] >= a, "balance");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a, "allowance");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}
