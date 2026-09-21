# User Flow

## Actors

### Series Creator

Creates a new option series through the canonical factory.

### Writer

Deposits collateral, mints option tokens, and keeps the corresponding short obligation.

### Buyer or Trader

Receives or buys option tokens, holds them, sells them, or redeems them after settlement.

### Keeper

Calls settlement after expiry when the oracle price is available.

### Integrator

Builds a frontend, indexer, wallet view, market maker, or analytics tool using the registry, option vaults, and Kuru markets.

## Flow 1: Create a Series

1. Series creator selects option type, underlying, quote, strike, expiry, oracle, and contract size.
2. Frontend validates that the assets are allowlisted and that the oracle config is approved **for this exact pair**.
3. Creator submits the series creation transaction to `OptionSeriesFactory`.
4. Factory validates parameters.
5. Factory deploys `OptionSeriesVault`.
6. Factory registers the series in `SeriesRegistry`.
7. Registry exposes the canonical series address and immutable parameters.

User-facing result:

- A new official option series exists.
- No option tokens exist yet.
- The series can now accept fully collateralized minting before expiry.

Security checks:

- Expiry is in the future.
- Strike and contract size are nonzero.
- The oracle config is approved for this exact underlying/quote pair.
- The series is canonical and discoverable.

## Flow 2: Link or Deploy a Kuru Market

1. Creator or integrator selects the option token as base asset.
2. Creator or integrator selects the quote token as quote asset.
3. Kuru market parameters are calculated and reviewed.
4. Kuru Router deploys the market, or an existing valid market is linked.
5. Registry stores the Kuru market address as metadata.

User-facing result:

- Traders can find the Kuru market for the option token.
- The market may have no liquidity until users provide it.

Security checks:

- Kuru market base asset matches the official option token.
- Kuru market quote asset matches the series quote asset.
- Kuru market parameters do not create unusable precision or dust behavior.
- Kuru is not granted authority over option collateral.

## Flow 3: Writer Mints Options

1. Writer opens the official series page.
2. Frontend shows collateral asset, required collateral, strike, expiry, and risks.
3. Writer approves the collateral asset for the required collateral plus the mint fee.
4. Writer calls `mint(amount, receiver)`.
5. Vault transfers collateral plus mint fee from writer, accruing the fee separately from collateral.
6. Vault records writer short obligation.
7. Vault mints ERC-20 option tokens to writer.

User-facing result:

- Writer owns option tokens that can be sold or transferred.
- Writer also has a short obligation recorded in the vault.
- Writer cannot withdraw locked collateral until after settlement in the basic V1 flow.

Security checks:

- Minting occurs before expiry.
- Required collateral is rounded up.
- Mint amount is above minimum size.
- Mint does not push open interest past the series cap, where one is set.
- State updates and token minting are atomic.

## Flow 4: Writer Sells on Kuru

1. Writer goes to the Kuru market linked in the registry.
2. Writer places a sell order or provides liquidity at an ask price they are willing to accept.
3. Official helper or frontend classifies the ask against the acceptable premium range.
4. Buyer fills the order using the quote asset only if the ask is inside the range and the price satisfies the buyer's own limit.
5. Kuru transfers option tokens from seller to buyer according to its market rules.

User-facing result:

- Buyer owns the option token.
- Writer receives quote asset from the trade.
- Vault collateral accounting is unchanged.
- The executed premium is the market-clearing trade price, not a protocol-set price.

Security checks:

- Kuru trade does not alter series parameters.
- Kuru trade does not alter settlement price.
- Kuru trade does not release collateral.
- Writer ask price is not treated as fair value or a protocol maximum premium.
- Writer ask price must be inside the acceptable premium range for official routed execution.
- Buyer cannot be routed into paying above their submitted maximum total cost, which includes Kuru's taker fee.

## Flow 4A: Premium Safety for One-Click Buying

