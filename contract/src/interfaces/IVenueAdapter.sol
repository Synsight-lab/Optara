// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVenueAdapter
/// @notice One external venue behind VenueRouter (docs/VENUES_AND_KURU.md §4). Buys are exact-in: the router hands
///         the adapter `premiumIn` of the quote token and the adapter spends at most that (DD-33). Adapters are called
///         only by the router, hold tokens only during a call, and send every output and leftover to `recipient`
///         (the router), which measures what it received itself.
interface IVenueAdapter {
    function venueId() external view returns (bytes32);
    /// @notice The venue's own record of a market's base and quote tokens (never the caller's word).
    function marketTokens(address market) external view returns (address base, address quote);
    /// @notice Venue fee for a buy spending `premiumIn` (in the quote token).
    function quoteBuy(address market, uint256 premiumIn) external view returns (uint256 venueFee);
    /// @notice Venue fee for a sell of `qty` base, expressed in the quote token at `proceeds`.
    function quoteSell(address market, uint256 proceeds) external view returns (uint256 venueFee);
    /// @notice Spends up to `premiumIn` (already transferred to the adapter) on the market; sends the bought base and
    ///         any unspent quote to `recipient`.
    function buy(address market, uint256 premiumIn, uint256 maxVenueFee, address recipient, bytes calldata data)
        external
        returns (uint256 premiumSpent, uint256 venueFee);
    /// @notice Sells up to `qty` base (already transferred to the adapter); sends the proceeds and any unsold base to
    ///         `recipient`.
    function sell(address market, uint256 qty, uint256 maxVenueFee, address recipient, bytes calldata data)
        external
        returns (uint256 qtySold, uint256 venueFee);
}
