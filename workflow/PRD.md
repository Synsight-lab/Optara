# Product Requirements Document

## Product Summary

This project is a Monad-native options protocol that creates fully collateralized European options and lists the resulting ERC-20 option tokens on Kuru for secondary trading.

Each option series is immutable after deployment. A series defines:

- Option type: call or put.
- Underlying asset.
- Quote asset.
- Strike price.
- Expiry timestamp.
- Settlement oracle.
- Contract size.
- Collateral asset and collateral formula.
- Option token metadata.

For V1, Kuru is not an options engine. Kuru is a venue where ERC-20 option tokens can trade against a quote token. The options protocol owns the lifecycle, collateral accounting, settlement, and redemption logic.

See [main-goal.md](./main-goal.md) for the project objective and [architectural.md](./architectural.md) for the system design.

For production implementation, use [implementation-spec.md](./implementation-spec.md), [contract-interfaces.md](./contract-interfaces.md), [storage-layout.md](./storage-layout.md), [state-machine.md](./state-machine.md), [oracle-spec.md](./oracle-spec.md), [premium-pricing-spec.md](./premium-pricing-spec.md), [kuru-integration-spec.md](./kuru-integration-spec.md), [security-threat-model.md](./security-threat-model.md), [testing-and-invariants.md](./testing-and-invariants.md), [deployment-runbook.md](./deployment-runbook.md), [production-checklist.md](./production-checklist.md), and [founder-decisions.md](./founder-decisions.md).

## Problem

Users need a way to create and trade options on Monad without relying on an order book to enforce option solvency. If option settlement depends on market trading behavior, a malicious buyer or seller could attempt to manipulate prices, create fake liquidity, wash trade, exploit precision settings, or use venue-specific behavior to extract collateral from the system.

The protocol solves this by separating responsibilities:

- The options protocol guarantees collateral and settlement.
- Kuru provides secondary-market trading.
- The oracle provides the independent expiry price.
- The canonical factory and registry define which series are real.

## Target Users

### Writers

Writers deposit collateral, mint option tokens, and may sell those tokens on Kuru or transfer them elsewhere. Writers retain a short position and can withdraw residual collateral only after settlement and after their obligations are accounted for.

### Buyers and Traders

Buyers acquire option tokens and hold them through expiry or sell them before expiry. After settlement, token holders can redeem the option token for the final payout.

### Liquidity Providers and Market Makers

Market makers quote option tokens on Kuru. They must manage liquidity, inventory, and pricing risk themselves. The protocol does not guarantee Kuru liquidity or fair market pricing.

### Keepers

Keepers trigger settlement after expiry once the oracle price is available. Keeper actions must be permissionless where possible and must not allow the keeper to influence the settlement price.

### Integrators

Frontends, indexers, wallets, and analytics tools use the canonical registry to discover official series and use Kuru events to display secondary-market activity.

## V1 Requirements

### Series Creation

The protocol must allow creation of new option series through a canonical factory.

In V1 creation is restricted to `SERIES_CREATOR_ROLE` rather than permissionless. Series name and symbol sit outside the series identifier and are permanent once set, so open creation would let anyone claim the metadata for every popular strike and expiry irreversibly. See FD-22.

Required inputs:

- `optionType`: call or put.
- `underlyingAsset`: ERC-20 asset used as the underlying.
- `quoteAsset`: ERC-20 asset used to denominate strike and Kuru trading.
- `strikePrice`: human price of one whole underlying in whole quote, times `PRICE_SCALE`.
- `expiry`: timestamp when the option stops trading as an unsettled claim and becomes eligible for settlement.
- `oracleConfig`: approved oracle configuration for the underlying/quote pair, covering feeds, thresholds, and which sources are required.
- `contractSize`: underlying raw units represented by one whole option token.
- `optionDecimals` and `minOptionAmount`.
- `name` and `symbol` for the option token.
- Optional Kuru market parameters if the creator also wants to deploy the market.

The caller supplies exactly this set and nothing else. Series identity, collateral asset, derived scales, and fee rates are computed or snapshotted by the factory. A caller must never be able to choose them; see [implementation-spec.md](./implementation-spec.md).

Acceptance criteria:

- Series parameters are immutable after deployment.
- Series are registered in the canonical registry.
- Duplicate series are either rejected or deterministically resolved to the same canonical series.
- Expiry must be in the future at creation.
- Strike, contract size, and precision values must be nonzero.
- Assets and oracle configs must pass protocol validation.
- Snapshotted fee rates must be within the hard caps.
- Derived values must match their formulas for the series' decimal pair.

### Option Token

Each series must expose an ERC-20 option token.

Acceptance criteria:

- The option token represents a long claim on exactly one immutable series.
- Token balances are freely transferable before settlement unless the series is paused for emergency reasons.
- The token is burnable only through protocol-approved flows, such as post-settlement redemption.
- Token metadata must make fake-series risk easier to detect, but metadata must not be the source of truth. The registry is the source of truth.

### Minting

Writers must deposit collateral before option tokens are minted.

Acceptance criteria:

- Calls are collateralized by the underlying asset.
- Puts are collateralized by the quote asset.
- Minting must calculate required collateral using conservative rounding.
- The minted option amount must be greater than or equal to the series minimum amount.
- Minting must not be possible after expiry.
- Minting must update writer obligation accounting atomically with token minting.

### Kuru Market Integration

The protocol should support creating or linking a Kuru market for each option token against the quote asset.

Expected Kuru usage:

- Base asset: option token.
- Quote asset: quote asset, such as USDC.
- Market type: ERC-20 against ERC-20 when both assets are ERC-20s.
- Router function: Kuru Router market deployment, such as `deployProxy`, or the SDK helper wrapping it.
- OrderBook: secondary trading only.

Acceptance criteria:

- The protocol must not read Kuru prices for settlement.
- The protocol must not give Kuru permission to withdraw collateral from option vaults.
- Kuru market address can be stored as metadata in the registry.
- If Kuru is unavailable or paused, option settlement and redemption must still work.
- Precision settings must be chosen carefully to avoid zero-size orders, unusable ticks, or misleading market depth.

### Premium Pricing and Execution

The option premium is the price paid to acquire an option token before settlement. In V1, premium is not set by the option vault, the factory, or governance. Premium is discovered through voluntary trading, primarily on the Kuru market for `optionToken / quoteAsset`.

The writer may post an ask price. The buyer may post a bid price or submit a marketable order with an explicit maximum premium. A trade clears only if both sides agree through the market mechanism. The writer's ask is allowed as an offer, but it must not be treated as automatically fair, reasonable, or safe.

For a filled order, the realized premium is derived from actual fills on the canonical Kuru market:

```text
totalPremiumPaid = sum(fillOptionAmount_i * fillPrice_i)
realizedPremiumPerOption = totalPremiumPaid / totalOptionAmountReceived
```

The frontend may preview this from current order-book depth, but the transaction must still enforce the buyer's submitted maximum premium at execution time.

### Premium Acceptable Range

Official frontends, mint-and-list helpers, routed-buy helpers, and any protocol-controlled primary-sale flow should classify each writer ask against a premium safety range before routing buyers into it.

The range has two layers:

- Hard economic bounds derived from the approved current reference price for the underlying/quote pair, strike, option type, collateral model, and maximum possible payout.
- Market-health bounds derived from canonical Kuru order-book depth, spread, recent volume, quote age, and price impact.

For V1, the hard bounds are safety rails, not a complete options pricing model:

- A call premium should not be above the current quote value of the maximum underlying payout.
- A put premium should not be above the maximum quote payout at strike.
- A call or put ask below current intrinsic value should be treated as a seller-loss warning or blocked in protocol-controlled listing helpers.
- The range should include configurable tolerance for fees, spread, and oracle/reference latency.

If the ask is above the acceptable maximum, a one-click buyer route must not fill it. If the ask is below the acceptable minimum, the system should warn or reject the listing helper because the seller may be giving away value accidentally or through a manipulated flow.

If Kuru market data is too thin, stale, or inconsistent to support the market-health layer, simplified routing must fail closed or fall back to explicit manual limit-order UX. A single last-traded price must never define the range.

Acceptance criteria:

- The protocol must not store a writer-controlled `maxPremium` as a series parameter that bypasses range checks.
- The protocol must not require buyers to pay a premium chosen by the collateral owner without buyer-side limits and range validation.
- Writers can specify an ask premium, but official listing helpers and simplified routes must reject, disable, or clearly flag asks outside the acceptable range.
- Any one-click buy, routed buy, auction, or primary-sale helper must require buyer-provided price protection: `buyerMaxTotalPremium`, `minOptionAmountOut`, and `deadline`. The cost limit binds on the fee-inclusive all-in total, never on a per-option figure.
- If an execution route cannot satisfy the buyer's limits, the transaction must fail safely instead of filling at a manipulated or unexpected price.
- If an execution route cannot validate that the ask is inside the acceptable premium range, the transaction must fail safely or require manual limit-order execution.
- Premium quotes shown by frontends must be labeled as market quotes, not guaranteed fair value.
- Premium quotes must never affect collateral requirements, settlement price, redemption payout, or writer residual withdrawal.
- Frontends should warn when a displayed premium is based on thin liquidity, wide spread, stale market data, or low recent volume.
- Frontends should warn when the premium is above a conservative reference bound, such as the current oracle-implied maximum payout estimate, while making clear that this warning is not settlement logic.