1. Buyer selects an official option series.
2. Frontend verifies the series and Kuru market through the registry.
3. Frontend computes or fetches the acceptable premium range from hard economic bounds and market-health data.
4. Frontend shows current executable premium, acceptable range, spread, liquidity depth, price impact, and quote age.
5. Buyer submits a maximum total all-in cost, a minimum option amount out, and a deadline.
6. Route checks canonical market, acceptable range, buyer limits, quote age, spread, depth, and price impact.
7. If every check passes and the deadline has not passed, the frontend submits the Kuru trade with Kuru-native limit price and minimum output. Kuru-native deadline protection is used only if FD-17 verifies support for the exact order type.
8. If Layer 1 buyer limits fail, the Kuru transaction reverts. If Layer 2 acceptable-range or market-health checks fail, the official UI refuses the simplified route before submission.

User-facing result:

- Buyer decides the maximum total cost they are willing to pay, fees included.
- Collateral owner can specify an ask, but cannot force an out-of-range premium through official routes.
- Unsafe market conditions fail closed.
- The hard buyer execution limit comes from Kuru's own limit-order parameters. Optara's acceptable-range checks are enforced by the official frontend and do not bind a user trading directly against Kuru.

Security checks:

- Do not use last-traded price as fair value.
- Do not execute against non-canonical markets.
- Do not execute stale quotes.
- Do not execute if spread or price impact exceeds configured limits.
- Do not execute if writer ask is outside the acceptable premium range.
- Do not use premium price for settlement, collateral, or payout.

## Flow 5: Buyer Holds or Trades Before Expiry

1. Buyer can hold the option token.
2. Buyer can transfer it to another wallet.
3. Buyer can sell it on Kuru if liquidity exists.

User-facing result:

- The current token holder owns the post-settlement redemption claim.
- There is no early exercise in V1.

Risks shown to user:

- Kuru liquidity may be thin or unavailable.
- Option market price may differ from theoretical value.
- The final payoff depends on the settlement oracle, not Kuru trading price.

## Flow 6: Expiry

1. Chain timestamp reaches expiry.
2. New minting is disabled.
3. Series waits for settlement.

User-facing result:

- The option is no longer mintable.
- The option is not yet redeemable until settlement succeeds.

Security checks:

- No transaction at or after expiry can mint new options.
- No redemption can occur before settlement.

## Flow 7: Settlement

1. Keeper or any user waits until Chainlink has published a round after expiry, then assembles a `SettlementProof` naming the Chainlink round in force at expiry and its immediate successor, plus the Pyth update at or after expiry.
2. They call `settle(proof)`, sending enough native token to cover any Pyth update fee.
3. Vault checks that expiry has passed and that settlement is not paused.
4. Vault asks `OracleRouter` for the settlement price, passing only `seriesId` and the proof.
5. Router reads the series' frozen oracle config from the registry and queries the adapters.
6. Adapters verify the proof against the source and return normalized prices; the router applies quorum and deviation policy.
7. Vault computes payout and residual rates and stores the result permanently.
8. Vault refunds unused native token and emits `SeriesSettled`.

User-facing result:

- The final option payout is known.
- Buyers can redeem.
- Writers can claim residual collateral.

Security checks:

- Settlement cannot use Kuru prices.
- Settlement cannot be called twice with different prices.
- Invalid oracle data does not finalize the series.
- The settlement price is the expiry price, not the price when settle happened to be called. Settling minutes after expiry and settling months after produce the same result, so no one gains by waiting for a favorable move.
- A proof naming any round other than the one in force at expiry is rejected.

## Flow 8: Buyer Redeems

1. Buyer calls `redeem(amount, receiver)` after settlement. Any nonzero amount is accepted; the series minimum applies to minting only.
2. Vault calculates gross payout using the stored payout rate, then the exercise fee and net payout.
3. Vault burns the buyer's option tokens or records the redeemed amount.
4. Vault transfers payout collateral to buyer.
5. Vault emits `OptionsRedeemed`.

User-facing result:

- Buyer receives the correct payout asset.
- Buyer's option token balance decreases by the redeemed amount.

Security checks:

- Buyer cannot redeem more than their token balance.
- Buyer cannot redeem the same tokens twice.
- Payout is rounded down to protect solvency.
- State changes happen before external transfers.

