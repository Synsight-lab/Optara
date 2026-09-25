// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {OracleConfig} from "../libraries/OptaraTypes.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ChainlinkSettlementAdapter
/// @notice Deterministic Chainlink settlement rule (ORACLE_AND_SETTLEMENT.md sections 10-25, 71-77, 119).
///
/// OBSERVATION RULE. For every feed leg, the observation is the round IN FORCE at the observation end
/// T = expiry + observationEndOffset: the last round with updatedAt <= T. The caller proves it either with the
/// round's immediate successor (updatedAt > T) or by showing it is the feed's latest round. Exactly one round
/// satisfies the proof, so the result is a fixed function of feed history, independent of who finalizes or when.
/// A leg is VALID when answer > 0 and updatedAt >= observation start (expiry + observationStartOffset).
///
/// SOURCES. DIRECT = one UNDERLYING/SETTLEMENT_ASSET feed. DERIVED = UNDERLYING/USD divided by
/// SETTLEMENT_ASSET/USD, both legs valid and their timestamps within maxLegSkew, rounded half-up
/// (MATH.md sections 40-41). A generic USD price is never used as a stablecoin price.
///
/// SELECTION. The primary source settles if its observation is valid. The secondary source is eligible only when
/// the caller proves ON-CHAIN that the primary's in-force observation is invalid (stale, nonpositive, skewed or
/// unrepresentable). Omitting primary data proves nothing, and a caller can never choose between two valid prices.
/// If neither source is valid the group stays EXPIRED_UNSETTLED; no price is invented.
contract ChainlinkSettlementAdapter is ISettlementOracle {
    uint8 public constant KIND_NONE = 0;
    uint8 public constant KIND_DIRECT = 1;
    uint8 public constant KIND_DERIVED = 2;

    struct Source {
        uint8 kind;
        address feed; // DIRECT: UNDERLYING/ASSET. DERIVED: UNDERLYING/USD.
        uint8 feedDecimals;
        address quoteFeed; // DERIVED only: SETTLEMENT_ASSET/USD.
        uint8 quoteFeedDecimals;
        uint32 maxLegSkew; // DERIVED only: max |updatedAt(underlying) - updatedAt(quote)|.
    }

    struct Params {
        Source primary;
        Source secondary; // kind == KIND_NONE when there is no fallback
    }

    /// @dev nextRoundId == 0 means "roundId is the feed's latest round".
    struct RoundProof {
        uint80 roundId;
        uint80 nextRoundId;
    }

    /// @dev sourceIndex 0 = primary, 1 = secondary. primaryProofs are always required: selecting the secondary
    ///      requires proving the primary observation invalid.
    struct SettlementData {
        uint8 sourceIndex;
        RoundProof[] primaryProofs;
        RoundProof[] secondaryProofs;
    }

    IOracleRegistry public immutable registry;

    error ZeroAddress();
    error NoFeeRequired();
    error WrongAdapter();
    error InvalidSource(string reason);
    error ObservationNotFinal(uint64 observationEnd);
    error InvalidSourceIndex(uint8 sourceIndex);
    error NoSecondarySource();
    error PrimaryObservationValid();
    error PrimaryObservationInvalid();
    error SecondaryObservationInvalid();
    error WrongProofCount(uint256 expected, uint256 actual);
    error RoundUnavailable(address feed, uint80 roundId);
    error SuccessorUnavailable(address feed, uint80 roundId);
    error RoundAfterObservation(address feed, uint80 roundId);
    error NotLatestRound(address feed, uint80 roundId);
    error NotImmediateSuccessor(address feed, uint80 roundId, uint80 nextRoundId);
    error SuccessorNotAfterObservation(address feed, uint80 nextRoundId);

    constructor(IOracleRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    // ---------------------------------------------------------------------------------------------
    // Registration-time validation
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ISettlementOracle
    function validateConfig(OracleConfig calldata cfg) external view {
        if (cfg.adapter != address(this)) revert WrongAdapter();
        Params memory p = abi.decode(cfg.sourceParams, (Params));
        if (p.primary.kind == KIND_NONE) revert InvalidSource("primary missing");
        _validateSource(p.primary);
        if (p.secondary.kind != KIND_NONE) {
            _validateSource(p.secondary);
        } else if (
            p.secondary.feed != address(0) || p.secondary.quoteFeed != address(0) || p.secondary.feedDecimals != 0
                || p.secondary.quoteFeedDecimals != 0 || p.secondary.maxLegSkew != 0
        ) {
            revert InvalidSource("secondary fields set");
        }
    }

    function _validateSource(Source memory s) internal view {
        if (s.kind == KIND_DIRECT) {
            _validateFeed(s.feed, s.feedDecimals);
            if (s.quoteFeed != address(0) || s.quoteFeedDecimals != 0 || s.maxLegSkew != 0) {
                revert InvalidSource("direct has quote fields");
            }
        } else if (s.kind == KIND_DERIVED) {
            _validateFeed(s.feed, s.feedDecimals);
            _validateFeed(s.quoteFeed, s.quoteFeedDecimals);
            if (s.feed == s.quoteFeed) revert InvalidSource("same leg feeds");
            if (s.maxLegSkew == 0) revert InvalidSource("maxLegSkew");
        } else {
            revert InvalidSource("kind");
        }
    }

    function _validateFeed(address feed, uint8 feedDecimals) internal view {
        if (feed == address(0) || feed.code.length == 0) revert InvalidSource("feed");
        if (feedDecimals > 18) revert InvalidSource("decimals > 18");
        if (IAggregatorV3(feed).decimals() != feedDecimals) revert InvalidSource("decimals mismatch");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (updatedAt == 0 || answer <= 0) revert InvalidSource("feed not live");
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement verification
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ISettlementOracle
    function verifySettlementPrice(bytes32 oracleConfigId, uint64 expiry, bytes calldata oracleData)
        external
        payable
        returns (uint256 priceWad, uint64 observationTimestamp)
    {
        // Chainlink reads are free; accepting value would only strand it (FEES.md sections 40-42).
        if (msg.value != 0) revert NoFeeRequired();
        return _verify(oracleConfigId, expiry, oracleData);
    }

    /// @inheritdoc ISettlementOracle
    function quoteSettlementPrice(bytes32 oracleConfigId, uint64 expiry, bytes calldata oracleData)
        external
        view
        returns (uint256 priceWad, uint64 observationTimestamp)
    {
        return _verify(oracleConfigId, expiry, oracleData);
    }

    function _verify(bytes32 configId, uint64 expiry, bytes calldata oracleData)
        internal
        view
        returns (uint256 priceWad, uint64 observationTimestamp)
    {
        OracleConfig memory cfg = registry.getConfig(configId);
        if (cfg.adapter != address(this)) revert WrongAdapter();
        (uint64 start, uint64 end) = registry.observationWindow(configId, expiry);
        // Every round with updatedAt <= end is already on chain once block.timestamp > end.
        if (block.timestamp <= end) revert ObservationNotFinal(end);

        Params memory p = abi.decode(cfg.sourceParams, (Params));
        SettlementData memory d = abi.decode(oracleData, (SettlementData));

        if (d.sourceIndex == 0) {
            (bool valid, uint256 price, uint64 ts) = _evaluate(p.primary, d.primaryProofs, start, end);
            if (!valid) revert PrimaryObservationInvalid();
            return (price, ts);
        }
        if (d.sourceIndex == 1) {
            if (p.secondary.kind == KIND_NONE) revert NoSecondarySource();
            (bool primaryValid,,) = _evaluate(p.primary, d.primaryProofs, start, end);
            if (primaryValid) revert PrimaryObservationValid();
            (bool valid, uint256 price, uint64 ts) = _evaluate(p.secondary, d.secondaryProofs, start, end);
            if (!valid) revert SecondaryObservationInvalid();
            return (price, ts);
        }
        revert InvalidSourceIndex(d.sourceIndex);
    }

    /// @dev Proofs must establish the in-force rounds (reverts otherwise). `valid` reports whether the proven
    ///      observation is usable; an invalid-but-proven observation is what makes the secondary eligible.
    function _evaluate(Source memory s, RoundProof[] memory proofs, uint64 start, uint64 end)
        internal
        view
        returns (bool valid, uint256 priceWad, uint64 observationTimestamp)
    {
        if (s.kind == KIND_DIRECT) {
            if (proofs.length != 1) revert WrongProofCount(1, proofs.length);
            return _leg(s.feed, s.feedDecimals, proofs[0], start, end);
        }
        // KIND_DERIVED (sources are validated at registration)
        if (proofs.length != 2) revert WrongProofCount(2, proofs.length);
        (bool okU, uint256 pU, uint64 tsU) = _leg(s.feed, s.feedDecimals, proofs[0], start, end);
        (bool okS, uint256 pS, uint64 tsS) = _leg(s.quoteFeed, s.quoteFeedDecimals, proofs[1], start, end);
        if (!okU || !okS) return (false, 0, 0);
        uint64 skew = tsU > tsS ? tsU - tsS : tsS - tsU;
        if (skew > s.maxLegSkew) return (false, 0, 0);
        // MON/USDT = (MON/USD) / (USDT/USD), rounded half up; pS > 0 because each valid leg has answer > 0.
        priceWad = FixedPointMath.mulDivHalfUp(pU, FixedPointMath.WAD, pS);
        return (true, priceWad, tsU > tsS ? tsU : tsS);
    }

    /// @dev One proven leg: valid when answer > 0, updatedAt >= observation start, and normalization fits.
    function _leg(address feed, uint8 feedDecimals, RoundProof memory proof, uint64 start, uint64 end)
        internal
        view
        returns (bool valid, uint256 priceWad, uint64 updatedAt)
    {
        int256 answer;
        (answer, updatedAt) = _inForce(feed, proof, end);
        if (answer <= 0 || updatedAt < start) return (false, 0, updatedAt);
        (bool ok, uint256 price) = _normalize(answer, feedDecimals);
        if (!ok) return (false, 0, updatedAt);
        return (true, price, updatedAt);
    }

    /// @dev Proves `proof.roundId` is the round in force at `observationEnd` and returns its answer/timestamp.
    function _inForce(address feed, RoundProof memory proof, uint64 observationEnd)
        internal
        view
        returns (int256 answer, uint64 updatedAt)
    {
        (bool ok, int256 a, uint256 u) = _tryRound(feed, proof.roundId);
        if (!ok) revert RoundUnavailable(feed, proof.roundId);
        if (u > observationEnd) revert RoundAfterObservation(feed, proof.roundId);

        if (proof.nextRoundId == 0) {
            // No successor exists: the round must be the feed's latest.
            uint80 latestId;
            try IAggregatorV3(feed).latestRoundData() returns (uint80 id, int256, uint256, uint256, uint80) {
                latestId = id;
            } catch {
                revert NotLatestRound(feed, proof.roundId);
            }
            if (latestId != proof.roundId) revert NotLatestRound(feed, proof.roundId);
        } else {
            (bool okNext,, uint256 uNext) = _tryRound(feed, proof.nextRoundId);
            if (!okNext) revert SuccessorUnavailable(feed, proof.nextRoundId);
            if (!isImmediateSuccessor(feed, proof.roundId, proof.nextRoundId)) {
                revert NotImmediateSuccessor(feed, proof.roundId, proof.nextRoundId);
            }
            if (uNext <= observationEnd) revert SuccessorNotAfterObservation(feed, proof.nextRoundId);
        }
        return (a, uint64(u));
    }

    /// @dev answer * 10^(18 - decimals), or (false, 0) on overflow. answer > 0 is checked by the caller.
    function _normalize(int256 answer, uint8 feedDecimals) internal pure returns (bool ok, uint256 price) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.tryMul(uint256(answer), 10 ** (18 - uint256(feedDecimals)));
    }

    /// @dev Reads one round; ok is false if the call reverts, updatedAt == 0, or the feed returns another round.
    function _tryRound(address feed, uint80 id) internal view returns (bool ok, int256 answer, uint256 updatedAt) {
        if (id == 0) return (false, 0, 0);
        try IAggregatorV3(feed).getRoundData(id) returns (
            uint80 returnedId, int256 a, uint256, uint256 u, uint80 answeredInRound
        ) {
            if (u == 0 || returnedId != id || answeredInRound < id) return (false, 0, 0);
            return (true, a, u);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @notice Chainlink proxy round ids are phase-encoded: id = (phaseId << 64) | aggregatorRound.
    /// `next` is the immediate successor of `round` if, in the same phase, aggregatorRound(next) is
    /// aggregatorRound(round) + 1; or across a phase boundary, phase(next) = phase(round) + 1 with
    /// aggregatorRound(next) = 1 and `round` being the last round of its phase (round + 1 does not exist).
    function isImmediateSuccessor(address feed, uint80 round, uint80 next) public view returns (bool) {
        uint256 phaseRound = uint256(round) >> 64;
        uint256 phaseNext = uint256(next) >> 64;
        uint256 aggRound = uint256(round) & type(uint64).max;
        uint256 aggNext = uint256(next) & type(uint64).max;
        if (phaseNext == phaseRound) return aggNext == aggRound + 1;
        if (phaseNext == phaseRound + 1) {
            if (aggNext != 1 || round == type(uint80).max) return false;
            try IAggregatorV3(feed).getRoundData(round + 1) returns (uint80, int256, uint256, uint256 u, uint80) {
                return u == 0;
            } catch {
                return true;
            }
        }
        return false;
    }
}
