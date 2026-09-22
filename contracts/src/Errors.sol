// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// All custom errors, shared by every contract. See simple-workflow/contracts.md.

// creation and identity
error ZeroAddress();
error AssetNotAllowed();
error InvalidDecimals();
error InvalidStrike();
error InvalidExpiry();
error InvalidMinOptionAmount();
error InvalidContractSize();
error InvalidOracleConfig();
error DuplicateSeries(bytes32 seriesId);
error CreationPaused();
error FeedNotApproved();
error FeeExceedsCap();
error KuruMarketAlreadySet();
error SeriesNotFound();
error Unauthorized();
error InvalidGuardParam();

// lifecycle
error MintPaused();
error Expired();
error NotExpired();
error AlreadySettled();
error NotSettled();
error AmountTooSmall();
error OpenInterestCapExceeded();
error NoFeesAccrued();
error InsufficientGas();
error InsufficientShortBalance();

// oracle
error OracleInvalid();
// Each names exactly which check in ChainlinkAnchor.priceAtExpiry failed, so a revert traces to one path.
error SettlementAnchorZeroRoundId(); // the round-in-force id supplied was 0
error SettlementAnchorRoundsNotDistinct(); // the round-in-force id and its successor id were the same
error SettlementAnchorRoundUnavailable(); // the round-in-force id has no valid, present data
error SettlementAnchorSuccessorUnavailable(); // the successor id has no valid, present data
error SettlementAnchorNotImmediateSuccessor(); // the successor is not the immediate next round
error SettlementAnchorRoundAfterExpiry(); // the named round updated after expiry: not in force at expiry
error SettlementAnchorSuccessorNotAfterExpiry(); // the successor did not update after expiry
error SettlementAnchorTooStale(); // round in force at expiry is older than maxChainlinkAgeAtExpiry