Recommended safe-fail controls:

- Use Kuru limit orders for advanced users wherever possible.
- For simplified purchase flows, require explicit buyer-side limits and deadlines.
- Refuse automatic market buys when spread, depth, age of quote, or price impact exceeds configured thresholds.
- Refuse automatic fills against writer asks above the acceptable maximum premium.
- Warn or block protocol-controlled listings where the writer ask is below current intrinsic value or below a configured acceptable minimum.
- Do not use a single last-traded price as a fair premium.
- Do not auto-fill from a Kuru market that is not linked to the canonical series in the registry.
- If optional reference pricing is used, use it only as a UI or route-safety guard, not as protocol settlement.

### Protocol Fees

Optara charges protocol fees in V1. The full specification is in [fee-spec.md](./fee-spec.md).

Fee types:

- **Mint fee**, charged on the required collateral at mint, paid by the writer on top of collateral.
- **Exercise fee**, charged on gross payout at redemption, paid by the holder, and only on in-the-money redemptions.

No fee is charged on writer residual claims: the writer already paid at mint.

Acceptance criteria:

- No fee may be taken from collateral backing outstanding option claims.
- Mint fees are additive to required collateral, never deducted from it.
- Exercise fees are carved from an already-computed gross payout; the amount leaving `collateralLocked` is unchanged by the fee.
- Accrued fees are held in a balance strictly segregated from collateral, and no role can move collateral.
- Fee rates are snapshotted into a series at creation and are immutable for that series' life.
- Governance fee changes apply only to series created afterward.
- Hard fee caps are compile-time constants that governance cannot exceed.
- Every fee-bearing action emits the fee as a separate event field.
- With all fee rates set to zero, protocol behavior is bit-identical to a no-fee implementation.

### Venue Fees

Kuru charges its own maker and taker fees, which Optara never receives and never attempts to capture or rebate.

Acceptance criteria:

- Every premium quote, acceptable-range check, and buyer limit uses the fee-inclusive all-in cost, not the gross premium.
- Seller-side checks use proceeds net of the maker fee.
- Depth-walked estimates include taker fee and AMM spread.
- A market whose venue fees exceed the configured maximum is not linkable as canonical.
- Kuru's taker-fee convention is verified against deployed contracts before launch, with both conventions defended against until then.
- Frontends show protocol fee and venue fee as separate line items, never blended into one number.

### Trading

Trading happens by transferring the ERC-20 option token directly or by using Kuru.

Acceptance criteria:

- A Kuru trade changes option token ownership only.
- A Kuru trade does not change strike, expiry, oracle, collateral, settlement status, or vault accounting.
- Wash trades, spoofed orders, thin liquidity, or manipulated option market prices cannot increase vault payouts.
- Wash trades, spoofed orders, thin liquidity, or manipulated option market prices cannot force a buyer to pay more than their submitted maximum premium.
- Frontends must show liquidity risk clearly because the protocol cannot guarantee an exit before expiry.

### Settlement

Settlement must be oracle-based and independent of Kuru.

V1 oracle model:

- Primary: Chainlink if a feed exists for the pair.
- Secondary/corroborator: Pyth if a feed exists for the pair.
- Kuru: never settlement; only premium execution and depth sanity.

Acceptance criteria:

- Settlement can only occur at or after expiry.
- The settlement price must come from `OracleRouter`, using the series' frozen oracle configuration.
- The settlement price must be the first oracle observation at or after expiry, proven onchain, so that it does not depend on when settlement is called.
- Settlement must produce the same price whether it is called minutes or months after expiry.
- The oracle price must be positive, fresh for the settlement window, and valid for the underlying/quote pair.
- Once settlement succeeds, the settlement price and payout ratios are final.
- Settlement must be idempotent. Calling settlement again must not change the result.
- If the oracle is stale, missing, or disputed, settlement must fail safely or enter a defined recovery path.

### Redemption

After settlement, option token holders can redeem.

Acceptance criteria:

- Redemption burns or marks the option tokens before transferring collateral.
- A holder cannot redeem the same option amount twice.
- Payout must follow the formulas in [math-of-core-invariants.md](./math-of-core-invariants.md).
- Payout must be rounded conservatively so total payouts never exceed locked collateral.
- Redemption must work regardless of where the option token was acquired.

### Writer Residual Withdrawal

After settlement, writers can withdraw remaining collateral.

Acceptance criteria:

