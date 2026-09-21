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
error SettlementAnchorInvalid(); // proof does not identify the round in force at expiry
error SettlementAnchorTooStale(); // round in force at expiry is older than maxChainlinkAgeAtExpiry