## Flow 9: Writer Claims Residual Collateral

1. Writer calls `claimWriterResidual(shortAmount, receiver)` after settlement.
2. Vault calculates residual collateral from the stored residual rate. No fee is charged on writer residual claims in V1.
3. Vault reduces writer claimable short balance.
4. Vault transfers residual collateral to writer.
5. Vault emits `WriterResidualClaimed`.

User-facing result:

- Writer receives collateral that was not owed to option holders.
- Writer's short obligation is reduced or closed.

Security checks:

- Writer cannot claim before settlement.
- Writer cannot claim more short amount than recorded.
- Buyer payout remains protected.

## Flow 10: Oracle Failure or Missing Anchor

1. Keeper calls `settle()`.
2. Oracle adapter or router rejects the proof because the required anchored observation is missing, too stale, too late, zero, incomplete, or otherwise invalid.
3. Settlement reverts or enters a predefined unresolved state.

User-facing result:

- No final settlement result is written.
- Buyers and writers must wait for valid oracle data or governance-defined recovery.

Security checks:

- The protocol must not fall back to Kuru market prices.
- The protocol must not let writers withdraw as if options expired worthless.
- Recovery must be explicit, reviewed, and evented.

## Flow 11: Fake Series Protection

1. User sees an option-like token or Kuru market.
2. Frontend checks the token against `SeriesRegistry`.
3. If the token is not registered, the frontend marks it as unofficial.

User-facing result:

- Users can distinguish official series from lookalike tokens.

Security checks:

- Token symbol is not trusted.
- Kuru listing is not trusted.
- Registry status is the source of truth.

## Flow 12: Kuru Market Failure

Possible failures:

- Kuru market is paused.
- Kuru Router changes future implementations.
- Kuru market has no liquidity.
- Kuru precision settings make trading awkward.
- Kuru indexer is unavailable.

Expected behavior:

- Minting remains governed by the option vault.
- Settlement remains governed by the oracle.
- Redemption remains available after settlement.
- Writer residual withdrawal remains available after settlement.

User-facing result:

- Users may lose secondary-market liquidity, but they do not lose the protocol-level claim represented by the option token.

## Frontend Flow Requirements

Every official series page should show:

- Canonical registry status.
- Option type.
- Underlying asset.
- Quote asset.
- Collateral asset.
- Strike price.
- Expiry.
- Settlement status.
- Oracle source.
- Kuru market link if available.
- This series' protocol fee rates, which are fixed for its life.
- Warning that Kuru market price is not settlement price.
- Warning that liquidity is not guaranteed.

Before minting, show:

- Required collateral.
- Mint fee, as a separate line item.
- Total the writer will pay, being collateral plus fee.
- Maximum liability.
- Writer cannot withdraw collateral before settlement in V1.

Before buying, show:

- Current Kuru market price.
- Executable premium for the intended size, not only the last-traded price.
- Kuru taker fee, as a separate line item.
- All-in cost, being premium plus venue fee, which is what the buyer's limit binds on.
- Acceptable premium range and whether the fee-inclusive cost is inside it.
- Buyer's maximum total cost setting.
- Spread, depth, price impact, and quote age.
- Expiry.
- Settlement oracle.
- Potential payout asset.
- Exercise fee rate that will apply if the option finishes in the money.
- Liquidity risk.
- Warning if the premium appears high relative to a conservative oracle-based reference estimate.

Before posting an ask, show:

- Gross ask.
- Kuru maker-side fee or rebate.
- Net proceeds, which is what the seller-protection check uses.

After settlement, show:

- Settlement price.
- Gross payout per option.
- Exercise fee and net payout per option.
- Residual per short unit.
- Redeem action for holders.
- Claim residual action for writers.

Fee display rules:

- Protocol fees and Kuru venue fees must always be shown as separate line items, never blended into a single number, because they are charged by different parties for different reasons.
- Never present Optara's acceptable-premium range as a guarantee. The official UI enforces it; the protocol does not, and a user trading directly against Kuru is not covered by it.