- Writers cannot withdraw collateral before settlement except through explicitly supported pre-expiry close flows. V1 should avoid close flows unless they can preserve all invariants.
- Writer withdrawals must be proportional to their short obligation amount.
- Writer residual claims must account for buyer payoff first.
- Writer residual withdrawal must not depend on Kuru liquidity or Kuru market state.

### Registry and Discovery

The registry is the canonical source of truth for official option series.

Acceptance criteria:

- The registry maps deterministic series identifiers to deployed series vaults.
- The registry exposes all immutable series parameters.
- The registry can store the associated Kuru market address.
- Frontends must verify series through the registry, not through token symbol or name.
- Fake tokens using similar symbols must not pass canonical registry checks.

## Non-Functional Requirements

### Security

The protocol must defend against:

- Undercollateralized minting.
- Double redemption.
- Early exercise.
- Reentrancy through ERC-20 calls.
- Oracle manipulation or stale oracle data.
- Fake option series.
- Kuru price manipulation.
- Premium price manipulation.
- Kuru downtime, pauses, upgrades, or parameter mistakes.
- Rounding and precision extraction.
- Min-size dust attacks.
- Settlement lifecycle race conditions.

Security requirements:

- Use checks-effects-interactions.
- Use reentrancy protection on state-changing external functions.
- Prefer allowlisted assets and oracle adapters for V1.
- Use safe token transfer wrappers.
- Store settlement results once and never recompute mutable outcomes after settlement.
- Emit events for all critical lifecycle changes.
- Include invariant, fuzz, and state-machine tests.

### Reliability

- Settlement and redemption must remain available even if no Kuru market exists.
- Keeper actions should be permissionless.
- Emergency pause may stop minting and market-linking, but should avoid blocking valid post-settlement redemptions unless required to prevent active loss.

### Usability

- Users must be able to identify option type, underlying, quote, strike, expiry, and canonical status.
- Frontends should display collateral type and settlement style.
- Frontends should warn that Kuru liquidity is not guaranteed.
- Frontends should distinguish option market price from settlement oracle price.
- Frontends should show the buyer's maximum premium, expected executable premium, spread, depth, price impact, and quote age before any simplified buy.

## Risk Register

| Risk | Description | Required Mitigation |
|---|---|---|
| Undercollateralization | Writer mints more options than collateral can cover. | Require full collateral before minting. Use formulas in [math-of-core-invariants.md](./math-of-core-invariants.md). |
| Double redemption | Holder claims payout multiple times. | Burn or mark redeemed amount before transfer. |
| Oracle manipulation | Expiry price is manipulated. | Chainlink/Pyth quorum, deviation checks, expiry-anchored observation, fail-closed settlement, and the FD-20 recovery decision. |
| Settlement timing | Caller picks a favorable post-expiry moment to settle. | Price anchored to the first observation at or after expiry and proven onchain, so the result is identical whenever settlement is called. |
| Kuru price manipulation | Wash trades create fake option prices. | Never use Kuru prices for settlement or collateral. |
| Premium price manipulation | Thin liquidity, spoofing, wash trades, or unrealistic writer asks make the option premium look fair or force a bad execution route. | Use buyer-specified max premium, acceptable premium ranges, hard economic bounds, slippage limits, deadlines, depth checks, spread checks, stale-quote checks, and fail-closed routing. |
| Fake series | Malicious token mimics official option symbol. | Canonical factory and registry checks. |
| Liquidity risk | User cannot exit position before expiry. | UI disclosure and no reliance on liquidity for settlement. |
| Rounding extraction | Tiny mints or redemptions accumulate favorable dust. | Round collateral up, payout down, enforce minimum amounts. |
| Reentrancy | Token callbacks or malicious assets re-enter vault functions. | Reentrancy guards, CEI, asset allowlist. |
| Kuru dependency | Kuru market is paused, upgraded, or unavailable. | Keep settlement independent from Kuru. |
| Precision mismatch | Kuru `sizePrecision`, `pricePrecision`, or tick settings make market unusable. | Validate market parameters and document deployment guidance. |
| Expiry race | Transactions around expiry enter wrong lifecycle. | Explicit state machine and timestamp checks. |

## V1 Launch Checklist

- Core contracts implemented.
- Canonical factory and registry implemented.
- Oracle adapter implemented and reviewed.
- Kuru market deployment path tested.
- Premium execution tested with buyer max price, acceptable premium range, unrealistic high ask, unrealistic low ask, slippage, deadline, stale quote, wide spread, and thin liquidity cases.
- Settlement formulas tested with edge cases.
- Fuzz tests for mint, settle, redeem, and withdraw.
- Reentrancy tests with malicious ERC-20 tokens.
- Fake-series UI and registry validation tested.
- Precision and minimum-size tests for small amounts.
- Emergency pause behavior tested.
- External security review completed.
