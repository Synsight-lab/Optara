// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOptionSeriesFactory} from "./interfaces/IOptionSeriesFactory.sol";
import {IOptionSeriesVault} from "./interfaces/IOptionSeriesVault.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {OptionType, SeriesInfo, BPS_SCALE, ADMIN_ROLE} from "./Types.sol";
import {ZeroAddress, Unauthorized, InvalidGuardParam} from "./Errors.sol";
import {OptionMath} from "./libraries/OptionMath.sol";
import {ChainlinkAnchor} from "./libraries/ChainlinkAnchor.sol";

/// @title PremiumExecutionGuard
/// @notice A READ-ONLY helper that checks whether a proposed buy or sell of an option token is inside sensible,
///         oracle-based bounds and inside the buyer's own limit. It holds no funds, executes no trades and needs
///         no approvals: every function is `view`. See simple-workflow/premium-guard.md.
///
/// This guard is ADVISORY. In V1 nothing forces a trade through it, so it cannot protect a user who trades
/// directly on Kuru, and it must never be described as a guarantee. Hard price protection comes from the limit
/// price and minimum output on the Kuru order itself. A future protocol-owned router must call these checks and
/// revert on `valid == false`.
///
/// Every premium figure is a TOTAL for `optionAmount` in quote raw units, never a per-option figure. Comparing a
/// per-option number against a total bound is wrong by a factor of the option amount and fails open.
///
/// Every step of a bound rounds in the direction that REJECTS MORE: minimums round up, maximums round down.
/// The bounds are conservative rails around today's reference price, not option pricing and not proofs. In
/// particular a call's payout in quote terms is unbounded, so a premium above `hardMaxPremium` for a call is
/// "economically suspicious for a simple routed buy", not "impossible to profit".
contract PremiumExecutionGuard {
    IOptionSeriesFactory public immutable factory;

    /// How far below intrinsic value a sell may be, in bps. Launch with at least MAX_EXERCISE_FEE_BPS so the
    /// acceptable range cannot be empty on deep in-the-money options.
    uint16 public sellerDiscountToleranceBps;
    /// Max age in seconds of the Chainlink reference price.
    uint32 public maxReferenceAge;
    /// Max Kuru taker or maker fee, in bps, that the guard will accept.
    uint16 public maxVenueFeeBps;

    enum Reason {
        OK,
        NOT_OFFICIAL_SERIES,
        EXPIRED,
        WRONG_MARKET,
        DEADLINE_PASSED,
        VENUE_FEE_TOO_HIGH,
        ORACLE_UNAVAILABLE,
        EMPTY_RANGE,
        ABOVE_BUYER_LIMIT,
        ABOVE_HARD_MAX,
        BELOW_ACCEPTABLE_MIN,
        ZERO_AMOUNT
    }

    struct BuyCheck {
        bytes32 seriesId;
        address market; // the Kuru market the trade will use
        uint256 optionAmount; // option raw units
        uint256 grossPremium; // quote raw units, TOTAL for optionAmount, from the Kuru quote
        uint16 takerFeeBps; // Kuru taker fee, read by the frontend from the market
        uint256 buyerMaxTotalPremium; // quote raw units, all-in cap the buyer chose
        uint256 deadline; // unix seconds
    }

    struct SellCheck {
        bytes32 seriesId;
        address market;
        uint256 optionAmount;
        uint256 grossPremium; // TOTAL for optionAmount
        uint16 makerFeeBps; // Kuru maker-side value
        bool makerFeeIsRebate; // until verified on the deployed market, the frontend must pass false
        uint256 deadline;
    }

    struct CheckResult {
        bool valid;
        Reason reason;
        uint256 acceptableMinPremium; // TOTAL, quote raw units
        uint256 hardMaxPremium; // TOTAL, quote raw units
        uint256 allInCost; // buy only
        uint256 netProceeds; // sell only
        uint256 referencePrice; // PRICE_SCALE
    }

    event SellerDiscountToleranceSet(uint16 bps);
    event MaxReferenceAgeSet(uint32 seconds_);
    event MaxVenueFeeSet(uint16 bps);

    constructor(
        IOptionSeriesFactory factory_,
        uint16 sellerDiscountToleranceBps_,
        uint32 maxReferenceAge_,
        uint16 maxVenueFeeBps_
    ) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        if (sellerDiscountToleranceBps_ > BPS_SCALE || maxVenueFeeBps_ > BPS_SCALE) revert InvalidGuardParam();
        factory = factory_;
        sellerDiscountToleranceBps = sellerDiscountToleranceBps_;
        maxReferenceAge = maxReferenceAge_;
        maxVenueFeeBps = maxVenueFeeBps_;
    }

    // ------------------------------------------------------------------ ADMIN parameters

    function setSellerDiscountToleranceBps(uint16 v) external onlyAdmin {
        if (v > BPS_SCALE) revert InvalidGuardParam();
        sellerDiscountToleranceBps = v;
        emit SellerDiscountToleranceSet(v);
    }

    function setMaxReferenceAge(uint32 v) external onlyAdmin {
        maxReferenceAge = v;
        emit MaxReferenceAgeSet(v);
    }

    function setMaxVenueFeeBps(uint16 v) external onlyAdmin {
        if (v > BPS_SCALE) revert InvalidGuardParam();
        maxVenueFeeBps = v;
        emit MaxVenueFeeSet(v);
    }

    modifier onlyAdmin() {
        if (!factory.hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    // ------------------------------------------------------------------ checks

    /// @notice Is this buy inside the buyer's own all-in limit and below the hard ceiling? Returns a result with
    ///         a reason instead of reverting, so a UI can explain why a route is unsafe.
    function checkBuy(BuyCheck calldata c) external view returns (CheckResult memory r) {
        SeriesInfo memory info;
        (r, info) = _common(c.seriesId, c.market, c.optionAmount, c.deadline, c.takerFeeBps);
        if (r.reason != Reason.OK) return r;

        // The estimated taker fee rounds UP: it is a cost bound compared against a limit.
        uint256 takerFee = OptionMath.mulDivUp(c.grossPremium, c.takerFeeBps, BPS_SCALE);
        r.allInCost = c.grossPremium + takerFee;

        if (r.allInCost > c.buyerMaxTotalPremium) return _fail(r, Reason.ABOVE_BUYER_LIMIT);
        if (r.allInCost > r.hardMaxPremium) return _fail(r, Reason.ABOVE_HARD_MAX);
        r.valid = true;
    }

    /// @notice Is this ask at or above the acceptable minimum, using what the seller actually receives?
    function checkSell(SellCheck calldata c) external view returns (CheckResult memory r) {
        SeriesInfo memory info;
        (r, info) = _common(c.seriesId, c.market, c.optionAmount, c.deadline, c.makerFeeBps);
        if (r.reason != Reason.OK) return r;

        // Both branches round toward a LOWER netProceeds, so this check can only get stricter.
        if (c.makerFeeIsRebate) {
            r.netProceeds = c.grossPremium + OptionMath.mulDivDown(c.grossPremium, c.makerFeeBps, BPS_SCALE); // rebate rounds DOWN
        } else {
            r.netProceeds = c.grossPremium - OptionMath.mulDivUp(c.grossPremium, c.makerFeeBps, BPS_SCALE); // fee rounds UP
        }

        if (r.netProceeds < r.acceptableMinPremium) return _fail(r, Reason.BELOW_ACCEPTABLE_MIN);
        r.valid = true;
    }

    // ------------------------------------------------------------------ shared checks and bounds

    /// @dev Runs the checks common to buys and sells, in order. The first failure sets the reason. On success it
    ///      also fills the reference price and both bounds.
    function _common(bytes32 seriesId, address market, uint256 optionAmount, uint256 deadline, uint16 venueFeeBps)
        private
        view
        returns (CheckResult memory r, SeriesInfo memory info)
    {
        address vault = factory.vaultOf(seriesId);
        if (vault == address(0)) return (_fail(r, Reason.NOT_OFFICIAL_SERIES), info);

        info = IOptionSeriesVault(vault).seriesInfo();
        if (block.timestamp >= info.expiry) return (_fail(r, Reason.EXPIRED), info);
        if (optionAmount == 0) return (_fail(r, Reason.ZERO_AMOUNT), info);
        if (market == address(0) || market != factory.kuruMarketOf(seriesId)) {
            return (_fail(r, Reason.WRONG_MARKET), info);
        }
        if (block.timestamp > deadline) return (_fail(r, Reason.DEADLINE_PASSED), info);
        if (venueFeeBps > maxVenueFeeBps) return (_fail(r, Reason.VENUE_FEE_TOO_HIGH), info);

        (bool ok, uint256 price) =
            ChainlinkAnchor.tryLatestPrice(IAggregatorV3(info.chainlinkFeed), info.feedDecimals, maxReferenceAge);
        if (!ok) return (_fail(r, Reason.ORACLE_UNAVAILABLE), info);
        r.referencePrice = price;

        (r.acceptableMinPremium, r.hardMaxPremium) = _bounds(info, optionAmount, price);
        // An empty range means NO price is acceptable. Never resolve it by preferring one bound.
        if (r.acceptableMinPremium > r.hardMaxPremium) return (_fail(r, Reason.EMPTY_RANGE), info);
        r.reason = Reason.OK;
    }

    /// @dev Both bounds are TOTALS for `optionAmount` in quote raw units. The exposure term is rounded in the
    ///      direction each bound needs, so it is NEVER shared between them.
    ///
    ///        acceptableMin = up( up( up(E_up * max(R-K,0) / UQ) * (BPS - sellerTol) ) / BPS )
    ///        hardMax       = down( down( down(E_down * R_or_K / UQ) * (BPS - exerciseFee) ) / BPS )
    ///
    ///      where E_up / E_down are the exposure a * C / OPTION_SCALE rounded up / down, and R_or_K is R for a
    ///      call and K for a put. `hardMax` is net of the exercise fee because a holder receives the gross payout
    ///      minus that fee. The seller floor takes no such adjustment: the writer never pays that fee.
    function _bounds(SeriesInfo memory i, uint256 optionAmount, uint256 R)
        private
        view
        returns (uint256 minPremium, uint256 hardMax)
    {
        uint256 K = i.strikePrice;
        bool isCall = i.optionType == OptionType.CALL;

        // minimum: everything rounds UP
        uint256 eUp = OptionMath.mulDivUp(optionAmount, i.contractSize, i.optionScale);
        uint256 diff = isCall ? (R > K ? R - K : 0) : (K > R ? K - R : 0);
        uint256 intrinsic = OptionMath.mulDivUp(eUp, diff, i.uqScale);
        minPremium = OptionMath.mulDivUp(intrinsic, BPS_SCALE - sellerDiscountToleranceBps, BPS_SCALE);

        // maximum: everything rounds DOWN
        uint256 eDown = OptionMath.mulDivDown(optionAmount, i.contractSize, i.optionScale);
        uint256 hardGross = OptionMath.mulDivDown(eDown, isCall ? R : K, i.uqScale);
        hardMax = OptionMath.mulDivDown(hardGross, BPS_SCALE - i.exerciseFeeBps, BPS_SCALE);
    }

    function _fail(CheckResult memory r, Reason reason) private pure returns (CheckResult memory) {
        r.valid = false;
        r.reason = reason;
        return r;
    }
}
