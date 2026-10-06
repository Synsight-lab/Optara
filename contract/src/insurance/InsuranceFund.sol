// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {NotAuthorized, ZeroAddress, ZeroAmount, NonExactTransfer, TokensNotReceived} from "../libraries/Errors.sol";

/// @title InsuranceFund
/// @notice Insurance balance per settlement asset. Funded by deposits, the insurance share of every fee,
///         liquidation penalties and swept settlement dust; pays bad-debt coverage into OptionClearing custody
///         (docs/FEES.md, LIQUIDATION.md §5, SETTLEMENT.md §7).
/// @dev The recorded balance never exceeds the tokens held (INV-37): every credit either pulls the tokens itself
///      (`deposit`) or checks they arrived (`notifyDeposit`). Coverage can only go to OptionClearing.
contract InsuranceFund is OptaraModule, IInsuranceFund {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:optara.storage.InsuranceFund
    struct InsuranceStorage {
        address feeController;
        address clearing;
        address liquidationModule;
        address settlementWindow;
        mapping(address asset => uint256) balances;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.InsuranceFund")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xf9ae136455891c346b2f4a2b25f9d9aded00dcfb73c5b2ccf7fee88d4b853c00;

    function initialize(
        IProtocolControl control_,
        address feeController_,
        address clearing_,
        address liquidationModule_,
        address settlementWindow_
    ) external initializer {
        __OptaraModule_init(control_);
        if (
            feeController_ == address(0) || clearing_ == address(0) || liquidationModule_ == address(0)
                || settlementWindow_ == address(0)
        ) revert ZeroAddress();
        InsuranceStorage storage $ = _s();
        $.feeController = feeController_;
        $.clearing = clearing_;
        $.liquidationModule = liquidationModule_;
        $.settlementWindow = settlementWindow_;
    }

    /// @inheritdoc IInsuranceFund
    function deposit(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert NonExactTransfer(amount, received);
        _s().balances[asset] += amount;
        emit InsuranceDeposited(asset, msg.sender, amount);
    }

    /// @inheritdoc IInsuranceFund
    function notifyDeposit(address asset, uint256 amount) external nonReentrant {
        InsuranceStorage storage $ = _s();
        if (msg.sender != $.feeController && msg.sender != $.clearing) revert NotAuthorized(msg.sender);
        uint256 held = IERC20(asset).balanceOf(address(this));
        uint256 recorded = $.balances[asset];
        if (held < recorded + amount) revert TokensNotReceived(amount, held - recorded);
        $.balances[asset] = recorded + amount;
        emit InsuranceDeposited(asset, msg.sender, amount);
    }

    /// @inheritdoc IInsuranceFund
    function cover(address asset, uint256 amount) external nonReentrant returns (uint256 paid) {
        InsuranceStorage storage $ = _s();
        if (msg.sender != $.liquidationModule && msg.sender != $.settlementWindow) revert NotAuthorized(msg.sender);
        uint256 balance = $.balances[asset];
        paid = amount < balance ? amount : balance;
        if (paid == 0) return 0;
        $.balances[asset] = balance - paid;
        IERC20(asset).safeTransfer($.clearing, paid);
        emit InsurancePaid(asset, msg.sender, paid);
    }

    function balanceOf(address asset) external view returns (uint256) {
        return _s().balances[asset];
    }

    function modules()
        external
        view
        returns (address feeController, address clearing, address liquidationModule, address settlementWindow)
    {
        InsuranceStorage storage $ = _s();
        return ($.feeController, $.clearing, $.liquidationModule, $.settlementWindow);
    }

    function _s() private pure returns (InsuranceStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
