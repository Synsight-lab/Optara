// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {
    OptionType,
    FeeConfig,
    SeriesConfig,
    SeriesInfo,
    SettlementProof,
    MAX_MINT_FEE_BPS,
    MAX_EXERCISE_FEE_BPS,
    ADMIN_ROLE,
    PAUSER_ROLE
} from "./Types.sol";
import {
    ZeroAddress,
    AssetNotAllowed,
    InvalidStrike,
    InvalidExpiry,
    InvalidContractSize,
    InvalidMinOptionAmount,
    InvalidOracleConfig,
    FeeExceedsCap,
    Unauthorized,
    MintPaused,
    Expired,
    NotExpired,
    AlreadySettled,
    NotSettled,
    AmountTooSmall,
    OpenInterestCapExceeded,
    NoFeesAccrued,
    InsufficientShortBalance,
    InsufficientGas
} from "./Errors.sol";
import {OptionMath} from "./libraries/OptionMath.sol";
import {ChainlinkAnchor} from "./libraries/ChainlinkAnchor.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IOptionSeriesFactory} from "./interfaces/IOptionSeriesFactory.sol";

/// @title OptionSeriesVault
/// @notice One per option series. It IS the option ERC-20 and it holds the collateral.
///         Fully collateralized European call or put, cash-settled once from a Chainlink price at expiry.
///         See simple-workflow/contracts.md and simple-workflow/math.md.
///
/// Guarantees:
///  - Every token is minted only against the full maximum liability, rounded up.
///  - The settlement result is written once and never changes.
///  - Claims can never exceed collateral (buyerPayoutRate + writerResidualRate == collateralPerOption).
///  - Protocol fees never come out of the collateral that backs claims: `accruedFees` is a separate balance.
///  - No role can move collateral, change the series, or stop settle / redeem / claim / payout / transfers.
///    The only switch is a freeze on MINTING.
///
/// Deployment: every series is an EIP-1167 minimal proxy clone of ONE implementation (deployed and cloned
/// by `VaultDeployer`), not a full contract deployment. A clone delegatecalls into shared code, so nothing
/// per-series can live in `immutable`/bytecode the way it could in a directly-deployed contract: `immutable`
/// values are baked into the implementation's OWN bytecode and would be identical, and wrong, on every clone.
/// Every field below is therefore regular storage, set exactly once by `initialize`, with the same effect a
/// constructor had before: no function ever writes these again, and there is no setter.
contract OptionSeriesVault is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev `payout` refuses to start an account with less gas than this left. Each account runs inside a
    ///      try/catch, so without this floor an account starved of gas would fail SILENTLY, and gas estimators
    ///      (which look for the minimum gas at which the outer call survives) would pick a limit too low to pay
    ///      everyone. With the floor, too little gas makes the whole call revert loudly instead. Comfortably
    ///      above the worst case for one account (a redeem and a claim, cold storage, a proxy token transfer).
    uint256 private constant PAYOUT_MIN_GAS = 250_000;

    // ------------------------------------------------------------------ fixed at initialization
    // Regular storage, not `immutable` (this contract is only ever run through a clone - see above).
    // Written once by `initialize` and never again: no function in this contract writes any of them.

    IOptionSeriesFactory public factory;
    bytes32 public seriesId;
    OptionType public optionType;
    address public underlying;
    address public quote;
    address public collateralAsset; // underlying for a CALL, quote for a PUT
    uint256 public strikePrice; // PRICE_SCALE
    uint64 public expiry;
    uint256 public contractSize; // underlying raw units per ONE WHOLE option
    uint8 public optionDecimals;
    uint256 public minOptionAmount; // mint only
    uint256 public maxTotalShortAmount; // 0 = uncapped
    address public chainlinkFeed;
    uint8 public feedDecimals;
    uint32 public maxChainlinkAgeAtExpiry;
    uint256 public optionScale; // 10 ** optionDecimals
    uint256 public uqScale; // PRICE_SCALE * 10**underlyingDecimals / 10**quoteDecimals
    uint256 public collateralPerOption; // maximum liability of one whole option
    uint16 public mintFeeBps;
    uint16 public exerciseFeeBps;

    // ------------------------------------------------------------------ state

    bool public settled;
    bool public mintPaused; // the freeze: blocks mint and nothing else

    uint256 public totalShortAmount;
    uint256 public totalUnclaimedShortAmount;
    uint256 public collateralLocked; // collateral backing outstanding claims
    uint256 public accruedFees; // protocol fees, strictly segregated from collateralLocked
    uint256 public totalBuyerPayoutClaimed; // gross
    uint256 public totalWriterResidualClaimed; // gross

    uint256 public settlementPrice; // PRICE_SCALE, write-once
    uint256 public buyerPayoutRate; // collateral raw units per whole option, write-once
    uint256 public writerResidualRate; // collateral raw units per whole option, write-once
    uint64 public settledAt;

    mapping(address => uint256) public writerShortBalance;

    // ------------------------------------------------------------------ events

    event OptionsMinted(
        address indexed writer, address indexed receiver, uint256 optionAmount, uint256 collateralAmount, uint256 feeAmount
    );
    event SeriesSettled(uint256 settlementPrice, uint256 buyerPayoutRate, uint256 writerResidualRate);
    event OptionsRedeemed(
        address indexed holder, address indexed receiver, uint256 optionAmount, uint256 grossPayout, uint256 feeAmount
    );
    event WriterResidualClaimed(
        address indexed writer, address indexed receiver, uint256 shortAmount, uint256 residualAmount
    );
    event FeesSwept(address indexed receiver, uint256 amount);
    event MintPauseSet(bool paused);

    // ------------------------------------------------------------------ construction

    /// @dev Runs only on the ONE implementation contract `VaultDeployer` deploys with `new` (never on a
    ///      clone - clones never execute their target's constructor, only its runtime code). It permanently
    ///      blocks `initialize` on the implementation itself, so nobody can initialize the shared logic
    ///      contract and mistake it, or trick someone else into mistaking it, for a real series.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a fresh clone as one series. Callable exactly once per clone - see `initializer`.
    /// @dev The factory validates policy (allowlists, expiry window, feed approval). The vault validates
    ///      everything its own arithmetic depends on and derives every scale itself, so it never trusts the
    ///      factory for a derived value.
    function initialize(address factory_, bytes32 seriesId_, SeriesConfig memory p, FeeConfig memory fees)
        external
        initializer
    {
        __ERC20_init(p.name, p.symbol);
        __ReentrancyGuard_init();

        if (factory_ == address(0) || p.underlying == address(0) || p.quote == address(0) || p.chainlinkFeed == address(0))
        {
            revert ZeroAddress();
        }
        if (p.underlying == p.quote) revert AssetNotAllowed();
        if (p.strikePrice == 0) revert InvalidStrike();
        if (p.expiry <= block.timestamp) revert InvalidExpiry();
        if (p.contractSize == 0) revert InvalidContractSize();
        if (p.minOptionAmount == 0) revert InvalidMinOptionAmount();
        if (fees.mintFeeBps > MAX_MINT_FEE_BPS || fees.exerciseFeeBps > MAX_EXERCISE_FEE_BPS) revert FeeExceedsCap();

        factory = IOptionSeriesFactory(factory_);
        seriesId = seriesId_;
        optionType = p.optionType;
        underlying = p.underlying;
        quote = p.quote;
        collateralAsset = p.optionType == OptionType.CALL ? p.underlying : p.quote;
        strikePrice = p.strikePrice;
        expiry = p.expiry;
        contractSize = p.contractSize;
        optionDecimals = p.optionDecimals;
        minOptionAmount = p.minOptionAmount;
        maxTotalShortAmount = p.maxTotalShortAmount;
        chainlinkFeed = p.chainlinkFeed;
        maxChainlinkAgeAtExpiry = p.maxChainlinkAgeAtExpiry;
        mintFeeBps = fees.mintFeeBps;
        exerciseFeeBps = fees.exerciseFeeBps;

        // Derived scales. optionScale and uqScale revert on decimals above 18.
        uint256 scale = OptionMath.optionScale(p.optionDecimals);
        uint256 uq = OptionMath.uqScale(IERC20Metadata(p.underlying).decimals(), IERC20Metadata(p.quote).decimals());
        uint256 cpo = OptionMath.collateralPerOption(p.optionType, p.contractSize, p.strikePrice, uq);
        optionScale = scale;
        uqScale = uq;
        collateralPerOption = cpo;

        // The smallest mintable position must need a nonzero amount of collateral.
        if (cpo == 0 || OptionMath.requiredCollateral(p.minOptionAmount, cpo, scale) == 0) {
            revert InvalidMinOptionAmount();
        }

        uint8 feedDec = IAggregatorV3(p.chainlinkFeed).decimals();
        if (feedDec > 18 || p.maxChainlinkAgeAtExpiry == 0) revert InvalidOracleConfig();
        feedDecimals = feedDec;
    }

    /// @notice Option tokens always have `optionDecimals` decimals.
    function decimals() public view override returns (uint8) {
        return optionDecimals;
    }

    // ------------------------------------------------------------------ mint

    /// @notice Lock collateral and mint option tokens. The short position belongs to msg.sender; the tokens
    ///         go to `receiver`. The mint fee is charged ON TOP of collateral.
    function mint(uint256 optionAmount, address receiver)
        external
        nonReentrant
        returns (uint256 collateralAmount, uint256 feeAmount)
    {
        if (mintPaused) revert MintPaused();
        if (block.timestamp >= expiry) revert Expired();
        if (optionAmount < minOptionAmount) revert AmountTooSmall();
        if (receiver == address(0) || receiver == address(this)) revert ZeroAddress();
        uint256 cap = maxTotalShortAmount;
        if (cap != 0 && totalShortAmount + optionAmount > cap) revert OpenInterestCapExceeded();

        collateralAmount = OptionMath.requiredCollateral(optionAmount, collateralPerOption, optionScale);
        if (collateralAmount == 0) revert AmountTooSmall();
        feeAmount = OptionMath.mintFee(collateralAmount, mintFeeBps);

        // effects
        writerShortBalance[msg.sender] += optionAmount;
        totalShortAmount += optionAmount;
        totalUnclaimedShortAmount += optionAmount;
        collateralLocked += collateralAmount;
        accruedFees += feeAmount;
        emit OptionsMinted(msg.sender, receiver, optionAmount, collateralAmount, feeAmount);

        // interactions. _mint is last so a token hook on the option token itself sees fully updated state.
        IERC20(collateralAsset).safeTransferFrom(msg.sender, address(this), collateralAmount + feeAmount);
        _mint(receiver, optionAmount);
    }

    // ------------------------------------------------------------------ settle

    /// @notice Settle once, at the Chainlink round in force at expiry. Anyone may call it, at any time after
    ///         expiry, and the price is the same whenever it is called. Pays nothing and makes no token call.
    function settle(SettlementProof calldata proof) external nonReentrant returns (uint256 price) {
        if (block.timestamp < expiry) revert NotExpired();
        if (settled) revert AlreadySettled();

        price = ChainlinkAnchor.priceAtExpiry(
            IAggregatorV3(chainlinkFeed),
            feedDecimals,
            expiry,
            maxChainlinkAgeAtExpiry,
            proof.chainlinkRoundId,
            proof.chainlinkNextRoundId
        );

        uint256 buyerRate = OptionMath.buyerPayoutRate(optionType, contractSize, strikePrice, price, uqScale);
        // ALWAYS by subtraction, so buyerRate + writerRate == collateralPerOption exactly.
        uint256 writerRate = OptionMath.residualRate(collateralPerOption, buyerRate);

        settlementPrice = price;
        buyerPayoutRate = buyerRate;
        writerResidualRate = writerRate;
        settledAt = uint64(block.timestamp);
        settled = true;

        emit SeriesSettled(price, buyerRate, writerRate);
    }

    // ------------------------------------------------------------------ redeem and claim

    /// @notice Burn `optionAmount` tokens and receive the payout. Any nonzero amount is accepted: the series
    ///         minimum applies to minting only, so a holder of any size can always exit.
    function redeem(uint256 optionAmount, address receiver)
        external
        nonReentrant
        returns (uint256 payoutAmount, uint256 feeAmount)
    {
        if (!settled) revert NotSettled();
        if (optionAmount == 0) revert AmountTooSmall();
        if (receiver == address(0)) revert ZeroAddress();
        return _redeem(msg.sender, receiver, optionAmount);
    }

    /// @notice A writer reclaims the collateral left after buyers' payouts. No fee: the writer paid at mint.
    function claimWriterResidual(uint256 shortAmount, address receiver)
        external
        nonReentrant
        returns (uint256 residualAmount)
    {
        if (!settled) revert NotSettled();
        if (shortAmount == 0) revert AmountTooSmall();
        if (receiver == address(0)) revert ZeroAddress();
        return _claim(msg.sender, receiver, shortAmount);
    }

    /// @dev Burn first, then account, then pay. `collateralLocked` drops by the GROSS amount while only the
    ///      NET leaves the vault: the difference stays as accrued fees.
    function _redeem(address holder, address receiver, uint256 optionAmount)
        private
        returns (uint256 payoutAmount, uint256 feeAmount)
    {
        uint256 gross = OptionMath.grossClaim(optionAmount, buyerPayoutRate, optionScale);
        feeAmount = OptionMath.exerciseFee(gross, exerciseFeeBps);
        payoutAmount = gross - feeAmount;

        _burn(holder, optionAmount); // reverts if the holder's balance is too small
        collateralLocked -= gross;
        accruedFees += feeAmount;
        totalBuyerPayoutClaimed += gross;
        emit OptionsRedeemed(holder, receiver, optionAmount, gross, feeAmount);

        // An out-of-the-money redemption pays nothing: skip the transfer entirely, since some tokens revert
        // on zero-value transfers.
        if (payoutAmount > 0) IERC20(collateralAsset).safeTransfer(receiver, payoutAmount);
    }

    function _claim(address writer, address receiver, uint256 shortAmount) private returns (uint256 residualAmount) {
        if (shortAmount > writerShortBalance[writer]) revert InsufficientShortBalance();
        residualAmount = OptionMath.grossClaim(shortAmount, writerResidualRate, optionScale);

        writerShortBalance[writer] -= shortAmount;
        totalUnclaimedShortAmount -= shortAmount;
        collateralLocked -= residualAmount;
        totalWriterResidualClaimed += residualAmount;
        emit WriterResidualClaimed(writer, receiver, shortAmount, residualAmount);

        if (residualAmount > 0) IERC20(collateralAsset).safeTransfer(receiver, residualAmount);
    }

    // ------------------------------------------------------------------ keeper payout

    /// @notice Pay a list of accounts what they are owed, so a keeper can settle everyone without each
    ///         person sending a transaction. Callable by anyone after settlement.
    /// @dev The keeper supplies the list (built off chain from Transfer and OptionsMinted events); the vault
    ///      reads every balance itself. Each account runs in its own guarded self-call inside try/catch, so
    ///      one account that fails (for example a blacklisted recipient) is skipped and rolled back without
    ///      affecting the others. Allowlisted tokens have no transfer hooks, so a recipient cannot run code
    ///      or burn gas. Payouts always go to the account, never to the caller.
    ///      Too little gas reverts (InsufficientGas) instead of silently skipping accounts. A keeper should also
    ///      re-read balances afterward: an account skipped because ITS transfer failed stays owed.
    function payout(address[] calldata accounts) external {
        if (!settled) revert NotSettled();
        for (uint256 i; i < accounts.length; ++i) {
            if (gasleft() < PAYOUT_MIN_GAS) revert InsufficientGas();
            try this.payAccount(accounts[i]) {} catch {}
        }
    }

    /// @dev Only callable by this contract, through `payout`. Redeems the account's ENTIRE token balance and
    ///      claims its ENTIRE short balance, exactly like redeem and claimWriterResidual. Full balance only, so
    ///      nobody can burn a holder's value by redeeming tiny chunks that round to a zero payout.
    ///      Contracts are skipped: a contract may hold option tokens on behalf of other people (for example a
    ///      Kuru order book), and redeeming them without its knowledge would break its accounting. Contracts
    ///      call redeem and claimWriterResidual themselves.
    function payAccount(address account) external nonReentrant {
        if (msg.sender != address(this)) revert Unauthorized();
        if (account == address(0) || account.code.length > 0) return;

        uint256 balance = balanceOf(account);
        if (balance > 0) _redeem(account, account, balance);

        uint256 shortAmount = writerShortBalance[account];
        if (shortAmount > 0) _claim(account, account, shortAmount);
    }

    // ------------------------------------------------------------------ fees

    /// @notice Send accrued protocol fees to the factory's fee recipient, read live. ADMIN only. Takes no
    ///         receiver argument, so the admin cannot redirect fees. Never reads or reduces collateralLocked.
    function sweepFees() external nonReentrant returns (uint256 amount) {
        if (!factory.hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
        amount = accruedFees;
        if (amount == 0) revert NoFeesAccrued();
        address receiver = factory.feeRecipient();
        if (receiver == address(0)) revert ZeroAddress();

        accruedFees = 0;
        emit FeesSwept(receiver, amount);
        IERC20(collateralAsset).safeTransfer(receiver, amount);
    }

    // ------------------------------------------------------------------ freeze

    /// @notice Freeze or unfreeze MINTING on this series. PAUSER or ADMIN can freeze; only ADMIN can unfreeze.
    /// @dev A freeze stops new deposits and nothing else. It can never block settle, redeem,
    ///      claimWriterResidual, payout, sweepFees or transfers, and it does not change the series.
    function setMintPaused(bool paused) external {
        if (paused) {
            if (!factory.hasRole(PAUSER_ROLE, msg.sender) && !factory.hasRole(ADMIN_ROLE, msg.sender)) {
                revert Unauthorized();
            }
        } else if (!factory.hasRole(ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        mintPaused = paused;
        emit MintPauseSet(paused);
    }

    // ------------------------------------------------------------------ views

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiry;
    }

    function seriesInfo() external view returns (SeriesInfo memory) {
        return SeriesInfo({
            seriesId: seriesId,
            optionType: optionType,
            underlying: underlying,
            quote: quote,
            collateralAsset: collateralAsset,
            strikePrice: strikePrice,
            expiry: expiry,
            contractSize: contractSize,
            optionDecimals: optionDecimals,
            minOptionAmount: minOptionAmount,
            maxTotalShortAmount: maxTotalShortAmount,
            chainlinkFeed: chainlinkFeed,
            feedDecimals: feedDecimals,
            maxChainlinkAgeAtExpiry: maxChainlinkAgeAtExpiry,
            optionScale: optionScale,
            uqScale: uqScale,
            collateralPerOption: collateralPerOption,
            mintFeeBps: mintFeeBps,
            exerciseFeeBps: exerciseFeeBps
        });
    }

    /// @notice Exactly what `mint` would charge for `optionAmount`.
    function previewMint(uint256 optionAmount) external view returns (uint256 collateralAmount, uint256 feeAmount) {
        collateralAmount = OptionMath.requiredCollateral(optionAmount, collateralPerOption, optionScale);
        feeAmount = OptionMath.mintFee(collateralAmount, mintFeeBps);
    }

    /// @notice Exactly what `redeem` would pay for `optionAmount`. Returns (0, 0) before settlement, because
    ///         no payout rate exists yet.
    function previewRedeem(uint256 optionAmount) external view returns (uint256 payoutAmount, uint256 feeAmount) {
        uint256 gross = OptionMath.grossClaim(optionAmount, buyerPayoutRate, optionScale);
        feeAmount = OptionMath.exerciseFee(gross, exerciseFeeBps);
        payoutAmount = gross - feeAmount;
    }

    /// @notice Exactly what `claimWriterResidual` would pay for `shortAmount`. Returns 0 before settlement.
    function previewWriterResidual(uint256 shortAmount) external view returns (uint256 residualAmount) {
        return OptionMath.grossClaim(shortAmount, writerResidualRate, optionScale);
    }
}
