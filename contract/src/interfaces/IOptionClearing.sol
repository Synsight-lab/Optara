// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleUpdate} from "../oracle/OracleUpdates.sol";

/// @title IOptionClearing
/// @notice User entry point for collateral and positions; holds every settlement-asset token backing account cash and
///         settlement pools (docs/PROTOCOL_SPEC.md §3–§4, ARCHITECTURE.md §3).
interface IOptionClearing {
    /// @notice Module addresses fixed at initialization.
    struct Modules {
        address ledger;
        address registry;
        address risk;
        address fees;
        address insurance;
        address spot;
        address surface;
        address settlementState;
        address liquidationModule;
        address settlementWindow;
    }

    event CollateralDeposited(uint256 indexed accountId, address indexed from, uint256 amount);
    event CollateralWithdrawn(uint256 indexed accountId, address indexed recipient, uint256 amount);
    event ExternalLongMinted(
        uint256 indexed accountId, bytes32 indexed seriesId, uint256 qty, address indexed recipient, uint256 fee
    );
    event LongWrapped(uint256 indexed accountId, bytes32 indexed seriesId, uint256 qty, address indexed recipient);
    event LongUnwrapped(uint256 indexed accountId, bytes32 indexed seriesId, uint256 qty, address indexed from);
    event ShortClosedWithWrapper(uint256 indexed accountId, bytes32 indexed seriesId, uint256 qty);
    event ShortClosedWithInternalLong(
        uint256 indexed fromAccountId, uint256 indexed toAccountId, bytes32 indexed seriesId, uint256 qty
    );

    // ---- collateral ----
    /// @notice Anyone, into any account (deposits only help). Pulls exactly `amount` of the account's asset.
    function depositCollateral(uint256 accountId, uint256 amount) external;
    /// @notice Authorized for the account. Requires the account healthy (fresh oracles if it holds positions).
    function withdrawCollateral(uint256 accountId, uint256 amount, address recipient, OracleUpdate calldata u)
        external
        payable;

    // ---- positions ----
    /// @notice Writes `qty` options: the account goes short, `recipient` receives `qty` wrappers. The seller fee is
    ///         debited before the health check (FEES.md §2).
    function mintExternalLong(
        uint256 accountId,
        bytes32 seriesId,
        uint256 qty,
        address recipient,
        uint256 maxSellerFeeNative,
        OracleUpdate calldata u
    ) external payable;
    function wrapLong(uint256 accountId, bytes32 seriesId, uint256 qty, address recipient, OracleUpdate calldata u)
        external
        payable;
    /// @notice Burns the caller's wrappers and credits the long to an account the caller is authorized for.
    function unwrapLong(uint256 accountId, bytes32 seriesId, uint256 qty) external;
    function closeShortWithWrapper(uint256 accountId, bytes32 seriesId, uint256 qty) external;
    function closeShortWithInternalLong(
        uint256 fromAccountId,
        uint256 toAccountId,
        bytes32 seriesId,
        uint256 qty,
        OracleUpdate calldata u
    ) external payable;
    /// @notice Anyone: applies spot updates, surface reports and node proofs with no other effect.
    function updateOracles(OracleUpdate calldata u) external payable;

    // ---- custody (internal modules only) ----
    /// @notice LiquidationModule or SettlementWindow: move `amount` of custody to the insurance fund (liquidation
    ///         penalties, swept settlement dust). The caller has already debited the matching cash or pool.
    function payInsurance(address asset, uint256 amount) external;
    /// @notice SettlementWindow: pay `amount` of custody to `to` (wrapper redemptions). The caller has already
    ///         debited the matching pool.
    function payOut(address asset, address to, uint256 amount) external;

    // ---- views ----
    /// @notice The fee, equity and IM `mintExternalLong` would produce now. `ok` = data fresh, series active, product
    ///         not close-only, cash covers the fee and the account stays healthy (it does not check open-interest
    ///         caps or position limits, which depend on the post-mint ledger).
    function previewMint(uint256 accountId, bytes32 seriesId, uint256 qty)
        external
        view
        returns (uint256 fee, int256 equityAfter, uint256 imAfter, bool ok);
    function modules() external view returns (Modules memory);
}
