// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISettlementState} from "./IExternalDependencies.sol";

/// @title ISettlementWindow
/// @notice Expiry to payout without a redemption race: fix the price, settle every participant, cover the shortfall
///         from insurance, fix one recovery ratio, then open redemption and claims (docs/SETTLEMENT.md, MATH.md §13).
/// @dev Amounts named `...N` are exact numerators at scale 1e54 (quantity 1e18 × intrinsic 1e18 × contract size
///      1e18); native amounts are in settlement-asset units. Debts round up; credits, the ratio and payouts round
///      down (INV-49).
interface ISettlementWindow is ISettlementState {
    enum GroupState {
        ACTIVE,
        EXPIRED,
        ORACLE_STALLED,
        FINALIZED,
        ALL_SETTLED,
        REDEEMABLE
    }

    struct Modules {
        address ledger;
        address registry;
        address settlementOracle;
        address fees;
        address insurance;
        address clearing;
    }

    /// @notice Per-group accounting (all native unless named `...N`).
    struct GroupAccounting {
        uint256 priceWad; // capped settlement price used for payoffs
        uint64 finalizedAt;
        uint64 observationTime;
        bool finalized;
        bool ratioSet;
        bool stalledFlagged;
        uint256 ratioWad;
        uint256 wrapperClaimN; // Σ snapshot supply × payoff × CS
        uint256 netCreditN; // Σ positive account nets
        uint256 collected; // debts collected from account cash
        uint256 unpaid; // debts not collected
        uint256 insurance; // insurance paid into the pool
        uint256 pool; // collected + insurance − payouts so far
        uint256 unclaimedCredits; // creditor accounts that have not claimed
    }

    event GroupFinalized(bytes32 indexed groupId, uint256 priceWad, uint64 observationTime, uint256 participants);
    event AccountSettled(
        uint256 indexed accountId, bytes32 indexed groupId, int256 netNumerator, uint256 collected, uint256 unpaid
    );
    event InsuranceCovered(bytes32 indexed groupId, address indexed asset, uint256 amount);
    event RecoveryRatioSet(
        bytes32 indexed groupId, uint256 ratioWad, uint256 grossClaim, uint256 collected, uint256 insuranceContribution
    );
    event SettlementClaimed(uint256 indexed accountId, bytes32 indexed groupId, uint256 amount);
    event WrapperRedeemed(
        bytes32 indexed seriesId, address indexed holder, address indexed recipient, uint256 qty, uint256 payout
    );
    event DustSwept(bytes32 indexed groupId, uint256 amount);
    event OracleStalled(bytes32 indexed groupId, uint64 stalledAfter);

    /// @notice Anyone. Verifies the round-in-force proof, stores the capped price once, snapshots wrapper supplies
    ///         and pays the finalize reward to the caller.
    function finalizeGroup(bytes32 groupId, bytes calldata settlementData) external;
    /// @notice Anyone, for any participant: nets all its series in the group, collects the debt or records the
    ///         credit, zeroes its balances and pays the caller the settle reward.
    function settleAccountGroup(uint256 accountId, bytes32 groupId) external;
    /// @notice Batch of `settleAccountGroup`; non-participants are skipped.
    function settleAccountsGroup(uint256[] calldata accountIds, bytes32 groupId) external;
    /// @notice Once every participant is settled: insurance covers the shortfall, the ratio is fixed forever.
    function computeRecoveryRatio(bytes32 groupId) external;
    /// @notice Anyone: credits `floor(creditN × ratio)` to the account's cash, once.
    function claimSettlement(uint256 accountId, bytes32 groupId) external;
    /// @notice Burns the caller's wrappers and pays `floor(qty × payoff × CS × ratio)` to `recipient`.
    function redeemWrapper(bytes32 seriesId, uint256 qty, address recipient) external;
    /// @notice After every wrapper is redeemed and every credit claimed: the pool's rounding dust goes to insurance.
    function sweepDust(bytes32 groupId) external;
    /// @notice Anyone, once a group is past its finalization deadline without a price: emits `OracleStalled` once.
    function flagOracleStalled(bytes32 groupId) external;

    function groupState(bytes32 groupId) external view returns (GroupState);
    function groupAccounting(bytes32 groupId) external view returns (GroupAccounting memory);
    /// @return 0 until finalized.
    function settlementPrice(bytes32 groupId) external view returns (uint256);
    function recoveryRatio(bytes32 groupId) external view returns (bool set, uint256 ratioWad);
    /// @notice The account's net in the group at the final price; reverts `GroupNotFinalized` before finalization.
    /// @return netNumerator Signed net (1e54 scale).
    /// @return debt Native debt (rounded up), 0 for a creditor.
    /// @return collectable The part of the debt its cash covers now.
    function previewSettle(uint256 accountId, bytes32 groupId)
        external
        view
        returns (int256 netNumerator, uint256 debt, uint256 collectable);
    /// @return payout At the current ratio (or 1 before it is set).
    /// @return ratioFixed True once the ratio is set.
    function previewRedeem(bytes32 seriesId, uint256 qty) external view returns (uint256 payout, bool ratioFixed);
    function isOracleStalled(bytes32 groupId) external view returns (bool);
    function creditOf(uint256 accountId, bytes32 groupId) external view returns (uint256 creditN);
    function wrapperSupplyAtFinalization(bytes32 seriesId) external view returns (uint256);
    function modules() external view returns (Modules memory);
}
